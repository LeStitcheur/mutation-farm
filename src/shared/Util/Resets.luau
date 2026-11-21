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

type PlayerData = Types.PlayerData
type BigNum = Types.BigNum

export type RebirthFailure = "stale_revision" | "below_threshold"

export type RebirthOutcome = {
	rebirths: number, -- rebirths depuis le dernier prestige, après ce rebirth
	essence: BigNum, -- Mutation Essence gagnée
	multiplier: number, -- nouveau multiplicateur de revenu
	revision: number, -- nouvelle révision de progression
}

local Resets = {}

-- Économie du cycle : Coins, graines, sac, améliorations normales, drones, cultures (les cases sont replantées
-- par le serveur), Coins gagnés pendant le cycle de rebirth.
local function resetEconomy(data: PlayerData)
	data.currencies.coins = BigNum.zero()
	data.seeds.unlocked = { [GameConfig.StarterSeed] = true }
	data.seeds.selected = GameConfig.StarterSeed
	data.bag.items = {}
	data.upgrades.normal = {}
	data.machines.drones = {}
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
	local essence = ProgressionMath.rebirthEssence(progression.rebirths, progression.cycleCoins)
	resetEconomy(data)
	progression.rebirths += 1
	progression.revision += 1
	data.stats.totalRebirths += 1
	data.currencies.essence = BigNum.add(data.currencies.essence, essence)
	return {
		rebirths = progression.rebirths,
		essence = essence,
		multiplier = ProgressionMath.rebirthMultiplier(progression.rebirths),
		revision = progression.revision,
	},
		nil
end

-- Prestige (règles complètes au jalon B) : reset de l'économie, des parcelles, des rebirths du cycle, de l'Essence et
-- des améliorations de rebirth. Conserve Primal Cores (+ gain), améliorations permanentes, Mutadex, cosmétiques,
-- familiers, reçus, statistiques historiques.
function Resets.prestige(data: PlayerData, coresGained: number)
	assert(coresGained >= 0 and coresGained % 1 == 0, "Resets.prestige : gain de Primal Cores invalide")
	resetEconomy(data)
	data.currencies.essence = BigNum.zero()
	data.upgrades.rebirth = {}
	data.farm.plots = FarmLayout.defaultPlots()
	data.progression.rebirths = 0
	data.progression.prestigeCoins = BigNum.zero()
	data.progression.prestiges += 1
	data.progression.revision += 1
	data.currencies.primalCores = BigNum.add(data.currencies.primalCores, BigNum.fromNumber(coresGained))
end

return Resets
