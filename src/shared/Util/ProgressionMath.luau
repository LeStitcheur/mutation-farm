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

type BigNum = Types.BigNum
type PlayerData = Types.PlayerData

-- Jusqu'à n = 10, la partie fractionnaire exacte de 10⁵ × 3,2ⁿ est un multiple de 10^-(n-5) ≥ 10⁻⁵, bien
-- au-dessus de l'erreur flottante (< 10⁻⁶) : l'arrondi à l'entier supérieur est donc exact.
local EXACT_LIMIT = 10
local FLOAT_TOLERANCE = 1e-6

export type RebirthFailure = "below_threshold"

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

-- Multiplicateur appliqué à toute rentrée de Coins gagnée (vente et bonus de précision).
-- Phase 3 jalon A : rebirth seulement (prestige et améliorations : jalons B et C).
function ProgressionMath.incomeMultiplier(data: PlayerData): number
	return ProgressionMath.rebirthMultiplier(data.progression.rebirths)
end

-- Mutation Essence d'un rebirth fait avec `cycleCoins` gagnés pendant le cycle (0 sous le seuil).
function ProgressionMath.rebirthEssence(n: number, cycleCoins: BigNum): BigNum
	local threshold = ProgressionMath.rebirthThreshold(n)
	if BigNum.lt(cycleCoins, threshold) then
		return BigNum.zero()
	end
	local config = ProgressionConfig.Rebirth
	local overshoot = math.min(BigNum.ratio(cycleCoins, threshold), config.EssenceOvershootCap)
	local amount = config.EssenceBase
		* (1 + n) ^ config.EssenceRebirthExponent
		* overshoot ^ config.EssenceOvershootExponent
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
	return {
		rebirths = n,
		threshold = threshold,
		cycleCoins = progression.cycleCoins,
		progress = math.clamp(BigNum.ratio(progression.cycleCoins, threshold), 0, 1),
		eligible = eligible,
		essence = ProgressionMath.rebirthEssence(n, progression.cycleCoins),
		multiplier = ProgressionMath.rebirthMultiplier(n),
		nextMultiplier = ProgressionMath.rebirthMultiplier(n + 1),
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
