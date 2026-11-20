return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local Resets = require(Shared.Util.Resets)
	local DataSchema = require(Shared.Util.DataSchema)
	local BigNum = require(Shared.Util.BigNum)
	local GameConfig = require(Shared.Config.GameConfig)

	local function richData()
		local data = DataSchema.template(0)
		data.currencies.coins = BigNum.fromNumber(1e9)
		data.currencies.essence = BigNum.fromNumber(500)
		data.currencies.primalCores = BigNum.fromNumber(7)
		data.currencies.rebirthTokens = 3
		data.farm.plots.west = true
		data.farm.tiles["main:1"] = { plantId = "tomato", plantedAt = 10, growTime = 12 }
		data.seeds.unlocked.tomato = true
		data.seeds.selected = "tomato"
		data.bag.items["carrot|normal"] = 12
		data.upgrades.normal.speed = 4
		data.upgrades.rebirth.luck = 2
		data.upgrades.permanent.value = 1
		data.machines.drones.harvester = 2
		data.progression.rebirths = 9
		data.progression.prestiges = 1
		data.mutadex["carrot|shiny"] = 123
		data.cosmetics.owned.hat = true
		data.pets.owned.cat = 1
		data.receipts = { "r1" }
		data.stats.harvests = 50
		return data
	end

	local function expectPermanentKept(data)
		expect(data.upgrades.permanent.value).to.equal(1)
		expect(data.mutadex["carrot|shiny"]).to.equal(123)
		expect(data.cosmetics.owned.hat).to.equal(true)
		expect(data.pets.owned.cat).to.equal(1)
		expect(data.receipts[1]).to.equal("r1")
		expect(data.stats.harvests).to.equal(50)
	end

	local function expectEconomyReset(data)
		expect(BigNum.isZero(data.currencies.coins)).to.equal(true)
		expect(data.seeds.unlocked.tomato).to.equal(nil)
		expect(data.seeds.unlocked[GameConfig.StarterSeed]).to.equal(true)
		expect(data.seeds.selected).to.equal(GameConfig.StarterSeed)
		expect(next(data.bag.items)).to.equal(nil)
		expect(next(data.upgrades.normal)).to.equal(nil)
		expect(next(data.machines.drones)).to.equal(nil)
		expect(next(data.farm.tiles)).to.equal(nil)
	end

	describe("rebirth", function()
		it("reset l'économie et conserve parcelles + progrès de rebirth", function()
			local data = richData()
			Resets.rebirth(data)
			expectEconomyReset(data)
			expect(data.farm.plots.west).to.equal(true)
			expect(data.upgrades.rebirth.luck).to.equal(2)
			expect(data.currencies.essence.m).to.equal(500)
			expect(data.currencies.primalCores.m).to.equal(7)
			expect(data.progression.rebirths).to.equal(10)
			expect(data.currencies.rebirthTokens).to.equal(3 + GameConfig.Rebirth.TokensPerRebirth)
			expectPermanentKept(data)
		end)
	end)

	describe("prestige", function()
		it("reset parcelles, rebirths et upgrades de rebirth ; ajoute les Primal Cores", function()
			local data = richData()
			Resets.prestige(data, 5)
			expectEconomyReset(data)
			expect(data.farm.plots.west).to.equal(nil)
			expect(data.farm.plots.main).to.equal(true)
			expect(next(data.upgrades.rebirth)).to.equal(nil)
			expect(BigNum.isZero(data.currencies.essence)).to.equal(true)
			expect(data.currencies.rebirthTokens).to.equal(0)
			expect(data.progression.rebirths).to.equal(0)
			expect(data.progression.prestiges).to.equal(2)
			expect(data.currencies.primalCores.m).to.equal(12)
			expectPermanentKept(data)
		end)

		it("refuse un gain de Primal Cores invalide", function()
			expect(function()
				Resets.prestige(richData(), -1)
			end).to.throw()
			expect(function()
				Resets.prestige(richData(), 1.5)
			end).to.throw()
		end)
	end)

	describe("intégrité", function()
		it("la donnée reste valide après chaque reset", function()
			local data = richData()
			Resets.rebirth(data)
			expect((DataSchema.validate(data))).to.equal(true)
			Resets.prestige(data, 3)
			expect((DataSchema.validate(data))).to.equal(true)
			expect(#DataSchema.sanitize(data)).to.equal(0)
		end)
	end)
end
