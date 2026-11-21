-- Formules de progression (Phase 3) : seuils exacts, précision, multiplicateur, Essence, éligibilité, comptage.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local ProgressionMath = require(Shared.Util.ProgressionMath)
	local ProgressionConfig = require(Shared.Config.ProgressionConfig)
	local DataSchema = require(Shared.Util.DataSchema)
	local BigNum = require(Shared.Util.BigNum)

	local function exact(value: number)
		return BigNum.fromNumber(value)
	end

	describe("seuils de rebirth", function()
		it("valeurs exactes de 100 000 × 3,2ⁿ (arrondi à l'entier supérieur) pour n = 0..10", function()
			local expected = {
				[0] = 100000,
				[1] = 320000,
				[2] = 1024000,
				[3] = 3276800,
				[4] = 10485760,
				[5] = 33554432,
				[6] = 107374183, -- 107 374 182,4
				[7] = 343597384, -- 343 597 383,68
				[8] = 1099511628, -- 1 099 511 627,776
				[9] = 3518437209, -- 3 518 437 208,8832
				[10] = 11258999069, -- 11 258 999 068,426 24
			}
			for n = 0, 10 do
				expect(BigNum.eq(ProgressionMath.rebirthThreshold(n), exact(expected[n]))).to.equal(true)
			end
		end)

		it("croissance stricte et écart relatif borné jusqu'à n = 200 (au-delà de 10¹⁵)", function()
			local config = ProgressionConfig.Rebirth
			local previous = ProgressionMath.rebirthThreshold(0)
			for n = 1, 200 do
				local threshold = ProgressionMath.rebirthThreshold(n)
				expect(BigNum.gt(threshold, previous)).to.equal(true)
				local expectedLog = math.log10(config.BaseThreshold) + n * math.log10(config.ThresholdGrowth)
				-- Écart relatif : ≤ 1e-8 pour n ≤ 10 (arrondi à l'entier supérieur), ≤ 1e-10 au-delà (troncature à
				-- l'entier jusqu'à 1e15, puis 15 chiffres significatifs).
				local relative = if n <= 10 then 1e-8 else 1e-10
				expect(math.abs(BigNum.log10(threshold) - expectedLog) <= relative / math.log(10)).to.equal(true)
				previous = threshold
			end
		end)

		it("rejette un nombre de rebirths invalide", function()
			for _, bad in { -1, 1.5, 0 / 0 } do
				expect(function()
					ProgressionMath.rebirthThreshold(bad)
				end).to.throw()
			end
		end)
	end)

	describe("multiplicateur", function()
		it("1 + 0,35 R + 0,015 R²", function()
			expect(ProgressionMath.rebirthMultiplier(0)).to.equal(1)
			expect(ProgressionMath.rebirthMultiplier(1)).to.be.near(1.365, 1e-12)
			expect(ProgressionMath.rebirthMultiplier(2)).to.be.near(1.76, 1e-12)
			expect(ProgressionMath.rebirthMultiplier(10)).to.be.near(6, 1e-12)
		end)

		it("chaque seuil croît plus vite que le multiplicateur (invariant 7)", function()
			for r = 0, 60 do
				local thresholdGrowth = ProgressionConfig.Rebirth.ThresholdGrowth
				local multiplierGrowth = ProgressionMath.rebirthMultiplier(r + 1) / ProgressionMath.rebirthMultiplier(r)
				expect(thresholdGrowth > multiplierGrowth).to.equal(true)
			end
		end)
	end)

	describe("Mutation Essence", function()
		it("100 au premier rebirth pile au seuil, 168 au deuxième", function()
			expect(BigNum.eq(ProgressionMath.rebirthEssence(0, exact(100000)), exact(100))).to.equal(true)
			expect(BigNum.eq(ProgressionMath.rebirthEssence(1, exact(320000)), exact(168))).to.equal(true)
		end)

		it("dépasser le seuil rapporte plus, au plus ×2 (plafond ×4 du seuil)", function()
			local atThreshold = ProgressionMath.rebirthEssence(0, exact(100000))
			local double = ProgressionMath.rebirthEssence(0, exact(200000))
			local capped = ProgressionMath.rebirthEssence(0, exact(400000))
			local huge = ProgressionMath.rebirthEssence(0, BigNum.fromNumber(1e14))
			expect(BigNum.gt(double, atThreshold)).to.equal(true)
			expect(BigNum.eq(capped, exact(200))).to.equal(true)
			expect(BigNum.eq(huge, capped)).to.equal(true)
		end)

		it("rien sous le seuil", function()
			expect(BigNum.isZero(ProgressionMath.rebirthEssence(0, exact(99999)))).to.equal(true)
		end)
	end)

	describe("éligibilité, aperçu et comptage", function()
		it("éligible à partir du seuil exact des Coins GAGNÉS pendant le cycle (pas du solde)", function()
			local data = DataSchema.template(0)
			data.currencies.coins = BigNum.fromNumber(1e9) -- solde énorme, mais rien gagné pendant le cycle
			expect(select(2, ProgressionMath.canRebirth(data))).to.equal("below_threshold")
			data.progression.cycleCoins = exact(99999)
			expect((ProgressionMath.canRebirth(data))).to.equal(false)
			data.progression.cycleCoins = exact(100000)
			expect((ProgressionMath.canRebirth(data))).to.equal(true)
		end)

		it("l'aperçu donne seuil, progression, Essence et multiplicateurs actuel/futur", function()
			local data = DataSchema.template(0)
			data.progression.rebirths = 1
			data.progression.cycleCoins = exact(160000)
			local preview = ProgressionMath.rebirthPreview(data)
			expect(BigNum.eq(preview.threshold, exact(320000))).to.equal(true)
			expect(preview.progress).to.be.near(0.5, 1e-12)
			expect(preview.eligible).to.equal(false)
			expect(BigNum.isZero(preview.essence)).to.equal(true)
			expect(preview.multiplier).to.be.near(1.365, 1e-12)
			expect(preview.nextMultiplier).to.be.near(1.76, 1e-12)
		end)

		it("recordEarnings alimente l'historique et les deux cycles", function()
			local data = DataSchema.template(0)
			ProgressionMath.recordEarnings(data, exact(250))
			ProgressionMath.recordEarnings(data, exact(750))
			for _, value in { data.stats.coinsEarned, data.progression.cycleCoins, data.progression.prestigeCoins } do
				expect(BigNum.eq(value, exact(1000))).to.equal(true)
			end
		end)

		it("le multiplicateur de revenu suit les rebirths du cycle", function()
			local data = DataSchema.template(0)
			expect(ProgressionMath.incomeMultiplier(data)).to.equal(1)
			data.progression.rebirths = 2
			expect(ProgressionMath.incomeMultiplier(data)).to.be.near(1.76, 1e-12)
		end)
	end)
end
