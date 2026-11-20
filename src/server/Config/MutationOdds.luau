--!strict
-- Poids de tirage des mutations (sur 1 000 000). SECRET : vit dans ServerScriptService, jamais répliqué.
-- Modifier ici = modifier les probabilités en jeu. Invariants testés : tests/specs/MutationRoll.spec.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Deep = require(ReplicatedStorage.Shared.Util.Deep)

local weights: { Types.MutationWeight } = {
	{ id = "normal", weight = 927093 },
	{ id = "shiny", weight = 50000 }, -- Brillante ×2 : 5 %
	{ id = "giant", weight = 16667 }, -- Géante ×4 : 1,667 %
	{ id = "crystal", weight = 5000 }, -- Cristallisée ×8 : 0,5 %
	{ id = "radioactive", weight = 1000 }, -- Radioactive ×20 : 0,1 %
	{ id = "astral", weight = 200 }, -- Astrale ×50 : 0,02 %
	{ id = "divine", weight = 40 }, -- Divine ×150 : 0,004 %
}

local MutationOdds = {
	Weights = weights,
	-- Facteurs de chance appliqués aux poids non normaux (Phase 2).
	Luck = {
		Base = 1,
		MutagenicRain = 3,
	},
}

return Deep.freeze(MutationOdds)
