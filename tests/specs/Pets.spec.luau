-- Familiers (Phase 4, jalon B) : œufs (probabilités affichées, tirage), éclosion atomique et idempotente (Coins ou
-- œuf gratuit), inventaire plein, équipement (3 emplacements), bonus cumulés et plafonnés (règles de jeu réelles),
-- XP et niveaux, conservation (rebirth, prestige, sauvegarde), migration v3 -> v4, données malformées, doublons.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local Shared = ReplicatedStorage.Shared
	local Pets = require(Shared.Util.Pets)
	local PetConfig = require(Shared.Config.PetConfig)
	local UpgradeConfig = require(Shared.Config.UpgradeConfig)
	local DroneConfig = require(Shared.Config.DroneConfig)
	local Bonuses = require(Shared.Util.Bonuses)
	local Economy = require(Shared.Util.Economy)
	local DroneLogic = require(Shared.Util.DroneLogic)
	local HarvestRules = require(Shared.Util.HarvestRules)
	local MutationRoll = require(Shared.Util.MutationRoll)
	local ProgressionMath = require(Shared.Util.ProgressionMath)
	local Resets = require(Shared.Util.Resets)
	local DataSchema = require(Shared.Util.DataSchema)
	local BigNum = require(Shared.Util.BigNum)
	local Deep = require(Shared.Util.Deep)
	local MutationOdds = require(ServerScriptService.Server.Config.MutationOdds)

	local NOW = 7000

	local function rich(coins: number?)
		local data = DataSchema.template(0)
		data.currencies.coins = BigNum.fromNumber(coins or 1e9)
		return data
	end

	-- Ajoute directement une instance (fixtures) et l'équipe si demandé.
	local function give(data, petId: string, level: number?, equip: boolean?): string
		local id = "p" .. data.pets.nextSerial
		data.pets.nextSerial += 1
		data.pets.instances[id] = { petId = petId, level = level or 1, xp = 0, obtainedAt = 1 }
		if equip then
			assert(Pets.equip(data, id))
		end
		return id
	end

	local function ripeTile(data, tileId: string)
		data.farm.tiles[tileId] = { plantId = "carrot", plantedAt = 0, growTime = 6 }
	end

	describe("œufs et probabilités", function()
		it("probabilités affichées = poids / somme ; espèces connues ; prix en Coins ou œuf non vendu", function()
			for _, egg in PetConfig.Eggs do
				local sum = 0
				for _, odds in Pets.odds(egg) do
					expect(Pets.get(odds.petId)).to.be.ok()
					expect(odds.probability > 0).to.equal(true)
					sum += odds.probability
				end
				expect(math.abs(sum - 1) < 1e-9).to.equal(true)
				if egg.price then
					expect(egg.price > 0 and egg.price % 1 == 0).to.equal(true)
				end
			end
			expect(PetConfig.EggById.mission.price).to.equal(nil)
			expect(#PetConfig.List).to.equal(6)
		end)

		it("tirage : bornes et répartition exacte sur une grille uniforme de 20 000 aléas", function()
			local egg = PetConfig.EggById.crystal
			expect(Pets.draw(egg, 0)).to.equal(egg.weights[1].petId)
			expect(Pets.draw(egg, 0.999999)).to.equal(egg.weights[#egg.weights].petId)
			local counts = {}
			local n = 20000
			for i = 1, n do
				local petId = Pets.draw(egg, (i - 0.5) / n)
				counts[petId] = (counts[petId] or 0) + 1
			end
			for _, odds in Pets.odds(egg) do
				expect(math.abs(counts[odds.petId] / n - odds.probability) <= 1 / n).to.equal(true)
			end
		end)
	end)

	describe("éclosion", function()
		it("achat en Coins : paiement, instance unique de niveau 1, compteur d'éclosions", function()
			local data = rich(10000)
			local outcome, failure = Pets.hatch(data, "meadow", 0, false, 0, NOW)
			expect(failure).to.equal(nil)
			local result = assert(outcome, "éclosion refusée")
			expect(result.instanceId).to.equal("p1")
			expect(result.petId).to.equal("sproutling")
			expect(BigNum.toNumber(data.currencies.coins)).to.equal(5000)
			expect(BigNum.toNumber(result.price)).to.equal(5000)
			expect(data.pets.hatched).to.equal(1)
			local instance = assert(Pets.instance(data, "p1"))
			expect(instance.level).to.equal(1)
			expect(instance.xp).to.equal(0)
			expect(instance.obtainedAt).to.equal(NOW)
		end)

		it("fonds insuffisants, œuf inconnu, œuf non vendu : rien ne change", function()
			local data = rich(4999)
			local before = Deep.copy(data)
			expect(select(2, Pets.hatch(data, "meadow", 0, false, 0.5, NOW))).to.equal("insufficient_funds")
			expect(select(2, Pets.hatch(data, "golden", 0, false, 0.5, NOW))).to.equal("unknown_egg")
			expect(select(2, Pets.hatch(data, "mission", 0, false, 0.5, NOW))).to.equal("not_for_sale")
			expect(Deep.equal(data, before)).to.equal(true)
		end)

		it("œuf gratuit : consommé sans dépense ; réserve vide refusée ; réserve plafonnée", function()
			local data = rich(0)
			expect(select(2, Pets.hatch(data, "mission", 0, true, 0.5, NOW))).to.equal("no_free_egg")
			expect(Pets.addFreeEggs(data, "mission", 2)).to.equal(2)
			local result = assert(Pets.hatch(data, "mission", 0, true, 0.99, NOW))
			expect(result.free).to.equal(true)
			expect(BigNum.isZero(result.price)).to.equal(true)
			expect(Pets.freeEggs(data, "mission")).to.equal(1)
			expect(Pets.addFreeEggs(data, "mission", 500)).to.equal(PetConfig.MaxFreeEggs - 1)
			expect(Pets.addFreeEggs(data, "unknown", 1)).to.equal(0)
		end)

		it("inventaire plein : refusé AVANT tout paiement", function()
			local data = rich(1e9)
			for _ = 1, PetConfig.InventoryCapacity do
				give(data, "sproutling")
			end
			local coins = Deep.copy(data.currencies.coins)
			expect(select(2, Pets.hatch(data, "meadow", 0, false, 0.5, NOW))).to.equal("inventory_full")
			expect(BigNum.eq(data.currencies.coins, coins)).to.equal(true)
			expect(Pets.count(data)).to.equal(PetConfig.InventoryCapacity)
		end)

		it("double clic / paquet rejoué (même révision attendue) : un seul œuf ouvert, un seul paiement", function()
			local data = rich(12000)
			assert(Pets.hatch(data, "meadow", 0, false, 0.1, NOW))
			local outcome, failure = Pets.hatch(data, "meadow", 0, false, 0.1, NOW)
			expect(outcome).to.equal(nil)
			expect(failure).to.equal("stale")
			expect(Pets.count(data)).to.equal(1)
			expect(BigNum.toNumber(data.currencies.coins)).to.equal(7000)
		end)

		it("identifiants jamais réutilisés, même après un relâchement", function()
			local data = rich()
			local first = assert(Pets.hatch(data, "meadow", 0, false, 0.1, NOW))
			local second = assert(Pets.hatch(data, "meadow", 1, false, 0.1, NOW))
			assert(Pets.release(data, second.instanceId))
			local third = assert(Pets.hatch(data, "meadow", 2, false, 0.1, NOW))
			expect(first.instanceId).to.equal("p1")
			expect(second.instanceId).to.equal("p2")
			expect(third.instanceId).to.equal("p3")
			expect(Pets.instance(data, "p2")).to.equal(nil)
		end)
	end)

	describe("inventaire et équipement", function()
		it("3 emplacements ; double équipement refusé ; relâcher un équipé refusé ; déséquiper", function()
			local data = rich()
			local ids = {}
			for index = 1, 4 do
				ids[index] = give(data, "crystal_fox")
			end
			for index = 1, 3 do
				expect((Pets.equip(data, ids[index]))).to.equal(true)
			end
			expect(select(2, Pets.equip(data, ids[1]))).to.equal("already_equipped")
			expect(select(2, Pets.equip(data, ids[4]))).to.equal("slots_full")
			expect(select(2, Pets.release(data, ids[1]))).to.equal("equipped")
			expect((Pets.unequip(data, ids[1]))).to.equal(true)
			expect(select(2, Pets.unequip(data, ids[1]))).to.equal("not_equipped")
			expect((Pets.equip(data, ids[4]))).to.equal(true)
			expect(#data.pets.equipped).to.equal(3)
			expect(select(2, Pets.equip(data, "p999"))).to.equal("unknown_pet")
		end)

		it(
			"tri : équipés, rareté, niveau ; doublons comptés ; espèce en sommeil ni listée ni équipable",
			function()
				local data = rich()
				give(data, "sproutling", 3)
				give(data, "sproutling", 7)
				local wisp = give(data, "primal_wisp", 1)
				local fox = give(data, "crystal_fox", 2, true)
				data.pets.instances.p99 = { petId = "retired_pet", level = 1, xp = 0, obtainedAt = 1 }
				local order = {}
				for _, owned in Pets.sorted(data) do
					table.insert(order, owned.id)
				end
				expect(table.concat(order, ",")).to.equal(fox .. "," .. wisp .. ",p2,p1")
				expect(Pets.speciesCount(data).sproutling).to.equal(2)
				expect(select(2, Pets.equip(data, "p99"))).to.equal("dormant")
				expect(Pets.count(data)).to.equal(5) -- la place d'inventaire reste occupée
			end
		)
	end)

	describe("bonus", function()
		it("par niveau : minimum au niveau 1, maximum au niveau maximum, interpolation linéaire", function()
			local fox = assert(Pets.get("crystal_fox"))
			expect(Pets.bonus(fox, "value", 1)).to.equal(0.05)
			expect(math.abs(Pets.bonus(fox, "value", PetConfig.Level.Max) - 0.15) < 1e-12).to.equal(true)
			expect(math.abs(Pets.bonus(fox, "value", 8) - 0.10) < 1e-12).to.equal(true)
			expect(Pets.bonus(fox, "luck", 15)).to.equal(0)
			expect(Pets.describe(fox, 1)).to.equal("+5 % revenu")
		end)

		it("cumul de 3 familiers plafonné par effet ; non équipés sans effet", function()
			local data = rich()
			for _ = 1, 3 do
				give(data, "crystal_fox", PetConfig.Level.Max, true)
			end
			give(data, "moon_moth", PetConfig.Level.Max) -- possédé, non équipé
			local effects = Pets.effects(data)
			expect(effects.value).to.equal(PetConfig.Caps.value) -- 3 × 0,15 = 0,45 → 0,40
			expect(effects.luck).to.equal(0)
		end)

		it("règles de jeu : pousse, revenu, chance, drones et précision manuelle suivent les familiers", function()
			local data = rich()
			local base = {
				grow = Economy.growTime(data, "carrot"),
				income = ProgressionMath.incomeMultiplier(data),
				luck = Bonuses.luck(data),
				drone = DroneLogic.interval(assert(DroneConfig.get("harvester")), data),
			}
			give(data, "primal_wisp", 1, true)
			expect(math.abs(Economy.growTime(data, "carrot") - base.grow * 0.98) < 1e-9).to.equal(true)
			expect(math.abs(ProgressionMath.incomeMultiplier(data) - base.income * 1.03) < 1e-9).to.equal(true)
			expect(math.abs(Bonuses.luck(data) - (base.luck + 0.05)) < 1e-9).to.equal(true)
			local droneInterval = DroneLogic.interval(assert(DroneConfig.get("harvester")), data)
			expect(math.abs(droneInterval - base.drone * 0.98) < 1e-9).to.equal(true)
			-- Précision manuelle : récolte « Parfait » du joueur × (1 + 0,10) ; un drone n'a jamais de bonus.
			local plain = rich()
			ripeTile(plain, "main:1")
			ripeTile(data, "main:1")
			local reference = HarvestRules.apply(plain, "main:1", 6.05, "player")
			local boosted = HarvestRules.apply(data, "main:1", 6.05, "player")
			expect(reference.tier).to.equal("perfect")
			local expected = BigNum.toNumber(reference.bonus) * 1.03 * 1.10
			expect(math.abs(BigNum.toNumber(boosted.bonus) - expected) <= 1).to.equal(true)
			ripeTile(data, "main:2")
			expect(BigNum.isZero(HarvestRules.apply(data, "main:2", 6.05, "drone").bonus)).to.equal(true)
		end)

		it("plafonds globaux : pousse ≥ 40 %, drones ≥ 50 %, chance ≤ 5 et P(normale) ≥ 46 %", function()
			local data = rich()
			for _, upgrade in UpgradeConfig.List do
				local storage = UpgradeConfig.Trees[upgrade.tree].storage
				data.upgrades[storage][upgrade.id] = upgrade.maxLevel
			end
			give(data, "primal_wisp", PetConfig.Level.Max, true)
			give(data, "moon_moth", PetConfig.Level.Max, true)
			give(data, "moon_moth", PetConfig.Level.Max, true)
			expect(Bonuses.growthFactor(data) >= UpgradeConfig.Caps.MinGrowthFactor).to.equal(true)
			expect(Bonuses.droneIntervalFactor(data) >= UpgradeConfig.Caps.MinDroneIntervalFactor).to.equal(true)
			local luck = Bonuses.luck(data)
			expect(luck <= UpgradeConfig.Caps.MaxTotalLuck).to.equal(true)
			expect(luck > UpgradeConfig.Caps.MaxLuck).to.equal(true) -- les familiers s'ajoutent aux améliorations
			local worst = MutationRoll.probabilities(
				MutationRoll.applyLuck(MutationOdds.Weights, UpgradeConfig.Caps.MaxTotalLuck)
			)
			expect(worst.normal >= 0.46).to.equal(true)
		end)
	end)

	describe("XP et niveaux", function()
		it("coût exponentiel, niveau plafonné, XP remise à zéro au maximum", function()
			expect(Pets.xpToNext(1)).to.equal(PetConfig.Level.XpBase)
			expect(Pets.xpToNext(2) > Pets.xpToNext(1)).to.equal(true)
			expect(Pets.xpToNext(PetConfig.Level.Max)).to.equal(math.huge)
			local data = rich()
			local id = give(data, "sproutling", 1, true)
			local ups = Pets.grantXp(data, 1e7)
			local instance = assert(Pets.instance(data, id))
			expect(instance.level).to.equal(PetConfig.Level.Max)
			expect(instance.xp).to.equal(0)
			expect(#ups).to.equal(PetConfig.Level.Max - 1)
			expect(#Pets.grantXp(data, 1000)).to.equal(0)
		end)

		it(
			"récoltes manuelles et de drones : XP aux seuls équipés, « Parfait » +1, passage de niveau signalé",
			function()
				local data = rich()
				local equipped = give(data, "solar_bunny", 1, true)
				local idle = give(data, "solar_bunny", 1)
				data.pets.instances[equipped].xp = PetConfig.Level.XpBase - 2
				ripeTile(data, "main:1")
				ripeTile(data, "main:2")
				local drone = HarvestRules.apply(data, "main:1", 50, "drone")
				expect(#drone.petLevelUps).to.equal(0)
				expect(data.pets.instances[equipped].xp).to.equal(PetConfig.Level.XpBase - 1)
				local perfect = HarvestRules.apply(data, "main:2", 6.05, "player")
				expect(#perfect.petLevelUps).to.equal(1)
				expect(perfect.petLevelUps[1].level).to.equal(2)
				expect(data.pets.instances[equipped].level).to.equal(2)
				expect(data.pets.instances[equipped].xp).to.equal(1)
				expect(data.pets.instances[idle].xp).to.equal(0)
			end
		)
	end)

	describe("conservation et données", function()
		local function owner()
			local data = rich()
			give(data, "moon_moth", 4, true)
			give(data, "crystal_fox", 2)
			Pets.addFreeEggs(data, "mission", 3)
			data.pets.hatched = 2
			return data
		end

		it("rebirth et prestige ne touchent pas aux familiers", function()
			local data = owner()
			local pets = Deep.copy(data.pets)
			data.progression.cycleCoins = BigNum.fromNumber(100000)
			assert(Resets.rebirth(data, 0))
			expect(Deep.equal(data.pets, pets)).to.equal(true)
			data.progression.rebirths = 5
			data.progression.prestigeCoins = BigNum.fromNumber(1e7)
			assert(Resets.prestige(data, 1))
			expect(Deep.equal(data.pets, pets)).to.equal(true)
		end)

		it("sauvegarde et rechargement identiques ; résumé publié pour le rendu", function()
			local data = owner()
			expect((DataSchema.validate(data))).to.equal(true)
			local loaded = assert(DataSchema.load(Deep.copy(data), NOW))
			expect(Deep.equal(loaded.pets, data.pets)).to.equal(true)
			expect(#loaded.meta.quarantine).to.equal(0)
			expect(Pets.equippedSummary(loaded)).to.equal("moon_moth:4")
			local parsed = Pets.parseSummary("moon_moth:4;ghost:2;crystal_fox:1;x")
			expect(#parsed).to.equal(2)
			expect(parsed[1].level).to.equal(4)
		end)

		it("migration v3 -> v4 : anciens exemplaires convertis, équipés reportés, rien n'est supprimé", function()
			local v3 = DataSchema.template(0)
			v3.version = 3
			v3.meta.createdAt = 42
			v3.pets =
				{ owned = { crystal_fox = 2, moon_moth = 1, broken = -1 }, equipped = { "moon_moth", "nope" } } :: any
			local data, err = DataSchema.load(Deep.copy(v3), NOW)
			expect(err).to.equal(nil)
			assert(data, "chargement refusé")
			expect(data.version).to.equal(DataSchema.VERSION)
			expect(Pets.count(data)).to.equal(3)
			expect(data.pets.nextSerial).to.equal(4)
			expect(data.pets.hatched).to.equal(0)
			expect(#data.pets.equipped).to.equal(1)
			local equipped = assert(Pets.instance(data, data.pets.equipped[1]))
			expect(equipped.petId).to.equal("moon_moth")
			expect(equipped.obtainedAt).to.equal(42)
			expect(data.pets.owned.crystal_fox).to.equal(2) -- ancien champ conservé tel quel
			expect(data.pets.owned.broken).to.equal(-1)
			expect(Deep.equal((data.pets :: any).legacyEquipped, { "moon_moth", "nope" })).to.equal(true)
		end)

		it(
			"données malformées : quarantaine, sommeil, niveau plafonné, compteur et équipement corrigés",
			function()
				local raw = DataSchema.template(0)
				raw.pets.instances = {
					p1 = { petId = "moon_moth", level = 3, xp = 2, obtainedAt = 5 },
					p2 = { petId = "crystal_fox", level = 99, xp = 7, obtainedAt = 5 },
					p3 = { petId = "retired_pet", level = 2, xp = 0, obtainedAt = 5 },
					p4 = { petId = "moon_moth", level = 0, xp = 0, obtainedAt = 5 },
					bad = { petId = "moon_moth", level = 1, xp = 0, obtainedAt = 5 },
				} :: any
				raw.pets.nextSerial = 2
				raw.pets.equipped = { "p1", "p1", "p3", "p404" }
				raw.pets.freeEggs = { mission = 2.5, meadow = 500 } :: any
				local data = assert(DataSchema.load(raw, NOW))
				local paths = {}
				for _, item in data.meta.quarantine do
					paths[item.path] = true
				end
				for _, path in
					{
						"pets.instances.p4",
						"pets.instances.bad",
						"pets.instances.p2.level",
						"pets.freeEggs.mission",
						"pets.freeEggs.meadow",
						"pets.equipped",
					}
				do
					expect(paths[path]).to.equal(true)
				end
				expect(data.pets.instances.p2.level).to.equal(PetConfig.Level.Max)
				expect(data.pets.instances.p3.petId).to.equal("retired_pet") -- en sommeil, conservé
				expect(data.pets.nextSerial).to.equal(5) -- au-dessus de p4, même mis en quarantaine (jamais réutilisé)
				expect(Deep.equal(data.pets.equipped, { "p1" })).to.equal(true)
				expect(data.pets.freeEggs.meadow).to.equal(PetConfig.MaxFreeEggs)
			end
		)
	end)
end
