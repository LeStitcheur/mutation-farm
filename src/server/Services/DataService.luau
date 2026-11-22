--!strict
-- DataService — persistance des profils joueurs (docs/ARCHITECTURE.md §7).
-- Garanties :
--   * verrou de session via UpdateAsync : un seul serveur écrit un profil ;
--   * jamais de jeu ni d'écriture sans chargement réussi ;
--   * copie profonde + validation JSON avant chaque écriture ;
--   * autosave étalée, sauvegarde finale au départ et à l'arrêt (BindToClose).
-- API : GetData, IsLoaded, Update, SaveNow, IsMemoryStore.
-- Signaux : ProfileLoaded(player, data), ProfileReleasing(player, data), Changed(player, data).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Types = require(Shared.Types)
local DataSchema = require(Shared.Util.DataSchema)
local Deep = require(Shared.Util.Deep)
local SessionLock = require(Shared.Util.SessionLock)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)
local DataStoreAdapter = require(script.Parent.Parent.Infra.DataStoreAdapter)

type PlayerData = Types.PlayerData

type Profile = {
	player: Player,
	key: string,
	data: PlayerData,
	lost: boolean,
	released: boolean,
	saving: boolean,
	sessionClock: number,
}

type AcquireOutcome = "ok" | "locked" | "error"

local Config = GameConfig.Data
local SESSION_ID = HttpService:GenerateGUID(false)

local profiles: { [Player]: Profile } = {}
local loading: { [Player]: boolean } = {}
-- Étapes de chargement (Phase 5 : production hors ligne) : appliquées à la donnée chargée AVANT qu'elle ne devienne
-- vivante (aucun autre code ne peut encore la lire ni la modifier) ; elles peuvent céder la main.
local loadSteps: { (Player, PlayerData) -> PlayerData? } = {}
local store: DataStoreAdapter.Store? = nil
local shuttingDown = false
-- UserId dont la sauvegarde finale est en cours : un rejoin rapide sur CE serveur attend sa fin,
-- sinon il relirait une donnée antérieure (le verrou porte notre propre SESSION_ID).
local releasing: { [number]: boolean } = {}

local DataService = {
	ProfileLoaded = Signal.new() :: Signal.Signal<Player, PlayerData>,
	ProfileReleasing = Signal.new() :: Signal.Signal<Player, PlayerData>,
	Changed = Signal.new() :: Signal.Signal<Player, PlayerData>,
}

local function getStore(): DataStoreAdapter.Store
	return assert(store, "DataService : Start() n'a pas été appelé")
end

local function keyFor(player: Player): string
	return Config.KeyPrefix .. tostring(player.UserId)
end

local function sendStatus(player: Player, status: Types.LoadStatusKind, message: string)
	local payload: Types.LoadStatus = { status = status, message = message }
	Net.event(Net.Events.LoadStatus):FireClient(player, payload)
end

-- Tente d'acquérir le verrou de session et retourne la donnée brute stockée.
local function tryAcquire(key: string): (AcquireOutcome, any)
	local now = os.time()
	local outcome: AcquireOutcome = "error"
	local loaded: any = nil
	local ok, err = pcall(function()
		getStore().update(key, function(old: any): any
			-- Verrou actif d'un autre serveur : "locked" et aucune écriture (record = nil).
			-- Annotation explicite : sans elle, l'inférence élargit l'union de littéraux en `string`.
			local result: SessionLock.AcquireOutcome, record: any, data: any =
				SessionLock.acquire(old, SESSION_ID, now, Config.LockTimeout, Config.RecordFormat)
			outcome = result
			loaded = data
			return record
		end)
	end)
	if not ok then
		return "error", err
	end
	return outcome, loaded
end

-- Libère notre verrou sans modifier la donnée (ex. version future refusée).
local function releaseLockOnly(key: string)
	local ok, err = pcall(function()
		getStore().update(key, function(old: any): any
			return SessionLock.release(old, SESSION_ID)
		end)
	end)
	if not ok then
		warn(string.format("[DataService] Libération du verrou %s impossible : %s", key, tostring(err)))
	end
end

local function accumulatePlayTime(profile: Profile)
	local now = os.clock()
	profile.data.stats.playTime += now - profile.sessionClock
	profile.sessionClock = now
end

-- Écrit le profil. `release` = sauvegarde finale (libère le verrou, 3 tentatives).
local function writeProfile(profile: Profile, release: boolean): boolean
	if profile.lost then
		return false
	end
	if profile.released then
		return true
	end
	accumulatePlayTime(profile)
	local now = os.time()
	local snapshot = Deep.copy(profile.data)
	-- Horloge serveur synchronisée (comme plantedAt) : la production hors ligne compare ces deux horodatages
	-- (Phase 5, revue : os.time() entier pouvait décaler la fenêtre d'une seconde). Le verrou garde os.time().
	snapshot.meta.lastSeen = Workspace:GetServerTimeNow()
	local valid, reason = DataSchema.validate(snapshot)
	if not valid then
		warn(
			string.format(
				"[DataService] Donnée invalide pour %s, écriture annulée : %s",
				profile.key,
				tostring(reason)
			)
		)
		return false
	end

	local attempts = if release then Config.SaveRetries else 1
	for attempt = 1, attempts do
		local lost = false
		local ok, err = pcall(function()
			getStore().update(profile.key, function(old: any): any
				-- nil : le verrou appartient à quelqu'un d'autre, on n'écrase jamais.
				local record = SessionLock.write(old, SESSION_ID, snapshot, release, now, Config.RecordFormat)
				lost = record == nil
				return record
			end)
		end)
		if ok then
			if lost then
				profile.lost = true
				warn(string.format("[DataService] Verrou perdu pour %s : profil gelé, aucune écriture.", profile.key))
				return false
			end
			if release then
				profile.released = true
			end
			return true
		end
		warn(
			string.format(
				"[DataService] Échec de sauvegarde %s (tentative %d/%d) : %s",
				profile.key,
				attempt,
				attempts,
				tostring(err)
			)
		)
		if attempt < attempts then
			task.wait(2 ^ attempt)
		end
	end
	return false
end

local function kickLost(player: Player)
	if player.Parent == Players then
		player:Kick("Ta partie a été ouverte sur un autre serveur. Reconnecte-toi pour continuer.")
	end
end

local function loadProfile(player: Player)
	if loading[player] or profiles[player] then
		return
	end
	loading[player] = true
	local key = keyFor(player)
	local started = os.clock()
	local attempt = 0
	sendStatus(player, "loading", "Chargement de ta ferme…")

	while releasing[player.UserId] and player.Parent == Players and os.clock() - started < Config.LoadMaxWait do
		task.wait(0.2)
	end

	while true do
		if player.Parent ~= Players or shuttingDown or releasing[player.UserId] then
			break -- parti avant l'acquisition : aucun verrou pris
		end
		attempt += 1
		local outcome, payload = tryAcquire(key)
		if outcome == "ok" then
			local data, loadError, notes = DataSchema.load(payload, os.time())
			if not data then
				releaseLockOnly(key)
				warn(string.format("[DataService] Chargement refusé pour %s : %s", key, tostring(loadError)))
				sendStatus(player, "failed", "Ce serveur n'est pas à jour.")
				player:Kick("Une nouvelle version du jeu est disponible : rejoins un autre serveur.")
				break
			end
			for _, note in notes do
				warn(string.format("[DataService] %s : %s", key, note))
			end
			-- Étapes de chargement : une étape qui échoue est ignorée (la donnée d'avant est gardée, rien n'est perdu).
			for _, step in loadSteps do
				local ok, result = pcall(step, player, data)
				if ok and result ~= nil then
					data = result
				elseif not ok then
					warn(
						string.format(
							"[DataService] Étape de chargement en erreur pour %s : %s",
							key,
							tostring(result)
						)
					)
				end
			end
			local profile: Profile = {
				player = player,
				key = key,
				data = data,
				lost = false,
				released = false,
				saving = false,
				sessionClock = os.clock(),
			}
			if player.Parent ~= Players or shuttingDown then
				-- parti pendant le chargement, ou arrêt du serveur déjà en cours : libération immédiate
				writeProfile(profile, true)
				break
			end
			profiles[player] = profile
			DataService.ProfileLoaded:Fire(player, data)
			sendStatus(player, "ready", "")
			break
		end

		if os.clock() - started >= Config.LoadMaxWait then
			sendStatus(player, "failed", "Impossible de charger ta ferme.")
			player:Kick(
				"Impossible de charger ta ferme pour le moment. Tes données sont intactes : réessaie dans un instant."
			)
			break
		end
		if outcome == "locked" then
			sendStatus(player, "waiting_lock", "Ta ferme se ferme encore sur un autre serveur… (jusqu'à 2 min)")
			task.wait(Config.LoadRetryInterval)
		else
			warn(
				string.format(
					"[DataService] Échec de chargement %s (tentative %d) : %s",
					key,
					attempt,
					tostring(payload)
				)
			)
			task.wait(math.min(2 ^ attempt, 10))
		end
	end
	loading[player] = nil
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	local userId = player.UserId
	releasing[userId] = true
	DataService.ProfileReleasing:Fire(player, profile.data)
	while profile.saving do
		task.wait(0.1)
	end
	profile.saving = true
	writeProfile(profile, true)
	profile.saving = false
	profiles[player] = nil
	releasing[userId] = nil
end

local function autosaveLoop()
	while true do
		task.wait(Config.AutosaveInterval)
		local snapshot: { Profile } = {}
		for _, profile in profiles do
			table.insert(snapshot, profile)
		end
		local spacing = math.min(1, Config.AutosaveInterval / math.max(1, #snapshot) / 2)
		for _, profile in snapshot do
			if
				not profile.saving
				and not profile.lost
				and not profile.released
				and profiles[profile.player] == profile
			then
				task.spawn(function()
					profile.saving = true
					writeProfile(profile, false)
					profile.saving = false
					if profile.lost then
						profiles[profile.player] = nil
						kickLost(profile.player)
					end
				end)
				task.wait(spacing)
			end
		end
	end
end

local function onClose()
	shuttingDown = true
	local pending = 0
	for _, profile in profiles do
		pending += 1
		task.spawn(function()
			while profile.saving do
				task.wait(0.1)
			end
			profile.saving = true
			writeProfile(profile, true)
			profile.saving = false
			pending -= 1
		end)
	end
	local deadline = os.clock() + Config.ShutdownTimeout
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end

-- API publique ---------------------------------------------------------------------------------

-- Donnée vivante du joueur (lecture). Toute modification passe par Update.
function DataService.GetData(player: Player): PlayerData?
	local profile = profiles[player]
	if profile and not profile.lost and not profile.released then
		return profile.data
	end
	return nil
end

function DataService.IsLoaded(player: Player): boolean
	return DataService.GetData(player) ~= nil
end

-- Applique une modification synchrone (le mutateur ne doit pas céder la main) et notifie Changed.
function DataService.Update(player: Player, mutator: (PlayerData) -> ()): boolean
	local profile = profiles[player]
	if not profile or profile.lost or profile.released then
		return false
	end
	mutator(profile.data)
	DataService.Changed:Fire(player, profile.data)
	return true
end

-- Sauvegarde immédiate (ex. reçus d'achat). Retourne true si l'écriture a réussi.
function DataService.SaveNow(player: Player): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	while profile.saving do
		task.wait(0.1)
	end
	profile.saving = true
	local ok = writeProfile(profile, false)
	profile.saving = false
	if profile.lost then
		kickLost(player)
	end
	return ok
end

-- Ajoute une étape de chargement (appelée dans Init des services) : `step(player, data)` reçoit la donnée chargée,
-- migrée et assainie, AVANT qu'elle ne devienne vivante (ni remote ni service ne peut encore la lire) ; elle peut
-- céder la main et retourner une donnée de remplacement (nil : inchangée). Une erreur laisse la donnée intacte.
function DataService.AddLoadStep(step: (Player, PlayerData) -> PlayerData?)
	table.insert(loadSteps, step)
end

function DataService.IsMemoryStore(): boolean
	return store ~= nil and (store :: DataStoreAdapter.Store).isMemory
end

function DataService.Init() end

function DataService.Start()
	store = DataStoreAdapter.open(Config.StoreName, Config.ForceMemoryStoreInStudio)
	Players.PlayerAdded:Connect(loadProfile)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(loadProfile, player)
	end
	task.spawn(autosaveLoop)
	game:BindToClose(onClose)
end

return DataService
