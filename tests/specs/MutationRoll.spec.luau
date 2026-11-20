return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local MutationRoll = require(ReplicatedStorage.Shared.Util.MutationRoll)
	local MutationConfig = require(ReplicatedStorage.Shared.Config.MutationConfig)
	local MutationOdds = require(ServerScriptService.Server.Config.MutationOdds)

	local weights = MutationOdds.Weights

	describe("configuration serveur", function()
		it("est valide et totalise 1 000 000", function()
			local ok, reason = MutationRoll.validate(weights)
			expect(ok).to.equal(true)
			expect(reason).to.equal(nil)
			expect(MutationRoll.total(weights)).to.equal(1000000)
		end)

		it("couvre exactement les mutations définies", function()
			local ids = {}
			for _, entry in weights do
				ids[entry.id] = true
				expect(MutationConfig.get(entry.id)).to.be.ok()
			end
			for _, def in MutationConfig.List do
				expect(ids[def.id]).to.equal(true)
			end
		end)

		it("multiplicateurs exacts du game design (invariant 6)", function()
			local expected =
				{ normal = 1, shiny = 2, giant = 4, crystal = 8, radioactive = 20, astral = 50, divine = 150 }
			local count = 0
			for _, def in MutationConfig.List do
				expect(def.multiplier).to.equal(expected[def.id])
				count += 1
			end
			expect(count).to.equal(7)
		end)
	end)

	describe("tirage exclusif", function()
		it("choisit selon les bornes cumulées", function()
			expect(MutationRoll.pick(weights, 0)).to.equal("normal")
			expect(MutationRoll.pick(weights, 0.927)).to.equal("normal")
			expect(MutationRoll.pick(weights, 0.9271)).to.equal("shiny")
			expect(MutationRoll.pick(weights, 0.99999999)).to.equal("divine")
			expect(MutationRoll.pick(weights, 1)).to.equal("divine")
			expect(MutationRoll.pick(weights, -5)).to.equal("normal")
		end)

		it("respecte exactement les poids sur un balayage déterministe", function()
			local samples = 1000000
			local counts = {}
			for i = 0, samples - 1 do
				local id = MutationRoll.pick(weights, (i + 0.5) / samples)
				counts[id] = (counts[id] or 0) + 1
			end
			for _, entry in weights do
				expect(math.abs((counts[entry.id] or 0) - entry.weight) <= 1).to.equal(true)
			end
		end)

		it("ignore les poids nuls", function()
			local custom = { { id = "normal", weight = 1 }, { id = "shiny", weight = 0 } }
			expect(MutationRoll.pick(custom, 0.999)).to.equal("normal")
			expect(MutationRoll.pick(custom, 1)).to.equal("normal")
		end)
	end)

	describe("probabilités et espérance", function()
		it("les probabilités somment à 1", function()
			local sum = 0
			for _, probability in MutationRoll.probabilities(weights) do
				sum += probability
			end
			expect(sum).to.be.near(1, 1e-12)
		end)

		it("espérance du multiplicateur ≈ 1,170 (invariant 6)", function()
			local expected = MutationRoll.expectedMultiplier(weights, MutationConfig.multipliers())
			expect(expected).to.be.near(1.169761, 1e-6)
			expect(expected >= 1.1 and expected <= 1.3).to.equal(true)
		end)

		it("la chance multiplie les poids rares sans toucher au normal", function()
			local lucky = MutationRoll.applyLuck(weights, 3)
			for index, entry in lucky do
				local original = weights[index]
				if entry.id == "normal" then
					expect(entry.weight).to.equal(original.weight)
				else
					expect(entry.weight).to.equal(original.weight * 3)
				end
			end
			local expected = MutationRoll.expectedMultiplier(lucky, MutationConfig.multipliers())
			expect(expected).to.be.near((927093 + 3 * 242668) / (927093 + 3 * 72907), 1e-9)
		end)
	end)

	describe("validation", function()
		it("rejette les tables invalides", function()
			expect((MutationRoll.validate({}))).to.equal(false)
			expect((MutationRoll.validate({ { id = "shiny", weight = 1 } }))).to.equal(false)
			expect((MutationRoll.validate({ { id = "normal", weight = -1 } }))).to.equal(false)
			expect((MutationRoll.validate({ { id = "normal", weight = 1 }, { id = "normal", weight = 2 } }))).to.equal(
				false
			)
			expect((MutationRoll.validate({ { id = "normal", weight = 0 } }))).to.equal(false)
		end)
	end)
end
