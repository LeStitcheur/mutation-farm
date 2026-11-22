--!strict
-- Règles PURES de progression (testées en Lune) : seuils et multiplicateur de rebirth, Mutation Essence,
-- éligibilité, aperçu pour l'interface, comptage des Coins gagnés par cycle.
-- Précision : les seuils sont des BigNum. Ils sont exacts tant que 100 000 × 3,2ⁿ est calculable sans erreur
-- d'arrondi déterminante (n ≤ EXACT_LIMIT, arrondi à l'entier supérieur) ; au-delà, écart relatif ≤ 1e-10
-- (troncature à l'entier jusqu'à 1e15, puis logarithmes et 15 chiffres significatifs), croissance stricte testée
-- jusqu'à n = 200. Voir docs/PROGRESSION.md §Précision.

local Types = require(script.Parent.Parent.Types)
local ProgressionConfig = require(script.Parent.Parent.Config.ProgressionConfig)
local BigNum = require(script.Parent.BigNum)
local Upgrades = require(script.Parent.Upgrades)
local Bonuses = require(script.Parent.Bonuses)

type BigNum = Types.BigNum
type PlayerData = Types.PlayerData

-- Jusqu'à n = 10, la partie fractionnaire exacte de 10⁵ × 3,2ⁿ est un multiple de 10^-(n-5) ≥ 10⁻⁵, bien
-- au-dessus de l'erreur flottante (< 10⁻⁶) : l'arrondi à l'entier supérieur est donc exact.
local EXACT_LIMIT = 10
local FLOAT_TOLERANCE = 1e-6

-- 1e7 × 10^p reste un entier exact (< 1e15) jusqu'à p = 7 ; au-delà : BigNum par logarithmes.
local PRESTIGE_EXACT_LIMIT = 7

export type RebirthFailure = "below_threshold"
export type PrestigeFailure = "not_enough_rebirths" | "not_enough_coins"

export type PrestigePreview = {
	prestiges: number, -- P actuel
	rebirths: number,
	rebirthsRequired: number,
	prestigeCoins: BigNum,
	coinsRequired: BigNum,
	coinsProgress: number, -- [0, 1]
	eligible: boolean,
	failure: PrestigeFailure?,
	cores: BigNum, -- Primal Cores obtenus si le prestige était fait maintenant (0 si non éligible)
	prestigeMultiplier: number,
	nextPrestigeMultiplier: number,
	incomeMultiplier: number, -- revenu actuel (rebirth × prestige)
	nextIncomeMultiplier: number, -- revenu juste après le prestige (rebirths remis à 0)
}

export type RebirthPreview = {
	rebirths: number,
	threshold: BigNum,
	cycleCoins: BigNum,
	progress: number, -- [0, 1]
	eligible: boolean,
	essence: BigNum, -- Essence obtenue si le rebirth était fait maintenant (0 si non éligible)
	multiplier: number,
	nextMultiplier: number,
}

local ProgressionMath = {}

-- Coins à gagner pendant le cycle pour le rebirth n° n + 1 (n = rebirths déjà faits depuis le dernier prestige).
function ProgressionMath.rebirthThreshold(n: number): BigNum
	assert(n >= 0 and n % 1 == 0, "ProgressionMath.rebirthThreshold : n invalide")
	local config = ProgressionConfig.Rebirth
	if n <= EXACT_LIMIT then
		local value = config.BaseThreshold * config.ThresholdGrowth ^ n
		return BigNum.fromNumber(math.ceil(value - FLOAT_TOLERANCE))
	end
	return BigNum.fromExponential(config.BaseThreshold, config.ThresholdGrowth, n)
end

-- Multiplicateur de revenu après R rebirths : 1 + 0,35 R + 0,015 R².
function ProgressionMath.rebirthMultiplier(rebirths: number): number
	assert(rebirths >= 0 and rebirths % 1 == 0, "ProgressionMath.rebirthMultiplier : R invalide")
	local config = ProgressionConfig.Rebirth
	return 1 + config.MultiplierLinear * rebirths + config.MultiplierQuadratic * rebirths * rebirths
end

-- Multiplicateur de prestige après P prestiges : 1 + 0,5 P + 0,08 P² (jamais réinitialisé).
function ProgressionMath.prestigeMultiplier(prestiges: number): number
	assert(prestiges >= 0 and prestiges % 1 == 0, "ProgressionMath.prestigeMultiplier : P invalide")
	local config = ProgressionConfig.Prestige
	return 1 + config.MultiplierLinear * prestiges + config.MultiplierQuadratic * prestiges * prestiges
end

-- Multiplicateur appliqué à toute rentrée de Coins gagnée (vente et bonus de précision) :
-- rebirth × prestige × améliorations de valeur × familiers (point d'entrée unique).
function ProgressionMath.incomeMultiplier(data: PlayerData): number
	local progression = data.progression
	return ProgressionMath.rebirthMultiplier(progression.rebirths)
		* ProgressionMath.prestigeMultiplier(progression.prestiges)
		* Bonuses.valueMultiplier(data)
end

-- Mutation Essence d'un rebirth fait avec `cycleCoins` gagnés pendant le cycle (0 sous le seuil).
-- `bonus` : multiplicateur des améliorations (Instinct du collectionneur), 1 par défaut.
function ProgressionMath.rebirthEssence(n: number, cycleCoins: BigNum, bonus: number?): BigNum
	local threshold = ProgressionMath.rebirthThreshold(n)
	if BigNum.lt(cycleCoins, threshold) then
		return BigNum.zero()
	end
	local config = ProgressionConfig.Rebirth
	local overshoot = math.min(BigNum.ratio(cycleCoins, threshold), config.EssenceOvershootCap)
	local amount = config.EssenceBase
		* (1 + n) ^ config.EssenceRebirthExponent
		* overshoot ^ config.EssenceOvershootExponent
		* (bonus or 1)
	return BigNum.fromNumber(math.floor(amount + 1e-9))
end

function ProgressionMath.canRebirth(data: PlayerData): (boolean, RebirthFailure?)
	local progression = data.progression
	if BigNum.lt(progression.cycleCoins, ProgressionMath.rebirthThreshold(progression.rebirths)) then
		return false, "below_threshold"
	end
	return true, nil
end

-- Données affichées par le panneau Rebirth (mêmes règles que le serveur ; le serveur revalide tout).
function ProgressionMath.rebirthPreview(data: PlayerData): RebirthPreview
	local progression = data.progression
	local n = progression.rebirths
	local threshold = ProgressionMath.rebirthThreshold(n)
	local eligible = ProgressionMath.canRebirth(data)
	local prestigeFactor = ProgressionMath.prestigeMultiplier(progression.prestiges)
	return {
		rebirths = n,
		threshold = threshold,
		cycleCoins = progression.cycleCoins,
		progress = math.clamp(BigNum.ratio(progression.cycleCoins, threshold), 0, 1),
		eligible = eligible,
		essence = ProgressionMath.rebirthEssence(n, progression.cycleCoins, Upgrades.essenceMultiplier(data)),
		multiplier = ProgressionMath.incomeMultiplier(data),
		-- Les améliorations Essence et permanentes et les familiers sont conservés au rebirth ; les améliorations
		-- normales (Coins) sont perdues.
		nextMultiplier = ProgressionMath.rebirthMultiplier(n + 1)
			* prestigeFactor
			* Bonuses.valueMultiplierExcept(data, "coins"),
	}
end

-- Rebirths (depuis le dernier prestige) exigés pour le prestige n° p + 1 : 5, 8, 12, 17, 23…
function ProgressionMath.prestigeRebirthsRequired(p: number): number
	assert(p >= 0 and p % 1 == 0, "ProgressionMath.prestigeRebirthsRequired : p invalide")
	local config = ProgressionConfig.Prestige
	return config.RebirthsBase + config.RebirthsLinear * p + config.RebirthsQuadratic * p * (p - 1) // 2
end

-- Coins gagnés depuis le dernier prestige exigés pour le prestige n° p + 1 : 1e7 × 10^p.
function ProgressionMath.prestigeCoinsRequired(p: number): BigNum
	assert(p >= 0 and p % 1 == 0, "ProgressionMath.prestigeCoinsRequired : p invalide")
	local config = ProgressionConfig.Prestige
	if p <= PRESTIGE_EXACT_LIMIT then
		return BigNum.fromNumber(math.ceil(config.CoinsBase * config.CoinsGrowth ^ p - FLOAT_TOLERANCE))
	end
	return BigNum.fromExponential(config.CoinsBase, config.CoinsGrowth, p)
end

-- Primal Cores d'un prestige n° p + 1 fait avec `rebirths` rebirths (0 sous le minimum de rebirths).
function ProgressionMath.prestigeCores(p: number, rebirths: number): BigNum
	local required = ProgressionMath.prestigeRebirthsRequired(p)
	if rebirths < required then
		return BigNum.zero()
	end
	local config = ProgressionConfig.Prestige
	local extra = math.min(rebirths - required, config.CoresExtraRebirthCap)
	local amount = config.CoresBase
		* (1 + p) ^ config.CoresPrestigeExponent
		* (1 + config.CoresExtraRebirthBonus * extra)
	return BigNum.fromNumber(math.floor(amount + 1e-9))
end

-- Les deux conditions sont requises ; la première manquante est signalée (rebirths d'abord).
function ProgressionMath.canPrestige(data: PlayerData): (boolean, PrestigeFailure?)
	local progression = data.progression
	if progression.rebirths < ProgressionMath.prestigeRebirthsRequired(progression.prestiges) then
		return false, "not_enough_rebirths"
	end
	if BigNum.lt(progression.prestigeCoins, ProgressionMath.prestigeCoinsRequired(progression.prestiges)) then
		return false, "not_enough_coins"
	end
	return true, nil
end

-- Données affichées par le panneau Prestige (mêmes règles que le serveur ; le serveur revalide tout).
function ProgressionMath.prestigePreview(data: PlayerData): PrestigePreview
	local progression = data.progression
	local p = progression.prestiges
	local coinsRequired = ProgressionMath.prestigeCoinsRequired(p)
	local eligible: boolean, failure: PrestigeFailure? = ProgressionMath.canPrestige(data)
	return {
		prestiges = p,
		rebirths = progression.rebirths,
		rebirthsRequired = ProgressionMath.prestigeRebirthsRequired(p),
		prestigeCoins = progression.prestigeCoins,
		coinsRequired = coinsRequired,
		coinsProgress = math.clamp(BigNum.ratio(progression.prestigeCoins, coinsRequired), 0, 1),
		eligible = eligible,
		failure = failure,
		cores = if eligible then ProgressionMath.prestigeCores(p, progression.rebirths) else BigNum.zero(),
		prestigeMultiplier = ProgressionMath.prestigeMultiplier(p),
		nextPrestigeMultiplier = ProgressionMath.prestigeMultiplier(p + 1),
		incomeMultiplier = ProgressionMath.incomeMultiplier(data),
		-- Seules les améliorations permanentes (Primal Cores) survivent au prestige ; les familiers aussi.
		nextIncomeMultiplier = ProgressionMath.prestigeMultiplier(p + 1) * Bonuses.valueMultiplier(data, "cores"),
	}
end

-- Comptabilise des Coins GAGNÉS (pas les achats Robux ni les remboursements) : historique, cycle de rebirth et
-- cycle de prestige, dans la même mutation que le crédit. Montant ≥ 0 déjà validé par l'appelant.
function ProgressionMath.recordEarnings(data: PlayerData, amount: BigNum)
	data.stats.coinsEarned = BigNum.add(data.stats.coinsEarned, amount)
	data.progression.cycleCoins = BigNum.add(data.progression.cycleCoins, amount)
	data.progression.prestigeCoins = BigNum.add(data.progression.prestigeCoins, amount)
end

return table.freeze(ProgressionMath)
