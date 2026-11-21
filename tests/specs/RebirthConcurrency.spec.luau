-- Rebirth et opérations concurrentes : récolte joueur/drone préparée avant le reset, vente, sauvegarde/restauration.
-- Le serveur exécute chaque opération dans un mutateur synchrone : ces tests rejouent les entrelacements possibles.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local Resets = require(Shared.Util.Resets)
	local HarvestRules = require(Shared.Util.HarvestRules)
	local DroneLogic = require(Shared.Util.DroneLogic)
	local DroneConfig = require(Shared.Config.DroneConfig)
	local DataSchema = require(Shared.Util.DataSchema)
	local SessionLock = require(Shared.Util.SessionLock)
	local Economy = require(Shared.Util.Economy)
	local Inventory = require(Shared.Util.Inventory)
	local ProgressionMath = require(Shared.Util.ProgressionMath)
	local BigNum = require(Shared.Util.BigNum)
	local Deep = require(Shared.Util.Deep)
	local GameConfig = require(Shared.Config.GameConfig)

	local NOW = 1000

	-- Joueur prêt pour son premier rebirth : ferme mûre, 1 drone, sac partiellement rempli.
	local function readyFarm()
		local data = DataSchema.template(0)
		data.progression.cycleCoins = BigNum.fromNumber(150000)
		data.machines.drones.harvester = 1
		data.bag.items["tomato|giant"] = 5
		for index = 1, 9 do
			data.farm.tiles["main:" .. index] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
		end
		return data
	end

	-- Replantation faite par le serveur après le reset (FarmService) : cultures neuves, non mûres.
	local function replantAll(data, now)
		for index = 1, 9 do
			data.farm.tiles["main:" .. index] = { plantId = GameConfig.StarterSeed, plantedAt = now, growTime = 6 }
		end
	end

	describe("récolte et drone concurrents", function()
		it(
			"une récolte joueur décidée avant le reset ne s'applique pas après (case vide puis pas mûre)",
			function()
				local data = readyFarm()
				expect((HarvestRules.check(data, "main:1", NOW))).to.equal(true) -- vue « avant »
				assert(Resets.rebirth(data, 0))
				expect(select(2, HarvestRules.check(data, "main:1", NOW))).to.equal("empty")
				replantAll(data, NOW)
				expect(select(2, HarvestRules.check(data, "main:1", NOW))).to.equal("not_ripe")
				expect(Inventory.count(data.bag.items)).to.equal(0)
				expect(BigNum.isZero(data.progression.cycleCoins)).to.equal(true)
			end
		)

		it("une cible de drone choisie avant le reset est refusée, et la flotte est vide ensuite", function()
			local data = readyFarm()
			local def = assert(DroneConfig.get("harvester"))
			local home = DroneLogic.homePosition(1, 1)
			local targets = DroneLogic.selectTargets(data, NOW, home, def, {})
			expect(#targets).to.equal(1)
			assert(Resets.rebirth(data, 0))
			expect((HarvestRules.check(data, targets[1], NOW))).to.equal(false)
			expect(#DroneLogic.fleet(data)).to.equal(0)
			replantAll(data, NOW)
			expect(#DroneLogic.selectTargets(data, NOW + 6 + def.graceDelay - 0.1, home, def, {})).to.equal(0)
		end)

		it("le sac du cycle est vidé : rien à revendre avec le nouveau multiplicateur", function()
			local data = readyFarm()
			assert(Resets.rebirth(data, 0))
			expect(BigNum.isZero(Economy.sellValue(data.bag.items, ProgressionMath.incomeMultiplier(data)))).to.equal(
				true
			)
		end)

		it("après le reset, ventes et bonus suivent le nouveau multiplicateur (×1,365)", function()
			local data = readyFarm()
			assert(Resets.rebirth(data, 0))
			data.bag.items["carrot|normal"] = 10 -- récolté pendant le nouveau cycle
			local sale = Economy.sellValue(data.bag.items, ProgressionMath.incomeMultiplier(data))
			expect(BigNum.eq(sale, BigNum.fromNumber(136))).to.equal(true) -- floor(100 × 1,365)
			replantAll(data, NOW)
			local outcome = HarvestRules.apply(data, "main:1", NOW + 6.5, "player")
			expect(BigNum.eq(outcome.bonus, BigNum.fromNumber(6))).to.equal(true) -- floor(5 × 1,365)
		end)
	end)

	describe("sauvegarde et restauration", function()
		local function newStore()
			local entries = {}
			local store = {}
			function store.update(key, transform)
				local result = transform(Deep.copy(entries[key]))
				if result ~= nil then
					entries[key] = Deep.copy(result)
				end
			end
			function store.peek(key)
				return Deep.copy(entries[key])
			end
			return store
		end

		local function save(store, data, now)
			store.update("p", function(old)
				return SessionLock.write(old, "S", Deep.copy(data), false, now, GameConfig.Data.RecordFormat)
			end)
		end

		it("chaque sauvegarde est cohérente : jamais de récompense sans le reset correspondant", function()
			local store = newStore()
			store.update("p", function(old)
				local _, record = SessionLock.acquire(old, "S", 0, GameConfig.Data.LockTimeout, 1)
				return record
			end)
			local data = readyFarm()
			save(store, data, 10) -- autosave avant le rebirth
			local before = DataSchema.load(store.peek("p").data, 11)
			expect(BigNum.isZero(before.currencies.essence)).to.equal(true)
			expect(before.progression.rebirths).to.equal(0)

			assert(Resets.rebirth(data, 0))
			save(store, data, 12) -- SaveNow juste après le rebirth
			local after = DataSchema.load(store.peek("p").data, 13)
			expect(after.progression.rebirths).to.equal(1)
			expect(after.progression.revision).to.equal(1)
			expect(BigNum.eq(after.currencies.essence, BigNum.fromNumber(122))).to.equal(true) -- 100 × √1,5
			expect(BigNum.isZero(after.progression.cycleCoins)).to.equal(true)
			expect(next(after.bag.items)).to.equal(nil)
		end)

		it("une requête rejouée après restauration est refusée (révision persistée)", function()
			local data = readyFarm()
			assert(Resets.rebirth(data, 0))
			local restored = DataSchema.load(Deep.copy(data), 20)
			restored.progression.cycleCoins = BigNum.fromNumber(1e9)
			expect(select(2, Resets.rebirth(restored, 0))).to.equal("stale_revision")
			expect(restored.progression.rebirths).to.equal(1)
		end)
	end)
end
