--!strict
-- Règles économiques pures (valeurs, bonus, capacité, déblocages, formules de rebirth/prestige).

local Types = require(script.Parent.Parent.Types)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local PlantConfig = require(script.Parent.Parent.Config.PlantConfig)
local MutationConfig = require(script.Parent.Parent.Config.MutationConfig)
local BigNum = require(script.Parent.BigNum)
local Inventory = require(script.Parent.Inventory)
local Upgrades = require(script.Parent.Upgrades)
local Mutadex = require(script.Parent.Mutadex)
local Bonuses = require(script.Parent.Bonuses)

type BigNum = Types.BigNum
type PlayerData = Types.PlayerData

local Economy = {}

function Economy.itemKey(plantId: string, mutationId: string?): string
	return plantId .. "|" .. (mutationId or MutationConfig.NORMAL)
end

function Economy.parseItemKey(key: string): (string?, string?)
	local plantId, mutationId = string.match(key, "^([%w_]+)|([%w_]+)$")
	return plantId, mutationId
end

-- Valeur unitaire d'un objet récolté (nil si plante ou mutation inconnue).
function Economy.itemValue(plantId: string, mutationId: string): BigNum?
	local plant = PlantConfig.get(plantId)
	local mutation = MutationConfig.get(mutationId)
	if not plant or not mutation then
		return nil
	end
	return BigNum.mulNumber(BigNum.fromNumber(plant.baseValue), mutation.multiplier)
end

function Economy.isValidItemKey(key: string): boolean
	local plantId, mutationId = Economy.parseItemKey(key)
	return plantId ~= nil and mutationId ~= nil and Economy.itemValue(plantId, mutationId) ~= nil
end

-- Valeur totale de vente d'un sac (objets inconnus ignorés).
function Economy.sellValue(items: { [string]: number }, multiplier: number?): BigNum
	local total = BigNum.zero()
	for key, quantity in items do
		if quantity > 0 then
			local plantId, mutationId = Economy.parseItemKey(key)
			local unit = if plantId and mutationId then Economy.itemValue(plantId, mutationId) else nil
			if unit then
				total = BigNum.add(total, BigNum.mulNumber(unit, quantity))
			end
		end
	end
	if multiplier and multiplier ~= 1 then
		total = BigNum.mulNumber(total, multiplier)
	end
	return total
end

function Economy.precisionFraction(tier: Types.PrecisionTier): number
	if tier == "perfect" then
		return GameConfig.Harvest.PerfectBonus
	elseif tier == "good" then
		return GameConfig.Harvest.GoodBonus
	end
	return 0
end

-- Coins immédiats accordés par une récolte précise (arrondis à l'inférieur).
function Economy.precisionBonus(plantId: string, tier: Types.PrecisionTier): BigNum
	local plant = PlantConfig.get(plantId)
	if not plant then
		return BigNum.zero()
	end
	return BigNum.fromNumber(math.floor(plant.baseValue * Economy.precisionFraction(tier) + 1e-9))
end

-- Capacité du sac : base + améliorations (Capacité du sac) + paliers du Mutadex. Phase 6 : Game Pass Sac ×2.
function Economy.bagCapacity(data: PlayerData): number
	return GameConfig.Bag.BaseCapacity + Upgrades.bagBonus(data) + Mutadex.bagBonus(data)
end

-- Durée de pousse effective d'une nouvelle culture (figée à la plantation) : base × bonus de croissance
-- (améliorations × familiers, plafonnés : Util/Bonuses).
function Economy.growTime(data: PlayerData, plantId: string): number
	local plant = PlantConfig.get(plantId)
	assert(plant, "Economy.growTime : plante inconnue " .. plantId)
	return plant.growTime * Bonuses.growthFactor(data)
end

function Economy.bagCount(data: PlayerData): number
	return Inventory.count(data.bag.items)
end

export type UnlockFailure = "unknown" | "already_unlocked" | "locked_order" | "insufficient_funds"

function Economy.canUnlockSeed(data: PlayerData, plantId: string): (boolean, UnlockFailure?)
	local plant = PlantConfig.get(plantId)
	if not plant then
		return false, "unknown"
	end
	if data.seeds.unlocked[plantId] then
		return false, "already_unlocked"
	end
	local previous = PlantConfig.previous(plantId)
	if previous and not data.seeds.unlocked[previous.id] then
		return false, "locked_order"
	end
	if BigNum.lt(data.currencies.coins, BigNum.fromNumber(plant.unlockPrice)) then
		return false, "insufficient_funds"
	end
	return true, nil
end

function Economy.incomePerTileSecond(plant: Types.PlantDef): number
	return plant.baseValue / plant.growTime
end

-- Rebirth, prestige et multiplicateurs de progression : Util/ProgressionMath (Phase 3).

return Economy
