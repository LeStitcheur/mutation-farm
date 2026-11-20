--!strict
-- Règles PURES des drones (testées en Lune) : prix, achat, points d'attente, portée, choix des cibles.
-- Toutes les positions sont LOCALES à la parcelle (FarmLayout) : aucune API Roblox.

local Types = require(script.Parent.Parent.Types)
local DroneConfig = require(script.Parent.Parent.Config.DroneConfig)
local BigNum = require(script.Parent.BigNum)
local FarmLayout = require(script.Parent.FarmLayout)
local Growth = require(script.Parent.Growth)

type PlayerData = Types.PlayerData
type DroneDef = Types.DroneDef
type Vec3 = FarmLayout.Vec3

export type BuyFailure = "unknown" | "max_owned" | "insufficient_funds"

local DroneLogic = {}

-- Nombre d'exemplaires possédés (0 si absent).
function DroneLogic.owned(data: PlayerData, droneId: string): number
	local count = data.machines.drones[droneId]
	return if type(count) == "number" then count else 0
end

-- Prix du prochain exemplaire quand `owned` sont déjà possédés (entier, arrondi à l'inférieur).
function DroneLogic.price(def: DroneDef, owned: number): number
	return math.floor(def.price * def.priceGrowth ^ owned + 1e-9)
end

function DroneLogic.canBuy(data: PlayerData, droneId: string): (boolean, BuyFailure?)
	local def = DroneConfig.get(droneId)
	if not def then
		return false, "unknown"
	end
	local owned = DroneLogic.owned(data, droneId)
	if owned >= def.maxOwned then
		return false, "max_owned"
	end
	if BigNum.lt(data.currencies.coins, BigNum.fromNumber(DroneLogic.price(def, owned))) then
		return false, "insufficient_funds"
	end
	return true, nil
end

-- Liste ordonnée des drones possédés (ordre de DroneConfig puis exemplaire) : un élément par drone.
function DroneLogic.fleet(data: PlayerData): { DroneDef }
	local fleet: { DroneDef } = {}
	for _, def in DroneConfig.List do
		for _ = 1, math.min(DroneLogic.owned(data, def.id), def.maxOwned) do
			table.insert(fleet, def)
		end
	end
	return fleet
end

-- Point d'attente local du `index`-ième drone (1..total), alignés au-dessus de la parcelle principale.
function DroneLogic.homePosition(index: number, total: number): Vec3
	local features = FarmLayout.Features
	local offset = (index - (total + 1) / 2) * features.droneSpacing
	return { x = features.droneHome.x + offset, y = features.droneHome.y, z = features.droneHome.z }
end

-- Case à portée horizontale (plan XZ) du point d'attente `home`.
function DroneLogic.inRange(home: Vec3, tileId: string, range: number): boolean
	local position = FarmLayout.tileLocalPosition(tileId)
	if not position then
		return false
	end
	local dx, dz = position.x - home.x, position.z - home.z
	return dx * dx + dz * dz <= range * range
end

-- Cases débloquées, mûres et à portée, de la plus anciennement mûre à la plus récente (au plus `def.capacity`),
-- en ignorant celles déjà réservées par un autre drone pendant le même tick.
function DroneLogic.selectTargets(
	data: PlayerData,
	now: number,
	home: Vec3,
	def: DroneDef,
	reserved: { [string]: boolean }
): { string }
	local candidates: { { id: string, ripeAt: number } } = {}
	for tileId, tile in data.farm.tiles do
		if
			not reserved[tileId]
			and FarmLayout.isTileUnlocked(data.farm.plots, tileId)
			and Growth.isRipe(tile, now)
			and DroneLogic.inRange(home, tileId, def.range)
		then
			table.insert(candidates, { id = tileId, ripeAt = Growth.ripeAt(tile) })
		end
	end
	table.sort(candidates, function(a, b)
		if a.ripeAt ~= b.ripeAt then
			return a.ripeAt < b.ripeAt
		end
		return a.id < b.id
	end)
	local targets: { string } = {}
	for index = 1, math.min(def.capacity, #candidates) do
		table.insert(targets, candidates[index].id)
	end
	return targets
end

return table.freeze(DroneLogic)
