--!strict
-- Agrégation PURE des bonus de toutes les sources (Phase 4) : améliorations (Phase 3) × familiers (jalon B), sous
-- les plafonds globaux d'UpgradeConfig.Caps (aucun cumul ne rend un cycle instantané ni ne dépasse les limites de
-- probabilité). Point d'entrée unique pour la pousse, la chance, les drones, le revenu et la précision manuelle.

local Types = require(script.Parent.Parent.Types)
local UpgradeConfig = require(script.Parent.Parent.Config.UpgradeConfig)
local Upgrades = require(script.Parent.Upgrades)
local Pets = require(script.Parent.Pets)

type PlayerData = Types.PlayerData
type TreeId = UpgradeConfig.TreeId

local Bonuses = {}

-- Durée de pousse : × facteur (≥ MinGrowthFactor).
function Bonuses.growthFactor(data: PlayerData): number
	return math.max(UpgradeConfig.Caps.MinGrowthFactor, Upgrades.growthFactor(data) * Pets.growthFactor(data))
end

-- Intervalle des drones : × facteur (≥ MinDroneIntervalFactor).
function Bonuses.droneIntervalFactor(data: PlayerData): number
	return math.max(
		UpgradeConfig.Caps.MinDroneIntervalFactor,
		Upgrades.droneIntervalFactor(data) * Pets.droneFactor(data)
	)
end

-- Chance de mutation totale (1 = base) : (améliorations + familiers) × facteur d'événement (Pluie mutagène, 1 par
-- défaut), arrondie au centième (cache des poids côté serveur), jamais au-delà de MaxTotalLuck.
function Bonuses.luck(data: PlayerData, eventFactor: number?): number
	local factor = if eventFactor and eventFactor == eventFactor and eventFactor >= 1 then eventFactor else 1
	local luck = (Upgrades.luck(data) + Pets.luckBonus(data)) * factor
	return math.min(UpgradeConfig.Caps.MaxTotalLuck, math.floor(luck * 100 + 0.5) / 100)
end

-- Multiplicateur de revenu hors rebirth/prestige : améliorations (d'un arbre si `tree`) × familiers.
function Bonuses.valueMultiplier(data: PlayerData, tree: TreeId?): number
	return Upgrades.valueMultiplier(data, tree) * Pets.valueMultiplier(data)
end

-- Multiplicateur de revenu hors rebirth/prestige, sans les améliorations de l'arbre `excluded` (aperçus).
function Bonuses.valueMultiplierExcept(data: PlayerData, excluded: TreeId): number
	return Upgrades.valueMultiplierExcept(data, excluded) * Pets.valueMultiplier(data)
end

-- Bonus de précision d'une récolte MANUELLE : × facteur (familiers).
function Bonuses.manualMultiplier(data: PlayerData): number
	return Pets.manualMultiplier(data)
end

return table.freeze(Bonuses)
