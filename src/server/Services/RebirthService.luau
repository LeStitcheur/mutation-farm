--!strict
-- RebirthService — rebirth (Phase 3, jalon A). Le client n'envoie qu'une intention et la révision de progression
-- qu'il affiche ; le serveur :
--   1. refuse si une transition est déjà en cours pour ce joueur (verrou), puis limite le débit ;
--   2. valide, réinitialise et récompense dans UN mutateur synchrone (Resets.rebirth) : aucune récolte, vente ou
--      tâche de drone ne peut s'intercaler, et une requête rejouée (révision périmée) ne paie jamais deux fois ;
--   3. replante les cases et vide la flotte (les anciennes récoltes/cibles échouent : case vide ou pas mûre) ;
--   4. sauvegarde immédiatement. En cas d'échec, l'état en mémoire reste cohérent et l'autosave réessaie ;
--      chaque enregistrement contient soit l'état avant, soit l'état après (jamais de récompense sans reset).
-- API : Rebirth.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Format = require(Shared.Util.Format)
local Resets = require(Shared.Util.Resets)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local DroneService = require(script.Parent.DroneService)
local FarmService = require(script.Parent.FarmService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

local MAX_REVISION = 2 ^ 31

local busy: { [Player]: boolean } = {}
local limiter = RateLimiter.new(ProgressionConfig.Rebirth.RequestsPerSecond, 1)

local RebirthService = {}

function RebirthService.Rebirth(player: Player, expectedRevision: number): (boolean, string?)
	if busy[player] then
		return false, "busy"
	end
	if not DataService.GetData(player) then
		return false, "not_loaded"
	end
	busy[player] = true
	local outcome: Resets.RebirthOutcome? = nil
	local failure: Resets.RebirthFailure? = nil
	DataService.Update(player, function(data)
		outcome, failure = Resets.rebirth(data, expectedRevision)
	end)
	local result = outcome
	if not result then
		busy[player] = nil
		if failure == "below_threshold" then
			Notifier.send(player, "error", "Pas encore assez de Coins gagnés pendant ce cycle pour un rebirth.")
		end
		return false, failure
	end

	FarmService.ReplantEmpty(player)
	DroneService.Refresh(player)
	Notifier.send(
		player,
		"success",
		string.format(
			"Rebirth %d ! +%s Mutation Essence · revenus %s",
			result.rebirths,
			Format.bigNum(result.essence),
			Format.multiplier(result.multiplier)
		)
	)
	if not DataService.SaveNow(player) then
		warn(
			string.format(
				"[RebirthService] Sauvegarde immédiate échouée pour %s : l'autosave réessaiera.",
				player.Name
			)
		)
	end
	busy[player] = nil
	return true, nil
end

function RebirthService.Init()
	Net.event(Net.Events.RebirthRequest).OnServerEvent:Connect(function(player: Player, expectedRevision: unknown)
		if
			typeof(expectedRevision) ~= "number"
			or expectedRevision ~= expectedRevision
			or expectedRevision % 1 ~= 0
			or expectedRevision < 0
			or expectedRevision >= MAX_REVISION
		then
			return
		end
		if not limiter:allow(player) then
			return
		end
		RebirthService.Rebirth(player, expectedRevision)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		busy[player] = nil
	end)
end

function RebirthService.Start() end

return RebirthService
