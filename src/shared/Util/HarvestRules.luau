--!strict
-- Règles PURES d'une récolte, communes au joueur et aux drones (testées en Lune).
-- Le serveur exécute `check` puis `apply` dans le MÊME mutateur synchrone de DataService.Update : une case ne peut
-- être récoltée qu'une seule fois par cycle, même si un joueur et un drone la visent au même instant (la seconde
-- tentative trouve la case vidée puis replantée → "empty" / "not_ripe").

local Types = require(script.Parent.Parent.Types)
local MutationConfig = require(script.Parent.Parent.Config.MutationConfig)
local BigNum = require(script.Parent.BigNum)
local Economy = require(script.Parent.Economy)
local FarmLayout = require(script.Parent.FarmLayout)
local Growth = require(script.Parent.Growth)
local Inventory = require(script.Parent.Inventory)
local ProgressionMath = require(script.Parent.ProgressionMath)
local Mutadex = require(script.Parent.Mutadex)
local MutadexConfig = require(script.Parent.Parent.Config.MutadexConfig)
local Bonuses = require(script.Parent.Bonuses)
local Pets = require(script.Parent.Pets)

type PlayerData = Types.PlayerData

export type Failure = "invalid_tile" | "empty" | "not_ripe" | "bag_full"

export type Outcome = {
	plantId: string,
	mutation: string,
	tier: Types.PrecisionTier,
	bonus: Types.BigNum,
	itemKey: string,
	discovered: boolean, -- première récolte de cette combinaison (Mutadex)
	milestones: { MutadexConfig.MilestoneDef }, -- paliers du Mutadex accordés par cette découverte
	petLevelUps: { Pets.LevelUp }, -- familiers équipés passés au niveau supérieur (XP de cette récolte)
	eventBonus: Types.BigNum, -- Floraison dorée : part de la valeur versée À LA RÉCOLTE (0 hors événement)
}

local HarvestRules = {}

-- Validations sur la donnée (ordre : case, culture, maturité selon l'horloge serveur, place dans le sac).
function HarvestRules.check(data: PlayerData, tileId: string, now: number): (boolean, Failure?)
	if not FarmLayout.isTileUnlocked(data.farm.plots, tileId) then
		return false, "invalid_tile"
	end
	local tile = data.farm.tiles[tileId]
	if not tile then
		return false, "empty"
	end
	if not Growth.isRipe(tile, now) then
		return false, "not_ripe"
	end
	if Inventory.isFull(data.bag.items, Economy.bagCapacity(data)) then
		return false, "bag_full"
	end
	return true, nil
end

-- Applique une récolte DÉJÀ validée par `check` : objet (avec sa mutation) dans le sac, statistiques, case vidée.
-- Les drones ne reçoivent jamais de bonus de précision (palier "normal").
-- `eventValueBonus` (Floraison dorée, lu par le serveur à l'horloge serveur au moment de la récolte) : part de la
-- valeur de l'objet versée immédiatement, joueur ou drone, une seule fois par récolte ; l'objet du sac garde sa
-- valeur normale à la vente (aucun intérêt à garder son sac pour un événement).
function HarvestRules.apply(
	data: PlayerData,
	tileId: string,
	now: number,
	source: Types.HarvestSource,
	eventValueBonus: number?
): Outcome
	local tile = data.farm.tiles[tileId]
	assert(tile, "HarvestRules.apply : case vide " .. tileId)
	local mutation = tile.mutation or MutationConfig.NORMAL
	local tier: Types.PrecisionTier = if source == "player"
		then Growth.precisionTier(now - Growth.ripeAt(tile))
		else "normal"
	local key = Economy.itemKey(tile.plantId, mutation)
	Inventory.add(data.bag.items, key, 1, Economy.bagCapacity(data))
	data.stats.harvests += 1
	if tier == "perfect" then
		data.stats.perfectHarvests += 1
	end
	data.farm.tiles[tileId] = nil
	-- Bonus de précision (récolte manuelle uniquement) × multiplicateur de revenu (rebirth…) × familiers de
	-- précision, appliqué une seule fois puis tronqué.
	local bonus = if tier == "normal"
		then BigNum.zero()
		else BigNum.mulNumber(
			Economy.precisionBonus(tile.plantId, tier),
			ProgressionMath.incomeMultiplier(data) * Bonuses.manualMultiplier(data)
		)
	-- Mutadex et XP des familiers : même mutateur que la récolte (joueur ou drone) → une culture compte une fois.
	local discovered = Mutadex.record(data, tile.plantId, mutation, now)
	local milestones = if discovered then Mutadex.claimMilestones(data, now) else {}
	local petLevelUps = Pets.grantXp(data, Pets.harvestXp(source, tier))
	local eventBonus = BigNum.zero()
	local value = Economy.itemValue(tile.plantId, mutation)
	if eventValueBonus and eventValueBonus > 0 and value then
		eventBonus = BigNum.mulNumber(value, eventValueBonus * ProgressionMath.incomeMultiplier(data))
	end
	return {
		plantId = tile.plantId,
		mutation = mutation,
		tier = tier,
		bonus = bonus,
		itemKey = key,
		discovered = discovered,
		milestones = milestones,
		petLevelUps = petLevelUps,
		eventBonus = eventBonus,
	}
end

return table.freeze(HarvestRules)
