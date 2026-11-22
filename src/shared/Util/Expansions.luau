--!strict
-- Règles PURES des extensions de ferme (Phase 5, jalon A ; testées en Lune) : ordre d'achat, prix, achat atomique.
-- Le serveur exécute `purchase` dans UN mutateur de DataService.Update : ordre et solde vérifiés, puis débit et
-- déblocage indissociables. Un second achat de la même parcelle (double appui, requête rejouée) échoue sans effet
-- (« owned »). Le client ne fournit jamais de prix : l'achat passe par une invite serveur (FarmService).

local Types = require(script.Parent.Parent.Types)
local ExpansionConfig = require(script.Parent.Parent.Config.ExpansionConfig)
local BigNum = require(script.Parent.BigNum)
local Economy = require(script.Parent.Economy)
local FarmLayout = require(script.Parent.FarmLayout)

type PlayerData = Types.PlayerData
type BigNum = Types.BigNum
type ExpansionDef = ExpansionConfig.ExpansionDef

export type BuyFailure = "unknown" | "owned" | "locked_order" | "insufficient_funds"

export type PurchaseOutcome = {
	plotId: string,
	name: string,
	price: BigNum,
	tiles: number, -- cases ajoutées
}

local Expansions = {}

function Expansions.get(plotId: string): ExpansionDef?
	return ExpansionConfig.get(plotId)
end

-- Extensions dans l'ordre d'achat.
function Expansions.list(): { ExpansionDef }
	return ExpansionConfig.List
end

function Expansions.price(def: ExpansionDef): BigNum
	return BigNum.fromNumber(def.price)
end

function Expansions.isOwned(data: PlayerData, plotId: string): boolean
	return data.farm.plots[plotId] == true
end

-- Extension précédente dans l'ordre d'achat (nil pour la première).
function Expansions.previous(plotId: string): ExpansionDef?
	local def = ExpansionConfig.get(plotId)
	if not def then
		return nil
	end
	for _, other in ExpansionConfig.List do
		if other.order == def.order - 1 then
			return other
		end
	end
	return nil
end

-- Prochaine extension à acheter (nil : toutes possédées).
function Expansions.nextToBuy(data: PlayerData): ExpansionDef?
	for _, def in ExpansionConfig.List do
		if not Expansions.isOwned(data, def.plotId) then
			return def
		end
	end
	return nil
end

function Expansions.canBuy(data: PlayerData, plotId: string): (boolean, BuyFailure?)
	local def = ExpansionConfig.get(plotId)
	if not def or not FarmLayout.getPlot(plotId) then
		return false, "unknown"
	end
	if Expansions.isOwned(data, plotId) then
		return false, "owned"
	end
	local previous = Expansions.previous(plotId)
	if previous and not Expansions.isOwned(data, previous.plotId) then
		return false, "locked_order"
	end
	if BigNum.lt(data.currencies.coins, Expansions.price(def)) then
		return false, "insufficient_funds"
	end
	return true, nil
end

-- Achat d'une extension : débit (jamais de solde négatif) et déblocage dans la même mutation.
function Expansions.purchase(data: PlayerData, plotId: string): (PurchaseOutcome?, BuyFailure?)
	local allowed: boolean, failure: BuyFailure? = Expansions.canBuy(data, plotId)
	if not allowed then
		return nil, failure
	end
	local def = ExpansionConfig.get(plotId) :: ExpansionDef
	local price = Expansions.price(def)
	if not Economy.trySpend(data, price) then
		return nil, "insufficient_funds"
	end
	data.farm.plots[plotId] = true
	return { plotId = plotId, name = def.name, price = price, tiles = #FarmLayout.tileIds(plotId) }, nil
end

-- Nombre de cases cultivables (parcelles débloquées).
function Expansions.tileCount(data: PlayerData): number
	local count = 0
	for _, plot in FarmLayout.Plots do
		if data.farm.plots[plot.id] == true then
			count += plot.rows * plot.cols
		end
	end
	return count
end

-- Identifiants des cases cultivables, parcelle par parcelle (ordre de FarmLayout).
function Expansions.unlockedTiles(data: PlayerData): { string }
	local tiles: { string } = {}
	for _, plot in FarmLayout.Plots do
		if data.farm.plots[plot.id] == true then
			for _, tileId in FarmLayout.tileIds(plot.id) do
				table.insert(tiles, tileId)
			end
		end
	end
	return tiles
end

return table.freeze(Expansions)
