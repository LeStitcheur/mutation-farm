-- EconomySim — simulateur économique DÉTERMINISTE (Phase 3, jalon C). Rejoue une partie avec les règles pures du
-- jeu — HarvestRules, Economy, DroneLogic, ProgressionMath, Resets, Upgrades, MutationRoll — sans en recopier
-- aucune : seules les décisions du joueur (profil) sont modélisées. Pas de temps fixe (DT), mutations tirées avec
-- math.random après math.randomseed(graine) : même graine = même partie.
-- Hypothèses (docs/ECONOMY.md §8) : parcelle principale 3×3 ; récolte manuelle de la case mûre la plus ancienne
-- après `reaction` s (bonus Parfait ≤ 1,5 s, Bien ≤ 5 s), `moveTime` s entre deux récoltes ; vente quand le sac est
-- plein (aller-retour `sellTrip` s, récolte manuelle suspendue, drones actifs) ou toutes les `sellEvery` s.
-- Achats : graine suivante dès qu'elle est payable (et sélectionnée), drones jusqu'à `targetDrones`, rebirth et
-- prestige dès l'éligibilité, améliorations les moins chères d'abord.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Shared = ReplicatedStorage.Shared
local PlantConfig = require(Shared.Config.PlantConfig)
local DroneConfig = require(Shared.Config.DroneConfig)
local UpgradeConfig = require(Shared.Config.UpgradeConfig)
local MutationConfig = require(Shared.Config.MutationConfig)
local BigNum = require(Shared.Util.BigNum)
local DataSchema = require(Shared.Util.DataSchema)
local DroneLogic = require(Shared.Util.DroneLogic)
local Economy = require(Shared.Util.Economy)
local FarmLayout = require(Shared.Util.FarmLayout)
local Growth = require(Shared.Util.Growth)
local HarvestRules = require(Shared.Util.HarvestRules)
local Inventory = require(Shared.Util.Inventory)
local MutationRoll = require(Shared.Util.MutationRoll)
local ProgressionMath = require(Shared.Util.ProgressionMath)
local Resets = require(Shared.Util.Resets)
local Upgrades = require(Shared.Util.Upgrades)
local MutationOdds = require(ServerScriptService.Server.Config.MutationOdds)

local DT = 0.25
local TILES = FarmLayout.tileIds("main")

local EconomySim = {
	DT = DT,
}

EconomySim.Profiles = {
	active = {
		name = "1. Actif sans drone",
		manual = true,
		reaction = 1.0,
		moveTime = 1.2,
		sellTrip = 8,
		targetDrones = 0,
	},
	hybrid = {
		name = "2. Hybride, 1 drone",
		manual = true,
		reaction = 3.0,
		moveTime = 1.5,
		sellTrip = 8,
		targetDrones = 1,
	},
	automated = {
		name = "3. Principalement automatisé",
		manual = true,
		manualUntilDrones = 1, -- joue seulement jusqu'au premier drone, puis passe vendre toutes les 2 min
		reaction = 3.0,
		moveTime = 1.5,
		sellTrip = 8,
		sellEvery = 120,
		targetDrones = 3,
	},
	advanced = {
		name = "4. Avancé (rebirths, prestige, améliorations)",
		manual = true,
		reaction = 1.0,
		moveTime = 1.2,
		sellTrip = 8,
		targetDrones = 3,
		rebirth = true,
		prestige = true,
		buyUpgrades = true,
	},
}

local weightsCache = {}
local function weightsFor(luck: number)
	local cached = weightsCache[luck]
	if not cached then
		cached = MutationRoll.applyLuck(MutationOdds.Weights, MutationOdds.Luck.Base * luck)
		weightsCache[luck] = cached
	end
	return cached
end

local function plant(sim, tileId: string)
	local data = sim.data
	local plantId = data.seeds.selected
	local mutation = MutationRoll.pick(weightsFor(Upgrades.luck(data)), math.random())
	data.farm.tiles[tileId] = {
		plantId = plantId,
		plantedAt = sim.now,
		growTime = Economy.growTime(data, plantId),
		mutation = if mutation ~= MutationConfig.NORMAL then mutation else nil,
	}
end

local function replantAll(sim)
	for _, tileId in TILES do
		if sim.data.farm.tiles[tileId] == nil then
			plant(sim, tileId)
		end
	end
end

local function credit(sim, amount)
	local data = sim.data
	data.currencies.coins = BigNum.add(data.currencies.coins, amount)
	ProgressionMath.recordEarnings(data, amount)
end

local function rebuildFleet(sim)
	local fleet = DroneLogic.fleet(sim.data)
	sim.drones = {}
	for index, def in fleet do
		table.insert(sim.drones, {
			def = def,
			home = DroneLogic.homePosition(index, #fleet),
			nextAt = sim.now + DroneLogic.interval(def, sim.data) * index / #fleet,
		})
	end
end

-- Nouvelle simulation. `data` : état de départ (gabarit neuf par défaut). `frozen` : aucun achat ni transition.
function EconomySim.new(profile, seed: number, data, frozen: boolean?)
	math.randomseed(seed)
	local sim = {
		profile = profile,
		data = data or DataSchema.template(0),
		frozen = frozen == true,
		now = 0,
		nextManual = 0,
		sellingUntil = nil,
		nextPeriodicSell = profile.sellEvery or math.huge,
		drones = {},
		events = {}, -- { kind, time, detail }
		manualHarvests = 0,
		droneHarvests = 0,
		coinsBySource = { player = 0, drone = 0 },
	}
	sim.data.farm.tiles = {}
	replantAll(sim)
	rebuildFleet(sim)
	return sim
end

local function harvest(sim, tileId: string, source: string): boolean
	local data = sim.data
	if not HarvestRules.check(data, tileId, sim.now) then
		return false
	end
	local outcome = HarvestRules.apply(data, tileId, sim.now, source)
	if not BigNum.isZero(outcome.bonus) then
		credit(sim, outcome.bonus)
	end
	local value = Economy.sellValue({ [outcome.itemKey] = 1 }, ProgressionMath.incomeMultiplier(data))
	sim.coinsBySource[source] += BigNum.toNumber(value) + BigNum.toNumber(outcome.bonus)
	if source == "player" then
		sim.manualHarvests += 1
	else
		sim.droneHarvests += 1
	end
	plant(sim, tileId)
	return true
end

local function sell(sim)
	local data = sim.data
	if Inventory.count(data.bag.items) == 0 then
		return
	end
	credit(sim, Economy.sellValue(data.bag.items, ProgressionMath.incomeMultiplier(data)))
	data.stats.sells += 1
	data.bag.items = {}
end
EconomySim.sell = sell

local function buyCheapestUpgrades(sim)
	local data = sim.data
	while true do
		local best, bestLevel, bestWeight = nil, 0, nil
		for _, def in UpgradeConfig.List do
			local level = Upgrades.level(data, def.id)
			local useless = def.effect == "droneSpeed" and sim.profile.targetDrones == 0
			if level < def.maxLevel and not useless then
				local cost = Upgrades.cost(def, level)
				local affordable = not BigNum.lt(Upgrades.balance(data, def.tree), cost)
				-- Comparaison entre arbres : un Primal Core pèse comme ~100 Essence.
				local weight = BigNum.toNumber(cost) * (if def.tree == "cores" then 100 else 1)
				if affordable and (bestWeight == nil or weight < bestWeight) then
					best, bestLevel, bestWeight = def, level, weight
				end
			end
		end
		if not best then
			return
		end
		assert(Upgrades.purchase(data, best.id, bestLevel))
		table.insert(sim.events, { kind = "upgrade", time = sim.now, detail = best.id .. " " .. (bestLevel + 1) })
	end
end

local function purchases(sim)
	local data = sim.data
	local profile = sim.profile
	-- Graine suivante dès qu'elle est payable (sélectionnée aussitôt) ; graine héritée : la meilleure.
	local nextPlant = PlantConfig.nextAfter(data.seeds.selected)
	if nextPlant and data.seeds.unlocked[nextPlant.id] then
		data.seeds.selected = nextPlant.id
	elseif nextPlant and Economy.canUnlockSeed(data, nextPlant.id) then
		data.currencies.coins = BigNum.sub(data.currencies.coins, BigNum.fromNumber(nextPlant.unlockPrice))
		data.seeds.unlocked[nextPlant.id] = true
		data.seeds.selected = nextPlant.id
		table.insert(sim.events, { kind = "seed", time = sim.now, detail = nextPlant.id })
	end
	-- Drones jusqu'à la cible.
	local def = DroneConfig.get("harvester")
	while def and DroneLogic.owned(data, def.id) < profile.targetDrones and DroneLogic.canBuy(data, def.id) do
		local price = DroneLogic.price(def, DroneLogic.owned(data, def.id))
		data.currencies.coins = BigNum.sub(data.currencies.coins, BigNum.fromNumber(price))
		data.machines.drones[def.id] = DroneLogic.owned(data, def.id) + 1
		rebuildFleet(sim)
		table.insert(sim.events, { kind = "drone", time = sim.now, detail = tostring(data.machines.drones[def.id]) })
	end
	-- Transitions (règles pures du serveur).
	if profile.prestige and ProgressionMath.canPrestige(data) then
		local outcome = assert(Resets.prestige(data, data.progression.revision))
		table.insert(sim.events, { kind = "prestige", time = sim.now, detail = BigNum.toNumber(outcome.cores) })
		replantAll(sim)
		rebuildFleet(sim)
	elseif profile.rebirth and ProgressionMath.canRebirth(data) then
		local outcome = assert(Resets.rebirth(data, data.progression.revision))
		table.insert(sim.events, { kind = "rebirth", time = sim.now, detail = BigNum.toNumber(outcome.essence) })
		replantAll(sim)
		rebuildFleet(sim)
	end
	if profile.buyUpgrades then
		local before = DroneLogic.owned(data, "harvester")
		buyCheapestUpgrades(sim)
		if DroneLogic.owned(data, "harvester") ~= before then
			rebuildFleet(sim)
		end
	end
end

-- Prochain achat visé par le joueur (graine suivante, puis drone manquant) : prix en Coins, ou nil.
local function nextPurchasePrice(sim): number?
	local data = sim.data
	local best: number? = nil
	local nextPlant = PlantConfig.nextAfter(data.seeds.selected)
	if nextPlant and not data.seeds.unlocked[nextPlant.id] then
		best = nextPlant.unlockPrice
	end
	local def = DroneConfig.get("harvester")
	if def and DroneLogic.owned(data, def.id) < sim.profile.targetDrones then
		local price = DroneLogic.price(def, DroneLogic.owned(data, def.id))
		best = if best then math.min(best, price) else price
	end
	return best
end

-- Un joueur présent va vendre dès que le contenu du sac lui permet son prochain achat (pas seulement sac plein).
local function shouldSellEarly(sim): boolean
	local data = sim.data
	if sim.frozen or Inventory.count(data.bag.items) == 0 then
		return false
	end
	local price = nextPurchasePrice(sim)
	if not price then
		return false
	end
	local coins = BigNum.toNumber(data.currencies.coins)
	if coins >= price then
		return false
	end
	local bag = BigNum.toNumber(Economy.sellValue(data.bag.items, ProgressionMath.incomeMultiplier(data)))
	return coins + bag >= price
end

local function manualActive(sim): boolean
	local profile = sim.profile
	if not profile.manual then
		return false
	end
	local untilDrones = profile.manualUntilDrones
	return untilDrones == nil or DroneLogic.owned(sim.data, "harvester") < untilDrones
end

function EconomySim.step(sim)
	local data = sim.data
	local profile = sim.profile
	sim.now += DT
	local now = sim.now

	-- Drones (une action par intervalle, mêmes règles que DroneService).
	local reserved = {}
	for _, drone in sim.drones do
		if now >= drone.nextAt then
			drone.nextAt = math.max(drone.nextAt + DroneLogic.interval(drone.def, data), now) -- comme DroneService
			for _, tileId in DroneLogic.selectTargets(data, now, drone.home, drone.def, reserved) do
				reserved[tileId] = true
				harvest(sim, tileId, "drone")
			end
		end
	end

	-- Ventes.
	if sim.sellingUntil and now >= sim.sellingUntil then
		sell(sim)
		sim.sellingUntil = nil
	end
	if profile.sellEvery and now >= sim.nextPeriodicSell then
		sim.nextPeriodicSell = now + profile.sellEvery
		if not sim.sellingUntil then
			sim.sellingUntil = now + profile.sellTrip
		end
	end

	-- Récolte manuelle (ou, sans joueur ni vente périodique, vente quand le sac est plein).
	if manualActive(sim) then
		if not sim.sellingUntil and now >= sim.nextManual then
			if
				Inventory.isFull(data.bag.items, Economy.bagCapacity(data))
				or (now % 1 < DT and shouldSellEarly(sim))
			then
				sim.sellingUntil = now + profile.sellTrip
			else
				local target, oldest = nil, math.huge
				for _, tileId in TILES do
					local tile = data.farm.tiles[tileId]
					if tile then
						local ripeAt = Growth.ripeAt(tile)
						if now - ripeAt >= profile.reaction and ripeAt < oldest then
							target, oldest = tileId, ripeAt
						end
					end
				end
				if target and harvest(sim, target, "player") then
					sim.nextManual = now + profile.moveTime
				end
			end
		end
	elseif not profile.sellEvery and not sim.sellingUntil then
		if Inventory.isFull(data.bag.items, Economy.bagCapacity(data)) then
			sim.sellingUntil = now + profile.sellTrip
		end
	end

	-- Achats et transitions (une fois par seconde).
	if not sim.frozen and now % 1 < DT then
		purchases(sim)
	end
end

-- Avance jusqu'à `predicate(sim)` vrai ou `maxTime` (s). Retourne l'instant atteint ou nil.
function EconomySim.runUntil(sim, predicate, maxTime: number): number?
	while sim.now < maxTime do
		EconomySim.step(sim)
		if predicate(sim) then
			return sim.now
		end
	end
	return nil
end

function EconomySim.eventTimes(sim, kind: string): { number }
	local times = {}
	for _, event in sim.events do
		if event.kind == kind then
			table.insert(times, event.time)
		end
	end
	return times
end

-- Coins gagnés par minute en régime établi : une seule graine, aucun achat ni transition, `duration` s.
function EconomySim.steadyIncome(profile, plantId: string, drones: number, duration: number, seed: number): number
	local data = DataSchema.template(0)
	data.seeds.unlocked[plantId] = true
	data.seeds.selected = plantId
	if drones > 0 then
		data.machines.drones.harvester = drones
	end
	local sim = EconomySim.new(profile, seed, data, true)
	while sim.now < duration do
		EconomySim.step(sim)
	end
	sell(sim)
	return BigNum.toNumber(sim.data.stats.coinsEarned) / (duration / 60)
end

return EconomySim
