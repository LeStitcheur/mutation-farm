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
	Prestige = {
		-- Conditions du prestige n° p + 1 (p = prestiges déjà faits), TOUTES deux requises :
		--   rebirths depuis le dernier prestige ≥ RebirthsBase + RebirthsLinear × p + RebirthsQuadratic × p(p − 1)/2
		--     → 5, 8, 12, 17, 23… (cahier des charges : 5 / 8 / 12) ;
		--   Coins GAGNÉS depuis le dernier prestige ≥ CoinsBase × CoinsGrowth^p → 1e7, 1e8, 1e9…
		RebirthsBase = 5,
		RebirthsLinear = 3,
		RebirthsQuadratic = 1,
		CoinsBase = 1e7,
		CoinsGrowth = 10,
		-- Multiplicateur de prestige (permanent, P = prestiges réalisés) : 1 + Linear × P + Quadratic × P².
		MultiplierLinear = 0.5,
		MultiplierQuadratic = 0.08,
		-- Primal Cores : floor(CoresBase × (1 + p)^CoresPrestigeExponent × (1 + ExtraRebirthBonus × min(e, ExtraCap))),
		-- e = rebirths faits au-delà du minimum : faire plus de rebirths rapporte au plus ×2.
		CoresBase = 10,
		CoresPrestigeExponent = 0.75,
		CoresExtraRebirthBonus = 0.25,
		CoresExtraRebirthCap = 4,
		RequestsPerSecond = 0.5, -- débit maximal des requêtes de prestige par joueur
	},
}

return Deep.freeze(ProgressionConfig)
