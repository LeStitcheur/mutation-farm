--!strict
-- Règles contractuelles de reset (Phase 5). Purement structurelles : les coûts et récompenses sont
-- validés/calculés par RebirthService/PrestigeService avant l'appel. Voir docs/GAME_DESIGN.md §8.

local Types = require(script.Parent.Parent.Types)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local BigNum = require(script.Parent.BigNum)
local FarmLayout = require(script.Parent.FarmLayout)

type PlayerData = Types.PlayerData

local Resets = {}

local function resetEconomy(data: PlayerData)
	data.currencies.coins = BigNum.zero()
	data.seeds.unlocked = { [GameConfig.StarterSeed] = true }
	data.seeds.selected = GameConfig.StarterSeed
	data.bag.items = {}
	data.upgrades.normal = {}
	data.machines.drones = {}
	data.farm.tiles = {}
end

-- Rebirth : reset Coins, graines, machines, upgrades normaux, sac, cultures.
-- Conserve : parcelles, upgrades de rebirth, Rebirth Tokens, Essence, et tout ce que conserve le prestige.
function Resets.rebirth(data: PlayerData)
	resetEconomy(data)
	data.progression.rebirths += 1
	data.currencies.rebirthTokens += GameConfig.Rebirth.TokensPerRebirth
end

-- Prestige : reset de toute la progression économique, des parcelles, rebirths et upgrades de rebirth.
-- Conserve : Primal Cores (+ gain), upgrades permanents, Mutadex, cosmétiques, familiers, stats, reçus.
function Resets.prestige(data: PlayerData, coresGained: number)
	assert(coresGained >= 0 and coresGained % 1 == 0, "Resets.prestige : gain de Primal Cores invalide")
	resetEconomy(data)
	data.currencies.essence = BigNum.zero()
	data.currencies.rebirthTokens = 0
	data.upgrades.rebirth = {}
	data.farm.plots = FarmLayout.defaultPlots()
	data.progression.rebirths = 0
	data.progression.prestiges += 1
	data.currencies.primalCores = BigNum.add(data.currencies.primalCores, BigNum.fromNumber(coresGained))
end

return Resets
