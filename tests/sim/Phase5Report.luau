-- Rapport d'équilibrage de la Phase 5 : `tools/bin/lune.exe run tests/run.luau report phase5`.
-- Même méthode que Report.luau : temps de jeu simulé, MOYENNE de 8 parties (graines 1 à 8), règles pures du jeu.
return function()
	local Shared = game:GetService("ReplicatedStorage").Shared
	local EconomySim = require(game:GetService("TestService").Sim.EconomySim)
	local ExpansionConfig = require(Shared.Config.ExpansionConfig)
	local PlantConfig = require(Shared.Config.PlantConfig)
	local ProgressionMath = require(Shared.Util.ProgressionMath)

	local SEEDS = { 1, 2, 3, 4, 5, 6, 7, 8 }
	local profiles = EconomySim.Profiles

	local function mean(values: { number }): number?
		if #values == 0 then
			return nil
		end
		local sum = 0
		for _, value in values do
			sum += value
		end
		return sum / #values
	end

	local function minutes(seconds: number?): string
		if not seconds then
			return "—"
		end
		if seconds >= 3600 then
			return string.format("%d h %02d", seconds // 3600, (seconds % 3600) // 60)
		end
		return string.format("%.1f min", seconds / 60)
	end

	local function averaged(measure: (number) -> number?): (number?, { number })
		local values = {}
		for _, seed in SEEDS do
			local value = measure(seed)
			if value then
				table.insert(values, value)
			end
		end
		return mean(values), values
	end

	local function eligible(sim)
		return ProgressionMath.canRebirth(sim.data)
	end

	print(string.format("# Rapport d'équilibrage Phase 5 (moyenne de %d parties)\n", #SEEDS))

	-- H1. Revenu en régime établi selon le nombre de cases.
	print("## H1. Coins gagnés par minute selon les parcelles possédées (10 min, sans amélioration)\n")
	print("| Graine | Actif 9 cases | Actif 18 | Actif 36 | 3 drones 9 cases | 3 drones 18 | 3 drones 36 |")
	print("|---|---|---|---|---|---|---|")
	local dronesOnly = { name = "drones", manual = false, sellTrip = 8, sellEvery = 120, targetDrones = 3 }
	local layouts = { {}, { "west" }, { "west", "east", "terrace" } }
	for _, plant in PlantConfig.List do
		local cells = {}
		for _, profile in { profiles.active, dronesOnly } do
			for _, plots in layouts do
				local drones = if profile == dronesOnly then 3 else 0
				local rate = averaged(function(seed)
					return EconomySim.steadyIncome(profile, plant.id, drones, 600, seed, plots)
				end)
				table.insert(cells, string.format("%.0f", rate or 0))
			end
		end
		print(string.format("| %s | %s |", plant.name, table.concat(cells, " | ")))
	end

	-- H2. Premier rebirth, avec et sans extensions.
	print("\n## H2. Premier rebirth depuis une partie neuve : sans / avec extensions\n")
	print("| Profil | Sans extension | Avec extensions | Extensions achetées (moyenne) | Part des drones (avec) |")
	print("|---|---|---|---|---|")
	for _, key in { "active", "hybrid", "automated" } do
		local without = averaged(function(seed)
			local sim = EconomySim.new(EconomySim.variant(profiles[key], { expansions = false }), seed)
			return EconomySim.runUntil(sim, eligible, 4 * 3600)
		end)
		local bought, shares = {}, {}
		local with = averaged(function(seed)
			local sim = EconomySim.new(profiles[key], seed)
			local t = EconomySim.runUntil(sim, eligible, 4 * 3600)
			table.insert(bought, #EconomySim.eventTimes(sim, "expansion"))
			local total = sim.coinsBySource.player + sim.coinsBySource.drone
			table.insert(shares, 100 * sim.coinsBySource.drone / math.max(total, 1))
			return t
		end)
		print(
			string.format(
				"| %s | %s | %s | %.1f | %.0f %% |",
				profiles[key].name,
				minutes(without),
				minutes(with),
				mean(bought) or 0,
				mean(shares) or 0
			)
		)
	end

	-- H3. Profil avancé jusqu'au premier prestige, avec et sans extensions.
	print("\n## H3. Profil 4 (avancé) : premier prestige, sans / avec extensions\n")
	local function prestigeRun(profile, seed: number)
		local sim = EconomySim.new(profile, seed)
		local at = EconomySim.runUntil(sim, function(s)
			return s.data.progression.prestiges >= 1
		end, 24 * 3600)
		return at, sim
	end
	local withoutTimes, withTimes = {}, {}
	local purchaseTimes: { [string]: { number } } = {}
	local cycleDurations: { { number } } = {}
	for _, seed in SEEDS do
		local t0 =
			prestigeRun(EconomySim.variant(profiles.advanced, { expansions = false, coinUpgrades = false }), seed)
		if t0 then
			table.insert(withoutTimes, t0)
		end
		local t1, sim = prestigeRun(EconomySim.variant(profiles.advanced, { coinUpgrades = false }), seed)
		if t1 then
			table.insert(withTimes, t1)
		end
		for _, event in sim.events do
			if event.kind == "expansion" then
				purchaseTimes[event.detail] = purchaseTimes[event.detail] or {}
				table.insert(purchaseTimes[event.detail], event.time)
			end
		end
		local previous = 0
		for index, time in EconomySim.eventTimes(sim, "rebirth") do
			cycleDurations[index] = cycleDurations[index] or {}
			table.insert(cycleDurations[index], time - previous)
			previous = time
		end
	end
	print(
		string.format(
			"Premier prestige : sans extension %s (%d/%d parties), avec extensions %s (%d/%d parties).\n",
			minutes(mean(withoutTimes)),
			#withoutTimes,
			#SEEDS,
			minutes(mean(withTimes)),
			#withTimes,
			#SEEDS
		)
	)
	print("| Extension | Prix | Achetée à (moyenne, avant le 1ᵉʳ prestige) | Parties |")
	print("|---|---|---|---|")
	for _, def in ExpansionConfig.List do
		local times = purchaseTimes[def.plotId] or {}
		print(string.format("| %s | %d | %s | %d/%d |", def.name, def.price, minutes(mean(times)), #times, #SEEDS))
	end
	print("\n| Cycle (avec extensions) | Durée moyenne |")
	print("|---|---|")
	for index, durations in cycleDurations do
		print(string.format("| Rebirth %d | %s |", index, minutes(mean(durations))))
	end

	-- I. Améliorations normales (arbre Coins).
	print("\n## I1. Premier rebirth : sans / avec améliorations normales (achat si coût ≤ 20 % du solde)\n")
	print("| Profil | Sans | Avec | Niveaux achetés (moyenne) |")
	print("|---|---|---|---|")
	for _, key in { "active", "hybrid", "automated" } do
		local without = averaged(function(seed)
			local sim = EconomySim.new(profiles[key], seed)
			return EconomySim.runUntil(sim, eligible, 4 * 3600)
		end)
		local bought = {}
		local with = averaged(function(seed)
			local sim = EconomySim.new(EconomySim.variant(profiles[key], { coinUpgrades = true }), seed)
			local t = EconomySim.runUntil(sim, eligible, 4 * 3600)
			table.insert(bought, #EconomySim.eventTimes(sim, "coinUpgrade"))
			return t
		end)
		print(
			string.format(
				"| %s | %s | %s | %.1f |",
				profiles[key].name,
				minutes(without),
				minutes(with),
				mean(bought) or 0
			)
		)
	end

	print("\n## I2. Profil 4 (avancé, extensions comprises) : premier prestige sans / avec améliorations normales\n")
	local plain, upgraded, levels = {}, {}, {}
	for _, seed in SEEDS do
		local t0 = prestigeRun(EconomySim.variant(profiles.advanced, { coinUpgrades = false }), seed)
		if t0 then
			table.insert(plain, t0)
		end
		local t1, sim = prestigeRun(profiles.advanced, seed)
		if t1 then
			table.insert(upgraded, t1)
		end
		table.insert(levels, #EconomySim.eventTimes(sim, "coinUpgrade"))
	end
	print(
		string.format(
			"Premier prestige : sans %s (%d/%d), avec %s (%d/%d) ; niveaux achetés avant le prestige : %.1f.",
			minutes(mean(plain)),
			#plain,
			#SEEDS,
			minutes(mean(upgraded)),
			#upgraded,
			#SEEDS,
			mean(levels) or 0
		)
	)

	print("\n## I3. Rentabilité : revenu sur 20 min après le rebirth n° 1 avec un niveau donné (moyennes)\n")
	print("| Amélioration | Niveau | Coût total | Actif | Hybride | Automatisé |")
	print("|---|---|---|---|---|---|")
	local Upgrades = require(Shared.Util.Upgrades)
	local DataSchema = require(Shared.Util.DataSchema)
	local Economy = require(Shared.Util.Economy)
	local BigNum = require(Shared.Util.BigNum)
	local WINDOW = 1200
	local function windowRate(profile, upgradeId: string?, level: number, seed: number): number
		local data = DataSchema.template(0)
		data.progression.rebirths = 1
		if upgradeId then
			data.upgrades.normal[upgradeId] = level
		end
		local sim = EconomySim.new(profile, seed, data)
		while sim.now < WINDOW do
			EconomySim.step(sim)
		end
		local bag = Economy.sellValue(sim.data.bag.items, ProgressionMath.incomeMultiplier(sim.data))
		return (BigNum.toNumber(sim.data.stats.coinsEarned) + BigNum.toNumber(bag)) / (WINDOW / 60)
	end
	local references = {}
	for _, key in { "active", "hybrid", "automated" } do
		references[key] = assert(averaged(function(seed)
			return windowRate(profiles[key], nil, 0, seed)
		end))
	end
	print(
		string.format(
			"| (aucune) | — | — | %.0f /min | %.0f /min | %.0f /min |",
			references.active,
			references.hybrid,
			references.automated
		)
	)
	for _, def in Upgrades.list("coins") do
		for _, level in { 1, 5 } do
			local gains = {}
			for _, key in { "active", "hybrid", "automated" } do
				local rate = assert(averaged(function(seed)
					return windowRate(profiles[key], def.id, level, seed)
				end))
				gains[key] = 100 * (rate / references[key] - 1)
			end
			local cost = 0
			for step = 0, level - 1 do
				cost += BigNum.toNumber(Upgrades.cost(def, step))
			end
			print(
				string.format(
					"| %s | %d | %d | %+.1f %% | %+.1f %% | %+.1f %% |",
					def.name,
					level,
					cost,
					gains.active,
					gains.hybrid,
					gains.automated
				)
			)
		end
	end
end
