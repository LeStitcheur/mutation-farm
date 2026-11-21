-- Missions (Phase 4, jalon D) : périodes UTC (00:00, lundi 00:00), tirage (3 quotidiennes, 2 hebdomadaires,
-- déterministe, éligibilité), récompenses proportionnelles à la difficulté, progression (récoltes manuelles et de
-- drones, mutations, plante précise, ventes), rebirth/prestige, expiration, récupération unique, reconnexion et
-- changement de serveur, concurrence, triche, boosts, migration v4 -> v5.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local Quests = require(Shared.Util.Quests)
	local QuestConfig = require(Shared.Config.QuestConfig)
	local HarvestRules = require(Shared.Util.HarvestRules)
	local Pets = require(Shared.Util.Pets)
	local Resets = require(Shared.Util.Resets)
	local DataSchema = require(Shared.Util.DataSchema)
	local BigNum = require(Shared.Util.BigNum)
	local Deep = require(Shared.Util.Deep)

	local DAY = 86400
	local NOW = 20409 * DAY + 3600 -- 01:00 UTC
	local USER = 123456

	local function fresh()
		local data = DataSchema.template(0)
		Quests.refresh(data, USER, NOW)
		return data
	end

	-- Mission construite à la main (progression contrôlée), placée dans le tableau quotidien courant.
	local function withMission(data, template: string, target: number, plantId: string?)
		local mission = {
			id = "d:test:" .. template,
			template = template,
			difficulty = "easy",
			target = target,
			progress = 0,
			plantId = plantId,
			claimed = false,
			rewards = {
				coins = BigNum.fromNumber(100),
				eggs = 1,
				boost = "fertilizer",
				decoration = "deco_mutant_gnome",
			},
		}
		data.quests.daily = { period = Quests.periodOf("daily", NOW), missions = { mission } }
		return mission
	end

	local function ripeTile(data, tileId: string, plantId: string?, mutation: string?)
		data.farm.tiles[tileId] = { plantId = plantId or "carrot", plantedAt = 0, growTime = 6, mutation = mutation }
	end

	describe("périodes UTC", function()
		it("quotidienne : bascule à 00:00 UTC ; fin = minuit suivant", function()
			local day = 20409
			expect(Quests.periodOf("daily", day * DAY - 0.001)).to.equal(day - 1)
			expect(Quests.periodOf("daily", day * DAY)).to.equal(day)
			expect(Quests.periodEnd("daily", day)).to.equal((day + 1) * DAY)
		end)

		it("hebdomadaire : bascule le lundi 00:00 UTC (le 5 janvier 1970 était un lundi)", function()
			local monday = 4 * DAY
			expect(Quests.periodOf("weekly", monday - 0.001)).to.equal(0)
			expect(Quests.periodOf("weekly", monday)).to.equal(1)
			expect(Quests.periodOf("weekly", monday + 7 * DAY - 0.001)).to.equal(1)
			expect(Quests.periodEnd("weekly", 1)).to.equal(monday + 7 * DAY)
			-- Lundi 2026-11-23 00:00 UTC (jour 20780) : nouvelle semaine.
			expect(Quests.periodOf("weekly", 20780 * DAY) - Quests.periodOf("weekly", 20780 * DAY - 1)).to.equal(1)
		end)
	end)

	describe("tirage", function()
		it(
			"3 quotidiennes (facile, moyenne, difficile) + 2 hebdomadaires, modèles distincts, identifiants uniques",
			function()
				local data = fresh()
				expect(#data.quests.daily.missions).to.equal(3)
				expect(#data.quests.weekly.missions).to.equal(2)
				local ids, templates = {}, {}
				for index, mission in data.quests.daily.missions do
					expect(mission.difficulty).to.equal(QuestConfig.Slots.daily[index])
					expect(templates[mission.template]).to.equal(nil)
					templates[mission.template] = true
					ids[mission.id] = true
					expect(mission.progress).to.equal(0)
					expect(mission.claimed).to.equal(false)
				end
				for _, mission in data.quests.weekly.missions do
					expect(ids[mission.id]).to.equal(nil)
				end
			end
		)

		it(
			"déterministe : même joueur, même période, même état → mêmes missions ; autre joueur → autre tirage",
			function()
				local a, b = fresh(), fresh()
				expect(Deep.equal(a.quests, b.quests)).to.equal(true)
				local differs = false
				for user = 1, 20 do
					local other = DataSchema.template(0)
					Quests.refresh(other, user, NOW)
					if not Deep.equal(other.quests.daily.missions, a.quests.daily.missions) then
						differs = true
					end
				end
				expect(differs).to.equal(true)
			end
		)

		it("récompenses proportionnelles à la difficulté et à la période ; Coins × revenu du joueur", function()
			local data = fresh()
			local daily = data.quests.daily.missions
			local weekly = data.quests.weekly.missions
			local function coins(mission): number
				return BigNum.toNumber(mission.rewards.coins)
			end
			expect(coins(daily[1]) < coins(daily[2]) and coins(daily[2]) < coins(daily[3])).to.equal(true)
			expect(coins(weekly[1]) > coins(daily[3]) and coins(weekly[2]) > coins(weekly[1])).to.equal(true)
			expect(daily[2].rewards.boost).to.equal("fertilizer")
			expect(daily[3].rewards.eggs).to.equal(1)
			expect(weekly[2].rewards.decoration ~= nil).to.equal(true)
			local richer = DataSchema.template(0)
			richer.progression.rebirths = 3
			Quests.refresh(richer, USER, NOW)
			expect(coins(richer.quests.daily.missions[1]) > coins(daily[1])).to.equal(true)
		end)

		it("éligibilité : drones, plante débloquée, Mutadex restant, rebirth déjà fait", function()
			for user = 1, 60 do
				local data = DataSchema.template(0)
				Quests.refresh(data, user, NOW + user * 7 * DAY)
				for _, kind in { "daily", "weekly" } do
					for _, mission in data.quests[kind].missions do
						expect(mission.template ~= "drone_harvest").to.equal(true) -- aucun drone
						expect(mission.template ~= "rebirth").to.equal(true) -- jamais de rebirth
						if mission.template == "harvest_plant" then
							expect(data.seeds.unlocked[mission.plantId]).to.equal(true)
						end
					end
				end
			end
			local veteran = DataSchema.template(0)
			veteran.machines.drones.harvester = 1
			veteran.stats.totalRebirths = 2
			local drone = assert(QuestConfig.ById.drone_harvest, "modèle absent")
			local rebirth = assert(QuestConfig.ById.rebirth, "modèle absent")
			expect(Quests.eligible(veteran, drone, "daily", "easy")).to.equal(true)
			expect(Quests.eligible(veteran, rebirth, "weekly", "hard")).to.equal(true)
			expect(Quests.eligible(veteran, rebirth, "daily", "hard")).to.equal(false)
		end)
	end)

	describe("progression", function()
		it("récolte manuelle et « Parfait » : comptées, plafonnées à l'objectif", function()
			local data = DataSchema.template(0)
			local manual = withMission(data, "harvest_manual", 2)
			for index = 1, 3 do
				ripeTile(data, "main:" .. index)
				HarvestRules.apply(data, "main:" .. index, NOW, "player")
			end
			expect(manual.progress).to.equal(2) -- plafonnée
			local perfect = withMission(data, "harvest_perfect", 5)
			ripeTile(data, "main:4")
			data.farm.tiles["main:4"].plantedAt = NOW
			local outcome = HarvestRules.apply(data, "main:4", NOW + 6.05, "player")
			expect(outcome.tier).to.equal("perfect")
			expect(perfect.progress).to.equal(1)
		end)

		it("récolte de drone : compte pour « drones », jamais pour « à la main »", function()
			local data = DataSchema.template(0)
			local droneMission = withMission(data, "drone_harvest", 10)
			local manual = {
				id = "d:test:manual",
				template = "harvest_manual",
				difficulty = "easy",
				target = 10,
				progress = 0,
				claimed = false,
				rewards = { coins = BigNum.zero(), eggs = 0 },
			}
			table.insert(data.quests.daily.missions, manual :: any)
			ripeTile(data, "main:1")
			HarvestRules.apply(data, "main:1", NOW, "drone")
			expect(droneMission.progress).to.equal(1)
			expect(manual.progress).to.equal(0)
		end)

		it("mutations et plante précise : seules les bonnes récoltes comptent", function()
			local data = DataSchema.template(0)
			local rare = withMission(data, "mutation_rare", 3)
			ripeTile(data, "main:1", "carrot", "shiny")
			ripeTile(data, "main:2", "carrot", "crystal")
			HarvestRules.apply(data, "main:1", NOW, "player")
			HarvestRules.apply(data, "main:2", NOW, "player")
			expect(rare.progress).to.equal(1) -- seule la Cristallisée (×8)
			local tomato = withMission(data, "harvest_plant", 5, "tomato")
			ripeTile(data, "main:3", "carrot")
			ripeTile(data, "main:4", "tomato")
			HarvestRules.apply(data, "main:3", NOW, "player")
			local outcome = HarvestRules.apply(data, "main:4", NOW, "player")
			expect(tomato.progress).to.equal(1)
			expect(#outcome.questsCompleted).to.equal(0)
		end)

		it("une période échue ne progresse plus", function()
			local data = DataSchema.template(0)
			local mission = withMission(data, "sell", 5)
			Quests.record(data, "sell", 1, NOW)
			Quests.record(data, "sell", 1, NOW + DAY) -- lendemain : tableau périmé
			expect(mission.progress).to.equal(1)
		end)

		it("rebirth et prestige : missions et progression conservées", function()
			local data = DataSchema.template(0)
			local mission = withMission(data, "sell", 5)
			Quests.record(data, "sell", 2, NOW)
			local quests = Deep.copy(data.quests)
			data.progression.cycleCoins = BigNum.fromNumber(100000)
			assert(Resets.rebirth(data, 0))
			data.progression.rebirths = 5
			data.progression.prestigeCoins = BigNum.fromNumber(1e7)
			assert(Resets.prestige(data, 1))
			expect(Deep.equal(data.quests, quests)).to.equal(true)
			Quests.record(data, "sell", 1, NOW)
			expect(mission.progress).to.equal(3)
		end)
	end)

	describe("récupération", function()
		it("une seule fois : Coins (gagnés), œuf, boost, décoration ; seconde tentative refusée", function()
			local data = DataSchema.template(0)
			local mission = withMission(data, "sell", 1)
			expect(select(2, Quests.claim(data, mission.id, NOW))).to.equal("not_completed")
			Quests.record(data, "sell", 1, NOW)
			local outcome = assert(Quests.claim(data, mission.id, NOW), "récupération refusée")
			expect(BigNum.toNumber(outcome.coins)).to.equal(100)
			expect(BigNum.toNumber(data.currencies.coins)).to.equal(100)
			expect(BigNum.toNumber(data.progression.cycleCoins)).to.equal(100)
			expect(Pets.freeEggs(data, "mission")).to.equal(1)
			expect(Quests.boostRemaining(data, "fertilizer", NOW)).to.equal(600)
			expect(data.cosmetics.owned.deco_mutant_gnome).to.equal(true)
			expect(data.quests.claimed).to.equal(1)
			local again, failure = Quests.claim(data, mission.id, NOW)
			expect(again).to.equal(nil)
			expect(failure).to.equal("already_claimed")
			expect(BigNum.toNumber(data.currencies.coins)).to.equal(100)
			expect(Pets.freeEggs(data, "mission")).to.equal(1)
		end)

		it("expiration : récupération refusée après la période, puis nouveau tirage", function()
			local data = DataSchema.template(0)
			local mission = withMission(data, "sell", 1)
			Quests.record(data, "sell", 1, NOW)
			local tomorrow = NOW + DAY
			expect(select(2, Quests.claim(data, mission.id, tomorrow))).to.equal("expired")
			expect(Quests.needsRefresh(data, tomorrow)).to.equal(true)
			local renewed = Quests.refresh(data, USER, tomorrow)
			expect(table.find(renewed, "daily") ~= nil).to.equal(true)
			expect(data.quests.daily.period).to.equal(Quests.periodOf("daily", tomorrow))
			expect(Quests.find(data, mission.id)).to.equal(nil)
		end)

		it("triche : identifiant inconnu, mission non terminée, progression impossible à forcer", function()
			local data = fresh()
			expect(select(2, Quests.claim(data, "d:0:99", NOW))).to.equal("unknown_mission")
			local first = data.quests.daily.missions[1]
			expect(select(2, Quests.claim(data, first.id, NOW))).to.equal("not_completed")
			expect(BigNum.isZero(data.currencies.coins)).to.equal(true)
			-- Sauvegarde trafiquée (progression > objectif) : tableau mis en quarantaine puis tiré à nouveau.
			local raw = Deep.copy(data)
			raw.quests.daily.missions[1].progress = 1e9
			local loaded = assert(DataSchema.load(raw, NOW))
			expect(loaded.quests.daily.period).to.equal(-1)
			expect(loaded.meta.quarantine[1].path).to.equal("quests.daily")
			Quests.refresh(loaded, USER, NOW)
			expect(loaded.quests.daily.missions[1].progress).to.equal(0)
		end)

		it(
			"réserve d'œufs pleine : récupération refusée sans rien accorder, possible après avoir ouvert des œufs",
			function()
				local data = DataSchema.template(0)
				local mission = withMission(data, "sell", 1)
				Quests.record(data, "sell", 1, NOW)
				Pets.addFreeEggs(data, "mission", 99)
				local outcome, failure = Quests.claim(data, mission.id, NOW)
				expect(outcome).to.equal(nil)
				expect(failure).to.equal("reserve_full")
				expect(mission.claimed).to.equal(false)
				expect(BigNum.isZero(data.currencies.coins)).to.equal(true)
				data.pets.freeEggs.mission = 98 -- un œuf ouvert
				local claimed = assert(Quests.claim(data, mission.id, NOW), "récupération refusée")
				expect(claimed.eggs).to.equal(1)
				expect(claimed.eggsOverflow).to.equal(0)
				expect(Pets.freeEggs(data, "mission")).to.equal(99)
			end
		)

		it("concurrence : deux demandes de récupération successives → une seule récompense", function()
			local data = DataSchema.template(0)
			local mission = withMission(data, "sell", 1)
			Quests.record(data, "sell", 1, NOW)
			local first = Quests.claim(data, mission.id, NOW)
			local second = Quests.claim(data, mission.id, NOW)
			expect(first ~= nil).to.equal(true)
			expect(second).to.equal(nil)
			expect(data.quests.claimed).to.equal(1)
		end)

		it("reconnexion et changement de serveur : sauvegarde → chargement → aucun nouveau tirage", function()
			local data = fresh()
			Quests.record(data, "harvest", 7, NOW)
			local loaded = assert(DataSchema.load(Deep.copy(data), NOW + 60))
			expect(Quests.needsRefresh(loaded, NOW + 60)).to.equal(false)
			expect(#Quests.refresh(loaded, USER, NOW + 60)).to.equal(0)
			expect(Deep.equal(loaded.quests, data.quests)).to.equal(true)
			expect(#loaded.meta.quarantine).to.equal(0)
		end)
	end)

	describe("boosts", function()
		it("Engrais : +25 % de valeur à la récolte ; Rosée : chance × 1,5 ; durée plafonnée", function()
			local data = DataSchema.template(0)
			expect(Quests.valueBoost(data, NOW)).to.equal(0)
			expect(Quests.luckBoost(data, NOW)).to.equal(1)
			assert(Quests.activateBoost(data, "fertilizer", NOW))
			assert(Quests.activateBoost(data, "lucky_dew", NOW))
			expect(Quests.valueBoost(data, NOW + 10)).to.equal(0.25)
			expect(Quests.luckBoost(data, NOW + 10)).to.equal(1.5)
			ripeTile(data, "main:1")
			local outcome = HarvestRules.apply(data, "main:1", NOW + 10, "drone")
			expect(BigNum.toNumber(outcome.eventBonus)).to.equal(2) -- Carotte 10 × 0,25 = 2,5 → 2
			expect(Quests.valueBoost(data, NOW + 601)).to.equal(0)
			for _ = 1, 50 do
				Quests.activateBoost(data, "fertilizer", NOW)
			end
			expect(Quests.boostRemaining(data, "fertilizer", NOW)).to.equal(QuestConfig.MaxBoostDuration)
			expect(Quests.activateBoost(data, "unknown", NOW)).to.equal(false)
		end)
	end)

	describe("schéma", function()
		it("migration v4 -> v5 : missions et boosts ajoutés vides, rien d'autre ne change", function()
			local v4 = DataSchema.template(0)
			v4.version = 4
			v4.quests = nil :: any
			v4.boosts = nil :: any
			v4.stats.harvests = 42
			local data, err, notes = DataSchema.load(Deep.copy(v4), NOW)
			expect(err).to.equal(nil)
			assert(data, "chargement refusé")
			expect(data.version).to.equal(DataSchema.VERSION)
			expect(data.quests.daily.period).to.equal(-1)
			expect(next(data.boosts)).to.equal(nil)
			expect(data.stats.harvests).to.equal(42)
			expect(#data.meta.quarantine).to.equal(0)
			expect(string.find(table.concat(notes, " "), "migration v4 -> v", 1, true)).to.be.ok()
		end)
	end)
end
