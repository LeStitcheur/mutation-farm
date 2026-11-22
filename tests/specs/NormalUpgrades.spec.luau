-- Améliorations normales (Phase 5, jalon B) : arbre « coins » payé en Coins, stocké dans upgrades.normal, remis à
-- zéro au rebirth et au prestige. Mêmes règles d'achat que les autres arbres (Upgrades.purchase), mêmes effets et
-- mêmes plafonds globaux (Util/Bonuses).
return function()
	local Shared = game:GetService("ReplicatedStorage").Shared
	local UpgradeConfig = require(Shared.Config.UpgradeConfig)
	local GameConfig = require(Shared.Config.GameConfig)
	local BigNum = require(Shared.Util.BigNum)
	local Bonuses = require(Shared.Util.Bonuses)
	local DataSchema = require(Shared.Util.DataSchema)
	local Deep = require(Shared.Util.Deep)
	local Economy = require(Shared.Util.Economy)
	local ProgressionMath = require(Shared.Util.ProgressionMath)
	local Resets = require(Shared.Util.Resets)
	local Upgrades = require(Shared.Util.Upgrades)

	local function withCoins(amount: number)
		local data = DataSchema.template(0)
		data.currencies.coins = BigNum.fromNumber(amount)
		return data
	end

	local function coins(data): number
		return BigNum.toNumber(data.currencies.coins)
	end

	describe("catalogue", function()
		it("trois améliorations en Coins : vitesse de croissance, valeur des récoltes, capacité du sac", function()
			local tree = UpgradeConfig.Trees.coins
			expect(tree.currency).to.equal("coins")
			expect(tree.storage).to.equal("normal")
			local effects = {}
			for _, def in Upgrades.list("coins") do
				effects[def.effect] = def.id
				expect(def.perLevel > 0).to.equal(true)
				expect(def.maxLevel >= 1).to.equal(true)
				-- Coûts entiers, strictement croissants niveau après niveau.
				local previous = 0
				for level = 0, def.maxLevel - 1 do
					local cost = BigNum.toNumber(Upgrades.cost(def, level))
					expect(cost % 1).to.equal(0)
					expect(cost > previous).to.equal(true)
					previous = cost
				end
			end
			expect(effects.growth).to.equal("coins_growth")
			expect(effects.value).to.equal("coins_value")
			expect(effects.bag).to.equal("coins_bag")
			expect(#Upgrades.list("coins")).to.equal(3)
		end)
	end)

	describe("achat en Coins", function()
		it("débit exact et niveau + 1 indissociables ; les autres monnaies ne bougent pas", function()
			local data = withCoins(10000)
			data.currencies.essence = BigNum.fromNumber(500)
			local outcome = assert(Upgrades.purchase(data, "coins_value", 0))
			expect(outcome.level).to.equal(1)
			expect(BigNum.toNumber(outcome.cost)).to.equal(2500)
			expect(coins(data)).to.equal(7500)
			expect(data.upgrades.normal.coins_value).to.equal(1)
			expect(BigNum.toNumber(data.currencies.essence)).to.equal(500)
			expect(next(data.upgrades.rebirth)).to.equal(nil)
		end)

		it("fonds insuffisants, niveau périmé ou maximum : refus sans aucune modification", function()
			local poor = withCoins(2499)
			local before = Deep.copy(poor)
			expect(select(2, Upgrades.purchase(poor, "coins_value", 0))).to.equal("insufficient_funds")
			expect(Deep.equal(poor, before)).to.equal(true)

			local data = withCoins(1e9)
			assert(Upgrades.purchase(data, "coins_bag", 0))
			local after = coins(data)
			for _ = 1, 20 do -- double clic, paquet rejoué : niveau attendu 0 périmé
				expect(select(2, Upgrades.purchase(data, "coins_bag", 0))).to.equal("stale_level")
			end
			expect(coins(data)).to.equal(after)
			local def = assert(Upgrades.get("coins_bag"))
			data.upgrades.normal.coins_bag = def.maxLevel
			expect(select(2, Upgrades.purchase(data, "coins_bag", def.maxLevel))).to.equal("max_level")
		end)

		it("le solde ne devient jamais négatif, même à coût exact", function()
			local data = withCoins(4000)
			assert(Upgrades.purchase(data, "coins_growth", 0))
			expect(coins(data)).to.equal(0)
			expect(BigNum.isNegative(data.currencies.coins)).to.equal(false)
			expect(select(2, Upgrades.purchase(data, "coins_growth", 1))).to.equal("insufficient_funds")
		end)

		it("dépenser des Coins ne retarde pas le rebirth (seuil sur les Coins GAGNÉS du cycle)", function()
			local data = withCoins(200000)
			data.progression.cycleCoins = BigNum.fromNumber(100000)
			assert(Upgrades.purchase(data, "coins_value", 0))
			expect((ProgressionMath.canRebirth(data))).to.equal(true)
		end)
	end)

	describe("effets et plafonds", function()
		it("valeur : × (1 + 0,05 L) sur le revenu, cumulée avec les autres arbres", function()
			local data = withCoins(0)
			local base = ProgressionMath.incomeMultiplier(data)
			data.upgrades.normal.coins_value = 4
			expect(math.abs(ProgressionMath.incomeMultiplier(data) - base * 1.2) < 1e-9).to.equal(true)
			data.upgrades.rebirth.essence_value = 2
			expect(math.abs(ProgressionMath.incomeMultiplier(data) - base * 1.2 * 1.2) < 1e-9).to.equal(true)
			-- Une vente applique bien le multiplicateur (même chemin que les autres arbres).
			local sale = Economy.sellValue({ ["carrot|normal"] = 10 }, ProgressionMath.incomeMultiplier(data))
			expect(BigNum.toNumber(sale)).to.equal(math.floor(100 * 1.44 + 1e-9))
		end)

		it("croissance : −3 % par niveau ; tous arbres au maximum, jamais sous le plafond de 40 %", function()
			local data = withCoins(0)
			data.upgrades.normal.coins_growth = 5
			expect(math.abs(Economy.growTime(data, "carrot") - 6 * 0.85) < 1e-9).to.equal(true)
			for _, def in UpgradeConfig.List do
				if def.effect == "growth" then
					local container = (data.upgrades :: any)[UpgradeConfig.Trees[def.tree].storage]
					container[def.id] = def.maxLevel
				end
			end
			expect(math.abs(Bonuses.growthFactor(data) - UpgradeConfig.Caps.MinGrowthFactor) < 1e-9).to.equal(true)
		end)

		it("sac : +10 places par niveau", function()
			local data = withCoins(0)
			data.upgrades.normal.coins_bag = 3
			expect(Economy.bagCapacity(data)).to.equal(GameConfig.Bag.BaseCapacity + 30)
		end)
	end)

	describe("rebirth et prestige", function()
		local function upgraded()
			local data = withCoins(1e9)
			assert(Upgrades.purchase(data, "coins_value", 0))
			assert(Upgrades.purchase(data, "coins_bag", 0))
			data.upgrades.rebirth.essence_value = 1
			data.upgrades.permanent.superior_genetics = 1
			data.progression.cycleCoins = BigNum.fromNumber(1e12)
			data.progression.rebirths = 20
			data.progression.prestigeCoins = BigNum.fromNumber(1e12)
			return data
		end

		it("rebirth : améliorations normales remises à zéro, arbres Essence et Primal Cores conservés", function()
			local data = upgraded()
			data.progression.rebirths = 0 -- seuil du 1er rebirth (100 000) atteint
			assert(Resets.rebirth(data, 0))
			expect(next(data.upgrades.normal)).to.equal(nil)
			expect(data.upgrades.rebirth.essence_value).to.equal(1)
			expect(data.upgrades.permanent.superior_genetics).to.equal(1)
			expect(Economy.bagCapacity(data)).to.equal(GameConfig.Bag.BaseCapacity)
		end)

		it("prestige : améliorations normales remises à zéro, Primal Cores conservés", function()
			local data = upgraded()
			assert(Resets.prestige(data, 0))
			expect(next(data.upgrades.normal)).to.equal(nil)
			expect(next(data.upgrades.rebirth)).to.equal(nil)
			expect(data.upgrades.permanent.superior_genetics).to.equal(1)
		end)

		it("l'aperçu du rebirth n'annonce pas la valeur des améliorations normales (perdues)", function()
			local data = withCoins(0)
			data.progression.cycleCoins = BigNum.fromNumber(1e6)
			local reference = ProgressionMath.rebirthPreview(data).nextMultiplier
			data.upgrades.normal.coins_value = 10
			local preview = ProgressionMath.rebirthPreview(data)
			expect(math.abs(preview.nextMultiplier - reference) < 1e-9).to.equal(true)
			expect(preview.multiplier > ProgressionMath.rebirthMultiplier(0)).to.equal(true) -- effet actuel affiché
			local copy = Deep.copy(data)
			assert(Resets.rebirth(copy, 0))
			expect(math.abs(ProgressionMath.incomeMultiplier(copy) - preview.nextMultiplier) < 1e-9).to.equal(true)
		end)
	end)

	describe("données corrompues", function()
		it("niveaux invalides en quarantaine ; au-delà du maximum plafonné ; niveaux valides conservés", function()
			local raw = Deep.copy(DataSchema.template(0)) :: any
			raw.upgrades.normal = {
				coins_value = 3,
				coins_bag = 99,
				essence_value = 2, -- mauvais arbre
				inconnue = 1,
				coins_growth = 1.5,
			}
			local data = DataSchema.load(raw, 10)
			expect(data.upgrades.normal.coins_value).to.equal(3)
			expect(data.upgrades.normal.coins_bag).to.equal(assert(Upgrades.get("coins_bag")).maxLevel)
			expect(data.upgrades.normal.essence_value).to.equal(nil)
			expect(data.upgrades.normal.inconnue).to.equal(nil)
			expect(data.upgrades.normal.coins_growth).to.equal(nil)
			local paths = {}
			for _, entry in data.meta.quarantine do
				paths[entry.path] = entry.value
			end
			expect(paths["upgrades.normal.coins_bag"]).to.equal(99)
			expect(paths["upgrades.normal.essence_value"]).to.equal(2)
			expect(paths["upgrades.normal.inconnue"]).to.equal(1)
			expect(paths["upgrades.normal.coins_growth"]).to.equal(1.5)
		end)

		it("une table d'améliorations normales non tabulaire est mise en quarantaine puis recréée", function()
			local raw = Deep.copy(DataSchema.template(0)) :: any
			raw.upgrades.normal = "rien"
			local data = DataSchema.load(raw, 10)
			expect(type(data.upgrades.normal)).to.equal("table")
			expect(next(data.upgrades.normal)).to.equal(nil)
			local found = false
			for _, entry in data.meta.quarantine do
				found = found or (entry.path == "upgrades.normal" and entry.value == "rien")
			end
			expect(found).to.equal(true)
		end)
	end)
end
