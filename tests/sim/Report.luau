-- Rapport du simulateur économique (Phase 3, jalon C) : `tools/bin/lune.exe run tests/run.luau report`.
-- Durées en temps de jeu simulé. Chaque mesure est la MOYENNE de 8 parties (graines 1 à 8) : une partie seule est
-- trop sensible aux mutations rares (Divine ×150) et à l'instant des déblocages de graines.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local Shared = ReplicatedStorage.Shared
	local EconomySim = require(game:GetService("TestService").Sim.EconomySim)
	local PlantConfig = require(Shared.Config.PlantConfig)
	local MutationConfig = require(Shared.Config.MutationConfig)
	local UpgradeConfig = require(Shared.Config.UpgradeConfig)
	local GameConfig = require(Shared.Config.GameConfig)
	local BigNum = require(Shared.Util.BigNum)
	local DataSchema = require(Shared.Util.DataSchema)
	local Economy = require(Shared.Util.Economy)
	local MutationRoll = require(Shared.Util.MutationRoll)
	local ProgressionMath = require(Shared.Util.ProgressionMath)
	local Upgrades = require(Shared.Util.Upgrades)
	local MutationOdds = require(ServerScriptService.Server.Config.MutationOdds)

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

	local function span(values: { number }): (number, number)
		local low, high = math.huge, -math.huge
		for _, value in values do
			low = math.min(low, value)
			high = math.max(high, value)
		end
		return low, high
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

	local function eligible(sim)
		return ProgressionMath.canRebirth(sim.data)
	end

	-- Moyenne d'une mesure sur toutes les graines (les mesures nil sont ignorées).
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

	print(
		string.format(
			"# Rapport du simulateur économique (moyenne de %d parties, pas de %s s)\n",
			#SEEDS,
			EconomySim.DT
		)
	)

	-- A. Coins par minute selon la graine (régime établi, 10 min, aucune amélioration).
	print("## A. Coins gagnés par minute selon la graine (10 min, 9 cases, sans amélioration)\n")
	print("| Graine | Actif sans drone | Hybride + 1 drone | Drones seuls (3, vente toutes les 2 min) |")
	print("|---|---|---|---|")
	local dronesOnly = { name = "drones", manual = false, sellTrip = 8, sellEvery = 120, targetDrones = 3 }
	local plantId = GameConfig.StarterSeed
	while plantId do
		local plant = assert(PlantConfig.get(plantId))
		local id = plantId
		local active = averaged(function(seed)
			return EconomySim.steadyIncome(profiles.active, id, 0, 600, seed)
		end)
		local hybrid = averaged(function(seed)
			return EconomySim.steadyIncome(profiles.hybrid, id, 1, 600, seed)
		end)
		local drones = averaged(function(seed)
			return EconomySim.steadyIncome(dronesOnly, id, 3, 600, seed)
		end)
		print(string.format("| %s | %.0f | %.0f | %.0f |", plant.name, active, hybrid, drones))
		local nextPlant = PlantConfig.nextAfter(plantId)
		plantId = if nextPlant then nextPlant.id else nil
	end

	-- B. Profils 1 à 3 : premier rebirth depuis une partie neuve.
	print("\n## B. Premier rebirth (100 000 Coins gagnés pendant le cycle) depuis une partie neuve\n")
	print("| Profil | Premier rebirth (moyenne) | Écart (min – max) | Coins gagnés / min | Part des drones |")
	print("|---|---|---|---|---|")
	for _, key in { "active", "hybrid", "automated" } do
		local profile = profiles[key]
		local rates, shares = {}, {}
		local avg, times = averaged(function(seed)
			local sim = EconomySim.new(profile, seed)
			local t = EconomySim.runUntil(sim, eligible, 4 * 3600)
			local total = sim.coinsBySource.player + sim.coinsBySource.drone
			table.insert(rates, BigNum.toNumber(sim.data.stats.coinsEarned) / (sim.now / 60))
			table.insert(shares, 100 * sim.coinsBySource.drone / math.max(total, 1))
			return t
		end)
		local low, high = span(times)
		print(
			string.format(
				"| %s | %s | %s – %s | %.0f | %.0f %% |",
				profile.name,
				minutes(avg),
				minutes(low),
				minutes(high),
				mean(rates) or 0,
				mean(shares) or 0
			)
		)
	end

	-- C/D. Profil 4 (avancé) jusqu'au premier prestige, puis profil 5 (après prestige).
	local rebirthTimes: { { number } } = {}
	local rebirthEssence: { { number } } = {}
	local prestigeTimes, coresGained, levelsBought = {}, {}, {}
	local afterFirst, afterFifth = {}, {}
	local sample = nil
	for _, seed in SEEDS do
		local sim = EconomySim.new(profiles.advanced, seed)
		local prestigeAt = EconomySim.runUntil(sim, function(s)
			return s.data.progression.prestiges >= 1
		end, 24 * 3600)
		local index = 0
		local bought = 0
		for _, event in sim.events do
			if event.kind == "rebirth" then
				index += 1
				rebirthTimes[index] = rebirthTimes[index] or {}
				rebirthEssence[index] = rebirthEssence[index] or {}
				table.insert(rebirthTimes[index], event.time)
				table.insert(rebirthEssence[index], event.detail)
			elseif event.kind == "upgrade" then
				bought += 1
			elseif event.kind == "prestige" then
				table.insert(coresGained, event.detail)
			end
		end
		table.insert(levelsBought, bought)
		if prestigeAt then
			table.insert(prestigeTimes, prestigeAt)
			local start = sim.now
			local first = EconomySim.runUntil(sim, function(s)
				return s.data.progression.rebirths >= 1
			end, start + 6 * 3600)
			if first then
				table.insert(afterFirst, first - start)
			end
			local fifth = EconomySim.runUntil(sim, function(s)
				return s.data.progression.rebirths >= 5 or s.data.progression.prestiges >= 2
			end, start + 24 * 3600)
			if fifth then
				table.insert(afterFifth, fifth - start)
			end
		end
		sample = sample or sim
	end

	print("\n## C. Profil 4 — avancé : rebirths jusqu'au premier prestige (moyennes)\n")
	print("| Rebirth n° | Atteint à | Durée du cycle | Essence gagnée |")
	print("|---|---|---|---|")
	local previous = 0
	for index, times in rebirthTimes do
		local reached = assert(mean(times))
		print(
			string.format(
				"| %d | %s | %s | %.0f |",
				index,
				minutes(reached),
				minutes(reached - previous),
				mean(rebirthEssence[index]) or 0
			)
		)
		previous = reached
	end
	local low, high = span(prestigeTimes)
	print(
		string.format(
			"\nPremier prestige : %s en moyenne (%s – %s), %d/%d parties ; Primal Cores : %.1f ; niveaux d'améliorations achetés : %.1f.",
			minutes(mean(prestigeTimes)),
			minutes(low),
			minutes(high),
			#prestigeTimes,
			#SEEDS,
			mean(coresGained) or 0,
			mean(levelsBought) or 0
		)
	)

	print("\n## D. Profil 5 — après le premier prestige (Primal Cores dépensés)\n")
	local levels = {}
	for _, def in UpgradeConfig.List do
		local level = Upgrades.level(sample.data, def.id)
		if level > 0 then
			table.insert(levels, def.name .. " " .. level)
		end
	end
	print(
		"Exemple (graine 1), améliorations en fin de simulation : "
			.. (if #levels > 0 then table.concat(levels, ", ") else "aucune")
			.. "."
	)
	print(
		string.format(
			"Premier rebirth après prestige : %s (contre %s au tout premier cycle) ; 5ᵉ rebirth après prestige : %s.",
			minutes(mean(afterFirst)),
			minutes(rebirthTimes[1] and mean(rebirthTimes[1])),
			minutes(mean(afterFifth))
		)
	)

	-- E. Effets cumulés des mutations (espérance du multiplicateur de vente selon la chance).
	print("\n## E. Espérance du multiplicateur de mutation selon la chance\n")
	print("| Chance | E(multiplicateur) | Gain vs chance de base |")
	print("|---|---|---|")
	local base = MutationRoll.expectedMultiplier(MutationOdds.Weights, MutationConfig.multipliers())
	for _, luck in { 1, 1.5, 2, 2.5 } do
		local weights = MutationRoll.applyLuck(MutationOdds.Weights, luck)
		local expectation = MutationRoll.expectedMultiplier(weights, MutationConfig.multipliers())
		print(string.format("| ×%.1f | %.3f | %+.1f %% |", luck, expectation, 100 * (expectation / base - 1)))
	end

	-- F. Rentabilité des améliorations Essence : revenu sur une fenêtre fixe de 30 min après le rebirth n° 1.
	-- (Le temps jusqu'au seuil est quantifié par les ventes ; le revenu par minute ne l'est pas. Les mutations sont
	-- tirées dans l'ordre des plantations : avec et sans amélioration partagent la même suite aléatoire.)
	print(
		"\n## F. Rentabilité : revenu sur 30 min après le rebirth n° 1 avec UN niveau d'amélioration (moyennes)\n"
	)
	print("| Amélioration | Niveau | Coût | Actif | Hybride | Automatisé | Hybride / 100 Essence |")
	print("|---|---|---|---|---|---|---|")
	local WINDOW = 1800
	local function windowRate(profile, upgradeId: string?, level: number, seed: number): number
		local data = DataSchema.template(0)
		data.progression.rebirths = 1
		if upgradeId then
			data.upgrades.rebirth[upgradeId] = level
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
			"| (aucune) | — | — | %.0f /min | %.0f /min | %.0f /min | — |",
			references.active,
			references.hybrid,
			references.automated
		)
	)
	for _, def in Upgrades.list("essence") do
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
					"| %s | %d | %d | %+.1f %% | %+.1f %% | %+.1f %% | %+.2f %% |",
					def.name,
					level,
					cost,
					gains.active,
					gains.hybrid,
					gains.automated,
					gains.hybrid * 100 / cost
				)
			)
		end
	end

	-- G. Impact des multiplicateurs permanents : premier rebirth d'un cycle.
	print("\n## G. Impact des multiplicateurs permanents : premier rebirth (profil actif, moyennes)\n")
	print("| Situation | Premier rebirth |")
	print("|---|---|")
	local function firstRebirth(prestiges: number, permanent: { [string]: number }): number?
		return (
			averaged(function(seed)
				local data = DataSchema.template(0)
				data.progression.prestiges = prestiges
				for id, level in permanent do
					data.upgrades.permanent[id] = level
				end
				local sim = EconomySim.new(profiles.active, seed, data)
				return EconomySim.runUntil(sim, eligible, 4 * 3600)
			end)
		)
	end
	print(string.format("| Partie neuve | %s |", minutes(firstRebirth(0, {}))))
	print(string.format("| Après 1 prestige (×1,58), sans amélioration | %s |", minutes(firstRebirth(1, {}))))
	print(
		string.format(
			"| Après 1 prestige + Génétique 2 (+10 %%) | %s |",
			minutes(firstRebirth(1, { superior_genetics = 2 }))
		)
	)
	print(
		string.format(
			"| Après 1 prestige + Héritage agricole 1 (Tomate gardée) | %s |",
			minutes(firstRebirth(1, { farming_legacy = 1 }))
		)
	)
	print(
		string.format(
			"| Après 3 prestiges (×3,22) + Génétique 5, Croissance 5, Héritage 2 | %s |",
			minutes(firstRebirth(3, { superior_genetics = 5, ancestral_growth = 5, farming_legacy = 2 }))
		)
	)
end
