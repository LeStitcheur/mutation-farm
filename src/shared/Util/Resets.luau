--!strict
-- Transitions de progression PURES (testées en Lune), exécutées par le serveur dans UN SEUL mutateur synchrone
-- de DataService.Update : validation, réinitialisation et récompense sont indissociables (jamais de récompense
-- sans le reset correspondant), et la révision attendue rend chaque requête idempotente.
-- Contenu réinitialisé / conservé : docs/PROGRESSION.md.

local Types = require(script.Parent.Parent.Types)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local BigNum = require(script.Parent.BigNum)
local FarmLayout = require(script.Parent.FarmLayout)
local ProgressionMath = require(script.Parent.ProgressionMath)
local Upgrades = require(script.Parent.Upgrades)

type PlayerData = Types.PlayerData
type BigNum = Types.BigNum

export type RebirthFailure = "stale_revision" | "below_threshold"

export type RebirthOutcome = {
	rebirths: number, -- rebirths depuis le dernier prestige, après ce rebirth
	essence: BigNum, -- Mutation Essence gagnée
	multiplier: number, -- nouveau multiplicateur de revenu (rebirth × prestige)
	revision: number, -- nouvelle révision de progression
}

export type PrestigeFailure = "stale_revision" | "not_enough_rebirths" | "not_enough_coins"

export type PrestigeOutcome = {
	prestiges: number, -- prestiges réalisés, après ce prestige
	cores: BigNum, -- Primal Cores gagnés
	multiplier: number, -- nouveau multiplicateur de prestige (= revenu juste après, rebirths à 0)
	revision: number, -- nouvelle révision de progression
}

local Resets = {}

-- Économie du cycle : Coins, graines, sac, améliorations normales, drones, cultures (les cases sont replantées
-- par le serveur), Coins gagnés pendant le cycle de rebirth.
-- Améliorations permanentes appliquées au nouveau cycle : Héritage agricole (graines gardées, la meilleure
-- sélectionnée) et Automatisation primordiale (drones offerts).
local function resetEconomy(data: PlayerData)
	data.currencies.coins = BigNum.zero()
	local legacy = Upgrades.legacySeeds(data)
	local unlocked: { [string]: boolean } = {}
	for _, plantId in legacy do
		unlocked[plantId] = true
	end
	data.seeds.unlocked = unlocked
	data.seeds.selected = legacy[#legacy] or GameConfig.StarterSeed
	data.bag.items = {}
	data.upgrades.normal = {}
	data.machines.drones = {}
	Upgrades.grantStartingDrones(data)
	data.farm.tiles = {}
	data.progression.cycleCoins = BigNum.zero()
end

-- Rebirth : refusé si la révision ne correspond plus (requête rejouée ou concurrente) ou sous le seuil.
-- Conserve : parcelles, Mutation Essence, améliorations de rebirth et permanentes, Mutadex, cosmétiques, familiers,
-- reçus, statistiques, Primal Cores, prestiges, Coins du cycle de prestige — et tout champ non listé ci-dessus.
function Resets.rebirth(data: PlayerData, expectedRevision: number): (RebirthOutcome?, RebirthFailure?)
	local progression = data.progression
	if progression.revision ~= expectedRevision then
		return nil, "stale_revision"
	end
	-- Annotation explicite : sans elle, l'inférence élargit l'union de littéraux en `string`.
	local eligible: boolean, failure: ProgressionMath.RebirthFailure? = ProgressionMath.canRebirth(data)
	if not eligible then
		return nil, failure
	end
	local essence =
		ProgressionMath.rebirthEssence(progression.rebirths, progression.cycleCoins, Upgrades.essenceMultiplier(data))
	resetEconomy(data)
	progression.rebirths += 1
	progression.revision += 1
	data.stats.totalRebirths += 1
	data.currencies.essence = BigNum.add(data.currencies.essence, essence)
	return {
		rebirths = progression.rebirths,
		essence = essence,
		multiplier = ProgressionMath.incomeMultiplier(data),
		revision = progression.revision,
	},
		nil
end

-- Prestige : refusé si la révision ne correspond plus ou si une condition manque (rebirths, puis Coins gagnés depuis
-- le dernier prestige). Réinitialise l'économie du cycle, les parcelles achetées, les rebirths du cycle, la Mutation
-- Essence, les améliorations de rebirth et les Coins des deux cycles. Conserve Primal Cores (+ gain), améliorations
-- permanentes, Mutadex, cosmétiques, familiers, reçus (droits Robux), statistiques historiques, prestiges.
function Resets.prestige(data: PlayerData, expectedRevision: number): (PrestigeOutcome?, PrestigeFailure?)
	local progression = data.progression
	if progression.revision ~= expectedRevision then
		return nil, "stale_revision"
	end
	local eligible: boolean, failure: ProgressionMath.PrestigeFailure? = ProgressionMath.canPrestige(data)
	if not eligible then
		return nil, failure
	end
	local cores = ProgressionMath.prestigeCores(progression.prestiges, progression.rebirths)
	resetEconomy(data)
	data.currencies.essence = BigNum.zero()
	data.upgrades.rebirth = {}
	data.farm.plots = FarmLayout.defaultPlots()
	progression.rebirths = 0
	progression.prestigeCoins = BigNum.zero()
	progression.prestiges += 1
	progression.revision += 1
	data.currencies.primalCores = BigNum.add(data.currencies.primalCores, cores)
	return {
		prestiges = progression.prestiges,
		cores = cores,
		multiplier = ProgressionMath.prestigeMultiplier(progression.prestiges),
		revision = progression.revision,
	},
		nil
end

return Resets
