-- Invariants économiques et de configuration (docs/ECONOMY.md §5).
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local PlantConfig = require(Shared.Config.PlantConfig)
	local GameConfig = require(Shared.Config.GameConfig)
	local Economy = require(Shared.Util.Economy)

	local plants = PlantConfig.List
	local MAIN_TILES = 9

	describe("plantes", function()
		it("sept plantes initiales aux identifiants uniques", function()
			expect(#plants).to.equal(7)
			local seen = {}
			for index, plant in plants do
				expect(seen[plant.id]).to.equal(nil)
				seen[plant.id] = true
				expect(plant.order).to.equal(index)
				expect(PlantConfig.get(plant.id)).to.equal(plant)
			end
		end)

		it("la première plante est la graine de départ, gratuite", function()
			expect(plants[1].id).to.equal(GameConfig.StarterSeed)
			expect(plants[1].unlockPrice).to.equal(0)
			expect(PlantConfig.previous(plants[1].id)).to.equal(nil)
			expect(PlantConfig.previous(plants[2].id)).to.equal(plants[1])
		end)

		it("valeurs bien formées", function()
			for _, plant in plants do
				expect(plant.growTime > 0).to.equal(true)
				expect(plant.baseValue > 0 and plant.baseValue % 1 == 0).to.equal(true)
				expect(plant.unlockPrice % 1 == 0).to.equal(true)
				expect(string.match(plant.color, "^#%x%x%x%x%x%x$")).to.be.ok()
				expect(#plant.name > 0).to.equal(true)
			end
		end)

		it("prix de déblocage strictement croissants (invariant 2)", function()
			for index = 2, #plants do
				expect(plants[index].unlockPrice > plants[index - 1].unlockPrice).to.equal(true)
			end
		end)

		it("chaque graine augmente le revenu par case et par seconde (invariant 1)", function()
			for index = 2, #plants do
				local current = Economy.incomePerTileSecond(plants[index])
				local previous = Economy.incomePerTileSecond(plants[index - 1])
				expect(current > previous).to.equal(true)
			end
		end)

		it("temps de déblocage croissant et compris entre 30 s et 6 h (invariant 3)", function()
			local previousTime = 0
			for index = 2, #plants do
				local income = Economy.incomePerTileSecond(plants[index - 1]) * MAIN_TILES
				local seconds = plants[index].unlockPrice / income
				expect(seconds >= 30 and seconds <= 6 * 3600).to.equal(true)
				expect(seconds > previousTime).to.equal(true)
				previousTime = seconds
			end
		end)
	end)

	describe("réglages", function()
		it("fenêtres et bonus de précision cohérents", function()
			local harvest = GameConfig.Harvest
			expect(harvest.PerfectWindow > 0).to.equal(true)
			expect(harvest.PerfectWindow < harvest.GoodWindow).to.equal(true)
			expect(harvest.PerfectBonus <= 0.5).to.equal(true)
			expect(harvest.GoodBonus < harvest.PerfectBonus).to.equal(true)
			expect(harvest.PromptDistance < harvest.MaxDistance).to.equal(true)
		end)

		it("production hors ligne plafonnée à 2 h (invariant 8)", function()
			expect(GameConfig.Offline.MaxSeconds).to.equal(7200)
		end)

		it("verrou de session cohérent avec l'autosave", function()
			local data = GameConfig.Data
			expect(data.LockTimeout >= data.AutosaveInterval * 2).to.equal(true)
			expect(data.LoadMaxWait > data.LockTimeout).to.equal(true)
		end)

		it("la configuration est gelée", function()
			expect(function()
				(GameConfig :: any).StarterSeed = "triche"
			end).to.throw()
			expect(function()
				(plants[1] :: any).baseValue = 1e9
			end).to.throw()
		end)
	end)
end
