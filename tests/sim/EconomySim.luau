-- EconomySim — simulateur économique DÉTERMINISTE (Phase 3, jalon C). Rejoue une partie avec les règles pures du
-- jeu — HarvestRules, Economy, DroneLogic, ProgressionMath, Resets, Upgrades, MutationRoll, Expansions — sans en
-- recopier aucune : seules les décisions du joueur (profil) sont modélisées. Pas de temps fixe (DT), mutations tirées
-- avec math.random après math.randomseed(graine) : même graine = même partie.
-- Hypothèses (docs/ECONOMY.md §8) : cases des parcelles possédées ; récolte manuelle de la case mûre la plus
-- ancienne après `reaction` s (bonus Parfait ≤ 1,5 s, Bien ≤ 5 s), `moveTime` s entre deux récoltes (+ `plotSwitch`
-- s pour changer de parcelle) ; vente quand le sac est plein (aller-retour `sellTrip` s, récolte manuelle suspendue,
-- drones actifs) ou toutes les `sellEvery` s.
-- Achats : graine suivante dès qu'elle est payable (et sélectionnée), extensions (profils `expansions`) dès qu'elles
-- sont payables, drones jusqu'à `targetDrones`, rebirth et prestige dès l'éligibilité, améliorations les moins
-- chères d'abord.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Shared = ReplicatedStorage.Shared
local PlantConfig = require(Shared.Config.PlantConfig)
local DroneConfig = require(Shared.Config.DroneConfig)
local UpgradeConfig = require(Shared.Config.UpgradeConfig)
local MutationConfig = require(Shared.Config.MutationConfig)
local GameConfig = require(Shared.Config.GameConfig)
local Automation = require(Shared.Util.Automation)
local BigNum = require(Shared.Util.BigNum)
local DataSchema = require(Shared.Util.DataSchema)
local DroneLogic = require(Shared.Util.DroneLogic)
local Economy = require(Shared.Util.Economy)
local Expansions = require(Shared.Util.Expansions)
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
local DEFAULT_PLOT_SWITCH = 2 -- s : changer de parcelle (allée, escalier de la terrasse)

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
		expansions = true,
	},
	hybrid = {
		name = "2. Hybride, 1 drone",
		manual = true,
		reaction = 3.0,
		moveTime = 1.5,
		sellTrip = 8,
		targetDrones = 1,
		expansions = true,
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
		expansions = true,
	},
	-- Phase 5 : principalement automatisé avec le comptoir automatique (aucun aller-retour au marché après l'achat).
	automatedSeller = {
		name = "3 bis. Automatisé + comptoir automatique",
		manual = true,
		manualUntilDrones = 1,
		reaction = 3.0,
		moveTime = 1.5,
		sellTrip = 8,
		targetDrones = 3,
		expansions = true,
		autoSeller = true,
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
		coinUpgrades = true, -- améliorations normales (Phase 5) : coût ≤ 20 % du solde
		expansions = true,
	},
}

-- Copie d'un profil avec des champs remplacés (mesures comparatives du rapport).
function EconomySim.variant(profile, overrides)
	local copy = table.clone(profile)
	for key, value in overrides do
		copy[key] = value
	end
	return copy
end

-- Variabilité du joueur (réaction et cadence ±) : générateur congruentiel SÉPARÉ, à graine fixe. Il ne consomme pas
-- la suite des mutations (math.random) : deux parties de même graine gardent les mêmes mutations dans l'ordre des
-- plantations. Sans elle, un joueur « métronome » crée des effets de phase artificiels (bonus Parfait gagnés ou
-- perdus selon l'instant des allers-retours au marché).
local function newJitter(seed: number): () -> number
	local state = (seed * 2654435761 + 12345) % 4294967296
	return function(): number
		state = (1664525 * state + 1013904223) % 4294967296
		return state / 4294967296
	end
end

local weightsCache = {}
local function weightsFor(luck: number)
	local cached = weightsCache[luck]
	if not cached then
		cached = MutationRoll.applyLuck(MutationOdds.Weights, MutationOdds.Luck.Base * luck)
		weightsCache[luck] = cached
	end
	return cached
end

-- Tirages de mutation : un flux par plante (graine fixe). La n-ième Citrouille plantée reçoit le même nombre dans
-- deux parties comparées (avec / sans amélioration) : une mutation rare ne change pas de plante d'une partie à
-- l'autre, ce qui réduit fortement la variance des comparaisons (nombres aléatoires communs).
local function mutationDraw(sim, plantId: string): number
	local stream = sim.mutationStreams[plantId]
	if not stream then
		local plant = PlantConfig.get(plantId)
		stream = newJitter(sim.seed * 7919 + (if plant then plant.order else 0) * 104729)
		sim.mutationStreams[plantId] = stream
	end
	return stream()
end

local function plant(sim, tileId: string)
	local data = sim.data
	local plantId = data.seeds.selected
	local mutation = MutationRoll.pick(weightsFor(Upgrades.luck(data)), mutationDraw(sim, plantId))
	data.farm.tiles[tileId] = {
		plantId = plantId,
		plantedAt = sim.now,
		growTime = Economy.growTime(data, plantId),
		mutation = if mutation ~= MutationConfig.NORMAL then mutation else nil,
	}
end

-- Cases cultivables : celles des parcelles possédées (extensions comprises), recalculées à chaque achat ou reset.
local function refreshTiles(sim)
	sim.tiles = Expansions.unlockedTiles(sim.data)
end

local function replantAll(sim)
	for _, tileId in sim.tiles do
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
		seed = seed,
		jitter = newJitter(seed),
		mutationStreams = {},
		reaction = profile.reaction or 0,
		sellingUntil = nil,
		nextPeriodicSell = profile.sellEvery or math.huge,
		drones = {},
		tiles = {},
		lastPlot = "main",
		events = {}, -- { kind, time, detail }
		manualHarvests = 0,
		droneHarvests = 0,
		autoSales = 0,
		coinsBySource = { player = 0, drone = 0 },
	}
	sim.data.farm.tiles = {}
	refreshTiles(sim)
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
	-- Comptoir automatique (Phase 5) : même règle pure que le serveur, appelée juste après chaque récolte.
	local sale = Automation.autoSell(data, sim.now)
	if sale then
		sim.autoSales += 1
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
			-- L'arbre Coins (améliorations normales) suit sa propre règle (buyCoinUpgrades).
			if def.tree ~= "coins" and level < def.maxLevel and not useless then
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

-- Améliorations normales (arbre Coins, Phase 5) : la moins chère, seulement si elle coûte au plus `COIN_UPGRADE_SHARE`
-- du solde (le joueur garde l'essentiel pour la graine suivante). Sac : seulement pour un joueur qui compte sur ses
-- drones (pour un joueur présent, la vente par habitude rend des places en plus inutiles, §8).
local COIN_UPGRADE_SHARE = 0.2
local function buyCoinUpgrades(sim)
	local data = sim.data
	while true do
		local best, bestLevel, bestCost = nil, 0, nil
		for _, def in Upgrades.list("coins") do
			local level = Upgrades.level(data, def.id)
			local useless = def.effect == "bag" and sim.profile.targetDrones == 0
			if level < def.maxLevel and not useless then
				local cost = BigNum.toNumber(Upgrades.cost(def, level))
				if bestCost == nil or cost < bestCost then
					best, bestLevel, bestCost = def, level, cost
				end
			end
		end
		if not best or not bestCost or bestCost > COIN_UPGRADE_SHARE * BigNum.toNumber(data.currencies.coins) then
			return
		end
		assert(Upgrades.purchase(data, best.id, bestLevel))
		table.insert(sim.events, { kind = "coinUpgrade", time = sim.now, detail = best.id .. " " .. (bestLevel + 1) })
	end
end

local function afterReset(sim)
	refreshTiles(sim)
	replantAll(sim)
	rebuildFleet(sim)
end

local function manualActive(sim): boolean
	local profile = sim.profile
	if not profile.manual then
		return false
	end
	local untilDrones = profile.manualUntilDrones
	return untilDrones == nil or DroneLogic.owned(sim.data, "harvester") < untilDrones
end

-- Récoltes par seconde que le joueur et ses drones peuvent assurer, et que les cases possédées produisent avec la
-- graine actuelle. Un joueur raisonnable n'achète une extension que si ses cases ne suffisent plus à occuper ses
-- récolteurs : sinon les nouvelles cases ne produisent rien de plus (récolteurs saturés) et l'achat retarde
-- seulement la graine suivante (constat du simulateur, docs/ECONOMY.md §12).
local function harvestCapacity(sim): number
	local rate = 0
	if manualActive(sim) then
		rate += 1 / (sim.profile.moveTime + DEFAULT_PLOT_SWITCH / 2)
	end
	for _, drone in sim.drones do
		rate += drone.def.capacity / DroneLogic.interval(drone.def, sim.data)
	end
	return rate
end

local function farmProduction(sim): number
	local data = sim.data
	local waiting = if manualActive(sim) then sim.profile.reaction or 0 else 0
	if #sim.drones > 0 and not manualActive(sim) then
		waiting = sim.drones[1].def.graceDelay
	end
	return #sim.tiles / (Economy.growTime(data, data.seeds.selected) + waiting)
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
	-- Extension suivante dès qu'elle est payable ET utile (récolteurs sous-occupés) ; règle pure du serveur.
	local expansion = if profile.expansions then Expansions.nextToBuy(data) else nil
	if
		expansion
		and Expansions.canBuy(data, expansion.plotId)
		and (profile.expansions == "always" or farmProduction(sim) < harvestCapacity(sim))
	then
		assert(Expansions.purchase(data, expansion.plotId))
		refreshTiles(sim)
		replantAll(sim)
		table.insert(sim.events, { kind = "expansion", time = sim.now, detail = expansion.plotId })
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
	-- Comptoir automatique (Phase 5) dès le premier drone (règle pure du serveur ; à racheter après chaque rebirth).
	if profile.autoSeller and DroneLogic.owned(data, "harvester") >= 1 and Automation.canBuySeller(data) then
		assert(Automation.buySeller(data))
		table.insert(sim.events, { kind = "autoSeller", time = sim.now, detail = "" })
	end
	-- Transitions (règles pures du serveur).
	if profile.prestige and ProgressionMath.canPrestige(data) then
		local outcome = assert(Resets.prestige(data, data.progression.revision))
		table.insert(sim.events, { kind = "prestige", time = sim.now, detail = BigNum.toNumber(outcome.cores) })
		afterReset(sim)
	elseif profile.rebirth and ProgressionMath.canRebirth(data) then
		local outcome = assert(Resets.rebirth(data, data.progression.revision))
		table.insert(sim.events, { kind = "rebirth", time = sim.now, detail = BigNum.toNumber(outcome.essence) })
		afterReset(sim)
	end
	if profile.coinUpgrades then
		buyCoinUpgrades(sim)
	end
	if profile.buyUpgrades then
		local before = DroneLogic.owned(data, "harvester")
		buyCheapestUpgrades(sim)
		if DroneLogic.owned(data, "harvester") ~= before then
			rebuildFleet(sim)
		end
	end
end

-- Prochain achat visé par le joueur (graine suivante, extension, drone manquant) : prix en Coins, ou nil.
local function nextPurchasePrice(sim): number?
	local data = sim.data
	local best: number? = nil
	local nextPlant = PlantConfig.nextAfter(data.seeds.selected)
	if nextPlant and not data.seeds.unlocked[nextPlant.id] then
		best = nextPlant.unlockPrice
	end
	local expansion = if sim.profile.expansions then Expansions.nextToBuy(data) else nil
	if expansion and farmProduction(sim) < harvestCapacity(sim) then
		best = if best then math.min(best, expansion.price) else expansion.price
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
	-- Un joueur présent va vendre par habitude dès que son sac atteint la capacité de BASE (ou quand son contenu
	-- paie son prochain achat) : les places en plus servent de tampon (drones, absences). Sans cette règle, le
	-- rythme des ventes dépendrait de la capacité et créerait des effets de phase artificiels sur les bonus Parfait.
	if manualActive(sim) then
		if not sim.sellingUntil and now >= sim.nextManual then
			local count = Inventory.count(data.bag.items)
			local habit = math.min(Economy.bagCapacity(data), GameConfig.Bag.BaseCapacity)
			if count >= habit or (now % 1 < DT and shouldSellEarly(sim)) then
				sim.sellingUntil = now + profile.sellTrip
			else
				local target, oldest = nil, math.huge
				for _, tileId in sim.tiles do
					local tile = data.farm.tiles[tileId]
					if tile then
						local ripeAt = Growth.ripeAt(tile)
						if now - ripeAt >= sim.reaction and ripeAt < oldest then
							target, oldest = tileId, ripeAt
						end
					end
				end
				if target and harvest(sim, target, "player") then
					-- Réaction ×[0,6 ; 1,4] et cadence ×[0,8 ; 1,2] autour des valeurs du profil ; changer de
					-- parcelle coûte un trajet.
					local plotId = FarmLayout.parseTileId(target)
					local travel = if plotId ~= sim.lastPlot then profile.plotSwitch or DEFAULT_PLOT_SWITCH else 0
					sim.lastPlot = plotId or sim.lastPlot
					sim.reaction = profile.reaction * (0.6 + 0.8 * sim.jitter())
					sim.nextManual = now + profile.moveTime * (0.8 + 0.4 * sim.jitter()) + travel
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
-- `plots` : parcelles possédées en plus de la parcelle de départ (ex. { "west" }) ; `prepare` : réglages
-- supplémentaires de la donnée de départ (ex. comptoir automatique installé).
function EconomySim.steadyIncome(
	profile,
	plantId: string,
	drones: number,
	duration: number,
	seed: number,
	plots: { string }?,
	prepare: ((any) -> ())?
): number
	local data = DataSchema.template(0)
	data.seeds.unlocked[plantId] = true
	data.seeds.selected = plantId
	if drones > 0 then
		data.machines.drones.harvester = drones
	end
	for _, plotId in plots or {} do
		data.farm.plots[plotId] = true
	end
	if prepare then
		prepare(data)
	end
	local sim = EconomySim.new(profile, seed, data, true)
	while sim.now < duration do
		EconomySim.step(sim)
	end
	sell(sim)
	return BigNum.toNumber(sim.data.stats.coinsEarned) / (duration / 60)
end

return EconomySim
