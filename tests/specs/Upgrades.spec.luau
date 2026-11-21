-- Améliorations (Phase 3, jalon C) : catalogue, coûts exacts, achat atomique et idempotent, nombres invalides,
-- effets cumulés et plafonds, intégration aux resets et aux revenus, assainissement des données malformées.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local Shared = ReplicatedStorage.Shared
	local UpgradeConfig = require(Shared.Config.UpgradeConfig)
	local MutationConfig = require(Shared.Config.MutationConfig)
	local DroneConfig = require(Shared.Config.DroneConfig)
	local GameConfig = require(Shared.Config.GameConfig)
	local Upgrades = require(Shared.Util.Upgrades)
	local Economy = require(Shared.Util.Economy)
	local ProgressionMath = require(Shared.Util.ProgressionMath)
	local DroneLogic = require(Shared.Util.DroneLogic)
	local Resets = require(Shared.Util.Resets)
	local DataSchema = require(Shared.Util.DataSchema)
	local MutationRoll = require(Shared.Util.MutationRoll)
	local BigNum = require(Shared.Util.BigNum)
	local Deep = require(Shared.Util.Deep)
	local MutationOdds = require(ServerScriptService.Server.Config.MutationOdds)

	local function exact(value: number)
		return BigNum.fromNumber(value)
	end

	local function withLevels(rebirth, permanent)
		local data = DataSchema.template(0)
		for id, level in rebirth or {} do
			data.upgrades.rebirth[id] = level
		end
		for id, level in permanent or {} do
			data.upgrades.permanent[id] = level
		end
		return data
	end

	describe("catalogue", function()
		it("5 améliorations Essence et 6 Primal Cores, identifiants stables, valeurs cohérentes", function()
			local essence = {}
			for _, def in Upgrades.list("essence") do
				table.insert(essence, def.id)
			end
			local cores = {}
			for _, def in Upgrades.list("cores") do
				table.insert(cores, def.id)
			end
			expect(table.concat(essence, ",")).to.equal(
				"essence_value,essence_growth,essence_luck,essence_drones,essence_bag"
			)
			expect(table.concat(cores, ",")).to.equal(
				"superior_genetics,ancestral_growth,primal_automation,collector_instinct,farming_legacy,mutagenic_energy"
			)
			for _, def in UpgradeConfig.List do
				expect(#def.id <= UpgradeConfig.MaxIdLength).to.equal(true)
				expect(def.maxLevel >= 1 and def.maxLevel % 1 == 0).to.equal(true)
				expect(def.costBase > 0 and def.costGrowth > 1).to.equal(true)
				expect(def.perLevel > 0).to.equal(true)
			end
			expect(UpgradeConfig.Trees.essence.storage).to.equal("rebirth")
			expect(UpgradeConfig.Trees.cores.storage).to.equal("permanent")
		end)

		it("coûts exacts ceil(base × croissance^niveau), strictement croissants", function()
			local value = assert(Upgrades.get("essence_value"))
			expect(BigNum.eq(Upgrades.cost(value, 0), exact(40))).to.equal(true)
			expect(BigNum.eq(Upgrades.cost(value, 1), exact(62))).to.equal(true)
			expect(BigNum.eq(Upgrades.cost(value, 2), exact(97))).to.equal(true) -- 96,1
			local legacy = assert(Upgrades.get("farming_legacy"))
			expect(BigNum.eq(Upgrades.cost(legacy, 1), exact(14))).to.equal(true) -- 13,2
			expect(BigNum.eq(Upgrades.cost(legacy, 2), exact(30))).to.equal(true) -- 29,04
			for _, def in UpgradeConfig.List do
				for level = 0, def.maxLevel - 2 do
					expect(BigNum.gt(Upgrades.cost(def, level + 1), Upgrades.cost(def, level))).to.equal(true)
				end
			end
		end)
	end)

	describe("achat", function()
		it("dépense la bonne monnaie et monte d'un niveau", function()
			local data = DataSchema.template(0)
			data.currencies.essence = exact(100)
			data.currencies.primalCores = exact(10)
			local outcome = assert(Upgrades.purchase(data, "essence_value", 0))
			expect(outcome.level).to.equal(1)
			expect(BigNum.eq(outcome.cost, exact(40))).to.equal(true)
			expect(BigNum.eq(data.currencies.essence, exact(60))).to.equal(true)
			expect(data.upgrades.rebirth.essence_value).to.equal(1)
			assert(Upgrades.purchase(data, "superior_genetics", 0))
			expect(BigNum.eq(data.currencies.primalCores, exact(6))).to.equal(true)
			expect(BigNum.eq(data.currencies.essence, exact(60))).to.equal(true) -- l'autre monnaie est intacte
			expect(data.upgrades.permanent.superior_genetics).to.equal(1)
		end)

		it("refuse sans rien modifier : fonds insuffisants, niveau maximum, niveau périmé, inconnue", function()
			local cases = {
				{ "insufficient_funds", "essence_value", 0, 39, nil },
				{ "max_level", "essence_value", 10, 1e9, 10 },
				{ "stale_level", "essence_value", 1, 1e9, nil },
				{ "unknown_upgrade", "golden_touch", 0, 1e9, nil },
			}
			for _, case in cases do
				local data = DataSchema.template(0)
				data.currencies.essence = exact(case[4])
				if case[5] then
					data.upgrades.rebirth.essence_value = case[5]
				end
				local snapshot = Deep.copy(data)
				local outcome, failure = Upgrades.purchase(data, case[2], case[3])
				expect(outcome).to.equal(nil)
				expect(failure).to.equal(case[1])
				expect(Deep.equal(data, snapshot)).to.equal(true)
			end
		end)

		it("double requête : 100 achats avec le même niveau attendu = un seul niveau payé", function()
			local data = DataSchema.template(0)
			data.currencies.essence = exact(1e6)
			local successes = 0
			for _ = 1, 100 do
				if Upgrades.purchase(data, "essence_bag", 0) then
					successes += 1
				end
			end
			expect(successes).to.equal(1)
			expect(data.upgrades.rebirth.essence_bag).to.equal(1)
			expect(BigNum.eq(data.currencies.essence, exact(1e6 - 30))).to.equal(true)
		end)

		it("nombres invalides : niveaux stockés et niveaux attendus corrompus", function()
			local data = DataSchema.template(0)
			data.currencies.essence = exact(1e6)
			for _, bad in { 0 / 0, -1, 1.5, "3", math.huge } do
				data.upgrades.rebirth.essence_value = bad
				expect(Upgrades.level(data, "essence_value")).to.equal(0)
			end
			data.upgrades.rebirth.essence_value = 1e9 -- entier au-delà du maximum : plafonné à la lecture
			expect(Upgrades.level(data, "essence_value")).to.equal(10)
			data.upgrades.rebirth.essence_value = nil
			for _, expected in { 0 / 0, -1, 0.5, math.huge } do
				expect(select(2, Upgrades.purchase(data, "essence_value", expected))).to.equal("stale_level")
			end
		end)

		it("Automatisation primordiale et Héritage agricole profitent aussi au cycle en cours", function()
			local data = DataSchema.template(0)
			data.currencies.primalCores = exact(100)
			assert(Upgrades.purchase(data, "primal_automation", 0))
			expect(data.machines.drones.harvester).to.equal(1)
			assert(Upgrades.purchase(data, "farming_legacy", 0))
			expect(data.seeds.unlocked.tomato).to.equal(true)
			expect(data.seeds.selected).to.equal(GameConfig.StarterSeed) -- la sélection n'est pas imposée
			data.machines.drones.harvester = 3 -- drones achetés : jamais retirés
			assert(Upgrades.purchase(data, "primal_automation", 1))
			expect(data.machines.drones.harvester).to.equal(3)
		end)
	end)

	describe("effets et plafonds", function()
		it("valeur : cumul multiplicatif des deux arbres, appliqué au revenu", function()
			local data = withLevels({ essence_value = 3 }, { superior_genetics = 2 })
			expect(Upgrades.valueMultiplier(data)).to.be.near(1.3 * 1.1, 1e-12)
			expect(Upgrades.valueMultiplier(data, "cores")).to.be.near(1.1, 1e-12)
			data.progression.rebirths = 1
			data.progression.prestiges = 1
			expect(ProgressionMath.incomeMultiplier(data)).to.be.near(1.365 * 1.58 * 1.3 * 1.1, 1e-12)
			data.bag.items["carrot|normal"] = 10
			local expected = math.floor(100 * 1.365 * 1.58 * 1.3 * 1.1 + 1e-9)
			local sale = Economy.sellValue(data.bag.items, ProgressionMath.incomeMultiplier(data))
			expect(BigNum.eq(sale, exact(expected))).to.equal(true)
		end)

		it("croissance : durée de pousse réduite, jamais sous 40 %", function()
			local data = withLevels({ essence_growth = 5 }, nil)
			expect(Economy.growTime(data, "carrot")).to.be.near(6 * 0.8, 1e-9)
			local maxed = withLevels({ essence_growth = 10 }, { ancestral_growth = 10 })
			expect(Upgrades.growthFactor(maxed)).to.be.near(0.6 * 0.7, 1e-12)
			expect(Upgrades.growthFactor(maxed) >= UpgradeConfig.Caps.MinGrowthFactor).to.equal(true)
		end)

		it("chance de mutation : cumul additif plafonné, E(L) ≤ 2 au maximum", function()
			expect(Upgrades.luck(DataSchema.template(0))).to.equal(1)
			local maxed = withLevels({ essence_luck = 10 }, { mutagenic_energy = 5 })
			expect(Upgrades.luck(maxed)).to.be.near(2.5, 1e-12)
			expect(Upgrades.luck(maxed) <= UpgradeConfig.Caps.MaxLuck).to.equal(true)
			local weights = MutationRoll.applyLuck(MutationOdds.Weights, Upgrades.luck(maxed))
			local expectation = MutationRoll.expectedMultiplier(weights, MutationConfig.multipliers())
			expect(expectation).to.be.near(1.9828, 1e-3)
			expect(expectation <= 2).to.equal(true)
		end)

		it("drones : intervalle réduit, délai de grâce inchangé ; sac : places en plus", function()
			local def = assert(DroneConfig.get("harvester"))
			local data = withLevels({ essence_drones = 8, essence_bag = 3 }, nil)
			expect(DroneLogic.interval(def, data)).to.be.near(4 * 0.6, 1e-12)
			expect(def.graceDelay).to.equal(5)
			expect(Economy.bagCapacity(data)).to.equal(GameConfig.Bag.BaseCapacity + 30)
		end)

		it("Essence des rebirths : Instinct du collectionneur (+10 % par niveau)", function()
			local data = withLevels(nil, { collector_instinct = 2 })
			data.progression.cycleCoins = exact(100000)
			local outcome = assert(Resets.rebirth(data, 0))
			expect(BigNum.eq(outcome.essence, exact(120))).to.equal(true)
		end)
	end)

	describe("resets", function()
		it("rebirth : améliorations conservées, graines et drones de départ appliqués", function()
			local data = withLevels({ essence_value = 2 }, { farming_legacy = 2, primal_automation = 1 })
			data.progression.cycleCoins = exact(100000)
			data.seeds.unlocked.pumpkin = true
			assert(Resets.rebirth(data, 0))
			expect(data.upgrades.rebirth.essence_value).to.equal(2)
			expect(data.upgrades.permanent.farming_legacy).to.equal(2)
			expect(data.seeds.unlocked.tomato).to.equal(true)
			expect(data.seeds.unlocked.corn).to.equal(true)
			expect(data.seeds.unlocked.pumpkin).to.equal(nil)
			expect(data.seeds.selected).to.equal("corn")
			expect(data.machines.drones.harvester).to.equal(1)
		end)

		it("prestige : améliorations Essence perdues, permanentes conservées (droits permanents)", function()
			local data = withLevels(
				{ essence_value = 4, essence_bag = 2 },
				{ superior_genetics = 3, primal_automation = 2 }
			)
			data.progression.rebirths = 5
			data.progression.prestigeCoins = exact(1e7)
			data.receipts = { "purchase-1" }
			local outcome = assert(Resets.prestige(data, 0))
			expect(next(data.upgrades.rebirth)).to.equal(nil)
			expect(data.upgrades.permanent.superior_genetics).to.equal(3)
			expect(data.receipts[1]).to.equal("purchase-1")
			expect(data.machines.drones.harvester).to.equal(2)
			expect(Economy.bagCapacity(data)).to.equal(GameConfig.Bag.BaseCapacity)
			expect(outcome.multiplier).to.be.near(1.58, 1e-12)
			expect(ProgressionMath.incomeMultiplier(data)).to.be.near(1.58 * 1.15, 1e-12)
		end)

		it("l'aperçu du prestige n'annonce que les bonus qui survivent", function()
			local data = withLevels({ essence_value = 3 }, { superior_genetics = 2 })
			data.progression.rebirths = 5
			data.progression.prestigeCoins = exact(1e7)
			local preview = ProgressionMath.prestigePreview(data)
			expect(preview.nextIncomeMultiplier).to.be.near(1.58 * 1.1, 1e-12)
		end)
	end)

	describe("données malformées", function()
		it("inconnue, mauvais arbre ou niveau invalide : quarantaine ; au-delà du maximum : plafonné", function()
			local raw = DataSchema.template(0)
			raw.upgrades.rebirth = {
				essence_value = 3,
				golden_touch = 2,
				superior_genetics = 1,
				essence_bag = 99,
				essence_growth = -1,
			}
			raw.upgrades.permanent = { mutagenic_energy = 2.5, ancestral_growth = 4 }
			local data = assert(DataSchema.load(raw, 10))
			expect(data.upgrades.rebirth.essence_value).to.equal(3)
			expect(data.upgrades.rebirth.golden_touch).to.equal(nil)
			expect(data.upgrades.rebirth.superior_genetics).to.equal(nil)
			expect(data.upgrades.rebirth.essence_bag).to.equal(10)
			expect(data.upgrades.rebirth.essence_growth).to.equal(nil)
			expect(data.upgrades.permanent.mutagenic_energy).to.equal(nil)
			expect(data.upgrades.permanent.ancestral_growth).to.equal(4)
			local paths = {}
			for _, entry in data.meta.quarantine do
				paths[entry.path] = entry.value
			end
			expect(paths["upgrades.rebirth.golden_touch"]).to.equal(2)
			expect(paths["upgrades.rebirth.superior_genetics"]).to.equal(1)
			expect(paths["upgrades.rebirth.essence_bag"]).to.equal(99)
			expect(paths["upgrades.rebirth.essence_growth"]).to.equal(-1)
			expect(paths["upgrades.permanent.mutagenic_energy"]).to.equal(2.5)
		end)
	end)
end
