return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local Economy = require(Shared.Util.Economy)
	local Inventory = require(Shared.Util.Inventory)
	local BigNum = require(Shared.Util.BigNum)
	local DataSchema = require(Shared.Util.DataSchema)
	local PlantConfig = require(Shared.Config.PlantConfig)
	local GameConfig = require(Shared.Config.GameConfig)

	describe("objets et valeurs", function()
		it("construit et analyse les clés d'objets", function()
			expect(Economy.itemKey("carrot")).to.equal("carrot|normal")
			expect(Economy.itemKey("corn", "divine")).to.equal("corn|divine")
			local plantId, mutationId = Economy.parseItemKey("tomato|shiny")
			expect(plantId).to.equal("tomato")
			expect(mutationId).to.equal("shiny")
			expect(Economy.parseItemKey("pas une clé")).to.equal(nil)
		end)

		it("applique le multiplicateur de mutation", function()
			expect(Economy.itemValue("carrot", "normal").m).to.equal(10)
			expect(Economy.itemValue("carrot", "divine").m).to.equal(1500)
			expect(Economy.itemValue("inconnue", "normal")).to.equal(nil)
			expect(Economy.itemValue("carrot", "inconnue")).to.equal(nil)
		end)

		it("calcule la valeur de vente en ignorant les objets inconnus", function()
			local items = { ["carrot|normal"] = 3, ["tomato|shiny"] = 2, ["inconnue|normal"] = 5 }
			expect(Economy.sellValue(items).m).to.equal(3 * 10 + 2 * 45 * 2)
			expect(Economy.sellValue(items, 2).m).to.equal(420)
			expect(BigNum.isZero(Economy.sellValue({}))).to.equal(true)
		end)
	end)

	describe("bonus de précision", function()
		it("verse 50 % / 20 % / 0 % de la valeur de base", function()
			expect(Economy.precisionBonus("carrot", "perfect").m).to.equal(5)
			expect(Economy.precisionBonus("carrot", "good").m).to.equal(2)
			expect(BigNum.isZero(Economy.precisionBonus("carrot", "normal"))).to.equal(true)
		end)

		it("ne dépasse jamais 50 % de la valeur de base (invariant 4)", function()
			for _, plant in PlantConfig.List do
				local bonus = Economy.precisionBonus(plant.id, "perfect")
				expect(BigNum.lte(bonus, BigNum.fromNumber(plant.baseValue * 0.5))).to.equal(true)
			end
		end)
	end)

	describe("sac", function()
		it("respecte la capacité", function()
			local items = {}
			expect(Inventory.add(items, "carrot|normal", 3, 5)).to.equal(3)
			expect(Inventory.add(items, "tomato|normal", 4, 5)).to.equal(2)
			expect(Inventory.count(items)).to.equal(5)
			expect(Inventory.isFull(items, 5)).to.equal(true)
			expect(Inventory.add(items, "carrot|normal", 1, 5)).to.equal(0)
			Inventory.clear(items)
			expect(Inventory.count(items)).to.equal(0)
		end)

		it("ignore les quantités nulles ou négatives", function()
			local items = {}
			expect(Inventory.add(items, "carrot|normal", 0, 5)).to.equal(0)
			expect(Inventory.add(items, "carrot|normal", -3, 5)).to.equal(0)
			expect(items["carrot|normal"]).to.equal(nil)
		end)

		it("utilise la capacité de base de la configuration", function()
			expect(Economy.bagCapacity(DataSchema.template(0))).to.equal(GameConfig.Bag.BaseCapacity)
		end)
	end)

	describe("déblocage des graines", function()
		it("exige l'ordre séquentiel et les fonds", function()
			local data = DataSchema.template(0)
			local ok, reason = Economy.canUnlockSeed(data, "tomato")
			expect(ok).to.equal(false)
			expect(reason).to.equal("insufficient_funds")

			data.currencies.coins = BigNum.fromNumber(750)
			expect((Economy.canUnlockSeed(data, "tomato"))).to.equal(true)

			local _, orderReason = Economy.canUnlockSeed(data, "corn")
			expect(orderReason).to.equal("locked_order")

			local _, ownedReason = Economy.canUnlockSeed(data, "carrot")
			expect(ownedReason).to.equal("already_unlocked")

			local _, unknownReason = Economy.canUnlockSeed(data, "licorne")
			expect(unknownReason).to.equal("unknown")
		end)
	end)

	-- Rebirth/prestige : tests/specs/Progression.spec.luau (contrat Phase 3).
end
