--!strict
-- Règles PURES des améliorations (Phase 3, jalon C ; testées en Lune) : niveaux, coûts, achat atomique et
-- idempotent (niveau attendu), effets cumulés et plafonnés. Le serveur exécute `purchase` dans UN mutateur de
-- DataService.Update ; le client n'envoie que l'identifiant et le niveau qu'il affiche.
-- Les fonctions d'effet tolèrent une donnée partielle (aperçus côté client) : niveau absent ou invalide = 0.

local Types = require(script.Parent.Parent.Types)
local UpgradeConfig = require(script.Parent.Parent.Config.UpgradeConfig)
local DroneConfig = require(script.Parent.Parent.Config.DroneConfig)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local PlantConfig = require(script.Parent.Parent.Config.PlantConfig)
local BigNum = require(script.Parent.BigNum)

type PlayerData = Types.PlayerData
type BigNum = Types.BigNum
type UpgradeDef = UpgradeConfig.UpgradeDef
type TreeId = UpgradeConfig.TreeId
type Effect = UpgradeConfig.Effect

export type PurchaseFailure = "unknown_upgrade" | "stale_level" | "max_level" | "insufficient_funds"

export type PurchaseOutcome = {
	id: string,
	tree: TreeId,
	level: number, -- nouveau niveau
	cost: BigNum, -- montant dépensé
}

local STARTER_DRONE = "harvester"

local Upgrades = {}

function Upgrades.get(id: string): UpgradeDef?
	return UpgradeConfig.ById[id]
end

-- Améliorations d'un arbre, dans l'ordre d'affichage.
function Upgrades.list(tree: TreeId): { UpgradeDef }
	local result: { UpgradeDef } = {}
	for _, def in UpgradeConfig.List do
		if def.tree == tree then
			table.insert(result, def)
		end
	end
	table.sort(result, function(a, b)
		return a.order < b.order
	end)
	return result
end

local function store(data: any, def: UpgradeDef): { [string]: any }?
	local upgrades = if type(data) == "table" then data.upgrades else nil
	if type(upgrades) ~= "table" then
		return nil
	end
	local container = upgrades[UpgradeConfig.Trees[def.tree].storage]
	return if type(container) == "table" then container else nil
end

-- Niveau courant : 0 si absent, inconnu ou invalide ; jamais au-delà du maximum.
function Upgrades.level(data: PlayerData, id: string): number
	local def = UpgradeConfig.ById[id]
	if not def then
		return 0
	end
	local container = store(data, def)
	local value = if container then container[id] else nil
	if type(value) ~= "number" or value ~= value or value < 0 or value % 1 ~= 0 then
		return 0
	end
	return math.min(value, def.maxLevel)
end

-- Coût du passage du niveau `level` au niveau `level + 1`.
function Upgrades.cost(def: UpgradeDef, level: number): BigNum
	return BigNum.fromNumber(math.ceil(def.costBase * def.costGrowth ^ level - 1e-9))
end

-- Solde de la monnaie de l'arbre (Mutation Essence ou Primal Cores).
function Upgrades.balance(data: PlayerData, tree: TreeId): BigNum
	local currencies = (data :: any).currencies
	local value = if type(currencies) == "table" then currencies[UpgradeConfig.Trees[tree].currency] else nil
	return BigNum.sanitize(value)
end

function Upgrades.canPurchase(data: PlayerData, id: string, expectedLevel: number): (boolean, PurchaseFailure?)
	local def = UpgradeConfig.ById[id]
	if not def then
		return false, "unknown_upgrade"
	end
	local level = Upgrades.level(data, id)
	if level ~= expectedLevel then
		return false, "stale_level"
	end
	if level >= def.maxLevel then
		return false, "max_level"
	end
	if BigNum.lt(Upgrades.balance(data, def.tree), Upgrades.cost(def, level)) then
		return false, "insufficient_funds"
	end
	return true, nil
end

-- Achat d'UN niveau : dépense et niveau + 1 indissociables. `expectedLevel` rend la requête idempotente (un double
-- clic ou un paquet rejoué trouve un niveau différent et n'achète rien de plus).
function Upgrades.purchase(data: PlayerData, id: string, expectedLevel: number): (PurchaseOutcome?, PurchaseFailure?)
	local allowed: boolean, failure: PurchaseFailure? = Upgrades.canPurchase(data, id, expectedLevel)
	if not allowed then
		return nil, failure
	end
	local def = UpgradeConfig.ById[id]
	local tree = UpgradeConfig.Trees[def.tree]
	local level = Upgrades.level(data, id)
	local cost = Upgrades.cost(def, level)
	local currencies = data.currencies :: any
	currencies[tree.currency] = BigNum.sub(currencies[tree.currency], cost)
	local levels = (data.upgrades :: any)[tree.storage]
	levels[id] = level + 1
	-- Les améliorations « de début de cycle » profitent aussi au cycle en cours.
	if def.effect == "startDrones" then
		Upgrades.grantStartingDrones(data)
	elseif def.effect == "legacySeeds" then
		for _, plantId in Upgrades.legacySeeds(data) do
			data.seeds.unlocked[plantId] = true
		end
	end
	return { id = id, tree = def.tree, level = level + 1, cost = cost }, nil
end

-- Somme perLevel × niveau des améliorations d'un effet (option : un seul arbre).
local function total(data: PlayerData, effect: Effect, tree: TreeId?): number
	local sum = 0
	for _, def in UpgradeConfig.List do
		if def.effect == effect and (tree == nil or def.tree == tree) then
			sum += def.perLevel * Upgrades.level(data, def.id)
		end
	end
	return sum
end

-- Produit des (1 + sign × perLevel × niveau) d'un effet (cumul multiplicatif entre arbres).
local function product(data: PlayerData, effect: Effect, sign: number, tree: TreeId?): number
	local result = 1
	for _, def in UpgradeConfig.List do
		if def.effect == effect and (tree == nil or def.tree == tree) then
			result *= 1 + sign * def.perLevel * Upgrades.level(data, def.id)
		end
	end
	return result
end

-- Multiplicateur de revenu des améliorations (ventes et bonus de précision). `tree` : un seul arbre.
function Upgrades.valueMultiplier(data: PlayerData, tree: TreeId?): number
	return product(data, "value", 1, tree)
end

-- Facteur de durée de pousse (≥ MinGrowthFactor).
function Upgrades.growthFactor(data: PlayerData): number
	return math.max(UpgradeConfig.Caps.MinGrowthFactor, product(data, "growth", -1))
end

-- Chance de mutation (1 = base, ≤ MaxLuck), appliquée aux poids non normaux par le serveur.
function Upgrades.luck(data: PlayerData): number
	return math.min(UpgradeConfig.Caps.MaxLuck, 1 + total(data, "luck"))
end

-- Facteur d'intervalle des drones (≥ MinDroneIntervalFactor). Le délai de grâce n'est jamais modifié.
function Upgrades.droneIntervalFactor(data: PlayerData): number
	return math.max(UpgradeConfig.Caps.MinDroneIntervalFactor, 1 - total(data, "droneSpeed"))
end

-- Places de sac supplémentaires.
function Upgrades.bagBonus(data: PlayerData): number
	return math.floor(total(data, "bag") + 1e-9)
end

-- Multiplicateur de Mutation Essence gagnée aux rebirths.
function Upgrades.essenceMultiplier(data: PlayerData): number
	return 1 + total(data, "essence")
end

-- Drones récolteurs offerts au début de chaque cycle (≤ maximum possédable).
function Upgrades.startingDrones(data: PlayerData): number
	local def = DroneConfig.get(STARTER_DRONE)
	local cap = if def then def.maxOwned else 0
	return math.min(math.floor(total(data, "startDrones") + 1e-9), cap)
end

-- Garantit au moins les drones offerts (jamais de retrait de drones achetés).
function Upgrades.grantStartingDrones(data: PlayerData)
	local count = Upgrades.startingDrones(data)
	local drones = data.machines.drones
	if count > 0 and (drones[STARTER_DRONE] or 0) < count then
		drones[STARTER_DRONE] = count
	end
end

-- Graines débloquées au début de chaque cycle : la graine de départ puis les suivantes, dans l'ordre.
function Upgrades.legacySeeds(data: PlayerData): { string }
	local seeds = { GameConfig.StarterSeed }
	local extra = math.floor(total(data, "legacySeeds") + 1e-9)
	local current = GameConfig.StarterSeed
	for _ = 1, extra do
		local nextPlant = PlantConfig.nextAfter(current)
		if not nextPlant then
			break
		end
		table.insert(seeds, nextPlant.id)
		current = nextPlant.id
	end
	return seeds
end

local function percent(value: number): number
	return math.floor(value * 100 + 0.5)
end

-- Effet d'une amélioration au niveau `level`, en texte (interface).
function Upgrades.describe(def: UpgradeDef, level: number): string
	local amount = def.perLevel * level
	local effect = def.effect
	if effect == "value" then
		return string.format("+%d %% de valeur", percent(amount))
	elseif effect == "growth" then
		return string.format("−%d %% de durée de pousse", percent(amount))
	elseif effect == "luck" then
		return string.format("+%d %% de chance de mutation", percent(amount))
	elseif effect == "droneSpeed" then
		return string.format("−%d %% d'intervalle des drones", percent(amount))
	elseif effect == "bag" then
		return string.format("+%d places", math.floor(amount + 1e-9))
	elseif effect == "essence" then
		return string.format("+%d %% de Mutation Essence", percent(amount))
	elseif effect == "startDrones" then
		local count = math.floor(amount + 1e-9)
		return if count == 0 then "aucun drone offert" else string.format("%d drone(s) offert(s) par cycle", count)
	end
	-- legacySeeds
	local names: { string } = {}
	local current = GameConfig.StarterSeed
	for _ = 1, math.floor(amount + 1e-9) do
		local nextPlant = PlantConfig.nextAfter(current)
		if not nextPlant then
			break
		end
		table.insert(names, nextPlant.name)
		current = nextPlant.id
	end
	return if #names == 0 then "aucune graine conservée" else table.concat(names, ", ") .. " conservée(s)"
end

return table.freeze(Upgrades)
