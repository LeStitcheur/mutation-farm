-- Simulation de la boucle Phase 1 (récolte → sac → marché → déblocage) avec les modules purs.
-- Joueur « attentif » : récolte la case mûre la plus ancienne, 1,2 s de déplacement entre deux récoltes,
-- va vendre quand le sac est plein ou quand la vente suffit pour le prochain déblocage (aller-retour 8 s).
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local PlantConfig = require(Shared.Config.PlantConfig)
	local Growth = require(Shared.Util.Growth)
	local Economy = require(Shared.Util.Economy)
	local Inventory = require(Shared.Util.Inventory)
	local BigNum = require(Shared.Util.BigNum)
	local DataSchema = require(Shared.Util.DataSchema)
	local FarmLayout = require(Shared.Util.FarmLayout)

	local MOVE_TIME = 1.2
	local SELL_TRIP = 8
	local MAX_SECONDS = 12 * 3600

	local function plantTile(seed, now)
		return { plantId = seed, plantedAt = now, growTime = PlantConfig.get(seed).growTime }
	end

	-- Joue jusqu'à débloquer toutes les plantes. Retourne la liste des instants de déblocage et des statistiques.
	local function simulate()
		local data = DataSchema.template(0)
		local capacity = Economy.bagCapacity(data)
		local tiles = {}
		for _, tileId in FarmLayout.tileIds("main") do
			tiles[tileId] = plantTile(data.seeds.selected, 0)
		end
		local now = 0
		local unlockTimes = {}
		local stats = { harvests = 0, perfect = 0, good = 0, sells = 0, minCoins = 0 }

		local function sell()
			now += SELL_TRIP
			data.currencies.coins = BigNum.add(data.currencies.coins, Economy.sellValue(data.bag.items))
			data.bag.items = {}
			stats.sells += 1
		end

		while now < MAX_SECONDS do
			local nextPlant = PlantConfig.nextAfter(data.seeds.selected)
			if not nextPlant then
				break
			end
			local price = BigNum.fromNumber(nextPlant.unlockPrice)
			if BigNum.gte(data.currencies.coins, price) then
				local ok = Economy.canUnlockSeed(data, nextPlant.id)
				assert(ok, "déblocage refusé alors que les fonds suffisent")
				data.currencies.coins = BigNum.sub(data.currencies.coins, price)
				data.seeds.unlocked[nextPlant.id] = true
				data.seeds.selected = nextPlant.id
				table.insert(unlockTimes, { id = nextPlant.id, at = now })
			else
				local pending = BigNum.add(data.currencies.coins, Economy.sellValue(data.bag.items))
				local hasItems = Inventory.count(data.bag.items) > 0
				if Inventory.isFull(data.bag.items, capacity) or (hasItems and BigNum.gte(pending, price)) then
					sell()
				else
					local bestId, bestRipe = nil, math.huge
					for tileId, tile in tiles do
						local ripeAt = Growth.ripeAt(tile)
						if ripeAt < bestRipe then
							bestId, bestRipe = tileId, ripeAt
						end
					end
					now = math.max(now + MOVE_TIME, bestRipe)
					local tile = tiles[bestId]
					local tier = Growth.precisionTier(now - Growth.ripeAt(tile))
					local added = Inventory.add(data.bag.items, Economy.itemKey(tile.plantId), 1, capacity)
					assert(added == 1, "la récolte doit entrer dans un sac non plein")
					data.currencies.coins =
						BigNum.add(data.currencies.coins, Economy.precisionBonus(tile.plantId, tier))
					stats.harvests += 1
					if tier == "perfect" then
						stats.perfect += 1
					elseif tier == "good" then
						stats.good += 1
					end
					tiles[bestId] = plantTile(data.seeds.selected, now)
				end
			end
			if BigNum.isNegative(data.currencies.coins) then
				stats.minCoins = -1
			end
		end
		return unlockTimes, stats, now
	end

	local unlockTimes, stats = simulate()

	describe("boucle Coins / vente", function()
		it("débloque les 6 graines suivantes en moins de 12 h de jeu attentif", function()
			expect(#unlockTimes).to.equal(#PlantConfig.List - 1)
		end)

		it("la Tomate arrive en moins de 3 minutes", function()
			expect(unlockTimes[1].id).to.equal("tomato")
			expect(unlockTimes[1].at > 30 and unlockTimes[1].at < 180).to.equal(true)
		end)

		it("chaque palier prend plus de temps que le précédent (invariant 3 en jeu réel)", function()
			local previous = 0
			local previousDuration = 0
			for _, entry in unlockTimes do
				local duration = entry.at - previous
				expect(duration > previousDuration).to.equal(true)
				previous = entry.at
				previousDuration = duration
			end
		end)

		it("la progression complète Phase 1 tient entre 1 h et 8 h", function()
			local last = unlockTimes[#unlockTimes].at
			expect(last > 3600 and last < 8 * 3600).to.equal(true)
		end)

		it("le sac impose des allers-retours au marché et le solde ne devient jamais négatif", function()
			expect(stats.sells > 10).to.equal(true)
			expect(stats.minCoins).to.equal(0)
		end)

		it("le bonus de précision est atteignable en jeu attentif", function()
			expect(stats.perfect > 0).to.equal(true)
			expect(stats.perfect + stats.good > stats.harvests / 4).to.equal(true)
		end)
	end)
end
