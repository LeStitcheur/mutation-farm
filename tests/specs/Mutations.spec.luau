-- Contrat Phase 2 des mutations : probabilités du cahier des charges, exclusivité, distribution statistique,
-- multiplicateurs appliqués à l'économie, sauvegarde et restauration.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local Shared = ReplicatedStorage.Shared
	local MutationRoll = require(Shared.Util.MutationRoll)
	local MutationConfig = require(Shared.Config.MutationConfig)
	local PlantConfig = require(Shared.Config.PlantConfig)
	local Economy = require(Shared.Util.Economy)
	local Inventory = require(Shared.Util.Inventory)
	local BigNum = require(Shared.Util.BigNum)
	local DataSchema = require(Shared.Util.DataSchema)
	local Deep = require(Shared.Util.Deep)
	local MutationOdds = require(ServerScriptService.Server.Config.MutationOdds)

	local weights = MutationOdds.Weights
	local SPEC = {
		{ id = "shiny", name = "Brillante", multiplier = 2, probability = 0.12 },
		{ id = "giant", name = "Géante", multiplier = 4, probability = 0.05 },
		{ id = "crystal", name = "Cristallisée", multiplier = 8, probability = 0.015 },
		{ id = "radioactive", name = "Radioactive", multiplier = 20, probability = 0.004 },
		{ id = "astral", name = "Astrale", multiplier = 50, probability = 0.0008 },
		{ id = "divine", name = "Divine", multiplier = 150, probability = 0.0001 },
	}

	describe("cahier des charges Phase 2", function()
		it("six mutations aux noms, multiplicateurs et probabilités exacts", function()
			local probabilities = MutationRoll.probabilities(weights)
			local mutated = 0
			for _, expected in SPEC do
				local def = MutationConfig.get(expected.id)
				expect(def.name).to.equal(expected.name)
				expect(def.multiplier).to.equal(expected.multiplier)
				expect(probabilities[expected.id]).to.be.near(expected.probability, 1e-12)
				mutated += expected.probability
			end
			expect(probabilities.normal).to.be.near(1 - mutated, 1e-12)
			expect(#MutationConfig.List).to.equal(#SPEC + 1)
		end)
	end)

	describe("exclusivité", function()
		it("chaque tirage renvoie exactement une mutation connue", function()
			for i = 0, 9999 do
				local id = MutationRoll.pick(weights, i / 10000)
				expect(type(id)).to.equal("string")
				expect(MutationConfig.get(id)).to.be.ok()
			end
		end)
	end)

	describe("distribution statistique (tirages pseudo-aléatoires)", function()
		-- χ² d'adéquation à 6 degrés de liberté : seuil 22,46 au risque α = 0,001. Graines fixes : test déterministe.
		local CHI2_CRITICAL = 22.46
		local DRAWS = 400000

		local function sample(seed: number)
			math.randomseed(seed)
			local counts = {}
			for _ = 1, DRAWS do
				local id = MutationRoll.pick(weights, math.random())
				counts[id] = (counts[id] or 0) + 1
			end
			return counts
		end

		local function chiSquare(counts)
			local chi2 = 0
			for id, probability in MutationRoll.probabilities(weights) do
				local expected = probability * DRAWS
				chi2 += ((counts[id] or 0) - expected) ^ 2 / expected
			end
			return chi2
		end

		for _, seed in { 1, 2, 3 } do
			it(string.format("les fréquences suivent les probabilités (graine %d, 400 000 tirages)", seed), function()
				local counts = sample(seed)
				local total = 0
				for _, count in counts do
					total += count
				end
				expect(total).to.equal(DRAWS)
				expect(chiSquare(counts) < CHI2_CRITICAL).to.equal(true)
				for _, expected in SPEC do
					expect((counts[expected.id] or 0) > 0).to.equal(true) -- même la Divine (≈ 40 attendues)
				end
			end)
		end

		it("le test détecte une Divine dix fois trop fréquente", function()
			local counts = sample(1)
			counts.divine = (counts.divine or 0) + 360
			counts.normal -= 360
			expect(chiSquare(counts) > CHI2_CRITICAL).to.equal(true)
		end)
	end)

	describe("multiplicateurs dans l'économie", function()
		it("Carotte et Tomate gardent leurs valeurs de base (10 et 45)", function()
			expect(PlantConfig.get("carrot").baseValue).to.equal(10)
			expect(PlantConfig.get("tomato").baseValue).to.equal(45)
		end)

		it("la valeur de vente applique le multiplicateur exact", function()
			for _, plantId in { "carrot", "tomato" } do
				local base = PlantConfig.get(plantId).baseValue
				for _, expected in SPEC do
					local value = Economy.itemValue(plantId, expected.id)
					expect(BigNum.eq(value, BigNum.fromNumber(base * expected.multiplier))).to.equal(true)
				end
			end
		end)

		it("un sac mixte se vend à la somme exacte des valeurs mutées", function()
			local items = {}
			Inventory.add(items, Economy.itemKey("carrot"), 10, 40)
			Inventory.add(items, Economy.itemKey("carrot", "shiny"), 3, 40)
			Inventory.add(items, Economy.itemKey("tomato", "giant"), 2, 40)
			Inventory.add(items, Economy.itemKey("carrot", "divine"), 1, 40)
			-- 10×10 + 3×20 + 2×180 + 1×1500
			expect(BigNum.eq(Economy.sellValue(items), BigNum.fromNumber(2020))).to.equal(true)
		end)

		it("le bonus de précision reste calculé sur la valeur de base (invariant 4)", function()
			expect(BigNum.eq(Economy.precisionBonus("carrot", "perfect"), BigNum.fromNumber(5))).to.equal(true)
			expect(BigNum.eq(Economy.precisionBonus("tomato", "good"), BigNum.fromNumber(9))).to.equal(true)
		end)
	end)

	describe("sauvegarde et restauration", function()
		local function profileWith(mutation: string?)
			local data = DataSchema.template(1000)
			data.farm.tiles["main:1"] = { plantId = "carrot", plantedAt = 1000, growTime = 6, mutation = mutation }
			data.bag.items[Economy.itemKey("tomato", mutation)] = 2
			return data
		end

		it("chaque mutation survit à l'écriture et au rechargement (case et sac)", function()
			for _, expected in SPEC do
				local data = profileWith(expected.id)
				expect((DataSchema.validate(data))).to.equal(true)
				local loaded, err = DataSchema.load(Deep.copy(data), 2000)
				expect(err).to.equal(nil)
				expect(loaded.farm.tiles["main:1"].mutation).to.equal(expected.id)
				expect(loaded.bag.items["tomato|" .. expected.id]).to.equal(2)
			end
		end)

		it("une culture normale (mutation absente) reste normale", function()
			local loaded = DataSchema.load(Deep.copy(profileWith(nil)), 2000)
			expect(loaded.farm.tiles["main:1"].mutation).to.equal(nil)
			expect(loaded.bag.items["tomato|normal"]).to.equal(2)
		end)

		it("une mutation inconnue est retirée au chargement (case et objet)", function()
			local data = profileWith("divine")
			data.farm.tiles["main:1"].mutation = "triche"
			data.bag.items["carrot|triche"] = 99
			local loaded = DataSchema.load(Deep.copy(data), 2000)
			expect(loaded.farm.tiles["main:1"]).to.equal(nil)
			expect(loaded.bag.items["carrot|triche"]).to.equal(nil)
			expect(loaded.bag.items["tomato|divine"]).to.equal(2)
		end)
	end)
end
