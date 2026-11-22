--!strict
-- Vente du sac, règle PURE commune à la vente au marché (manuelle) et au comptoir automatique (Phase 5, jalon C ;
-- testée en Lune). Exécutée dans UN mutateur de DataService.Update : total calculé sur le sac et le multiplicateur
-- de cet état, crédit (Coins GAGNÉS : historique et cycles), sac vidé — indissociables. Deux ventes concurrentes
-- (manuelle et automatique) ne peuvent donc jamais payer deux fois le même objet : la seconde trouve le sac vide.

local Types = require(script.Parent.Parent.Types)
local BigNum = require(script.Parent.BigNum)
local Economy = require(script.Parent.Economy)
local Inventory = require(script.Parent.Inventory)
local ProgressionMath = require(script.Parent.ProgressionMath)
local Quests = require(script.Parent.Quests)

type PlayerData = Types.PlayerData
type BigNum = Types.BigNum

export type SaleSource = "manual" | "auto"

export type SaleOutcome = {
	source: SaleSource,
	count: number, -- objets vendus
	total: BigNum, -- Coins crédités
	questsCompleted: { Types.Mission }, -- missions « vendre » terminées (ventes manuelles seulement)
}

local Selling = {}

-- Vend tout le sac. nil si le sac est vide (rien n'est modifié).
-- Les ventes automatiques ne comptent pas pour les missions « vendre » (elles récompensent le jeu actif) ; elles
-- alimentent les statistiques d'automatisation.
function Selling.sellBag(data: PlayerData, now: number, source: SaleSource): SaleOutcome?
	local count = Inventory.count(data.bag.items)
	if count <= 0 then
		return nil
	end
	local total = Economy.sellValue(data.bag.items, ProgressionMath.incomeMultiplier(data))
	data.currencies.coins = BigNum.add(data.currencies.coins, total)
	ProgressionMath.recordEarnings(data, total)
	data.stats.sells += 1
	data.bag.items = {}
	local completed: { Types.Mission } = {}
	if source == "manual" then
		completed = Quests.record(data, "sell", 1, now)
	else
		local stats = data.automation.stats
		stats.autoSells += 1
		stats.autoSellCoins = BigNum.add(stats.autoSellCoins, total)
	end
	return { source = source, count = count, total = total, questsCompleted = completed }
end

return table.freeze(Selling)
