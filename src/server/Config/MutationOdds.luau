--!strict
-- Poids de tirage des mutations (sur 1 000 000). SECRET : vit dans ServerScriptService, jamais répliqué.
-- Modifier ici = modifier les probabilités en jeu. Invariants testés : tests/specs/MutationRoll.spec.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Deep = require(ReplicatedStorage.Shared.Util.Deep)

-- Phase 2 (2026-11-20) : probabilités du cahier des charges Phase 2, espérance du multiplicateur E(1) = 1,5051.
local weights: { Types.MutationWeight } = {
	{ id = "normal", weight = 810100 }, -- 81,01 %
	{ id = "shiny", weight = 120000 }, -- Brillante ×2 : 12 %
	{ id = "giant", weight = 50000 }, -- Géante ×4 : 5 %
	{ id = "crystal", weight = 15000 }, -- Cristallisée ×8 : 1,5 %
	{ id = "radioactive", weight = 4000 }, -- Radioactive ×20 : 0,4 %
	{ id = "astral", weight = 800 }, -- Astrale ×50 : 0,08 %
	{ id = "divine", weight = 100 }, -- Divine ×150 : 0,01 %
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
