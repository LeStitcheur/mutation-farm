--!strict
-- Types de drones (publics, gelés). Ajouter un type = ajouter une entrée ici : station d'achat, sauvegarde,
-- boucle de travail et rendu sont génériques (DroneService, DroneLogic, DroneRenderer).
-- Économie et simulations : docs/ECONOMY.md §7 (tests/specs/DroneEconomy.spec.luau).

local Types = require(script.Parent.Parent.Types)
local Deep = require(script.Parent.Parent.Util.Deep)

type DroneDef = Types.DroneDef

local list: { DroneDef } = {
	{
		id = "harvester",
		order = 1,
		name = "Drone récolteur",
		description = "Récolte seul les plantes mûres de ta ferme (sans bonus de précision) et remplit ton sac.",
		price = 1500,
		priceGrowth = 2.5, -- 1 500, 3 750, 9 375
		maxOwned = 3,
		interval = 4,
		capacity = 1,
		range = 25, -- couvre la parcelle principale depuis n'importe quel point d'attente
		graceDelay = 5, -- = fenêtre « Bien » : le joueur garde ses chances de Parfait/Bien (docs/ECONOMY.md §7)
		color = "#4FC3F7",
	},
}

local byId: { [string]: DroneDef } = {}
for _, def in list do
	assert(byId[def.id] == nil, "DroneConfig : identifiant dupliqué " .. def.id)
	byId[def.id] = def
end

Deep.freeze(list)
table.freeze(byId)

local DroneConfig = {
	List = list,
}

function DroneConfig.get(id: string): DroneDef?
	return byId[id]
end

return table.freeze(DroneConfig)
