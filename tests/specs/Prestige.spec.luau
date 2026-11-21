-- Prestige (Phase 3, jalon B) : transition atomique et idempotente, conservation exacte, opérations concurrentes,
-- révisions croisées rebirth/prestige, sauvegarde/restauration simulée (store mémoire à sémantique UpdateAsync —
-- ce n'est PAS une validation du vrai DataStore).
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
	local ProgressionMath = require(Shared.Util.ProgressionMath)
	local FarmLayout = require(Shared.Util.FarmLayout)
	local BigNum = require(Shared.Util.BigNum)
	local Deep = require(Shared.Util.Deep)
	local GameConfig = require(Shared.Config.GameConfig)

	local NOW = 1000
	local REVISION = 9

	-- Joueur prêt pour son premier prestige (6 rebirths : un de plus que le minimum), chaque catégorie remplie.
	local function readyData()
		local data = DataSchema.template(0)
		data.currencies.coins = BigNum.fromNumber(4e6)
		data.currencies.essence = BigNum.fromNumber(1600)
		data.currencies.primalCores = BigNum.fromNumber(3)
		data.currencies.rebirthTokens = 2 -- obsolète, conservé tel quel
		data.farm.plots.west = true -- parcelle achetée : perdue au prestige
		data.seeds.unlocked.tomato = true
		data.seeds.selected = "tomato"
		data.bag.items["tomato|giant"] = 5
		data.upgrades.normal.speed = 4
		data.upgrades.rebirth.essence_luck = 3
		data.upgrades.permanent.mutagenic_energy = 2
		data.machines.drones.harvester = 2
		data.progression.rebirths = 6
		data.progression.revision = REVISION
		data.progression.cycleCoins = BigNum.fromNumber(5000)
		data.progression.prestigeCoins = BigNum.fromNumber(2e7)
		data.mutadex["carrot|shiny"] = 123
		data.cosmetics.owned.hat = true
		data.cosmetics.equipped.head = "hat"
		data.pets.owned.cat = 1
		data.receipts = { "purchase-1", "purchase-2" } -- droits Robux
		data.stats.harvests = 900
		data.stats.coinsEarned = BigNum.fromNumber(2.5e7)
		data.stats.totalRebirths = 6
		data.meta.quarantine = { { path = "x", value = 1, reason = "test", at = 0 } }
		for index = 1, 9 do
			data.farm.tiles["main:" .. index] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
		end
		data.farm.tiles["west:1"] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
		return data
	end

	-- Chemins modifiés par un prestige ; tout le reste doit rester identique.
	local PRESTIGE_RESET = {
		"currencies.coins",
		"currencies.essence",
		"currencies.primalCores", -- augmentés de la récompense (vérifiée à part)
		"seeds",
		"bag",
		"upgrades.normal",
		"upgrades.rebirth",
		"machines.drones",
		"farm.tiles",
		"farm.plots",
		"progression.rebirths",
		"progression.prestiges",
		"progression.revision",
		"progression.cycleCoins",
		"progression.prestigeCoins",
	}

	local function without(data, paths)
		local copy = Deep.copy(data)
		for _, path in paths do
			local parts = string.split(path, ".")
			local node = copy
			for index = 1, #parts - 1 do
				node = node[parts[index]]
			end
			node[parts[#parts]] = nil
		end
		return copy
	end

	-- Replantation faite par le serveur après le reset (FarmService) : parcelle principale seulement.
	local function replantMain(data, now)
		for index = 1, 9 do
			data.farm.tiles["main:" .. index] = { plantId = GameConfig.StarterSeed, plantedAt = now, growTime = 6 }
		end
	end

	describe("transition", function()
		it("réinitialise le cycle de prestige et crédite les Primal Cores, révision +1", function()
			local data = readyData()
			local outcome, failure = Resets.prestige(data, REVISION)
			expect(failure).to.equal(nil)
			expect(outcome.prestiges).to.equal(1)
			expect(outcome.revision).to.equal(REVISION + 1)
			expect(outcome.multiplier).to.be.near(1.58, 1e-12)
			expect(BigNum.eq(outcome.cores, BigNum.fromNumber(12))).to.equal(true) -- 6 rebirths : 10 × 1,25
			expect(BigNum.eq(data.currencies.primalCores, BigNum.fromNumber(15))).to.equal(true)
			for _, amount in
				{
					data.currencies.coins,
					data.currencies.essence,
					data.progression.cycleCoins,
					data.progression.prestigeCoins,
				}
			do
				expect(BigNum.isZero(amount)).to.equal(true)
			end
			expect(data.progression.rebirths).to.equal(0)
			expect(data.progression.prestiges).to.equal(1)
			expect(Deep.equal(data.farm.plots, FarmLayout.defaultPlots())).to.equal(true)
			expect(data.seeds.selected).to.equal(GameConfig.StarterSeed)
			expect(data.seeds.unlocked.tomato).to.equal(nil)
			for _, container in
				{ data.bag.items, data.upgrades.normal, data.upgrades.rebirth, data.machines.drones, data.farm.tiles }
			do
				expect(next(container)).to.equal(nil)
			end
		end)

		it(
			"conserve à l'identique Mutadex, cosmétiques, familiers, droits Robux, améliorations permanentes, stats",
			function()
				local before = readyData()
				local data = Deep.copy(before)
				assert(Resets.prestige(data, REVISION))
				expect(Deep.equal(without(data, PRESTIGE_RESET), without(before, PRESTIGE_RESET))).to.equal(true)
				expect(data.upgrades.permanent.mutagenic_energy).to.equal(2)
				expect(data.receipts[2]).to.equal("purchase-2")
				expect(data.stats.totalRebirths).to.equal(6)
				expect(BigNum.eq(data.stats.coinsEarned, BigNum.fromNumber(2.5e7))).to.equal(true)
				expect(data.currencies.rebirthTokens).to.equal(2)
			end
		)

		it("refuse sans rien modifier : révision périmée, rebirths insuffisants, Coins insuffisants", function()
			local cases = {
				{ "stale_revision", REVISION - 1, function(_) end },
				{
					"not_enough_rebirths",
					REVISION,
					function(data)
						data.progression.rebirths = 4
					end,
				},
				{
					"not_enough_coins",
					REVISION,
					function(data)
						data.progression.prestigeCoins = BigNum.fromNumber(9999999)
					end,
				},
			}
			for _, case in cases do
				local data = readyData()
				case[3](data)
				local snapshot = Deep.copy(data)
				local outcome, failure = Resets.prestige(data, case[2])
				expect(outcome).to.equal(nil)
				expect(failure).to.equal(case[1])
				expect(Deep.equal(data, snapshot)).to.equal(true)
			end
		end)

		it("double requête : 100 appels avec la même révision = une seule récompense", function()
			local data = readyData()
			data.progression.prestigeCoins = BigNum.fromNumber(1e15) -- même si l'éligibilité restait vraie
			local successes = 0
			for _ = 1, 100 do
				if Resets.prestige(data, REVISION) then
					successes += 1
				end
			end
			expect(successes).to.equal(1)
			expect(data.progression.prestiges).to.equal(1)
			expect(BigNum.eq(data.currencies.primalCores, BigNum.fromNumber(15))).to.equal(true)
		end)

		it("révisions croisées : un rebirth ou un prestige préparé avant l'autre transition est refusé", function()
			local data = readyData()
			data.progression.cycleCoins = ProgressionMath.rebirthThreshold(6) -- rebirth n° 7 possible aussi
			assert(Resets.prestige(data, REVISION))
			expect(select(2, Resets.rebirth(data, REVISION))).to.equal("stale_revision")

			local other = readyData()
			other.progression.cycleCoins = ProgressionMath.rebirthThreshold(6)
			assert(Resets.rebirth(other, REVISION))
			expect(select(2, Resets.prestige(other, REVISION))).to.equal("stale_revision")
			expect(other.progression.prestiges).to.equal(0)
		end)

		it("après un prestige, le cycle repart du premier seuil avec le multiplicateur de prestige", function()
			local data = readyData()
			assert(Resets.prestige(data, REVISION))
			local threshold = ProgressionMath.rebirthThreshold(data.progression.rebirths)
			expect(BigNum.eq(threshold, BigNum.fromNumber(100000))).to.equal(true)
			expect(ProgressionMath.incomeMultiplier(data)).to.be.near(1.58, 1e-12)
			data.progression.cycleCoins = BigNum.fromNumber(100000)
			local rebirth = assert(Resets.rebirth(data, REVISION + 1))
			expect(rebirth.multiplier).to.be.near(1.365 * 1.58, 1e-12)
			expect(BigNum.eq(rebirth.essence, BigNum.fromNumber(100))).to.equal(true)
		end)
	end)

	describe("opérations concurrentes", function()
		it("une récolte décidée avant le prestige ne s'applique pas après ; parcelle rendue refusée", function()
			local data = readyData()
			expect((HarvestRules.check(data, "main:1", NOW))).to.equal(true)
			expect((HarvestRules.check(data, "west:1", NOW))).to.equal(true)
			assert(Resets.prestige(data, REVISION))
			expect(select(2, HarvestRules.check(data, "main:1", NOW))).to.equal("empty")
			expect((HarvestRules.check(data, "west:1", NOW))).to.equal(false) -- parcelle perdue
			replantMain(data, NOW)
			expect(select(2, HarvestRules.check(data, "main:1", NOW))).to.equal("not_ripe")
		end)

		it("une cible de drone choisie avant le prestige est refusée ; flotte vide", function()
			local data = readyData()
			local def = assert(DroneConfig.get("harvester"))
			local targets = DroneLogic.selectTargets(data, NOW, DroneLogic.homePosition(1, 2), def, {})
			expect(#targets > 0).to.equal(true)
			assert(Resets.prestige(data, REVISION))
			for _, tileId in targets do
				expect((HarvestRules.check(data, tileId, NOW))).to.equal(false)
			end
			expect(#DroneLogic.fleet(data)).to.equal(0)
		end)

		it("sac vidé ; ventes et bonus ensuite au multiplicateur de prestige (×1,58)", function()
			local data = readyData()
			assert(Resets.prestige(data, REVISION))
			local emptySale = Economy.sellValue(data.bag.items, ProgressionMath.incomeMultiplier(data))
			expect(BigNum.isZero(emptySale)).to.equal(true)
			data.bag.items["carrot|normal"] = 10
			local sale = Economy.sellValue(data.bag.items, ProgressionMath.incomeMultiplier(data))
			expect(BigNum.eq(sale, BigNum.fromNumber(158))).to.equal(true) -- floor(100 × 1,58)
			replantMain(data, NOW)
			local outcome = HarvestRules.apply(data, "main:1", NOW + 6.5, "player")
			expect(BigNum.eq(outcome.bonus, BigNum.fromNumber(7))).to.equal(true) -- floor(5 × 1,58)
		end)
	end)

	describe("sauvegarde et restauration (simulation)", function()
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

		it("chaque sauvegarde contient l'état avant OU après, jamais de Primal Cores sans le reset", function()
			local store = newStore()
			store.update("p", function(old)
				local _, record = SessionLock.acquire(old, "S", 0, GameConfig.Data.LockTimeout, 1)
				return record
			end)
			local data = readyData()
			save(store, data, 10)
			local before = DataSchema.load(store.peek("p").data, 11)
			expect(before.progression.prestiges).to.equal(0)
			expect(BigNum.eq(before.currencies.primalCores, BigNum.fromNumber(3))).to.equal(true)
			expect(before.progression.rebirths).to.equal(6)

			assert(Resets.prestige(data, REVISION))
			save(store, data, 12)
			local after = DataSchema.load(store.peek("p").data, 13)
			expect(after.progression.prestiges).to.equal(1)
			expect(BigNum.eq(after.currencies.primalCores, BigNum.fromNumber(15))).to.equal(true)
			expect(after.progression.rebirths).to.equal(0)
			expect(BigNum.isZero(after.currencies.essence)).to.equal(true)
			expect(after.farm.plots.west).to.equal(nil)
			expect(after.receipts[1]).to.equal("purchase-1")
			expect(#after.meta.quarantine).to.equal(1) -- aucune nouvelle mise en quarantaine
		end)

		it("une requête rejouée après restauration est refusée (révision persistée)", function()
			local data = readyData()
			assert(Resets.prestige(data, REVISION))
			local restored = DataSchema.load(Deep.copy(data), 20)
			restored.progression.rebirths = 50
			restored.progression.prestigeCoins = BigNum.fromNumber(1e15)
			expect(select(2, Resets.prestige(restored, REVISION))).to.equal("stale_revision")
			expect(restored.progression.prestiges).to.equal(1)
		end)
	end)
end
