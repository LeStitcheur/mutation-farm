-- Automatisation avancée (Phase 5, jalon C) : comptoir de vente automatique (achat, seuil, vente par la même règle
-- que le marché), concurrence vente manuelle / automatique, sac plein, réglages, statistiques, transition de
-- progression pendant une opération automatique, migration v5 -> v6 et données corrompues.
return function()
	local Shared = game:GetService("ReplicatedStorage").Shared
	local AutomationConfig = require(Shared.Config.AutomationConfig)
	local DroneConfig = require(Shared.Config.DroneConfig)
	local GameConfig = require(Shared.Config.GameConfig)
	local Automation = require(Shared.Util.Automation)
	local BigNum = require(Shared.Util.BigNum)
	local DataSchema = require(Shared.Util.DataSchema)
	local Deep = require(Shared.Util.Deep)
	local DroneLogic = require(Shared.Util.DroneLogic)
	local Economy = require(Shared.Util.Economy)
	local HarvestRules = require(Shared.Util.HarvestRules)
	local Inventory = require(Shared.Util.Inventory)
	local ProgressionMath = require(Shared.Util.ProgressionMath)
	local Quests = require(Shared.Util.Quests)
	local Resets = require(Shared.Util.Resets)
	local Selling = require(Shared.Util.Selling)

	local NOW = 1000
	local PRICE = AutomationConfig.AutoSeller.Price

	local function withCoins(amount: number)
		local data = DataSchema.template(0)
		data.currencies.coins = BigNum.fromNumber(amount)
		return data
	end

	local function coins(data): number
		return BigNum.toNumber(data.currencies.coins)
	end

	local function withSeller(threshold: number?)
		local data = withCoins(PRICE)
		assert(Automation.buySeller(data))
		if threshold then
			assert(Automation.setSetting(data, "threshold", threshold))
		end
		return data
	end

	local function fillBag(data, count: number)
		data.bag.items = {}
		Inventory.add(data.bag.items, "carrot|normal", count, Economy.bagCapacity(data))
	end

	describe("comptoir automatique", function()
		it("achat : débit exact, installé et activé ; rejoué ou sans fonds : aucune modification", function()
			local data = withCoins(PRICE + 7)
			assert(Automation.buySeller(data))
			expect(coins(data)).to.equal(7)
			expect(data.machines.autoSeller).to.equal(true)
			expect(Automation.autoSellActive(data)).to.equal(true)
			for _ = 1, 10 do
				expect(select(2, Automation.buySeller(data))).to.equal("owned")
			end
			expect(coins(data)).to.equal(7)

			local poor = withCoins(PRICE - 1)
			local before = Deep.copy(poor)
			expect(select(2, Automation.buySeller(poor))).to.equal("insufficient_funds")
			expect(Deep.equal(poor, before)).to.equal(true)
		end)

		it("machine du cycle : perdue au rebirth et au prestige ; réglages et statistiques conservés", function()
			for _, kind in { "rebirth", "prestige" } do
				local data = withSeller(75)
				assert(Automation.setSetting(data, "drones", false))
				data.automation.stats.autoSells = 4
				data.progression.cycleCoins = BigNum.fromNumber(1e12)
				if kind == "prestige" then
					data.progression.rebirths = 20
					data.progression.prestigeCoins = BigNum.fromNumber(1e12)
					assert(Resets.prestige(data, 0))
				else
					assert(Resets.rebirth(data, 0))
				end
				expect(data.machines.autoSeller).to.equal(false)
				expect(Automation.autoSellActive(data)).to.equal(false)
				expect(data.automation.autoSellThreshold).to.equal(75)
				expect(data.automation.dronesEnabled).to.equal(false)
				expect(data.automation.stats.autoSells).to.equal(4)
			end
		end)
	end)

	describe("vente automatique", function()
		it("seuils 50 / 75 / 100 % de la capacité du sac (40, puis 50 avec Grand sac)", function()
			local expected = { [50] = 20, [75] = 30, [100] = 40 }
			for percent, count in expected do
				local data = withSeller(percent)
				expect(Automation.thresholdCount(data)).to.equal(count)
				fillBag(data, count - 1)
				expect(Automation.shouldAutoSell(data)).to.equal(false)
				fillBag(data, count)
				expect(Automation.shouldAutoSell(data)).to.equal(true)
			end
			local bigger = withSeller(75)
			bigger.upgrades.normal.coins_bag = 1
			expect(Automation.thresholdCount(bigger)).to.equal(38) -- ⌈50 × 0,75⌉
		end)

		it(
			"même règle que le marché : valeur × revenu, Coins gagnés, statistiques ; pas de mission « vendre »",
			function()
				local manual = withSeller(50)
				local auto = Deep.copy(manual)
				for _, data in { manual, auto } do
					data.upgrades.normal.coins_value = 2
					data.bag.items = { ["carrot|shiny"] = 7, ["tomato|normal"] = 13 }
					data.quests.daily = {
						period = Quests.periodOf("daily", NOW),
						missions = {
							{
								id = "d:0:1",
								template = "sell",
								difficulty = "easy",
								target = 5,
								progress = 0,
								claimed = false,
								rewards = { coins = BigNum.zero(), eggs = 0 },
							},
						},
					}
				end
				local expected = Economy.sellValue(manual.bag.items, ProgressionMath.incomeMultiplier(manual))
				local sale = assert(Selling.sellBag(manual, NOW, "manual"))
				local autoSale = assert(Automation.autoSell(auto, NOW))
				expect(BigNum.eq(sale.total, expected)).to.equal(true)
				expect(BigNum.eq(autoSale.total, expected)).to.equal(true)
				expect(BigNum.eq(auto.progression.cycleCoins, expected)).to.equal(true)
				expect(auto.automation.stats.autoSells).to.equal(1)
				expect(BigNum.eq(auto.automation.stats.autoSellCoins, expected)).to.equal(true)
				expect(manual.quests.daily.missions[1].progress).to.equal(1)
				expect(auto.quests.daily.missions[1].progress).to.equal(0)
				expect(manual.automation.stats.autoSells).to.equal(0)
			end
		)

		it("comptoir coupé ou absent : rien n'est vendu", function()
			local data = withSeller(50)
			assert(Automation.setSetting(data, "autosell", false))
			fillBag(data, 40)
			expect(Automation.autoSell(data, NOW)).to.equal(nil)
			local none = withCoins(0)
			fillBag(none, 40)
			expect(Automation.autoSell(none, NOW)).to.equal(nil)
			expect(Inventory.count(none.bag.items)).to.equal(40)
		end)
	end)

	describe("concurrence vente manuelle / automatique", function()
		it("jamais d'attribution double, quel que soit l'ordre (chaque vente dans son mutateur)", function()
			for _, order in { { "manual", "auto" }, { "auto", "manual" } } do
				local data = withSeller(50)
				fillBag(data, 25)
				local expected = Economy.sellValue(data.bag.items, ProgressionMath.incomeMultiplier(data))
				local sales = 0
				for _, kind in order do
					local outcome = if kind == "manual"
						then Selling.sellBag(data, NOW, "manual")
						else Automation.autoSell(data, NOW)
					if outcome then
						sales += 1
					end
				end
				expect(sales).to.equal(1)
				expect(BigNum.eq(data.currencies.coins, expected)).to.equal(true)
				expect(BigNum.eq(data.stats.coinsEarned, expected)).to.equal(true)
				expect(data.stats.sells).to.equal(1)
			end
		end)

		it(
			"la récolte qui atteint le seuil déclenche une seule vente ; la vente manuelle suivante trouve le sac vide",
			function()
				local data = withSeller(50)
				fillBag(data, 19)
				data.farm.tiles["main:1"] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
				assert(HarvestRules.check(data, "main:1", NOW))
				HarvestRules.apply(data, "main:1", NOW, "drone")
				local sale = assert(Automation.autoSell(data, NOW)) -- appel du serveur juste après la récolte
				expect(sale.count).to.equal(20)
				expect(Automation.autoSell(data, NOW)).to.equal(nil)
				expect(Selling.sellBag(data, NOW, "manual")).to.equal(nil)
				expect(data.stats.sells).to.equal(1)
			end
		)
	end)

	describe("sac plein", function()
		it("sans comptoir : la récolte attend, rien n'est perdu (culture intacte)", function()
			local data = withCoins(0)
			fillBag(data, GameConfig.Bag.BaseCapacity)
			data.farm.tiles["main:2"] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
			expect(select(2, HarvestRules.check(data, "main:2", NOW))).to.equal("bag_full")
			expect(data.farm.tiles["main:2"] ~= nil).to.equal(true)
			expect(Inventory.count(data.bag.items)).to.equal(GameConfig.Bag.BaseCapacity)
		end)

		it("avec comptoir à 100 % : le sac plein est vendu puis la récolte reprend", function()
			local data = withSeller(100)
			fillBag(data, 40)
			data.farm.tiles["main:2"] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
			expect(select(2, HarvestRules.check(data, "main:2", NOW))).to.equal("bag_full")
			assert(Automation.autoSell(data, NOW)) -- HarvestService : vente puis nouvelle tentative
			expect((HarvestRules.check(data, "main:2", NOW))).to.equal(true)
			HarvestRules.apply(data, "main:2", NOW, "drone")
			expect(Inventory.count(data.bag.items)).to.equal(1)
		end)

		it("abaisser le seuil sous le contenu du sac le vend aussitôt (réglage suivi d'une vente)", function()
			local data = withSeller(100)
			fillBag(data, 25)
			expect(Automation.shouldAutoSell(data)).to.equal(false)
			assert(Automation.setSetting(data, "threshold", 50))
			expect(Automation.shouldAutoSell(data)).to.equal(true)
		end)
	end)

	describe("réglages", function()
		it("validés : réglage inconnu, seuil hors liste, types incorrects refusés sans modification", function()
			local data = withSeller()
			local before = Deep.copy(data)
			local cases = {
				{ "turbo", true, "unknown_setting" },
				{ "threshold", 60, "invalid_value" },
				{ "threshold", "75", "invalid_value" },
				{ "threshold", 0 / 0, "invalid_value" },
				{ "threshold", true, "invalid_value" },
				{ "drones", 1, "invalid_value" },
				{ "autosell", "oui", "invalid_value" },
			}
			for _, case in cases do
				expect(select(2, Automation.setSetting(data, case[1], case[2]))).to.equal(case[3])
			end
			expect(Deep.equal(data, before)).to.equal(true)
		end)

		it("drones en pause : débit nul (la boucle serveur ne les fait plus agir)", function()
			local data = withCoins(0)
			data.machines.drones.harvester = 3
			local harvester = assert(DroneConfig.get("harvester"))
			local active = Automation.rates(data)
			expect(math.abs(active.dronesPerMinute - 3 * 60 / harvester.interval) < 1e-9).to.equal(true)
			expect(math.abs(active.farmPerMinute - 9 * 60 / (6 + harvester.graceDelay)) < 1e-9).to.equal(true)
			assert(Automation.setSetting(data, "drones", false))
			expect(Automation.dronesEnabled(data)).to.equal(false)
			expect(Automation.rates(data).dronesPerMinute).to.equal(0)
		end)
	end)

	describe("statistiques", function()
		it("les récoltes de drones sont comptées, pas celles du joueur", function()
			local data = withCoins(0)
			for index = 1, 3 do
				data.farm.tiles["main:" .. index] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
			end
			HarvestRules.apply(data, "main:1", NOW, "drone")
			HarvestRules.apply(data, "main:2", NOW, "drone")
			HarvestRules.apply(data, "main:3", NOW, "player")
			expect(data.automation.stats.droneHarvests).to.equal(2)
			expect(data.stats.harvests).to.equal(3)
		end)
	end)

	describe("transition de progression pendant une opération automatique", function()
		it("vente automatique préparée avant un rebirth : refusée après (sac vidé, comptoir perdu)", function()
			local data = withSeller(50)
			fillBag(data, 30)
			data.progression.cycleCoins = BigNum.fromNumber(200000)
			expect(Automation.shouldAutoSell(data)).to.equal(true) -- vue « avant »
			assert(Resets.rebirth(data, 0))
			expect(Automation.autoSell(data, NOW)).to.equal(nil)
			expect(BigNum.isZero(data.currencies.coins)).to.equal(true)
			expect(BigNum.isZero(data.progression.cycleCoins)).to.equal(true)
			expect(data.automation.stats.autoSells).to.equal(0)
		end)

		it("cible de drone choisie avant le rebirth : refusée après ; aucune vente du nouveau cycle", function()
			local data = withSeller(50)
			data.machines.drones.harvester = 1
			fillBag(data, 19)
			data.farm.tiles["main:1"] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
			data.progression.cycleCoins = BigNum.fromNumber(200000)
			local def = assert(DroneConfig.get("harvester"))
			local targets = DroneLogic.selectTargets(data, NOW, DroneLogic.homePosition(1, 1), def, {})
			expect(targets[1]).to.equal("main:1")
			assert(Resets.rebirth(data, 0))
			expect(select(2, HarvestRules.check(data, targets[1], NOW))).to.equal("empty")
			expect(Automation.autoSell(data, NOW)).to.equal(nil)
			expect(data.automation.stats.droneHarvests).to.equal(0)
		end)
	end)

	describe("migration v5 -> v6 et données corrompues", function()
		local function v5Save()
			local data = Deep.copy(DataSchema.template(1)) :: any
			data.version = 5
			data.machines.autoSeller = nil
			data.automation = nil
			data.machines.drones.harvester = 2
			data.currencies.coins = BigNum.fromNumber(123456)
			data.bag.items = { ["carrot|giant"] = 3 }
			data.farm.plots.west = true
			data.farm.tiles["west:1"] = { plantId = "carrot", plantedAt = 5, growTime = 6 }
			data.upgrades.normal.coins_value = 2
			data.stats.harvests = 77
			return data
		end

		it("aucune perte : chaque champ v5 est conservé, comptoir absent, réglages par défaut", function()
			local raw = v5Save()
			local original = Deep.copy(raw)
			local data, loadError, notes = DataSchema.load(raw, 50)
			expect(loadError).to.equal(nil)
			local loaded = assert(data, "donnée v5 non chargée") :: any
			expect(loaded.version).to.equal(DataSchema.VERSION)
			for key, value in original do
				if key ~= "version" and key ~= "machines" then
					expect(Deep.equal(loaded[key], value)).to.equal(true)
				end
			end
			expect(loaded.machines.drones.harvester).to.equal(2)
			expect(loaded.machines.autoSeller).to.equal(false)
			expect(loaded.automation.dronesEnabled).to.equal(true)
			expect(loaded.automation.autoSellEnabled).to.equal(false)
			expect(loaded.automation.autoSellThreshold).to.equal(AutomationConfig.DefaultThreshold)
			expect(loaded.automation.stats.droneHarvests).to.equal(0)
			expect(#loaded.meta.quarantine).to.equal(0)
			local migrated = false
			for _, note in notes do
				migrated = migrated or string.find(note, "migration v5 -> v", 1, true) ~= nil
			end
			expect(migrated).to.equal(true)
			expect((DataSchema.validate(loaded))).to.equal(true)
		end)

		it("valeurs corrompues : quarantaine et valeurs par défaut, jamais de suppression silencieuse", function()
			local raw = Deep.copy(DataSchema.template(0)) :: any
			raw.machines.autoSeller = "oui"
			raw.automation.dronesEnabled = "non"
			raw.automation.autoSellThreshold = 60
			raw.automation.stats.autoSells = -3
			raw.automation.stats.droneHarvests = 2.5
			raw.automation.stats.autoSellCoins = { m = "x", e = 0 }
			local data = DataSchema.load(raw, 50)
			expect(data.machines.autoSeller).to.equal(false)
			expect(data.automation.dronesEnabled).to.equal(true)
			expect(data.automation.autoSellThreshold).to.equal(AutomationConfig.DefaultThreshold)
			expect(data.automation.stats.autoSells).to.equal(0)
			expect(data.automation.stats.droneHarvests).to.equal(0)
			expect(BigNum.isZero(data.automation.stats.autoSellCoins)).to.equal(true)
			local paths = {}
			for _, entry in data.meta.quarantine do
				paths[entry.path] = true
			end
			for _, path in
				{
					"machines.autoSeller",
					"automation.dronesEnabled",
					"automation.autoSellThreshold",
					"automation.stats.autoSells",
					"automation.stats.droneHarvests",
					-- Montant corrompu : sa mantisse non numérique est remplacée par la réconciliation (chemin précis).
					"automation.stats.autoSellCoins.m",
				}
			do
				expect(paths[path]).to.equal(true)
			end
		end)

		it("sauvegarde puis rechargement : réglages, comptoir et statistiques conservés", function()
			local data = withSeller(75)
			assert(Automation.setSetting(data, "drones", false))
			data.automation.stats.autoSellCoins = BigNum.fromNumber(999)
			local reloaded = DataSchema.load(Deep.copy(data), 10)
			expect(reloaded.machines.autoSeller).to.equal(true)
			expect(reloaded.automation.autoSellThreshold).to.equal(75)
			expect(reloaded.automation.dronesEnabled).to.equal(false)
			expect(BigNum.toNumber(reloaded.automation.stats.autoSellCoins)).to.equal(999)
			expect(#reloaded.meta.quarantine).to.equal(0)
		end)
	end)
end
