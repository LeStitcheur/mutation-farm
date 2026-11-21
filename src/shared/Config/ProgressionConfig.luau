--!strict
-- Progression longue (Phase 3) : rebirth (puis prestige et améliorations). Valeurs publiques et gelées.
-- Formules : src/shared/Util/ProgressionMath.luau ; justification et simulations : docs/PROGRESSION.md.

local Deep = require(script.Parent.Parent.Util.Deep)

local ProgressionConfig = {
	Rebirth = {
		-- Seuil sur les Coins GAGNÉS pendant le cycle (pas le solde) : threshold(n) = BaseThreshold × Growth^n,
		-- n = rebirths depuis le dernier prestige.
		BaseThreshold = 100000,
		ThresholdGrowth = 3.2,
		-- Multiplicateur de revenu : 1 + Linear × R + Quadratic × R².
		MultiplierLinear = 0.35,
		MultiplierQuadratic = 0.015,
		-- Mutation Essence : floor(Base × (1 + n)^RebirthExponent × min(r, OvershootCap)^OvershootExponent),
		-- r = Coins gagnés pendant le cycle / seuil (r ≥ 1) : dépasser le seuil rapporte au plus ×2.
		EssenceBase = 100,
		EssenceRebirthExponent = 0.75,
		EssenceOvershootExponent = 0.5,
		EssenceOvershootCap = 4,
		RequestsPerSecond = 0.5, -- débit maximal des requêtes de rebirth par joueur
	},
}

return Deep.freeze(ProgressionConfig)
