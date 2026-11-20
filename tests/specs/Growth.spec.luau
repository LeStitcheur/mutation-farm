return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Growth = require(ReplicatedStorage.Shared.Util.Growth)
	local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

	local tile = { plantedAt = 100, growTime = 6 }

	describe("progression", function()
		it("est bornée dans [0, 1]", function()
			expect(Growth.progress(tile, 50)).to.equal(0)
			expect(Growth.progress(tile, 100)).to.equal(0)
			expect(Growth.progress(tile, 103)).to.be.near(0.5)
			expect(Growth.progress(tile, 1000)).to.equal(1)
		end)

		it("considère une durée nulle comme mûre", function()
			expect(Growth.progress({ plantedAt = 10, growTime = 0 }, 10)).to.equal(1)
		end)
	end)

	describe("maturité", function()
		it("dépend uniquement des timestamps", function()
			expect(Growth.ripeAt(tile)).to.equal(106)
			expect(Growth.isRipe(tile, 105.99)).to.equal(false)
			expect(Growth.isRipe(tile, 106)).to.equal(true)
		end)
	end)

	describe("paliers de précision", function()
		local perfect = GameConfig.Harvest.PerfectWindow
		local good = GameConfig.Harvest.GoodWindow

		it("Parfait jusqu'à la fin de la fenêtre incluse", function()
			expect(Growth.precisionTier(0)).to.equal("perfect")
			expect(Growth.precisionTier(perfect)).to.equal("perfect")
		end)

		it("Bien ensuite, puis Normal", function()
			expect(Growth.precisionTier(perfect + 0.01)).to.equal("good")
			expect(Growth.precisionTier(good)).to.equal("good")
			expect(Growth.precisionTier(good + 0.01)).to.equal("normal")
		end)

		it("Normal pour une latence négative (requête anticipée)", function()
			expect(Growth.precisionTier(-1)).to.equal("normal")
		end)
	end)
end
