--!strict
-- Catalogue des plantes. Valeurs équilibrées dans docs/ECONOMY.md ; invariants testés par tests/specs/Config.spec.luau.

local Types = require(script.Parent.Parent.Types)
local Deep = require(script.Parent.Parent.Util.Deep)

type PlantDef = Types.PlantDef

local list: { PlantDef } = {
	{
		id = "carrot",
		order = 1,
		name = "Carotte",
		description = "Croquante et rapide à pousser.",
		growTime = 6,
		baseValue = 10,
		unlockPrice = 0,
		color = "#F28C28",
	},
	{
		id = "tomato",
		order = 2,
		name = "Tomate",
		description = "Juteuse, trois fruits par plant.",
		growTime = 12,
		baseValue = 45,
		unlockPrice = 750,
		color = "#E53935",
	},
	{
		id = "corn",
		order = 3,
		name = "Maïs",
		description = "Un épi doré au sommet d'une grande tige.",
		growTime = 20,
		baseValue = 150,
		unlockPrice = 6000,
		color = "#FDD835",
	},
	{
		id = "pumpkin",
		order = 4,
		name = "Citrouille",
		description = "Lourde, ronde et très rentable.",
		growTime = 35,
		baseValue = 550,
		unlockPrice = 40000,
		color = "#FB8C00",
	},
	{
		id = "moonshroom",
		order = 5,
		name = "Champi-lune",
		description = "Son chapeau brille comme un ciel étoilé.",
		growTime = 60,
		baseValue = 2000,
		unlockPrice = 250000,
		color = "#8E5CD9",
	},
	{
		id = "starbloom",
		order = 6,
		name = "Fleur-étoile",
		description = "Ses pétales dorés captent la lumière.",
		growTime = 90,
		baseValue = 6500,
		unlockPrice = 1500000,
		color = "#FFD54F",
	},
	{
		id = "dragonfruit",
		order = 7,
		name = "Fruit du dragon",
		description = "Un cactus fier et ses fruits roses.",
		growTime = 150,
		baseValue = 22500,
		unlockPrice = 10000000,
		color = "#EC407A",
	},
}

table.sort(list, function(a, b)
	return a.order < b.order
end)

local byId: { [string]: PlantDef } = {}
local indexById: { [string]: number } = {}
for index, def in list do
	assert(byId[def.id] == nil, "PlantConfig : identifiant dupliqué " .. def.id)
	byId[def.id] = def
	indexById[def.id] = index
end

Deep.freeze(list)
table.freeze(byId)
table.freeze(indexById)

local PlantConfig = {
	List = list,
}

function PlantConfig.get(id: string): PlantDef?
	return byId[id]
end

-- Plante précédente dans l'ordre de déblocage (nil pour la première).
function PlantConfig.previous(id: string): PlantDef?
	local index = indexById[id]
	if index and index > 1 then
		return list[index - 1]
	end
	return nil
end

function PlantConfig.nextAfter(id: string): PlantDef?
	local index = indexById[id]
	if index then
		return list[index + 1]
	end
	return nil
end

return table.freeze(PlantConfig)
