-- Mutadex (Phase 4, jalon A) : catalogue dérivé, découvertes (joueur et drone), paliers accordés une seule fois,
-- conservation (rebirth, prestige, sauvegarde), migration v2 -> v3, données malformées, concurrence, recherche.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local Mutadex = require(Shared.Util.Mutadex)
	local MutadexConfig = require(Shared.Config.MutadexConfig)
	local MutationConfig = require(Shared.Config.MutationConfig)
	local PlantConfig = require(Shared.Config.PlantConfig)
	local GameConfig = require(Shared.Config.GameConfig)
	local Economy = require(Shared.Util.Economy)
	local HarvestRules = require(Shared.Util.HarvestRules)
	local Resets = require(Shared.Util.Resets)
	local DataSchema = require(Shared.Util.DataSchema)
	local BigNum = require(Shared.Util.BigNum)
	local Deep = require(Shared.Util.Deep)

	local NOW = 5000

	-- Découvre les `count` premières entrées du catalogue (ordre plante puis mutation).
	local function discoverFirst(data, count: number, now: number)
		for index = 1, count do
			local entry = Mutadex.catalog()[index]
			Mutadex.record(data, entry.plantId, entry.mutationId, now + index)
		end
	end

	local function ripeTile(data, tileId: string, plantId: string, mutation: string?)
		data.farm.tiles[tileId] = { plantId = plantId, plantedAt = 0, growTime = 6, mutation = mutation }
	end

	describe("catalogue", function()
		it("toutes les plantes × toutes les mutations, identifiants = clés d'objets du sac", function()
			expect(Mutadex.total()).to.equal(#PlantConfig.List * #MutationConfig.List)
			expect(Mutadex.total()).to.equal(49)
			local seen = {}
			for _, entry in Mutadex.catalog() do
				expect(seen[entry.id]).to.equal(nil)
				seen[entry.id] = true
				expect(entry.id).to.equal(Economy.itemKey(entry.plantId, entry.mutationId))
				expect(entry.multiplier).to.equal(assert(MutationConfig.get(entry.mutationId)).multiplier)
				expect(entry.rarity).to.equal(MutadexConfig.RarityByMutation[entry.mutationId])
			end
			local shiny = assert(Mutadex.get("carrot|shiny"))
			expect(shiny.name).to.equal("Carotte · Brillante")
			expect(shiny.rarity.name).to.equal("Peu commune")
			expect(assert(Mutadex.get("carrot|normal")).name).to.equal("Carotte")
			expect(assert(Mutadex.get("dragonfruit|divine")).rarity.order).to.equal(7)
		end)

		it("paliers : exigences ceil(49 × %) = 5, 13, 25, 37, 49", function()
			local expected = { 5, 13, 25, 37, 49 }
			for index, milestone in MutadexConfig.Milestones do
				expect(Mutadex.requirement(milestone)).to.equal(expected[index])
			end
		end)
	end)

	describe("découvertes", function()
		it("première découverte puis récoltes suivantes : date conservée, compteur incrémenté", function()
			local data = DataSchema.template(0)
			expect(Mutadex.record(data, "carrot", "shiny", 100)).to.equal(true)
			expect(Mutadex.record(data, "carrot", "shiny", 200)).to.equal(false)
			expect(Mutadex.record(data, "carrot", "shiny", 300)).to.equal(false)
			local entry = assert(Mutadex.entry(data, "carrot|shiny"))
			expect(entry.firstAt).to.equal(100)
			expect(entry.count).to.equal(3)
			expect(Mutadex.discoveredCount(data)).to.equal(1)
		end)

		it("combinaison hors catalogue ignorée", function()
			local data = DataSchema.template(0)
			expect(Mutadex.record(data, "banana", "shiny", 1)).to.equal(false)
			expect(Mutadex.record(data, "carrot", "golden", 1)).to.equal(false)
			expect(next(data.mutadex)).to.equal(nil)
		end)

		it("récolte manuelle et récolte de drone alimentent le Mutadex avec la mutation réelle", function()
			local data = DataSchema.template(0)
			ripeTile(data, "main:1", "carrot", "giant")
			ripeTile(data, "main:2", "carrot", "giant")
			local manual = HarvestRules.apply(data, "main:1", NOW, "player")
			expect(manual.discovered).to.equal(true)
			local drone = HarvestRules.apply(data, "main:2", NOW + 1, "drone")
			expect(drone.discovered).to.equal(false)
			local entry = assert(Mutadex.entry(data, "carrot|giant"))
			expect(entry.count).to.equal(2)
			expect(entry.firstAt).to.equal(NOW)
		end)

		it("concurrence : joueur et drone sur la même culture = une seule récolte comptée", function()
			local data = DataSchema.template(0)
			ripeTile(data, "main:1", "tomato", "shiny")
			local results = 0
			for _, source in { "player", "drone", "player", "drone" } do
				if HarvestRules.check(data, "main:1", NOW) then
					HarvestRules.apply(data, "main:1", NOW, source)
					results += 1
				end
			end
			expect(results).to.equal(1)
			expect(assert(Mutadex.entry(data, "tomato|shiny")).count).to.equal(1)
		end)
	end)

	describe("paliers", function()
		it("10 % : titre accordé une seule fois, au moment de la 5ᵉ découverte", function()
			local data = DataSchema.template(0)
			discoverFirst(data, 4, NOW)
			expect(#Mutadex.claimMilestones(data, NOW)).to.equal(0)
			discoverFirst(data, 5, NOW)
			local granted = Mutadex.claimMilestones(data, NOW + 10)
			expect(#granted).to.equal(1)
			expect(granted[1].id).to.equal("mutadex_10")
			expect(data.mutadexRewards.mutadex_10).to.equal(NOW + 10)
			expect(data.cosmetics.owned.title_curious_botanist).to.equal(true)
			for _ = 1, 20 do
				expect(#Mutadex.claimMilestones(data, NOW + 20)).to.equal(0) -- double attribution impossible
			end
			expect(data.mutadexRewards.mutadex_10).to.equal(NOW + 10)
		end)

		it("25 % et 75 % : places de sac permanentes (confort), jamais de multiplicateur de revenu", function()
			local data = DataSchema.template(0)
			local before = Economy.bagCapacity(data)
			discoverFirst(data, 13, NOW)
			Mutadex.claimMilestones(data, NOW)
			expect(Economy.bagCapacity(data)).to.equal(before + 5)
			discoverFirst(data, 37, NOW)
			Mutadex.claimMilestones(data, NOW)
			expect(Economy.bagCapacity(data)).to.equal(before + 15)
			expect(Mutadex.bagBonus(data)).to.equal(15)
			for _, milestone in MutadexConfig.Milestones do
				for _, reward in milestone.rewards do
					expect(reward.kind == "cosmetic" or reward.kind == "bag").to.equal(true)
				end
			end
		end)

		it("collection complète : tous les paliers et cosmétiques, plus de palier suivant", function()
			local data = DataSchema.template(0)
			discoverFirst(data, Mutadex.total(), NOW)
			local granted = Mutadex.claimMilestones(data, NOW)
			expect(#granted).to.equal(#MutadexConfig.Milestones)
			expect(Mutadex.progress(data).percent).to.equal(100)
			expect(Mutadex.nextMilestone(data)).to.equal(nil)
			expect(data.cosmetics.owned.aura_mutadex).to.equal(true)
		end)

		it("une découverte par récolte déclenche l'évaluation des paliers dans le même mutateur", function()
			local data = DataSchema.template(0)
			discoverFirst(data, 4, NOW)
			ripeTile(data, "main:1", "dragonfruit", "divine")
			local outcome = HarvestRules.apply(data, "main:1", NOW + 100, "drone")
			expect(outcome.discovered).to.equal(true)
			expect(#outcome.milestones).to.equal(1)
			expect(Mutadex.isClaimed(data, MutadexConfig.Milestones[1])).to.equal(true)
		end)
	end)

	describe("progression affichée", function()
		it("pourcentage, historique (plus récentes d'abord) et plus rares", function()
			local data = DataSchema.template(0)
			data.stats.harvests = 42
			Mutadex.record(data, "carrot", "normal", 10)
			Mutadex.record(data, "tomato", "crystal", 30)
			Mutadex.record(data, "corn", "shiny", 20)
			Mutadex.record(data, "carrot", "astral", 40)
			local progress = Mutadex.progress(data)
			expect(progress.discovered).to.equal(4)
			expect(progress.harvests).to.equal(42)
			expect(progress.percent).to.be.near(400 / 49, 1e-9)
			local history = Mutadex.history(data, 3)
			expect(#history).to.equal(3)
			expect(history[1].entry.id).to.equal("carrot|astral")
			expect(history[2].entry.id).to.equal("tomato|crystal")
			expect(history[3].entry.id).to.equal("corn|shiny")
			local rarest = Mutadex.rarest(data, 2)
			expect(rarest[1].id).to.equal("carrot|astral")
			expect(rarest[2].id).to.equal("tomato|crystal")
		end)

		it(
			"filtres et recherche : plante, rareté, nom sans accents ; les inconnues ne sont pas révélées",
			function()
				local data = DataSchema.template(0)
				Mutadex.record(data, "carrot", "giant", 1)
				local giant = assert(Mutadex.get("carrot|giant"))
				local hidden = assert(Mutadex.get("tomato|giant"))
				expect(Mutadex.matches(data, giant, "carrot", nil, nil)).to.equal(true)
				expect(Mutadex.matches(data, giant, "tomato", nil, nil)).to.equal(false)
				expect(Mutadex.matches(data, giant, nil, "rare", nil)).to.equal(true)
				expect(Mutadex.matches(data, giant, nil, "epic", nil)).to.equal(false)
				expect(Mutadex.matches(data, giant, nil, nil, "GEANTE")).to.equal(true)
				expect(Mutadex.matches(data, giant, nil, nil, "carotte · gé")).to.equal(true)
				expect(Mutadex.matches(data, hidden, nil, nil, "geante")).to.equal(false)
				expect(Mutadex.matches(data, hidden, nil, nil, "")).to.equal(true)
			end
		)
	end)

	describe("conservation", function()
		local function collector()
			local data = DataSchema.template(0)
			discoverFirst(data, 13, NOW)
			Mutadex.claimMilestones(data, NOW)
			return data
		end

		it("rebirth et prestige ne touchent ni au Mutadex, ni aux paliers, ni aux cosmétiques gagnés", function()
			local data = collector()
			local mutadex = Deep.copy(data.mutadex)
			local rewards = Deep.copy(data.mutadexRewards)
			data.progression.cycleCoins = BigNum.fromNumber(100000)
			assert(Resets.rebirth(data, 0))
			expect(Deep.equal(data.mutadex, mutadex)).to.equal(true)
			expect(Deep.equal(data.mutadexRewards, rewards)).to.equal(true)
			data.progression.rebirths = 5
			data.progression.prestigeCoins = BigNum.fromNumber(1e7)
			assert(Resets.prestige(data, 1))
			expect(Deep.equal(data.mutadex, mutadex)).to.equal(true)
			expect(Deep.equal(data.mutadexRewards, rewards)).to.equal(true)
			expect(data.cosmetics.owned.title_curious_botanist).to.equal(true)
			expect(Economy.bagCapacity(data)).to.equal(GameConfig.Bag.BaseCapacity + 5)
		end)

		it("sauvegarde et rechargement : entrées, compteurs et paliers identiques", function()
			local data = collector()
			Mutadex.record(data, "carrot", "normal", NOW + 999)
			expect((DataSchema.validate(data))).to.equal(true)
			local loaded = assert(DataSchema.load(Deep.copy(data), NOW + 2000))
			expect(Deep.equal(loaded.mutadex, data.mutadex)).to.equal(true)
			expect(Deep.equal(loaded.mutadexRewards, data.mutadexRewards)).to.equal(true)
			expect(#loaded.meta.quarantine).to.equal(0)
		end)
	end)

	describe("migration et données malformées", function()
		it("v2 -> v3 : anciens horodatages convertis, rien n'est supprimé, paliers ajoutés vides", function()
			local v2 = DataSchema.template(0)
			v2.version = 2
			v2.mutadex = { ["carrot|shiny"] = 1234 } :: any
			v2.mutadexRewards = nil :: any
			local data, err, notes = DataSchema.load(Deep.copy(v2), 100)
			expect(err).to.equal(nil)
			expect(data.version).to.equal(DataSchema.VERSION)
			local entry = assert(Mutadex.entry(data, "carrot|shiny"))
			expect(entry.firstAt).to.equal(1234)
			expect(entry.count).to.equal(1)
			expect(next(data.mutadexRewards)).to.equal(nil)
			expect(string.find(table.concat(notes, " "), "migration v2 -> v", 1, true)).to.be.ok()
		end)

		it("entrées et paliers malformés mis en quarantaine, jamais supprimés en silence", function()
			local raw = DataSchema.template(0)
			raw.mutadex = {
				["carrot|shiny"] = { firstAt = 10, count = 2 },
				["tomato|giant"] = { firstAt = 0 / 0, count = 1 },
				["corn|crystal"] = { firstAt = 5, count = -3 },
				["pumpkin|astral"] = "texte",
			} :: any
			raw.mutadexRewards = { mutadex_10 = 50, mutadex_25 = "hier" } :: any
			local data = assert(DataSchema.load(raw, 99))
			expect(Mutadex.discoveredCount(data)).to.equal(1)
			expect(data.mutadexRewards.mutadex_10).to.equal(50)
			expect(data.mutadexRewards.mutadex_25).to.equal(nil)
			local paths = {}
			for _, item in data.meta.quarantine do
				paths[item.path] = true
			end
			for _, path in
				{
					"mutadex.tomato|giant",
					"mutadex.corn|crystal",
					"mutadex.pumpkin|astral",
					"mutadexRewards.mutadex_25",
				}
			do
				expect(paths[path]).to.equal(true)
			end
			expect(#data.meta.quarantine).to.equal(4)
		end)

		it("contenu retiré de la configuration : entrées et paliers bien formés conservés en sommeil", function()
			-- Une plante ou un palier retiré (déploiement fautif, rééquilibrage) ne doit rien coûter au joueur :
			-- la quarantaine est bornée (FIFO), elle ne doit pas recevoir des découvertes valides.
			local raw = DataSchema.template(0)
			raw.mutadex = {
				["carrot|shiny"] = { firstAt = 10, count = 2 },
				["banana|shiny"] = { firstAt = 11, count = 3 },
			} :: any
			raw.mutadexRewards = { mutadex_10 = 50, mutadex_999 = 1 } :: any
			local data, _, notes = DataSchema.load(raw, 99)
			assert(data, "chargement refusé")
			expect(#data.meta.quarantine).to.equal(0)
			local banana = (data.mutadex :: any)["banana|shiny"]
			expect(banana.firstAt).to.equal(11)
			expect(banana.count).to.equal(3)
			expect(data.mutadexRewards.mutadex_999).to.equal(1)
			-- En sommeil : ni compté, ni affiché, ni accordé ; signalé dans les journaux du chargement.
			expect(Mutadex.discoveredCount(data)).to.equal(1)
			expect(#Mutadex.history(data, 10)).to.equal(1)
			expect(string.find(table.concat(notes, " "), "banana|shiny", 1, true)).to.be.ok()
			-- Toujours là après un nouveau cycle sauvegarde -> chargement.
			local reloaded = assert(DataSchema.load(Deep.copy(data), 100))
			expect((reloaded.mutadex :: any)["banana|shiny"].count).to.equal(3)
			expect(reloaded.mutadexRewards.mutadex_999).to.equal(1)
		end)

		it("Mutadex qui n'est pas une table : mis en quarantaine et remplacé par une collection vide", function()
			local raw = DataSchema.template(0)
			raw.mutadex = 12 :: any
			local data = assert(DataSchema.load(raw, 1))
			expect(type(data.mutadex)).to.equal("table")
			expect(data.meta.quarantine[1].path).to.equal("mutadex")
			expect(data.meta.quarantine[1].value).to.equal(12)
		end)
	end)
end
