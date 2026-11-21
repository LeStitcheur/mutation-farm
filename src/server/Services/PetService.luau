--!strict
-- PetService — familiers (Phase 4, jalon B). Le client n'envoie que des intentions : œuf + nombre d'éclosions qu'il
-- affiche + œuf gratuit ou non (PetHatch), identifiant d'instance (PetEquip / PetUnequip / PetRelease). Le serveur
-- valide (type, longueur, catalogue, entier borné, débit, aucune transition de progression en cours) puis exécute
-- la règle pure (Util/Pets) dans UN mutateur : paiement, tirage (générateur serveur) et nouvelle instance sont
-- indissociables ; un nombre d'éclosions attendu périmé (double clic, paquet rejoué) n'ouvre rien.
-- Éclosion : le résultat est SAUVEGARDÉ (DataService.SaveNow) avant d'être confirmé au client (PetHatched).
-- L'XP est accordée par HarvestRules dans le mutateur de récolte (aucun événement réseau par récolte) ; seuls les
-- passages de niveau sont annoncés. Les familiers équipés sont publiés dans l'attribut « Pets » du joueur
-- (« espèce:niveau;… ») : chaque client les affiche localement (Visuals/PetRenderer).
-- API : Hatch, Equip, Unequip, Release, OnLevelUps, GrantFreeEggs, Refresh.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local PetConfig = require(Shared.Config.PetConfig)
local Types = require(Shared.Types)
local Format = require(Shared.Util.Format)
local Pets = require(Shared.Util.Pets)
local Quests = require(Shared.Util.Quests)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local HarvestService = require(script.Parent.HarvestService)
local ProgressionService = require(script.Parent.ProgressionService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)
local QuestNotifier = require(script.Parent.Parent.Infra.QuestNotifier)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

local ATTRIBUTE = "Pets"
local MAX_EXPECTED_HATCHED = 1e9

local rng = Random.new()
local hatchLimiter = RateLimiter.new(1 / PetConfig.HatchCooldown, 1)
local actionLimiter = RateLimiter.new(5, 5)
local hatching: { [Player]: boolean } = {}

local PetService = {}

local HATCH_MESSAGES: { [string]: string } = {
	inventory_full = "Inventaire de familiers plein : relâche un familier pour faire de la place.",
	insufficient_funds = "Pas assez de Coins pour cet œuf.",
	no_free_egg = "Aucun œuf gratuit de ce type en réserve.",
	not_for_sale = "Cet œuf ne s'achète pas : il se gagne avec les missions.",
}

local ACTION_MESSAGES: { [string]: string } = {
	slots_full = string.format("Tu as déjà %d familiers équipés.", PetConfig.Slots),
	equipped = "Déséquipe ce familier avant de le relâcher.",
	dormant = "Ce familier n'est plus disponible dans cette version du jeu.",
}

-- Publie les familiers équipés (rendu chez tous les clients).
function PetService.Refresh(player: Player)
	local data = DataService.GetData(player)
	if data then
		player:SetAttribute(ATTRIBUTE, Pets.equippedSummary(data))
	end
end

function PetService.Hatch(player: Player, eggId: string, expectedHatched: number, useFree: boolean): (boolean, string?)
	if ProgressionService.IsBusy(player) then
		return false, "busy"
	end
	if hatching[player] then
		return false, "busy"
	end
	if not DataService.GetData(player) then
		return false, "not_loaded"
	end
	local outcome: Pets.HatchOutcome? = nil
	local failure: Pets.HatchFailure? = nil
	local roll = rng:NextNumber()
	local completed: { Types.Mission } = {}
	DataService.Update(player, function(data)
		local now = Workspace:GetServerTimeNow()
		outcome, failure = Pets.hatch(data, eggId, expectedHatched, useFree, roll, now)
		if outcome then
			completed = Quests.record(data, "hatch", 1, now)
		end
	end)
	local result = outcome
	if not result then
		local message = if failure then HATCH_MESSAGES[failure] else nil
		if message then
			Notifier.send(player, "error", message)
		end
		return false, failure
	end
	-- Résultat sauvegardé AVANT la confirmation (pas de familier « vu » puis perdu sur une panne de serveur).
	hatching[player] = true
	local ok, written = pcall(DataService.SaveNow, player)
	hatching[player] = nil -- toujours libéré, même si la sauvegarde lève une erreur
	local saved = ok and written == true
	if not saved then
		warn(
			string.format(
				"[PetService] Sauvegarde différée après l'éclosion %s de %d",
				result.instanceId,
				player.UserId
			)
		)
	end
	if player.Parent == nil then
		return true, nil
	end
	local def = Pets.get(result.petId)
	local payload: Types.HatchResult = {
		eggId = result.eggId,
		instanceId = result.instanceId,
		petId = result.petId,
		saved = saved,
	}
	Net.event(Net.Events.PetHatched):FireClient(player, payload)
	QuestNotifier.completed(player, completed)
	if def then
		Notifier.send(
			player,
			"success",
			string.format(
				"Éclosion : %s (%s) !%s",
				def.name,
				def.rarity.name,
				if result.free then "" else " (−" .. Format.bigNum(result.price) .. " Coins)"
			)
		)
	end
	return true, nil
end

local function runAction(
	player: Player,
	action: (Types.PlayerData, string) -> (boolean, Pets.ActionFailure?),
	instanceId: string
): (boolean, Pets.ActionFailure?)
	if ProgressionService.IsBusy(player) or not DataService.GetData(player) then
		return false, nil
	end
	local ok: boolean, failure: Pets.ActionFailure? = false, nil
	DataService.Update(player, function(data)
		ok, failure = action(data, instanceId)
	end)
	if ok then
		PetService.Refresh(player)
	else
		local message = if failure then ACTION_MESSAGES[failure] else nil
		if message then
			Notifier.send(player, "error", message)
		end
	end
	return ok, failure
end

function PetService.Equip(player: Player, instanceId: string): (boolean, Pets.ActionFailure?)
	return runAction(player, Pets.equip, instanceId)
end

function PetService.Unequip(player: Player, instanceId: string): (boolean, Pets.ActionFailure?)
	return runAction(player, Pets.unequip, instanceId)
end

function PetService.Release(player: Player, instanceId: string): (boolean, Pets.ActionFailure?)
	return runAction(player, Pets.release, instanceId)
end

-- Annonce les passages de niveau d'une récolte (déjà appliqués dans le mutateur de récolte).
function PetService.OnLevelUps(player: Player, levelUps: { Pets.LevelUp })
	if #levelUps == 0 then
		return
	end
	for _, levelUp in levelUps do
		local def = Pets.get(levelUp.petId)
		if def then
			local suffix = if levelUp.level >= PetConfig.Level.Max then " (maximum)" else ""
			Notifier.send(
				player,
				"success",
				string.format("%s passe au niveau %d%s !", def.name, levelUp.level, suffix)
			)
		end
	end
	PetService.Refresh(player)
end

-- Ajoute des œufs gratuits (récompenses de missions, outillage Studio). Retourne le nombre ajouté.
function PetService.GrantFreeEggs(player: Player, eggId: string, amount: number): number
	local added = 0
	DataService.Update(player, function(data)
		added = Pets.addFreeEggs(data, eggId, amount)
	end)
	return added
end

local function validId(value: unknown, maxLength: number): string?
	if typeof(value) ~= "string" then
		return nil
	end
	local text = value :: string
	if #text == 0 or #text > maxLength then
		return nil
	end
	return text
end

function PetService.Init()
	DataService.ProfileLoaded:Connect(function(player: Player)
		PetService.Refresh(player)
	end)
	HarvestService.Harvested:Connect(function(player: Player, outcome)
		PetService.OnLevelUps(player, outcome.petLevelUps)
	end)
	Net.event(Net.Events.PetHatch).OnServerEvent
		:Connect(function(player: Player, eggId: unknown, expectedHatched: unknown, useFree: unknown)
			local egg = validId(eggId, PetConfig.MaxIdLength)
			if not egg or PetConfig.EggById[egg] == nil then
				return
			end
			if typeof(expectedHatched) ~= "number" or typeof(useFree) ~= "boolean" then
				return
			end
			local expected = expectedHatched :: number
			if expected ~= expected or expected % 1 ~= 0 or expected < 0 or expected > MAX_EXPECTED_HATCHED then
				return
			end
			if not hatchLimiter:allow(player) then
				Notifier.send(player, "info", "Patiente un instant entre deux éclosions.")
				return
			end
			PetService.Hatch(player, egg, expected, useFree :: boolean)
		end)
	local actions: { [string]: (Player, string) -> (boolean, Pets.ActionFailure?) } = {
		[Net.Events.PetEquip] = PetService.Equip,
		[Net.Events.PetUnequip] = PetService.Unequip,
		[Net.Events.PetRelease] = PetService.Release,
	}
	for eventName, handler in actions do
		Net.event(eventName).OnServerEvent:Connect(function(player: Player, instanceId: unknown)
			local id = validId(instanceId, PetConfig.MaxIdLength)
			if not id or not actionLimiter:allow(player) then
				return
			end
			handler(player, id)
		end)
	end
end

function PetService.Start() end

return PetService
