--!strict
-- Extensions de ferme achetables (Phase 5, jalon A) : les parcelles de FarmLayout autres que la parcelle de départ,
-- débloquées dans l'ordre (ouest, est, terrasse) en Coins. Prix strictement croissants (testé, Expansions.spec).
-- Conservées au rebirth, réinitialisées au prestige (docs/PROGRESSION.md). Équilibrage : docs/ECONOMY.md §12.
-- Identifiants = identifiants de parcelle de FarmLayout (clés de sauvegarde farm.plots) : ne jamais les renommer.

local Deep = require(script.Parent.Parent.Util.Deep)

export type ExpansionDef = {
	plotId: string, -- parcelle de FarmLayout (clé de farm.plots)
	order: number, -- ordre d'achat : 1 = première extension
	name: string,
	price: number, -- Coins
}

local list: { ExpansionDef } = {
	{ plotId = "west", order = 1, name = "Champ ouest", price = 300000 },
	{ plotId = "east", order = 2, name = "Champ est", price = 4000000 },
	{ plotId = "terrace", order = 3, name = "Terrasse", price = 40000000 },
}

table.sort(list, function(a, b)
	return a.order < b.order
end)

local byPlot: { [string]: ExpansionDef } = {}
for _, def in list do
	assert(byPlot[def.plotId] == nil, "ExpansionConfig : parcelle dupliquée " .. def.plotId)
	byPlot[def.plotId] = def
end

Deep.freeze(list)
table.freeze(byPlot)

local ExpansionConfig = {
	List = list,
	PurchaseRequestsPerSecond = 2,
}

function ExpansionConfig.get(plotId: string): ExpansionDef?
	return byPlot[plotId]
end

return table.freeze(ExpansionConfig)
