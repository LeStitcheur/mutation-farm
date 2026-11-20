-- Règles de récolte communes joueur/drone : validations, bonus, concurrence, duplication, sac plein, propriété.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local HarvestRules = require(Shared.Util.HarvestRules)
	local DataSchema = require(Shared.Util.DataSchema)
	local Economy = require(Shared.Util.Economy)
	local Inventory = require(Shared.Util.Inventory)
	local BigNum = require(Shared.Util.BigNum)
	local GameConfig = require(Shared.Config.GameConfig)

	local GROW = 6

	local function farm(mutation: string?)
		local data = DataSchema.template(0)
		data.farm.tiles["main:1"] = { plantId = "carrot", plantedAt = 0, growTime = GROW, mutation = mutation }
		return data
	end

	local function harvestNow(data, tileId, now, source)
		local ok, failure = HarvestRules.check(data, tileId, now)
		if not ok then
			return nil, failure
		end
		return HarvestRules.apply(data, tileId, now, source), nil
	end

	describe("validations", function()
		it("refuse une case non débloquée, inexistante ou mal formée", function()
			local data = farm()
			for _, tileId in { "west:1", "main:99", "lune:1", "", "main:1:1" } do
				local ok, failure = HarvestRules.check(data, tileId, 100)
				expect(ok).to.equal(false)
				expect(failure).to.equal("invalid_tile")
			end
		end)

		it("refuse une case vide puis une culture pas encore mûre (horloge serveur)", function()
			local data = farm()
			expect(select(2, HarvestRules.check(data, "main:2", 100))).to.equal("empty")
			expect(select(2, HarvestRules.check(data, "main:1", GROW - 0.01))).to.equal("not_ripe")
			expect((HarvestRules.check(data, "main:1", GROW))).to.equal(true)
		end)

		it("refuse quand le sac est plein, sans rien perdre", function()
			local data = farm("astral")
			data.bag.items["carrot|normal"] = Economy.bagCapacity(data)
			local ok, failure = HarvestRules.check(data, "main:1", 100)
			expect(ok).to.equal(false)
			expect(failure).to.equal("bag_full")
			expect(data.farm.tiles["main:1"].mutation).to.equal("astral") -- culture intacte
		end)

		it("une case d'une parcelle verrouillée reste refusée même si une culture y figure", function()
			local data = farm()
			data.farm.tiles["west:1"] = { plantId = "carrot", plantedAt = 0, growTime = GROW }
			expect(select(2, HarvestRules.check(data, "west:1", 100))).to.equal("invalid_tile")
		end)
	end)

	describe("application", function()
		it("joueur : bonus de précision, statistiques, mutation conservée dans le sac", function()
			local data = farm("crystal")
			local outcome = harvestNow(data, "main:1", GROW + 0.5, "player")
			expect(outcome.tier).to.equal("perfect")
			expect(BigNum.eq(outcome.bonus, BigNum.fromNumber(5))).to.equal(true)
			expect(outcome.itemKey).to.equal("carrot|crystal")
			expect(data.bag.items["carrot|crystal"]).to.equal(1)
			expect(data.stats.harvests).to.equal(1)
			expect(data.stats.perfectHarvests).to.equal(1)
			expect(data.farm.tiles["main:1"]).to.equal(nil)
		end)

		it("drone : jamais de bonus de précision, même pile à maturité", function()
			for _, lateness in { 0, 0.5, 3, 60 } do
				local data = farm("divine")
				local outcome = harvestNow(data, "main:1", GROW + lateness, "drone")
				expect(outcome.tier).to.equal("normal")
				expect(BigNum.isZero(outcome.bonus)).to.equal(true)
				expect(outcome.itemKey).to.equal("carrot|divine")
				expect(data.stats.perfectHarvests).to.equal(0)
			end
		end)
	end)

	describe("concurrence et duplication", function()
		it("joueur et drone au même instant : une seule récolte, un seul objet", function()
			local data = farm()
			local now = GROW + 1
			local first = harvestNow(data, "main:1", now, "drone")
			expect(first).to.be.ok()
			local second, failure = harvestNow(data, "main:1", now, "player")
			expect(second).to.equal(nil)
			expect(failure).to.equal("empty")
			-- replantée (nouveau cycle) : toujours refusée tant qu'elle n'est pas mûre
			data.farm.tiles["main:1"] = { plantId = "carrot", plantedAt = now, growTime = GROW }
			expect(select(2, harvestNow(data, "main:1", now, "player"))).to.equal("not_ripe")
			expect(Inventory.count(data.bag.items)).to.equal(1)
			expect(data.stats.harvests).to.equal(1)
		end)

		it("cent tentatives sur un même cycle = un seul gain à la vente", function()
			local data = farm("giant")
			local successes = 0
			for attempt = 1, 100 do
				local source = if attempt % 2 == 0 then "drone" else "player"
				if harvestNow(data, "main:1", GROW + 2, source) then
					successes += 1
				end
			end
			expect(successes).to.equal(1)
			expect(BigNum.eq(Economy.sellValue(data.bag.items), BigNum.fromNumber(40))).to.equal(true)
		end)

		it("après la vente, le drone reprend et la mutation n'est pas perdue", function()
			local data = farm("radioactive")
			data.bag.items["carrot|normal"] = Economy.bagCapacity(data)
			expect(select(2, harvestNow(data, "main:1", 50, "drone"))).to.equal("bag_full")
			data.bag.items = {} -- vente
			local outcome = harvestNow(data, "main:1", 51, "drone")
			expect(outcome.itemKey).to.equal("carrot|radioactive")
			expect(Inventory.count(data.bag.items) <= GameConfig.Bag.BaseCapacity).to.equal(true)
		end)
	end)
end
