--!strict
-- Définitions publiques des mutations (noms, multiplicateurs, couleurs).
-- Les POIDS de tirage sont secrets : ServerScriptService.Server.Config.MutationOdds.

local Types = require(script.Parent.Parent.Types)
local Deep = require(script.Parent.Parent.Util.Deep)

type MutationDef = Types.MutationDef

local NORMAL = "normal"

local list: { MutationDef } = {
	{ id = NORMAL, order = 0, name = "Normale", multiplier = 1, essence = 0, color = "#FFFFFF" },
	{ id = "shiny", order = 1, name = "Brillante", multiplier = 2, essence = 1, color = "#FFF59D" },
	{ id = "giant", order = 2, name = "Géante", multiplier = 4, essence = 3, color = "#81C784" },
	{ id = "crystal", order = 3, name = "Cristallisée", multiplier = 8, essence = 10, color = "#80DEEA" },
	{ id = "radioactive", order = 4, name = "Radioactive", multiplier = 20, essence = 40, color = "#76FF03" },
	{ id = "astral", order = 5, name = "Astrale", multiplier = 50, essence = 150, color = "#B388FF" },
	{ id = "divine", order = 6, name = "Divine", multiplier = 150, essence = 600, color = "#FFD700" },
}

local byId: { [string]: MutationDef } = {}
for _, def in list do
	assert(byId[def.id] == nil, "MutationConfig : identifiant dupliqué " .. def.id)
	byId[def.id] = def
end

Deep.freeze(list)
table.freeze(byId)

local MutationConfig = {
	NORMAL = NORMAL,
	List = list,
}

function MutationConfig.get(id: string): MutationDef?
	return byId[id]
end

function MutationConfig.multipliers(): { [string]: number }
	local result: { [string]: number } = {}
	for _, def in list do
		result[def.id] = def.multiplier
	end
	return result
end

return table.freeze(MutationConfig)
