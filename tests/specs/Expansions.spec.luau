-- Extensions de ferme (Phase 5, jalon A) : configuration, achat atomique et ordonné, conservation au rebirth,
-- réinitialisation au prestige, accès aux nouvelles cases (joueur et drones), récoltes entre joueurs, géométrie
-- (aucune superposition, escalier praticable) et données corrompues.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local ExpansionConfig = require(Shared.Config.ExpansionConfig)
	local DroneConfig = require(Shared.Config.DroneConfig)
	local BigNum = require(Shared.Util.BigNum)
	local DataSchema = require(Shared.Util.DataSchema)
	local Deep = require(Shared.Util.Deep)
	local DroneLogic = require(Shared.Util.DroneLogic)
	local Expansions = require(Shared.Util.Expansions)
	local FarmLayout = require(Shared.Util.FarmLayout)
	local HarvestRules = require(Shared.Util.HarvestRules)
	local Inventory = require(Shared.Util.Inventory)
	local Resets = require(Shared.Util.Resets)

	local harvester = assert(DroneConfig.get("harvester"))
	local EPSILON = 1e-9
	local ALL_EXPANSIONS = 0 -- Coins nécessaires pour toutes les extensions (dérivé de la configuration)
	for _, def in ExpansionConfig.List do
		ALL_EXPANSIONS += def.price
	end

	local function withCoins(amount: number)
		local data = DataSchema.template(0)
		data.currencies.coins = BigNum.fromNumber(amount)
		return data
	end

	local function coins(data): number
		return BigNum.toNumber(data.currencies.coins)
	end

	describe("configuration", function()
		it("chaque parcelle non initiale est achetable une fois, à un prix strictement croissant", function()
			local previous = 0
			local seen = {}
			for index, def in ExpansionConfig.List do
				local plot = assert(FarmLayout.getPlot(def.plotId))
				expect(plot.default).to.equal(false)
				expect(def.order).to.equal(index)
				expect(def.price > previous).to.equal(true)
				expect(def.price % 1).to.equal(0)
				previous = def.price
				seen[def.plotId] = true
			end
			for _, plot in FarmLayout.Plots do
				expect(seen[plot.id] == true).to.equal(not plot.default)
			end
		end)
	end)

	describe("achat", function()
		it("dans l'ordre : ouest, puis est, puis terrasse", function()
			local data = withCoins(1e9)
			expect(select(2, Expansions.purchase(data, "east"))).to.equal("locked_order")
			expect(select(2, Expansions.purchase(data, "terrace"))).to.equal("locked_order")
			expect(coins(data)).to.equal(1e9)
			expect(Expansions.nextToBuy(data).plotId).to.equal("west")
			for _, plotId in { "west", "east", "terrace" } do
				local outcome = assert(Expansions.purchase(data, plotId))
				expect(outcome.tiles).to.equal(9)
			end
			expect(Expansions.nextToBuy(data)).to.equal(nil)
			expect(Expansions.tileCount(data)).to.equal(36)
			expect(#Expansions.unlockedTiles(data)).to.equal(36)
		end)

		it("débit exact et déblocage indissociables ; fonds insuffisants = aucune modification", function()
			local price = ExpansionConfig.get("west").price
			local poor = withCoins(price - 1)
			local before = Deep.copy(poor)
			expect(select(2, Expansions.purchase(poor, "west"))).to.equal("insufficient_funds")
			expect(Deep.equal(poor, before)).to.equal(true)

			local exact = withCoins(price)
			local outcome = assert(Expansions.purchase(exact, "west"))
			expect(BigNum.toNumber(outcome.price)).to.equal(price)
			expect(coins(exact)).to.equal(0)
			expect(exact.farm.plots.west).to.equal(true)
		end)

		it("un achat rejoué ou doublé n'achète rien de plus (idempotence)", function()
			local data = withCoins(1e6)
			assert(Expansions.purchase(data, "west"))
			local after = coins(data)
			for _ = 1, 20 do
				expect(select(2, Expansions.purchase(data, "west"))).to.equal("owned")
			end
			expect(coins(data)).to.equal(after)
		end)

		it("parcelle inconnue ou initiale : refus", function()
			local data = withCoins(1e9)
			for _, plotId in { "main", "lune", "", "west:1" } do
				expect(select(2, Expansions.purchase(data, plotId))).to.equal("unknown")
			end
			expect(coins(data)).to.equal(1e9)
		end)
	end)

	describe("rebirth et prestige", function()
		local function readyFor(kind: string)
			local data = withCoins(ALL_EXPANSIONS)
			for _, plotId in { "west", "east", "terrace" } do
				assert(Expansions.purchase(data, plotId))
			end
			data.farm.tiles["terrace:5"] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
			data.progression.cycleCoins = BigNum.fromNumber(1e12)
			if kind == "prestige" then
				data.progression.rebirths = 20
				data.progression.prestigeCoins = BigNum.fromNumber(1e12)
			end
			return data
		end

		it("rebirth : extensions conservées, cultures vidées (replantées ensuite par le serveur)", function()
			local data = readyFor("rebirth")
			assert(Resets.rebirth(data, 0))
			for _, plotId in { "main", "west", "east", "terrace" } do
				expect(data.farm.plots[plotId]).to.equal(true)
			end
			expect(next(data.farm.tiles)).to.equal(nil)
			expect(Expansions.tileCount(data)).to.equal(36)
		end)

		it("prestige : retour à la parcelle de départ ; les extensions sont rachetables dans l'ordre", function()
			local data = readyFor("prestige")
			assert(Resets.prestige(data, 0))
			expect(data.farm.plots.main).to.equal(true)
			for _, plotId in { "west", "east", "terrace" } do
				expect(data.farm.plots[plotId]).to.equal(nil)
			end
			expect(Expansions.tileCount(data)).to.equal(9)
			expect(select(2, HarvestRules.check(data, "terrace:5", 100))).to.equal("invalid_tile")
			data.currencies.coins = BigNum.fromNumber(1e9)
			expect(select(2, Expansions.purchase(data, "east"))).to.equal("locked_order")
			assert(Expansions.purchase(data, "west"))
		end)
	end)

	describe("accès aux nouvelles cases", function()
		it("une case d'extension n'est récoltable qu'après l'achat", function()
			local data = withCoins(1e6)
			data.farm.tiles["west:4"] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
			expect(select(2, HarvestRules.check(data, "west:4", 100))).to.equal("invalid_tile")
			assert(Expansions.purchase(data, "west"))
			expect((HarvestRules.check(data, "west:4", 100))).to.equal(true)
			local outcome = HarvestRules.apply(data, "west:4", 100, "player")
			expect(outcome.itemKey).to.equal("carrot|normal")
			expect(Inventory.count(data.bag.items)).to.equal(1)
			expect(data.farm.tiles["west:4"]).to.equal(nil)
		end)

		it("les drones couvrent toutes les cases de toutes les parcelles, quel que soit leur nombre", function()
			for total = 1, harvester.maxOwned do
				for index = 1, total do
					local home = DroneLogic.homePosition(index, total)
					for _, plot in FarmLayout.Plots do
						for _, tileId in FarmLayout.tileIds(plot.id) do
							expect(DroneLogic.inRange(home, tileId, harvester.range)).to.equal(true)
						end
					end
				end
			end
		end)

		it("un drone récolte la terrasse une fois achetée (délai de grâce inchangé)", function()
			local data = withCoins(ALL_EXPANSIONS)
			data.farm.tiles["terrace:9"] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
			local home = DroneLogic.homePosition(1, 1)
			expect(#DroneLogic.selectTargets(data, 100, home, harvester, {})).to.equal(0)
			for _, plotId in { "west", "east", "terrace" } do
				assert(Expansions.purchase(data, plotId))
			end
			expect(#DroneLogic.selectTargets(data, 6 + harvester.graceDelay - 0.01, home, harvester, {})).to.equal(0)
			expect(DroneLogic.selectTargets(data, 6 + harvester.graceDelay, home, harvester, {})[1]).to.equal(
				"terrace:9"
			)
		end)
	end)

	describe("récoltes multijoueurs", function()
		it("chaque joueur ne récolte que ses propres cases : les données des autres restent intactes", function()
			local alice = withCoins(1e6)
			local bob = withCoins(0)
			assert(Expansions.purchase(alice, "west"))
			for _, data in { alice, bob } do
				data.farm.tiles["west:1"] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
				data.farm.tiles["main:1"] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
			end
			local aliceBefore = Deep.copy(alice)
			-- Bob vise « west:1 » : sa propre donnée dit la parcelle verrouillée (le serveur résout toujours les cases
			-- dans la ferme du demandeur, jamais dans celle d'un autre joueur).
			expect(select(2, HarvestRules.check(bob, "west:1", 100))).to.equal("invalid_tile")
			HarvestRules.apply(bob, "main:1", 100, "player")
			expect(Deep.equal(alice, aliceBefore)).to.equal(true)
			-- Alice récolte sa case d'extension ; celle de Bob ne bouge pas.
			HarvestRules.apply(alice, "west:1", 100, "player")
			expect(bob.farm.tiles["west:1"] ~= nil).to.equal(true)
			expect(Inventory.count(bob.bag.items)).to.equal(1)
			expect(Inventory.count(alice.bag.items)).to.equal(1)
		end)

		it("les fermes des 8 emplacements ne se superposent pas, extensions comprises", function()
			local farm = FarmLayout.farmRect()
			for _, plot in FarmLayout.Plots do
				expect(FarmLayout.rectInside(assert(FarmLayout.plotRect(plot.id)), farm)).to.equal(true)
				local stairs = FarmLayout.stairsRect(plot.id)
				if stairs then
					expect(FarmLayout.rectInside(stairs, farm)).to.equal(true)
				end
			end
			for a = 1, FarmLayout.MaxSlots do
				for b = a + 1, FarmLayout.MaxSlots do
					expect(FarmLayout.rectsOverlap(FarmLayout.slotRect(a), FarmLayout.slotRect(b))).to.equal(false)
				end
			end
		end)
	end)

	describe("géométrie d'une ferme", function()
		it("parcelles, escalier et éléments fixes ne se recouvrent pas", function()
			local rects = {}
			for _, plot in FarmLayout.Plots do
				table.insert(rects, { name = plot.id, rect = assert(FarmLayout.plotRect(plot.id)) })
				local stairs = FarmLayout.stairsRect(plot.id)
				if stairs then
					table.insert(rects, { name = plot.id .. " (escalier)", rect = stairs })
				end
			end
			for name, rect in FarmLayout.featureRects() do
				table.insert(rects, { name = name, rect = rect })
			end
			for i = 1, #rects do
				for j = i + 1, #rects do
					if FarmLayout.rectsOverlap(rects[i].rect, rects[j].rect) then
						error(rects[i].name .. " recouvre " .. rects[j].name)
					end
				end
			end
		end)

		it(
			"escalier de la terrasse praticable : marches ≤ 1 stud, contiguës, jusqu'au sol de la terrasse",
			function()
				local terrace = assert(FarmLayout.getPlot("terrace"))
				local steps = FarmLayout.stairs("terrace")
				expect(#steps > 0).to.equal(true)
				local groundTop = FarmLayout.Features.groundTop
				local previousTop = groundTop
				local previousMinX: number? = nil
				for index, step in steps do
					local top = step.center.y + step.size.y / 2
					local rise = top - previousTop
					expect(rise > 0 and rise <= FarmLayout.StairRise + EPSILON).to.equal(true)
					expect(math.abs((step.center.y - step.size.y / 2) - groundTop) < EPSILON).to.equal(true) -- posée
					expect(step.size.z >= 4).to.equal(true) -- assez large pour un personnage
					local minX = step.center.x - step.size.x / 2
					local maxX = step.center.x + step.size.x / 2
					if previousMinX then
						expect(math.abs(maxX - previousMinX) < EPSILON).to.equal(true) -- marche suivante, contiguë
					end
					previousTop, previousMinX = top, minX
					if index == #steps then
						expect(math.abs(top - (groundTop + terrace.origin.y)) < EPSILON).to.equal(true)
						local face = terrace.origin.x
							+ terrace.cols * FarmLayout.TilePitch / 2
							+ FarmLayout.TerraceMargin
						expect(math.abs(minX - face) < EPSILON).to.equal(true) -- contre le socle de la terrasse
					end
				end
				expect(#FarmLayout.stairs("main")).to.equal(0)
			end
		)

		it("les drones attendent au-dessus du sol de la terrasse (allers-retours sans traverser le socle)", function()
			local terrace = assert(FarmLayout.getPlot("terrace"))
			local home = FarmLayout.Features.droneHome
			expect(home.y > FarmLayout.Features.groundTop + terrace.origin.y).to.equal(true)
		end)
	end)

	describe("données corrompues", function()
		it("état de parcelle non booléen ou parcelle inconnue : quarantaine, parcelle verrouillée", function()
			local raw = Deep.copy(DataSchema.template(0)) :: any
			raw.farm.plots.west = "oui"
			raw.farm.plots.lune = true
			raw.farm.plots.east = true
			raw.farm.plots.main = false
			local data = DataSchema.load(raw, 50)
			expect(data.farm.plots.west).to.equal(nil)
			expect(data.farm.plots.lune).to.equal(nil)
			expect(data.farm.plots.east).to.equal(true)
			expect(data.farm.plots.main).to.equal(true)
			local paths = {}
			for _, entry in data.meta.quarantine do
				paths[entry.path] = entry.value
			end
			expect(paths["farm.plots.west"]).to.equal("oui")
			expect(paths["farm.plots.lune"]).to.equal(true)
		end)

		it("extensions achetées conservées par une sauvegarde puis un rechargement", function()
			local data = withCoins(1e6)
			assert(Expansions.purchase(data, "west"))
			local reloaded = DataSchema.load(Deep.copy(data), 10)
			expect(reloaded.farm.plots.west).to.equal(true)
			expect(Expansions.tileCount(reloaded)).to.equal(18)
			expect(#reloaded.meta.quarantine).to.equal(0)
		end)
	end)
end
