-- Simulation des revenus : récolte manuelle vs drones, avec les modules purs du jeu (HarvestRules, DroneLogic,
-- Economy) — aucune règle recopiée. Hypothèses (docs/ECONOMY.md §7) : 9 cases d'une seule plante ; joueur
-- « attentif » qui récolte la case mûre la plus ancienne avec 1,2 s de déplacement entre deux récoltes ; vente quand
-- le sac est plein (aller-retour 8 s, récolte manuelle suspendue) ; valeur de vente = espérance des mutations.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local Shared = ReplicatedStorage.Shared
	local DroneConfig = require(Shared.Config.DroneConfig)
	local MutationConfig = require(Shared.Config.MutationConfig)
	local PlantConfig = require(Shared.Config.PlantConfig)
	local BigNum = require(Shared.Util.BigNum)
	local DataSchema = require(Shared.Util.DataSchema)
	local DroneLogic = require(Shared.Util.DroneLogic)
	local Economy = require(Shared.Util.Economy)
	local FarmLayout = require(Shared.Util.FarmLayout)
	local HarvestRules = require(Shared.Util.HarvestRules)
	local Inventory = require(Shared.Util.Inventory)
	local MutationRoll = require(Shared.Util.MutationRoll)
	local MutationOdds = require(ServerScriptService.Server.Config.MutationOdds)

	local MOVE_TIME = 1.2
	local SELL_TRIP = 8
	local DT = 0.05
	local DURATION = 600
	local EXPECTED_MULTIPLIER = MutationRoll.expectedMultiplier(MutationOdds.Weights, MutationConfig.multipliers())

	type Stats = {
		coins: number,
		bonus: number,
		manual: number,
		drone: number,
		maxBag: number,
		perMinute: number,
	}

	local function simulate(plantId: string, manual: boolean, droneCount: number): Stats
		local plant = assert(PlantConfig.get(plantId))
		local data = DataSchema.template(0)
		data.seeds.unlocked[plantId] = true
		data.seeds.selected = plantId
		if droneCount > 0 then
			data.machines.drones.harvester = droneCount
		end
		for _, tileId in FarmLayout.tileIds("main") do
			data.farm.tiles[tileId] = { plantId = plantId, plantedAt = 0, growTime = plant.growTime }
		end
		local fleet = DroneLogic.fleet(data)
		local drones = {}
		for index, def in fleet do
			table.insert(drones, {
				def = def,
				home = DroneLogic.homePosition(index, #fleet),
				nextAt = def.interval * index / #fleet,
			})
		end
		local capacity = Economy.bagCapacity(data)
		local stats: Stats = { coins = 0, bonus = 0, manual = 0, drone = 0, maxBag = 0, perMinute = 0 }
		local now = 0
		local nextManual = 0
		local sellingUntil: number? = nil

		local function harvest(tileId: string, source): boolean
			if not HarvestRules.check(data, tileId, now) then
				return false
			end
			local outcome = HarvestRules.apply(data, tileId, now, source)
			stats.bonus += BigNum.toNumber(outcome.bonus)
			data.farm.tiles[tileId] = { plantId = plantId, plantedAt = now, growTime = plant.growTime }
			if source == "player" then
				stats.manual += 1
			else
				stats.drone += 1
			end
			stats.maxBag = math.max(stats.maxBag, Inventory.count(data.bag.items))
			return true
		end

		while now < DURATION do
			if sellingUntil and now >= sellingUntil then
				stats.coins += BigNum.toNumber(Economy.sellValue(data.bag.items, EXPECTED_MULTIPLIER))
				data.bag.items = {}
				sellingUntil = nil
			elseif not sellingUntil and Inventory.isFull(data.bag.items, capacity) then
				sellingUntil = now + SELL_TRIP
			end
			local reserved = {}
			for _, drone in drones do
				if now >= drone.nextAt then
					drone.nextAt += drone.def.interval
					for _, tileId in DroneLogic.selectTargets(data, now, drone.home, drone.def, reserved) do
						reserved[tileId] = true
						harvest(tileId, "drone")
					end
				end
			end
			if manual and not sellingUntil and now >= nextManual then
				local best, bestRipe = nil, math.huge
				for tileId, tile in data.farm.tiles do
					local ripeAt = tile.plantedAt + tile.growTime
					if ripeAt <= now and ripeAt < bestRipe then
						best, bestRipe = tileId, ripeAt
					end
				end
				if best and harvest(best, "player") then
					nextManual = now + MOVE_TIME
				end
			end
			now += DT
		end
		assert(stats.manual + stats.drone == data.stats.harvests, "récoltes comptées deux fois")
		stats.perMinute = (stats.coins + stats.bonus) / (DURATION / 60)
		return stats
	end

	local scenarios = {}
	for _, plantId in { "carrot", "tomato" } do
		scenarios[plantId] = {
			manual = simulate(plantId, true, 0),
			manual1 = simulate(plantId, true, 1),
			manual3 = simulate(plantId, true, 3),
			drones1 = simulate(plantId, false, 1),
			drones3 = simulate(plantId, false, 3),
		}
	end

	describe("invariants de la simulation (10 min)", function()
		it("le sac ne dépasse jamais sa capacité", function()
			for _, set in scenarios do
				for _, stats in set do
					expect(stats.maxBag <= 40).to.equal(true)
				end
			end
		end)

		it("les drones seuls ne touchent jamais de bonus de précision", function()
			for _, set in scenarios do
				expect(set.drones1.bonus).to.equal(0)
				expect(set.drones3.bonus).to.equal(0)
			end
		end)

		it("jamais plus de récoltes que la ferme n'en produit", function()
			for plantId, set in scenarios do
				local supply = 9 * (DURATION / PlantConfig.get(plantId).growTime + 1)
				for _, stats in set do
					expect(stats.manual + stats.drone <= supply).to.equal(true)
				end
			end
		end)

		it(
			"les drones ne réduisent jamais les ventes du joueur ; une perte ne vient que des bonus remplacés",
			function()
				for _, set in scenarios do
					expect(set.manual1.coins >= set.manual.coins).to.equal(true)
					expect(set.manual3.coins >= set.manual.coins).to.equal(true)
				end
			end
		)

		it("drones seuls : plus de drones rapporte plus, mais un drone reste sous un joueur attentif", function()
			for _, set in scenarios do
				expect(set.drones3.perMinute > set.drones1.perMinute).to.equal(true)
				expect(set.drones1.perMinute > 0).to.equal(true)
				expect(set.drones1.perMinute < set.manual.perMinute).to.equal(true)
			end
		end)

		it("Carotte (production > cadence du joueur) : chaque drone ajoute du revenu au jeu actif", function()
			local carrot = scenarios.carrot
			expect(carrot.manual1.perMinute > carrot.manual.perMinute).to.equal(true)
			expect(carrot.manual3.perMinute > carrot.manual1.perMinute).to.equal(true)
		end)

		it("le premier drone se rembourse en moins de 30 min là où il rapporte", function()
			local price = DroneLogic.price(assert(DroneConfig.get("harvester")), 0)
			local carrot = scenarios.carrot
			expect(price / (carrot.manual1.perMinute - carrot.manual.perMinute) <= 30).to.equal(true)
			for _, set in scenarios do
				expect(price / set.drones1.perMinute <= 30).to.equal(true) -- joueur absent qui vend
			end
		end)

		it("délai de grâce : des drones ne font jamais perdre plus de 1 % à un joueur attentif", function()
			-- Tolérance : les replantations décalées par un drone déplacent le calendrier de maturité (≈ 2 bonus / 10 min).
			for _, set in scenarios do
				for _, withDrones in { set.manual1, set.manual3 } do
					expect(withDrones.perMinute >= set.manual.perMinute * 0.99).to.equal(true)
				end
			end
			expect(scenarios.tomato.manual1.perMinute > scenarios.tomato.manual.perMinute).to.equal(true)
		end)
	end)
end
