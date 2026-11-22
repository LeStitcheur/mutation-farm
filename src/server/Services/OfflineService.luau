--!strict
-- OfflineService — production hors ligne (Phase 5, jalon D ; docs/AUTOMATION.md §8).
--   • Au chargement du profil, AVANT qu'il ne devienne vivant (DataService.AddLoadStep : aucun remote ni service ne
--     peut encore le lire), la règle pure Offline.settle est appliquée à une COPIE de la donnée, avec des pauses
--     coopératives toutes les 500 actions de drone ; la copie remplace la donnée seulement si le calcul aboutit
--     (sinon rien n'est modifié et l'absence sera recomptée au chargement suivant). Tirages de mutation serveur.
--   • Horodatages serveur uniquement : `meta.lastSeen` (écrit par DataService à chaque sauvegarde) et
--     `offline.settledAt` (idempotence). Le client n'envoie jamais d'heure.
--   • Le bilan est répliqué (ClientState.offline) ; l'écran « Pendant ton absence » le signale lu
--     (OfflineReportSeen, sans charge utile).
-- API : SettleLive (Studio, outils de test : absence simulée sur le profil en jeu).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Types = require(Shared.Types)
local Deep = require(Shared.Util.Deep)
local Offline = require(Shared.Util.Offline)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local DroneService = require(script.Parent.DroneService)
local FarmService = require(script.Parent.FarmService)
local MutationService = require(script.Parent.MutationService)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

type PlayerData = Types.PlayerData

local YIELD_EVERY = 500
-- Studio uniquement : absence simulée au chargement (secondes), attribut posé sur ServerStorage en mode Édition pour
-- valider le chemin de chargement sans DataStore réel. Ignoré sur un serveur Roblox.
local DEV_AWAY_ATTRIBUTE = "MutationFarmDevOfflineAway"

local seenLimiter = RateLimiter.new(GameConfig.Offline.SeenRequestsPerSecond, 2)

local OfflineService = {}

local function roll(luck: number): string
	return MutationService.Roll(luck)
end

local function describe(player: Player, report: Types.OfflineReport)
	if report.reason == "ok" or report.reason == "no_drones" or report.reason == "paused" then
		print(
			string.format(
				"[OfflineService] %s : absence %d s, %d s comptées, %d récoltes, %d ventes (%s)",
				player.Name,
				report.awaySeconds,
				report.countedSeconds,
				report.harvests,
				report.sales,
				report.reason
			)
		)
	end
end

-- Étape de chargement : règle l'absence sur une copie, qui remplace la donnée si le calcul aboutit.
local function loadStep(player: Player, data: PlayerData): PlayerData?
	local copy = Deep.copy(data)
	if RunService:IsStudio() then
		local away = ServerStorage:GetAttribute(DEV_AWAY_ATTRIBUTE)
		if type(away) == "number" and away > 0 then
			copy.meta.lastSeen = Workspace:GetServerTimeNow() - away
			copy.offline.settledAt = 0
		end
	end
	local report = Offline.settle(copy, Workspace:GetServerTimeNow(), {
		roll = roll,
		expectedRevision = copy.progression.revision,
		yield = function()
			task.wait()
		end,
		yieldEvery = YIELD_EVERY,
	})
	describe(player, report)
	return copy
end

-- Studio (DevService) : simule une absence de `awaySeconds` sur le profil EN JEU (même règle pure que le
-- chargement, dans un mutateur, sans pause), puis resynchronise les cases et la flotte. Jamais appelé en jeu publié.
function OfflineService.SettleLive(player: Player, awaySeconds: number): Types.OfflineReport?
	if not RunService:IsStudio() or not DataService.GetData(player) then
		return nil
	end
	local now = Workspace:GetServerTimeNow()
	local result: Types.OfflineReport? = nil
	DataService.Update(player, function(data)
		-- Absence simulée : la dernière sauvegarde ET les cultures reculent ensemble (comme pour une vraie absence,
		-- où toutes les cultures ont été plantées avant la dernière sauvegarde).
		data.meta.lastSeen = now - awaySeconds
		data.offline.settledAt = 0
		for _, tile in data.farm.tiles do
			tile.plantedAt -= awaySeconds
		end
		result = Offline.settle(data, now, { roll = roll, expectedRevision = data.progression.revision })
	end)
	FarmService.ReplantEmpty(player) -- attributs des cases replantées hors ligne
	DroneService.Refresh(player)
	local report = result
	if report then
		describe(player, report)
	end
	return report
end

function OfflineService.Init()
	DataService.AddLoadStep(loadStep)
	Net.event(Net.Events.OfflineReportSeen).OnServerEvent:Connect(function(player: Player)
		if not seenLimiter:allow(player) or not DataService.GetData(player) then
			return
		end
		DataService.Update(player, function(data)
			data.offline.report.seen = true
		end)
	end)
end

function OfflineService.Start() end

return OfflineService
