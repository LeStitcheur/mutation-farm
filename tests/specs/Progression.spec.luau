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

		it("le multiplicateur de revenu = rebirth du cycle × prestige", function()
			local data = DataSchema.template(0)
			expect(ProgressionMath.incomeMultiplier(data)).to.equal(1)
			data.progression.rebirths = 2
			expect(ProgressionMath.incomeMultiplier(data)).to.be.near(1.76, 1e-12)
			data.progression.prestiges = 1
			expect(ProgressionMath.incomeMultiplier(data)).to.be.near(1.76 * 1.58, 1e-12)
			local preview = ProgressionMath.rebirthPreview(data)
			expect(preview.multiplier).to.be.near(1.76 * 1.58, 1e-12)
			expect(preview.nextMultiplier).to.be.near(2.185 * 1.58, 1e-12)
		end)
	end)

	describe("prestige : conditions", function()
		it("cahier des charges : 5 rebirths / 1e7, 8 / 1e8, 12 / 1e9, puis 17 / 1e10 et 23 / 1e11", function()
			local expected = {
				{ 5, 1e7 },
				{ 8, 1e8 },
				{ 12, 1e9 },
				{ 17, 1e10 },
				{ 23, 1e11 },
			}
			for p, pair in expected do
				expect(ProgressionMath.prestigeRebirthsRequired(p - 1)).to.equal(pair[1])
				expect(BigNum.eq(ProgressionMath.prestigeCoinsRequired(p - 1), exact(pair[2]))).to.equal(true)
			end
		end)

		it(
			"croissance stricte des deux conditions et Coins exponentiels jusqu'à p = 60 (au-delà de 10¹⁵)",
			function()
				for p = 0, 59 do
					local rebirthsNow = ProgressionMath.prestigeRebirthsRequired(p)
					expect(ProgressionMath.prestigeRebirthsRequired(p + 1) > rebirthsNow).to.equal(true)
					local current = ProgressionMath.prestigeCoinsRequired(p)
					local nextValue = ProgressionMath.prestigeCoinsRequired(p + 1)
					expect(BigNum.gt(nextValue, current)).to.equal(true)
					expect(BigNum.log10(current)).to.be.near(7 + p, 1e-9)
				end
			end
		)

		it("rejette un nombre de prestiges invalide", function()
			for _, bad in { -1, 0.5, 0 / 0 } do
				expect(function()
					ProgressionMath.prestigeCoinsRequired(bad)
				end).to.throw()
				expect(function()
					ProgressionMath.prestigeMultiplier(bad)
				end).to.throw()
			end
		end)

		it("les deux conditions sont requises (rebirths d'abord, puis Coins gagnés depuis le prestige)", function()
			local data = DataSchema.template(0)
			data.currencies.coins = exact(1e12) -- le solde ne compte jamais
			data.progression.rebirths = 4
			data.progression.prestigeCoins = exact(1e12)
			expect(select(2, ProgressionMath.canPrestige(data))).to.equal("not_enough_rebirths")
			data.progression.rebirths = 5
			data.progression.prestigeCoins = exact(9999999)
			expect(select(2, ProgressionMath.canPrestige(data))).to.equal("not_enough_coins")
			data.progression.prestigeCoins = exact(1e7)
			expect((ProgressionMath.canPrestige(data))).to.equal(true)

			data.progression.prestiges = 1 -- prestige n° 2 : 8 rebirths et 1e8
			expect(select(2, ProgressionMath.canPrestige(data))).to.equal("not_enough_rebirths")
			data.progression.rebirths = 8
			expect(select(2, ProgressionMath.canPrestige(data))).to.equal("not_enough_coins")
			data.progression.prestigeCoins = exact(1e8)
			expect((ProgressionMath.canPrestige(data))).to.equal(true)
		end)
	end)

	describe("prestige : récompenses et multiplicateur", function()
		it("1 + 0,5 P + 0,08 P²", function()
			expect(ProgressionMath.prestigeMultiplier(0)).to.equal(1)
			expect(ProgressionMath.prestigeMultiplier(1)).to.be.near(1.58, 1e-12)
			expect(ProgressionMath.prestigeMultiplier(2)).to.be.near(2.32, 1e-12)
			expect(ProgressionMath.prestigeMultiplier(3)).to.be.near(3.22, 1e-12)
		end)

		it("Primal Cores : 10 au minimum, +25 % par rebirth en plus (plafond ×2), croissants avec p", function()
			expect(BigNum.isZero(ProgressionMath.prestigeCores(0, 4))).to.equal(true)
			expect(BigNum.eq(ProgressionMath.prestigeCores(0, 5), exact(10))).to.equal(true)
			expect(BigNum.eq(ProgressionMath.prestigeCores(0, 6), exact(12))).to.equal(true) -- 12,5
			expect(BigNum.eq(ProgressionMath.prestigeCores(0, 9), exact(20))).to.equal(true)
			expect(BigNum.eq(ProgressionMath.prestigeCores(0, 40), exact(20))).to.equal(true) -- plafond
			expect(BigNum.eq(ProgressionMath.prestigeCores(1, 8), exact(16))).to.equal(true) -- 10 × 2^0,75
			expect(BigNum.eq(ProgressionMath.prestigeCores(2, 12), exact(22))).to.equal(true) -- 10 × 3^0,75
		end)

		it("pas de cycle instantané : juste après un prestige, le revenu baisse (invariant 12)", function()
			for p = 0, 30 do
				local before = ProgressionMath.rebirthMultiplier(ProgressionMath.prestigeRebirthsRequired(p))
					* ProgressionMath.prestigeMultiplier(p)
				expect(ProgressionMath.prestigeMultiplier(p + 1) < before).to.equal(true)
			end
		end)

		it("l'aperçu donne conditions, progression, Primal Cores et multiplicateurs", function()
			local data = DataSchema.template(0)
			data.progression.rebirths = 3
			data.progression.prestigeCoins = exact(5e6)
			local preview = ProgressionMath.prestigePreview(data)
			expect(preview.prestiges).to.equal(0)
			expect(preview.rebirthsRequired).to.equal(5)
			expect(preview.coinsProgress).to.be.near(0.5, 1e-12)
			expect(preview.eligible).to.equal(false)
			expect(preview.failure).to.equal("not_enough_rebirths")
			expect(BigNum.isZero(preview.cores)).to.equal(true)
			expect(preview.prestigeMultiplier).to.equal(1)
			expect(preview.nextPrestigeMultiplier).to.be.near(1.58, 1e-12)
			expect(preview.incomeMultiplier).to.be.near(2.185, 1e-12)
			expect(preview.nextIncomeMultiplier).to.be.near(1.58, 1e-12)

			data.progression.rebirths = 5
			data.progression.prestigeCoins = exact(2e7)
			local ready = ProgressionMath.prestigePreview(data)
			expect(ready.eligible).to.equal(true)
			expect(ready.failure).to.equal(nil)
			expect(BigNum.eq(ready.cores, exact(10))).to.equal(true)
			expect(ready.coinsProgress).to.equal(1)
		end)
	end)
end
