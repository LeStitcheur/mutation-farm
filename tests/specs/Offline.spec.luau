-- Production hors ligne (Phase 5, jalon D) : fenêtre plafonnée à 2 h, production réellement automatisable (drones,
-- sac, comptoir, bonus équipés, délai de grâce), idempotence (reconnexions répétées, sauvegarde puis rechargement),
-- révision de progression, horodatages serveur uniquement, cohérence avec la simulation au pas de 0,25 s, migration
-- v6 -> v7, données corrompues, coût de calcul du pire cas.
return function()
	local Shared = game:GetService("ReplicatedStorage").Shared
	local EconomySim = require(game:GetService("TestService").Sim.EconomySim)
	local DroneConfig = require(Shared.Config.DroneConfig)
	local GameConfig = require(Shared.Config.GameConfig)
	local BigNum = require(Shared.Util.BigNum)
	local DataSchema = require(Shared.Util.DataSchema)
	local Deep = require(Shared.Util.Deep)
	local Economy = require(Shared.Util.Economy)
	local Inventory = require(Shared.Util.Inventory)
	local Offline = require(Shared.Util.Offline)
	local ProgressionMath = require(Shared.Util.ProgressionMath)

	local MAX = GameConfig.Offline.MaxSeconds
	local T0 = 1000000 -- dernière sauvegarde (horodatage serveur)
	local harvester = assert(DroneConfig.get("harvester"), "drone récolteur")

	local function normalRoll(_luck: number): string
		return "normal"
	end

	-- Ferme de départ : `drones` drones, cases de Carotte mûres à la déconnexion, comptoir en option.
	local function farm(drones: number, seller: boolean?, plots: { string }?)
		local data = DataSchema.template(0)
		data.meta.lastSeen = T0
		if drones > 0 then
			data.machines.drones.harvester = drones
		end
		for _, plotId in plots or {} do
			data.farm.plots[plotId] = true
		end
		for plotId in data.farm.plots do
			for index = 1, 9 do
				data.farm.tiles[plotId .. ":" .. index] = { plantId = "carrot", plantedAt = T0 - 100, growTime = 6 }
			end
		end
		if seller then
			data.machines.autoSeller = true
			data.automation.autoSellEnabled = true
		end
		return data
	end

	local function settle(data, now: number, revision: number?)
		return Offline.settle(data, now, { roll = normalRoll, expectedRevision = revision })
	end

	local function coins(data): number
		return BigNum.toNumber(data.currencies.coins)
	end

	describe("fenêtre d'absence", function()
		it("plafonnée à 2 h ; part du plus récent de la dernière sauvegarde et du dernier règlement", function()
			local data = farm(1)
			local start, away, counted = Offline.window(data, T0 + 3 * 3600)
			expect(start).to.equal(T0)
			expect(away).to.equal(3 * 3600)
			expect(counted).to.equal(MAX)
			data.offline.settledAt = T0 + 600
			start, away, counted = Offline.window(data, T0 + 900)
			expect(start).to.equal(T0 + 600)
			expect(away).to.equal(300)
			expect(counted).to.equal(300)
		end)

		it("horodatage futur ou invalide (horloges décalées, donnée trafiquée) : aucune absence", function()
			local data = farm(3, true)
			data.meta.lastSeen = T0 + 50000
			local report = settle(data, T0 + 100)
			expect(report.reason).to.equal("too_short")
			expect(report.harvests).to.equal(0)
			expect(coins(data)).to.equal(0)
			local corrupt = farm(3, true) :: any
			corrupt.meta.lastSeen = "hier"
			expect(settle(corrupt, T0 + 3600).harvests).to.equal(0)
		end)
	end)

	describe("production réellement automatisable", function()
		it("absence trop courte (< 60 s) : rien, pas d'écran ; le règlement avance quand même", function()
			local data = farm(3, true)
			local before = Deep.copy(data)
			local report = settle(data, T0 + GameConfig.Offline.MinSeconds - 1)
			expect(report.reason).to.equal("too_short")
			expect(report.seen).to.equal(true)
			expect(data.offline.settledAt).to.equal(T0 + GameConfig.Offline.MinSeconds - 1)
			data.offline.settledAt = before.offline.settledAt
			expect(Deep.equal(data, before)).to.equal(true)
		end)

		it("sans drone ou drones en pause : aucune récolte ; écran de conseil après une longue absence", function()
			local none = farm(0, true)
			local report = settle(none, T0 + 3600)
			expect(report.reason).to.equal("no_drones")
			expect(report.harvests).to.equal(0)
			expect(report.seen).to.equal(false)
			local paused = farm(2, true)
			paused.automation.dronesEnabled = false
			expect(settle(paused, T0 + 3600).reason).to.equal("paused")
			expect(coins(paused)).to.equal(0)
			local short = farm(0)
			expect(settle(short, T0 + 120).seen).to.equal(true) -- absence courte : pas d'écran pour un conseil
		end)

		it("un drone, comptoir : 1 récolte / 4 s (drone limitant), tout est vendu au prix du marché", function()
			local data = farm(1, true)
			local report = settle(data, T0 + 3600)
			expect(report.reason).to.equal("ok")
			expect(report.countedSeconds).to.equal(3600)
			local expected = 3600 / harvester.interval
			expect(math.abs(report.harvests - expected) <= 1).to.equal(true)
			-- Carotte normale : 10 Coins l'objet ; tout ce qui n'est pas resté dans le sac a été vendu.
			local sold = report.harvests - report.bagAdded
			expect(BigNum.toNumber(report.coins)).to.equal(sold * 10)
			expect(coins(data)).to.equal(sold * 10)
			expect(BigNum.eq(data.progression.cycleCoins, data.currencies.coins)).to.equal(true) -- Coins GAGNÉS
			expect(report.sales).to.equal(math.floor(report.harvests / Economy.bagCapacity(data)))
			expect(data.automation.stats.droneHarvests).to.equal(report.harvests)
			expect(data.automation.stats.autoSells).to.equal(report.sales)
		end)

		it(
			"sans comptoir : le sac plein arrête les drones ; rien n'est perdu, les cultures restantes attendent",
			function()
				local data = farm(3)
				data.bag.items = { ["tomato|normal"] = 10 }
				local report = settle(data, T0 + 3600)
				expect(report.stoppedBagFull).to.equal(true)
				expect(report.harvests).to.equal(Economy.bagCapacity(data) - 10)
				expect(report.bagAdded).to.equal(report.harvests)
				expect(Inventory.count(data.bag.items)).to.equal(Economy.bagCapacity(data))
				expect(data.bag.items["tomato|normal"]).to.equal(10)
				expect(coins(data)).to.equal(0)
				-- Chaque case est intacte (culture d'avant l'absence) ou replantée dans la fenêtre : rien n'a disparu.
				local count = 0
				for _, tile in data.farm.tiles do
					count += 1
					local intact = tile.plantedAt == T0 - 100
					local replanted = tile.plantedAt >= T0 and tile.plantedAt <= T0 + 3600
					expect(intact or replanted).to.equal(true)
				end
				expect(count).to.equal(9)
			end
		)

		it("capacité du sac et bonus équipés respectés (Grand sac, Récoltes de qualité)", function()
			local bag = farm(3)
			bag.upgrades.normal.coins_bag = 2 -- 60 places
			expect(settle(bag, T0 + 3600).harvests).to.equal(60)

			local plain = farm(1, true)
			local boosted = farm(1, true)
			boosted.upgrades.normal.coins_value = 4 -- ×1,2
			local a = settle(plain, T0 + 1800)
			local b = settle(boosted, T0 + 1800)
			expect(a.harvests).to.equal(b.harvests)
			-- Chaque vente est tronquée séparément : ⌊lot × 10 × 1,2⌋ par lot de 40.
			local per = math.floor(40 * 10 * ProgressionMath.incomeMultiplier(boosted) + 1e-9)
			expect(BigNum.toNumber(b.coins)).to.equal(per * b.sales)
			expect(BigNum.toNumber(b.coins) > BigNum.toNumber(a.coins)).to.equal(true)
		end)

		it("délai de grâce respecté : une culture n'est récoltée que 5 s après sa maturité", function()
			local data = farm(1, true)
			data.farm.tiles = { ["main:5"] = { plantId = "carrot", plantedAt = T0 + 10, growTime = 6 } }
			-- Replantation en Fruit du dragon (150 s) : une seule récolte dans la fenêtre de 90 s, facile à observer.
			data.seeds.unlocked.dragonfruit = true
			data.seeds.selected = "dragonfruit"
			settle(data, T0 + 90)
			-- Mûre à T0 + 16 : drone sur sa grille (T0 + 4k), première action ≥ T0 + 21 -> T0 + 24 ; replantée alors.
			local tile = assert(data.farm.tiles["main:5"], "case replantée")
			expect(tile.plantedAt).to.equal(T0 + 24)
			expect(tile.plantedAt - (T0 + 16) >= harvester.graceDelay).to.equal(true)
		end)

		it(
			"cultures après l'absence cohérentes : replantées dans la fenêtre, avec la graine sélectionnée",
			function()
				local data = farm(3, true, { "west" })
				data.seeds.unlocked.tomato = true
				data.seeds.selected = "tomato"
				settle(data, T0 + 1800)
				for _, tile in data.farm.tiles do
					expect(tile.plantedAt <= T0 + 1800).to.equal(true)
					if tile.plantedAt > T0 then
						expect(tile.plantId).to.equal("tomato")
					end
				end
			end
		)
	end)

	describe("plafond, idempotence, reconnexions", function()
		it("absence de 10 h = exactement la production de 2 h", function()
			local twoHours = farm(2, true)
			local tenHours = farm(2, true)
			local a = settle(twoHours, T0 + MAX)
			local b = settle(tenHours, T0 + 10 * 3600)
			expect(b.countedSeconds).to.equal(MAX)
			expect(b.awaySeconds).to.equal(10 * 3600)
			expect(b.harvests).to.equal(a.harvests)
			expect(BigNum.eq(b.coins, a.coins)).to.equal(true)
		end)

		it("résultat idempotent : un second règlement au même instant ne rapporte rien", function()
			local data = farm(2, true)
			settle(data, T0 + 3600)
			local after = Deep.copy(data)
			local again = settle(data, T0 + 3600)
			expect(again.reason).to.equal("too_short")
			expect(Deep.equal(data, after)).to.equal(true)
		end)

		it(
			"reconnexions répétées (changements rapides de serveur) : jamais plus que le temps réellement écoulé",
			function()
				local hopper = farm(3, true)
				local now = T0
				for _ = 1, 30 do -- 30 sessions de 2 s séparées par 40 s : aucune absence ≥ 60 s
					now += 40
					settle(hopper, now)
					hopper.meta.lastSeen = now + 2 -- sauvegarde finale du serveur quitté
					now += 2
				end
				expect(coins(hopper)).to.equal(0)
				expect(hopper.automation.stats.droneHarvests).to.equal(0)
				-- Une heure d'absence ensuite : comptée une seule fois, à partir de la dernière sauvegarde.
				local report = settle(hopper, now + 3600)
				expect(report.countedSeconds).to.equal(3600)
			end
		)

		it("déconnexion / reconnexion via la sauvegarde : chaque période comptée une seule fois", function()
			local data = farm(1, true)
			-- 1ʳᵉ reconnexion après 1 h : règlement, puis autosave pendant la session (lastSeen = instant de l'écriture).
			local first = settle(data, T0 + 3600)
			local saved = Deep.copy(data)
			saved.meta.lastSeen = T0 + 3630
			local loaded = assert(DataSchema.load(Deep.copy(saved), T0 + 3700), "rechargement")
			-- Reconnexion 20 s après la dernière sauvegarde sur un autre serveur : rien, mais la période jusqu'à cette
			-- reconnexion est réglée (settledAt = T0 + 3650).
			expect(settle(loaded, T0 + 3650).reason).to.equal("too_short")
			-- Absence jusqu'à T0 + 7230 : comptée depuis ce dernier règlement (3 580 s), jamais depuis la sauvegarde
			-- plus ancienne, et une seule fois.
			local second = settle(loaded, T0 + 3630 + 3600)
			expect(second.countedSeconds).to.equal(3580)
			expect(math.abs(second.harvests - first.harvests * 3580 / 3600) <= 1).to.equal(true)
			-- Serveur arrêté sans écrire après ce règlement : la donnée stockée (`saved`) n'a pas changé ; la même
			-- absence est recalculée une seule fois au chargement suivant, jamais additionnée à la précédente.
			local replay =
				settle(assert(DataSchema.load(Deep.copy(saved), T0 + 7300), "rechargement"), T0 + 3630 + 3600)
			expect(replay.countedSeconds).to.equal(3600) -- depuis la dernière sauvegarde (le règlement perdu n'existe pas)
			expect(math.abs(replay.harvests - first.harvests) <= 1).to.equal(true)
		end)

		it("révision de progression différente (reset intervenu) : aucune récompense de l'ancien cycle", function()
			local data = farm(3, true)
			data.progression.revision = 4
			local report = settle(data, T0 + 3600, 3)
			expect(report.reason).to.equal("stale_revision")
			expect(report.harvests).to.equal(0)
			expect(coins(data)).to.equal(0)
			expect(settle(farm(3, true), T0 + 3600, 0).reason).to.equal("ok")
		end)
	end)

	describe("cohérence avec une session active", function()
		it(
			"même nombre de récoltes que la boucle des drones simulée au pas de 0,25 s (drones seuls, 10 min)",
			function()
				for _, setup in { { drones = 1, plots = {} }, { drones = 3, plots = { "west" } } } do
					local base = farm(setup.drones, true, setup.plots)
					local live = Deep.copy(base)
					local nobody =
						{ name = "drones", manual = false, sellTrip = 1e9, sellEvery = 1e9, targetDrones = 3 }
					local sim = EconomySim.new(nobody, 1, live, true) -- replante tout à t = 0
					while sim.now < 600 do
						EconomySim.step(sim)
					end
					local offline = Deep.copy(base)
					offline.meta.lastSeen = 0
					for _, tile in offline.farm.tiles do
						tile.plantedAt = 0 -- mêmes cultures que la simulation (plantées à t = 0)
					end
					local report = Offline.settle(offline, 600, { roll = normalRoll })
					local diff = math.abs(report.harvests - sim.droneHarvests)
					if diff > math.max(2, 0.02 * sim.droneHarvests) then
						print(string.format("    hors ligne %d, simulation %d", report.harvests, sim.droneHarvests))
					end
					expect(diff <= math.max(2, 0.02 * sim.droneHarvests)).to.equal(true)
				end
			end
		)
	end)

	describe("données", function()
		it("migration v6 -> v7 sans perte : champs v6 intacts, aucun bilan, totaux à zéro", function()
			local raw = Deep.copy(DataSchema.template(5)) :: any
			raw.version = 6
			raw.offline = nil
			raw.machines.autoSeller = true
			raw.automation.autoSellThreshold = 75
			raw.currencies.coins = BigNum.fromNumber(4242)
			local original = Deep.copy(raw)
			local data = assert(DataSchema.load(raw, 10), "chargement v6") :: any
			expect(data.version).to.equal(DataSchema.VERSION)
			for key, value in original do
				if key ~= "version" then
					expect(Deep.equal(data[key], value)).to.equal(true)
				end
			end
			expect(data.offline.settledAt).to.equal(0)
			expect(data.offline.report.seen).to.equal(true)
			expect(data.offline.totalSeconds).to.equal(0)
			expect(#data.meta.quarantine).to.equal(0)
		end)

		it("données hors ligne corrompues : quarantaine, valeurs sûres (aucun gain ne peut en résulter)", function()
			local raw = Deep.copy(DataSchema.template(0)) :: any
			raw.offline.settledAt = -5
			raw.offline.totalSeconds = 1.5
			raw.offline.totalCoins = { m = -3, e = 0 }
			raw.offline.report.countedSeconds = 999999
			local data = DataSchema.load(raw, 10)
			expect(data.offline.settledAt).to.equal(0)
			expect(data.offline.totalSeconds).to.equal(0)
			expect(BigNum.isZero(data.offline.totalCoins)).to.equal(true)
			expect(data.offline.report.countedSeconds).to.equal(0)
			local paths = {}
			for _, entry in data.meta.quarantine do
				paths[entry.path] = true
			end
			for _, path in { "offline.settledAt", "offline.totalSeconds", "offline.totalCoins", "offline.report" } do
				expect(paths[path]).to.equal(true)
			end
		end)

		it("bilan, règlement et totaux conservés par une sauvegarde puis un rechargement", function()
			local data = farm(2, true)
			local report = settle(data, T0 + 1800)
			local reloaded = DataSchema.load(Deep.copy(data), T0 + 1900)
			expect(reloaded.offline.settledAt).to.equal(T0 + 1800)
			expect(reloaded.offline.report.harvests).to.equal(report.harvests)
			expect(reloaded.offline.totalSeconds).to.equal(1800)
			expect(#reloaded.meta.quarantine).to.equal(0)
		end)
	end)

	describe("écran « Pendant ton absence »", function()
		it("indique la durée d'absence, la durée prise en compte (plafond) et les gains", function()
			local data = farm(2, true)
			local report = settle(data, T0 + 5 * 3600)
			local text = table.concat(Offline.describeReport(report), "\n")
			expect(string.find(text, "Absent 5 h · production comptée : 2 h (plafond de 2 h)", 1, true) ~= nil).to.equal(
				true
			)
			expect(string.find(text, "Tes drones ont récolté", 1, true) ~= nil).to.equal(true)
			expect(string.find(text, "Le comptoir a vendu", 1, true) ~= nil).to.equal(true)
		end)

		it("conseils : aucun drone, drones en pause, sac plein sans comptoir", function()
			local none = table.concat(Offline.describeReport(settle(farm(0), T0 + 3600)), "\n")
			expect(string.find(none, "aucun drone", 1, true) ~= nil).to.equal(true)
			local pausedFarm = farm(1, true)
			pausedFarm.automation.dronesEnabled = false
			local paused = table.concat(Offline.describeReport(settle(pausedFarm, T0 + 3600)), "\n")
			expect(string.find(paused, "en pause", 1, true) ~= nil).to.equal(true)
			local full = table.concat(Offline.describeReport(settle(farm(3), T0 + 3600)), "\n")
			expect(string.find(full, "Ton sac s'est rempli", 1, true) ~= nil).to.equal(true)
		end)
	end)

	describe("pauses coopératives", function()
		it("le calcul cède la main toutes les N actions sans changer le résultat", function()
			local plain = farm(3, true, { "west" })
			local paused = Deep.copy(plain)
			local a = settle(plain, T0 + 1800)
			local yields = 0
			local b = Offline.settle(paused, T0 + 1800, {
				roll = normalRoll,
				yield = function()
					yields += 1
				end,
				yieldEvery = 100,
			})
			expect(yields > 0).to.equal(true)
			expect(b.harvests).to.equal(a.harvests)
			expect(Deep.equal(paused, plain)).to.equal(true)
		end)
	end)

	describe("coût du calcul", function()
		it("pire cas (3 drones à l'intervalle minimal, 36 cases de Carotte, comptoir, 2 h) : calcul rapide", function()
			local data = farm(3, true, { "west", "east", "terrace" })
			data.upgrades.rebirth.essence_drones = 8 -- intervalle × 0,6
			local started = os.clock()
			local report = settle(data, T0 + MAX)
			local elapsed = os.clock() - started
			print(
				string.format(
					"    pire cas : %d récoltes, %d ventes, %.0f ms (Lune)",
					report.harvests,
					report.sales,
					elapsed * 1000
				)
			)
			expect(report.harvests > 8000).to.equal(true)
			expect(elapsed < 2).to.equal(true)
		end)
	end)
end
