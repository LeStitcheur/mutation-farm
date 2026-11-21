--!strict
-- UpgradeService — achats d'améliorations (Phase 3, jalon C). Le client n'envoie que l'identifiant et le niveau
-- qu'il affiche ; le serveur valide (type, longueur, catalogue, entier borné, débit, aucune transition de
-- progression en cours) puis exécute Upgrades.purchase dans UN mutateur : dépense et niveau + 1 indissociables ;
-- un niveau attendu périmé (double clic, paquet rejoué) n'achète rien. Effets : lus à la volée par les règles
-- pures (revenu, sac, pousse, chance, drones, Essence) ; drones offerts : flotte recalculée immédiatement.
-- API : Purchase.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local UpgradeConfig = require(Shared.Config.UpgradeConfig)
local Upgrades = require(Shared.Util.Upgrades)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local DroneService = require(script.Parent.DroneService)
local ProgressionService = require(script.Parent.ProgressionService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

local MAX_EXPECTED_LEVEL = 1000

local limiter = RateLimiter.new(4, 4)

local UpgradeService = {}

function UpgradeService.Purchase(player: Player, upgradeId: string, expectedLevel: number): (boolean, string?)
	if ProgressionService.IsBusy(player) then
		return false, "busy"
	end
	if not DataService.GetData(player) then
		return false, "not_loaded"
	end
	local outcome: Upgrades.PurchaseOutcome? = nil
	local failure: Upgrades.PurchaseFailure? = nil
	DataService.Update(player, function(data)
		outcome, failure = Upgrades.purchase(data, upgradeId, expectedLevel)
	end)
	local def = Upgrades.get(upgradeId)
	local result = outcome
	if not result or not def then
		if failure == "insufficient_funds" and def then
			Notifier.send(
				player,
				"error",
				string.format("Pas assez de %s pour cette amélioration.", UpgradeConfig.Trees[def.tree].name)
			)
		elseif failure == "max_level" then
			Notifier.send(player, "info", "Niveau maximum déjà atteint.")
		end
		return false, failure
	end
	if def.effect == "startDrones" then
		DroneService.Refresh(player)
	end
	Notifier.send(
		player,
		"success",
		string.format(
			"%s : niveau %d/%d (%s)",
			def.name,
			result.level,
			def.maxLevel,
			Upgrades.describe(def, result.level)
		)
	)
	return true, nil
end

function UpgradeService.Init()
	Net.event(Net.Events.UpgradePurchase).OnServerEvent
		:Connect(function(player: Player, upgradeId: unknown, expectedLevel: unknown)
			if typeof(upgradeId) ~= "string" or typeof(expectedLevel) ~= "number" then
				return
			end
			local id = upgradeId :: string
			local level = expectedLevel :: number
			if #id > UpgradeConfig.MaxIdLength or UpgradeConfig.ById[id] == nil then
				return
			end
			if level ~= level or level % 1 ~= 0 or level < 0 or level > MAX_EXPECTED_LEVEL then
				return
			end
			if not limiter:allow(player) then
				return
			end
			UpgradeService.Purchase(player, id, level)
		end)
end

function UpgradeService.Start() end

return UpgradeService
