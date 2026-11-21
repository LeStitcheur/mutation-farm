-- Transitions de progression : rebirth atomique et idempotent (Phase 3, jalon A). Prestige : Prestige.spec.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local Resets = require(Shared.Util.Resets)
	local DataSchema = require(Shared.Util.DataSchema)
	local BigNum = require(Shared.Util.BigNum)
	local Deep = require(Shared.Util.Deep)
	local GameConfig = require(Shared.Config.GameConfig)

	-- Profil « riche » : chaque catégorie conservée ou réinitialisée contient une valeur non nulle.
	local function richData()
		local data = DataSchema.template(0)
		data.currencies.coins = BigNum.fromNumber(1e9)
		data.currencies.essence = BigNum.fromNumber(500)
		data.currencies.primalCores = BigNum.fromNumber(7)
		data.currencies.rebirthTokens = 3
		data.farm.plots.west = true
		data.farm.tiles["main:1"] = { plantId = "tomato", plantedAt = 10, growTime = 12, mutation = "divine" }
		data.seeds.unlocked.tomato = true
		data.seeds.selected = "tomato"
		data.bag.items["carrot|normal"] = 12
		data.upgrades.normal.speed = 4
		data.upgrades.rebirth.luck = 2
		data.upgrades.permanent.value = 1
		data.machines.drones.harvester = 2
		data.progression.rebirths = 1
		data.progression.prestiges = 1
		data.progression.revision = 7
		data.progression.cycleCoins = BigNum.fromNumber(320000) -- seuil exact du rebirth n° 2
		data.progression.prestigeCoins = BigNum.fromNumber(900000)
		data.mutadex["carrot|shiny"] = 123
		data.cosmetics.owned.hat = true
		data.pets.owned.cat = 1
		data.receipts = { "r1" }
		data.stats.harvests = 50
		data.stats.totalRebirths = 4
		data.meta.quarantine = { { path = "x", value = 1, reason = "test", at = 0 } }
		return data
	end

	-- Chemins réinitialisés par un rebirth ; tout le reste doit rester identique.
	local REBIRTH_RESET = {
		"currencies.coins",
		"currencies.essence", -- augmentée de la récompense (vérifiée à part)
		"seeds",
		"bag",
		"upgrades.normal",
		"machines.drones",
		"farm.tiles",
		"progression.rebirths",
		"progression.revision",
		"progression.cycleCoins",
		"stats.totalRebirths",
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

	describe("rebirth", function()
		it("réinitialise l'économie du cycle et récompense en Essence, révision +1", function()
			local data = richData()
			local outcome, failure = Resets.rebirth(data, 7)
			expect(failure).to.equal(nil)
			expect(outcome.rebirths).to.equal(2)
			expect(outcome.revision).to.equal(8)
			expect(outcome.multiplier).to.be.near(1.76 * 1.58, 1e-12) -- revenu : rebirth (R = 2) × prestige (P = 1)
			expect(BigNum.eq(outcome.essence, BigNum.fromNumber(168))).to.equal(true)
			expect(BigNum.eq(data.currencies.essence, BigNum.fromNumber(668))).to.equal(true)
			expect(BigNum.isZero(data.currencies.coins)).to.equal(true)
			expect(BigNum.isZero(data.progression.cycleCoins)).to.equal(true)
			expect(data.seeds.unlocked.tomato).to.equal(nil)
			expect(data.seeds.unlocked[GameConfig.StarterSeed]).to.equal(true)
			expect(data.seeds.selected).to.equal(GameConfig.StarterSeed)
			for _, container in { data.bag.items, data.upgrades.normal, data.machines.drones, data.farm.tiles } do
				expect(next(container)).to.equal(nil)
			end
			expect(data.stats.totalRebirths).to.equal(5)
		end)

		it(
			"conserve à l'identique tout ce qui n'est pas listé (parcelles, Essence antérieure, Mutadex…)",
			function()
				local before = richData()
				local data = Deep.copy(before)
				Resets.rebirth(data, 7)
				expect(Deep.equal(without(data, REBIRTH_RESET), without(before, REBIRTH_RESET))).to.equal(true)
				expect(data.farm.plots.west).to.equal(true)
				expect(data.upgrades.rebirth.luck).to.equal(2)
				expect(BigNum.eq(data.progression.prestigeCoins, BigNum.fromNumber(900000))).to.equal(true)
			end
		)

		it("refuse sous le seuil ou avec une révision périmée, sans rien modifier", function()
			local poor = richData()
			poor.progression.cycleCoins = BigNum.fromNumber(319999)
			local snapshot = Deep.copy(poor)
			expect(select(2, Resets.rebirth(poor, 7))).to.equal("below_threshold")
			expect(Deep.equal(poor, snapshot)).to.equal(true)

			local stale = richData()
			local staleSnapshot = Deep.copy(stale)
			expect(select(2, Resets.rebirth(stale, 6))).to.equal("stale_revision")
			expect(Deep.equal(stale, staleSnapshot)).to.equal(true)
		end)

		it("double requête : 100 appels avec la même révision = une seule récompense", function()
			local data = richData()
			data.progression.cycleCoins = BigNum.fromNumber(1e9) -- assez pour plusieurs seuils
			local successes = 0
			for _ = 1, 100 do
				if Resets.rebirth(data, 7) then
					successes += 1
				end
			end
			expect(successes).to.equal(1)
			expect(data.progression.rebirths).to.equal(2)
			expect(data.progression.revision).to.equal(8)
		end)

		it("la donnée reste sérialisable et rechargeable après un rebirth", function()
			local data = richData()
			Resets.rebirth(data, 7)
			expect((DataSchema.validate(data))).to.equal(true)
			local loaded, err = DataSchema.load(Deep.copy(data), 10)
			expect(err).to.equal(nil)
			expect(loaded.progression.rebirths).to.equal(2)
			expect(loaded.progression.revision).to.equal(8)
		end)
	end)
end
