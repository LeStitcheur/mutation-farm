-- Simulateur économique (Phase 3, jalon C) : invariants de rythme mesurés sur des parties simulées courtes
-- (tests/sim/EconomySim.luau, règles pures du jeu). Rapport complet : `lune run tests/run.luau report`.
return function()
	local Shared = game:GetService("ReplicatedStorage").Shared
	local EconomySim = require(game:GetService("TestService").Sim.EconomySim)
	local BigNum = require(Shared.Util.BigNum)
	local DataSchema = require(Shared.Util.DataSchema)
	local Economy = require(Shared.Util.Economy)
	local ProgressionMath = require(Shared.Util.ProgressionMath)
	local Upgrades = require(Shared.Util.Upgrades)

	local profiles = EconomySim.Profiles
	local MINUTE = 60

	local function eligible(sim)
		return ProgressionMath.canRebirth(sim.data)
	end

	local function firstRebirth(profile, seed: number, data)
		local sim = EconomySim.new(profile, seed, data)
		return EconomySim.runUntil(sim, eligible, 3 * 3600), sim
	end

	-- Revenu par minute (Coins gagnés + valeur du sac) sur une fenêtre fixe après le rebirth n° 1.
	local function windowRate(profile, upgradeId: string?, seed: number, window: number): number
		local data = DataSchema.template(0)
		data.progression.rebirths = 1
		if upgradeId then
			data.upgrades.rebirth[upgradeId] = 1
		end
		local sim = EconomySim.new(profile, seed, data)
		while sim.now < window do
			EconomySim.step(sim)
		end
		local bag = Economy.sellValue(sim.data.bag.items, ProgressionMath.incomeMultiplier(sim.data))
		return (BigNum.toNumber(sim.data.stats.coinsEarned) + BigNum.toNumber(bag)) / (window / MINUTE)
	end

	describe("déterminisme", function()
		it("même graine = même partie (instants, Coins, événements)", function()
			local t1, sim1 = firstRebirth(profiles.hybrid, 3)
			local t2, sim2 = firstRebirth(profiles.hybrid, 3)
			expect(t1).to.equal(t2)
			expect(BigNum.eq(sim1.data.stats.coinsEarned, sim2.data.stats.coinsEarned)).to.equal(true)
			expect(#sim1.events).to.equal(#sim2.events)
		end)
	end)

	describe("rythme de progression", function()
		it("premier rebirth ni instantané ni interminable, pour chaque profil", function()
			local bounds = {
				active = { 8, 25 },
				hybrid = { 10, 30 },
				automated = { 15, 45 },
			}
			for key, range in bounds do
				for _, seed in { 1, 2 } do
					local t = firstRebirth(profiles[key], seed)
					expect(t ~= nil).to.equal(true)
					expect(t >= range[1] * MINUTE and t <= range[2] * MINUTE).to.equal(true)
				end
			end
		end)

		it("le profil automatisé tire l'essentiel de ses revenus des drones (délai de grâce respecté)", function()
			local _, sim = firstRebirth(profiles.automated, 1)
			local total = sim.coinsBySource.player + sim.coinsBySource.drone
			expect(sim.coinsBySource.drone / total > 0.8).to.equal(true)
			local _, hybrid = firstRebirth(profiles.hybrid, 1)
			-- Joueur attentif (réaction 3 s < délai de grâce 5 s) : le drone ne lui prend presque rien.
			local hybridTotal = hybrid.coinsBySource.player + hybrid.coinsBySource.drone
			expect(hybrid.coinsBySource.drone / hybridTotal < 0.1).to.equal(true)
		end)
	end)

	describe("extensions de ferme (Phase 5)", function()
		-- Doubler les cases n'aide que si les récolteurs ne sont pas déjà saturés : à partir de la Citrouille (35 s),
		-- 9 cases ne suffisent plus à occuper un joueur actif ni 3 drones (docs/ECONOMY.md §12, H1).
		it("une extension augmente nettement le revenu dès que les récolteurs ne sont plus saturés", function()
			local dronesOnly = { name = "drones", manual = false, sellTrip = 8, sellEvery = 120, targetDrones = 3 }
			for _, case in { { profiles.active, 0 }, { dronesOnly, 3 } } do
				local profile, drones = case[1], case[2]
				for _, plantId in { "pumpkin", "moonshroom" } do
					local base, extended = 0, 0
					for _, seed in { 1, 2 } do
						base += EconomySim.steadyIncome(profile, plantId, drones, 600, seed)
						extended += EconomySim.steadyIncome(profile, plantId, drones, 600, seed, { "west" })
					end
					expect(extended > base * 1.3).to.equal(true)
				end
			end
		end)
	end)

	describe("prestige", function()
		it("premier prestige en 1 h 30 – 5 h ; le cycle suivant est plus rapide, sans être instantané", function()
			local sim = EconomySim.new(profiles.advanced, 1)
			local prestigeAt = EconomySim.runUntil(sim, function(s)
				return s.data.progression.prestiges >= 1
			end, 8 * 3600)
			expect(prestigeAt ~= nil).to.equal(true)
			expect(prestigeAt >= 90 * MINUTE and prestigeAt <= 300 * MINUTE).to.equal(true)
			local firstCycle = EconomySim.eventTimes(sim, "rebirth")[1]
			local start = sim.now
			-- Le profil avancé fait son rebirth DANS le pas où il devient éligible : on détecte le rebirth effectué
			-- (rebirths repartis de 0 au prestige), pas l'éligibilité, qui peut ne jamais être visible entre deux pas.
			local after = EconomySim.runUntil(sim, function(s)
				return s.data.progression.rebirths >= 1
			end, start + 3600)
			expect(after ~= nil).to.equal(true)
			local duration = after - start
			expect(duration < firstCycle).to.equal(true)
			expect(duration >= 3 * MINUTE).to.equal(true) -- invariant 12 mesuré en jeu simulé
		end)
	end)

	describe("améliorations", function()
		-- +10 % de valeur donne ≈ +10 % de revenu (davantage avec l'effet boule de neige des graines) ; les troncatures
		-- de chaque vente et bonus retirent quelques centièmes : seuil à +8 %.
		it("aucune amélioration Essence ne réduit le revenu ; Valeur de vente l'augmente d'au moins 8 %", function()
			local window = 20 * MINUTE
			local failures = {}
			for _, key in { "active", "automated" } do
				for _, seed in { 1, 2 } do
					local reference = windowRate(profiles[key], nil, seed, window)
					for _, def in Upgrades.list("essence") do
						local rate = windowRate(profiles[key], def.id, seed, window)
						local floor = if def.id == "essence_value" then 1.08 else 0.99
						if rate < reference * floor then
							table.insert(
								failures,
								string.format(
									"%s / %s / graine %d : %+.1f %%",
									key,
									def.id,
									seed,
									100 * (rate / reference - 1)
								)
							)
						end
					end
				end
			end
			if #failures > 0 then
				print("    " .. table.concat(failures, "\n    "))
			end
			expect(#failures).to.equal(0)
		end)

		it("Efficacité des drones agit dès le premier niveau (intervalle non arrondi au pas de la boucle)", function()
			local window = 20 * MINUTE
			local reference = windowRate(profiles.automated, nil, 1, window)
			local upgraded = windowRate(profiles.automated, "essence_drones", 1, window)
			expect(upgraded > reference).to.equal(true)
		end)
	end)
end
