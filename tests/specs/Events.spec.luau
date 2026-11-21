-- Événements du monde (Phase 4, jalon C) : calendrier déterministe (tirage contrôlé, rendez-vous fixes), un seul
-- événement à la fois, écart minimal, déclenchement forcé et expiration, arrivée tardive, plusieurs joueurs, effets
-- (chance plafonnée à la plantation, valeur versée à la récolte pour le joueur et les drones), rebirth/prestige
-- pendant un événement, sauvegarde inchangée, aucun cumul.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local Shared = ReplicatedStorage.Shared
	local EventConfig = require(Shared.Config.EventConfig)
	local UpgradeConfig = require(Shared.Config.UpgradeConfig)
	local WorldEvents = require(Shared.Util.WorldEvents)
	local Bonuses = require(Shared.Util.Bonuses)
	local Economy = require(Shared.Util.Economy)
	local HarvestRules = require(Shared.Util.HarvestRules)
	local MutationRoll = require(Shared.Util.MutationRoll)
	local ProgressionMath = require(Shared.Util.ProgressionMath)
	local Resets = require(Shared.Util.Resets)
	local DataSchema = require(Shared.Util.DataSchema)
	local BigNum = require(Shared.Util.BigNum)
	local Deep = require(Shared.Util.Deep)
	local MutationOdds = require(ServerScriptService.Server.Config.MutationOdds)

	local SCHEDULE = EventConfig.Schedule
	local DAY = 86400
	local BASE_DAY = 20409 -- 2025-11-17 (jour UTC quelconque)
	local RAIN = MutationOdds.Luck.MutagenicRain

	local function isFixedSlot(slot: number): boolean
		local second = (slot * SCHEDULE.SlotLength) % DAY
		for _, fixed in SCHEDULE.Fixed do
			if fixed.hour * 3600 == second then
				return true
			end
		end
		return false
	end

	local function ripeTile(data, tileId: string, mutation: string?)
		data.farm.tiles[tileId] = { plantId = "carrot", plantedAt = 0, growTime = 6, mutation = mutation }
	end

	-- Premier événement planifié (aléatoire) trouvé à partir d'un jour donné.
	local function firstRandomWindow(): WorldEvents.Window
		local slot = WorldEvents.slotOf(BASE_DAY * DAY)
		while true do
			local window = WorldEvents.scheduled(slot)
			if window and not isFixedSlot(slot) then
				return window
			end
			slot += 1
		end
	end

	describe("calendrier", function()
		it("déterministe : même tranche, même événement (tous les serveurs, à tout moment)", function()
			for slot = 1000000, 1000200 do
				expect(Deep.equal(WorldEvents.scheduled(slot), WorldEvents.scheduled(slot))).to.equal(true)
			end
		end)

		it("tirage contrôlé : ≈ 50 % des tranches, Pluie 60 % / Floraison 40 % (20 000 tranches)", function()
			local slots, events, rain = 0, 0, 0
			for slot = 1000000, 1019999 do
				if not isFixedSlot(slot) then
					slots += 1
					local window = WorldEvents.scheduled(slot)
					if window then
						events += 1
						if window.id == "mutagenic_rain" then
							rain += 1
						end
					end
				end
			end
			expect(math.abs(events / slots - SCHEDULE.Chance) < 0.02).to.equal(true)
			expect(math.abs(rain / events - 0.6) < 0.03).to.equal(true)
		end)

		it("rendez-vous fixes : 12:00 et 20:00 UTC → Floraison dorée en début de tranche", function()
			for _, hour in { 12, 20 } do
				local start = (BASE_DAY + 3) * DAY + hour * 3600
				local window = assert(WorldEvents.scheduled(WorldEvents.slotOf(start)), "rendez-vous absent")
				expect(window.id).to.equal("golden_bloom")
				expect(window.startsAt).to.equal(start + SCHEDULE.MinGap / 2)
			end
		end)

		it("un seul événement à la fois et écart minimal entre deux événements (10 000 tranches)", function()
			local previous: WorldEvents.Window? = nil
			local count = 0
			for slot = 1000000, 1009999 do
				local window = WorldEvents.scheduled(slot)
				if window then
					count += 1
					local slotStart = slot * SCHEDULE.SlotLength
					expect(window.startsAt >= slotStart + SCHEDULE.MinGap / 2).to.equal(true)
					expect(window.endsAt <= slotStart + SCHEDULE.SlotLength - SCHEDULE.MinGap / 2).to.equal(true)
					if previous then
						expect(window.startsAt - previous.endsAt >= SCHEDULE.MinGap).to.equal(true)
					end
					previous = window
				end
			end
			expect(count > 4000).to.equal(true)
		end)
	end)

	describe("déclenchement, expiration, arrivée tardive", function()
		it("événement forcé : actif sur [début, fin[, puis plus rien (aucun bonus résiduel)", function()
			local t = BASE_DAY * DAY + 1234
			local forced = assert(WorldEvents.force("golden_bloom", t, 120), "événement inconnu")
			expect(Deep.equal(WorldEvents.activeAt(t, forced), forced)).to.equal(true)
			expect(WorldEvents.valueBonus(WorldEvents.activeAt(t + 119.9, forced))).to.equal(0.5)
			local after = WorldEvents.activeAt(t + 120, forced)
			expect(after).to.equal(nil)
			expect(WorldEvents.valueBonus(after)).to.equal(0)
			expect(WorldEvents.luckFactor(after, RAIN)).to.equal(1)
			expect(WorldEvents.force("unknown", t)).to.equal(nil)
			local capped = assert(WorldEvents.force("mutagenic_rain", t, 1e9), "événement inconnu")
			expect(capped.endsAt - capped.startsAt).to.equal(EventConfig.MaxForcedDuration)
		end)

		it(
			"événement planifié : début, milieu et fin donnent la même fenêtre (arrivée tardive) ; rien après",
			function()
				local window = firstRandomWindow()
				for _, t in { window.startsAt, (window.startsAt + window.endsAt) / 2, window.endsAt - 0.001 } do
					local active = assert(WorldEvents.activeAt(t), "événement absent")
					expect(active.id).to.equal(window.id)
					expect(active.endsAt).to.equal(window.endsAt)
					expect(math.abs(WorldEvents.remaining(active, t) - (window.endsAt - t)) < 1e-9).to.equal(true)
				end
				expect(WorldEvents.activeAt(window.startsAt - 0.001)).to.equal(nil)
				expect(WorldEvents.activeAt(window.endsAt)).to.equal(nil)
			end
		)

		it(
			"forcé pendant un événement planifié : un seul actif, le planifié reste annulé après la fin",
			function()
				local window = firstRandomWindow()
				local forced =
					assert(WorldEvents.force("golden_bloom", window.startsAt + 10, 30), "événement inconnu")
				local during = assert(WorldEvents.activeAt(window.startsAt + 20, forced), "événement absent")
				expect(during.forced).to.equal(true)
				expect(WorldEvents.activeAt(window.startsAt + 60, forced)).to.equal(nil)
			end
		)
	end)

	describe("effets", function()
		it("Pluie mutagène : chance × facteur serveur, plafonnée ; P(normale) ≥ 46 % au plafond", function()
			local data = DataSchema.template(0)
			expect(Bonuses.luck(data)).to.equal(1)
			expect(Bonuses.luck(data, RAIN)).to.equal(RAIN)
			expect(Bonuses.luck(data, 0.2)).to.equal(1) -- un facteur < 1 n'a aucun effet
			for _, upgrade in UpgradeConfig.List do
				data.upgrades[UpgradeConfig.Trees[upgrade.tree].storage][upgrade.id] = upgrade.maxLevel
			end
			expect(Bonuses.luck(data, RAIN)).to.equal(UpgradeConfig.Caps.MaxTotalLuck)
			local normal = MutationRoll.probabilities(MutationRoll.applyLuck(MutationOdds.Weights, 1)).normal
			local raining = MutationRoll.probabilities(MutationRoll.applyLuck(MutationOdds.Weights, RAIN)).normal
			expect((1 - raining) / (1 - normal) > 2).to.equal(true) -- mutations au moins doublées
			local capped = MutationRoll.applyLuck(MutationOdds.Weights, UpgradeConfig.Caps.MaxTotalLuck)
			expect(MutationRoll.probabilities(capped).normal >= 0.46).to.equal(true)
		end)

		it("Floraison dorée : +50 % de la valeur versé à la récolte, joueur et drone, une seule fois", function()
			local data = DataSchema.template(0)
			ripeTile(data, "main:1", "shiny")
			ripeTile(data, "main:2")
			ripeTile(data, "main:3")
			local player = HarvestRules.apply(data, "main:1", 100, "player", 0.5)
			expect(BigNum.toNumber(player.eventBonus)).to.equal(10) -- Carotte Brillante : 20 × 0,5
			local drone = HarvestRules.apply(data, "main:2", 100, "drone", 0.5)
			expect(BigNum.toNumber(drone.eventBonus)).to.equal(5)
			local outside = HarvestRules.apply(data, "main:3", 100, "player", nil)
			expect(BigNum.isZero(outside.eventBonus)).to.equal(true)
			-- Une culture n'est récoltée qu'une fois : pas de second versement.
			expect((HarvestRules.check(data, "main:1", 100))).to.equal(false)
			-- L'objet du sac garde sa valeur normale à la vente : rien à gagner à attendre l'événement pour vendre.
			expect(BigNum.toNumber(Economy.sellValue(data.bag.items))).to.equal(20 + 10 + 10)
		end)

		it("plusieurs joueurs : même fenêtre, bonus proportionnel au revenu de chacun", function()
			local window = firstRandomWindow()
			local t = window.startsAt + 1
			expect(Deep.equal(WorldEvents.activeAt(t), WorldEvents.activeAt(t))).to.equal(true)
			local first, second = DataSchema.template(0), DataSchema.template(0)
			second.progression.rebirths = 2
			ripeTile(first, "main:1")
			ripeTile(second, "main:1")
			local a = HarvestRules.apply(first, "main:1", 100, "player", 0.5)
			local b = HarvestRules.apply(second, "main:1", 100, "player", 0.5)
			local expected = 5 * ProgressionMath.incomeMultiplier(second)
			expect(BigNum.toNumber(a.eventBonus)).to.equal(5)
			expect(math.abs(BigNum.toNumber(b.eventBonus) - math.floor(expected)) <= 1).to.equal(true)
		end)

		it("rebirth et prestige pendant un événement : effets inchangés, rien n'est sauvegardé", function()
			local data = DataSchema.template(0)
			local before = Deep.copy(data)
			local window = firstRandomWindow()
			WorldEvents.valueBonus(WorldEvents.activeAt(window.startsAt + 5))
			expect(Deep.equal(data, before)).to.equal(true) -- les événements ne touchent jamais la sauvegarde
			data.progression.cycleCoins = BigNum.fromNumber(100000)
			assert(Resets.rebirth(data, 0))
			ripeTile(data, "main:1")
			local outcome = HarvestRules.apply(data, "main:1", 100, "player", 0.5)
			local expected = 5 * ProgressionMath.incomeMultiplier(data)
			expect(math.abs(BigNum.toNumber(outcome.eventBonus) - math.floor(expected)) <= 1).to.equal(true)
			data.progression.rebirths = 5
			data.progression.prestigeCoins = BigNum.fromNumber(1e7)
			assert(Resets.prestige(data, 1))
			expect(Bonuses.luck(data, RAIN)).to.equal(RAIN)
			local loaded = assert(DataSchema.load(Deep.copy(data), 200))
			expect(#loaded.meta.quarantine).to.equal(0)
		end)

		it(
			"aucun cumul : un facteur appliqué une fois, un seul événement actif, bonus jamais additionné",
			function()
				local data = DataSchema.template(0)
				expect(Bonuses.luck(data, RAIN)).to.equal(Bonuses.luck(data, RAIN))
				local window = firstRandomWindow()
				local forced =
					assert(WorldEvents.force("golden_bloom", window.startsAt - 5, 600), "événement inconnu")
				local active = assert(WorldEvents.activeAt(window.startsAt + 1, forced), "événement absent")
				expect(active.forced).to.equal(true)
				expect(WorldEvents.valueBonus(active)).to.equal(0.5)
				expect(WorldEvents.luckFactor(active, RAIN)).to.equal(1) -- la Floraison n'apporte aucune chance
			end
		)
	end)
end
