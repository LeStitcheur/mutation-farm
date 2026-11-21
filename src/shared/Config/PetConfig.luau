--!strict
-- Familiers (Phase 4, jalon B) : espèces, raretés, effets par niveau, œufs (prix, pools, probabilités AFFICHÉES),
-- progression (XP, niveaux), emplacements et plafonds de cumul. Valeurs publiques et gelées.
-- Les probabilités des œufs sont publiques par conception (affichées avant l'achat) ; le TIRAGE est fait par le
-- serveur (PetService) avec son propre générateur. Aucun œuf n'est vendu contre des Robux.
-- Les familiers ne sont jamais réinitialisés (ni rebirth, ni prestige).

local Deep = require(script.Parent.Parent.Util.Deep)

export type Effect =
	"growth" -- durée de pousse : × (1 − bonus)
	| "value" -- revenu (ventes et bonus de précision) : × (1 + bonus)
	| "luck" -- chance de mutation : + bonus (poids non normaux)
	| "drones" -- intervalle des drones : × (1 − bonus)
	| "manual" -- bonus de précision des récoltes MANUELLES : × (1 + bonus)

export type RarityDef = {
	id: string,
	order: number, -- 1 (commun) … 4 (légendaire) : tri de l'inventaire
	name: string,
	color: string,
}

export type Range = { min: number, max: number } -- bonus au niveau 1 et au niveau maximum (interpolation linéaire)

export type ModelDef = {
	shape: "sprout" | "fox" | "moth" | "beetle" | "bunny" | "wisp", -- silhouette (Visuals/PetModels)
	primary: string,
	secondary: string,
	glow: boolean, -- petite lumière (épique, légendaire)
}

export type PetDef = {
	id: string, -- identifiant stable (sauvegardes)
	order: number,
	name: string,
	rarity: RarityDef,
	description: string,
	effects: { [Effect]: Range },
	model: ModelDef,
}

export type EggDef = {
	id: string, -- identifiant stable (sauvegardes, remotes)
	order: number,
	name: string,
	price: number?, -- Coins ; nil = œuf non vendu (uniquement gagné : missions…)
	weights: { { petId: string, weight: number } }, -- pool ; probabilité = poids / somme (affichée)
	color: string,
}

local rarities = {
	common = { id = "common", order = 1, name = "Commun", color = "#B0BEC5" },
	rare = { id = "rare", order = 2, name = "Rare", color = "#4FC3F7" },
	epic = { id = "epic", order = 3, name = "Épique", color = "#BA68C8" },
	legendary = { id = "legendary", order = 4, name = "Légendaire", color = "#FFB300" },
}

local list: { PetDef } = {
	{
		id = "sproutling",
		order = 1,
		name = "Pousselet",
		rarity = rarities.common,
		description = "Ses racines pressent les graines : pousse plus rapide.",
		effects = { growth = { min = 0.04, max = 0.12 } },
		model = { shape = "sprout", primary = "#7CB342", secondary = "#C5E1A5", glow = false },
	},
	{
		id = "solar_bunny",
		order = 2,
		name = "Lapin solaire",
		rarity = rarities.common,
		description = "Bondit de joie à chaque cueillette : bonus de précision des récoltes manuelles.",
		effects = { manual = { min = 0.20, max = 0.60 } },
		model = { shape = "bunny", primary = "#FFCA28", secondary = "#FFF59D", glow = false },
	},
	{
		id = "crystal_fox",
		order = 3,
		name = "Renard de cristal",
		rarity = rarities.rare,
		description = "Fait briller les récoltes : revenu augmenté.",
		effects = { value = { min = 0.05, max = 0.15 } },
		model = { shape = "fox", primary = "#4DD0E1", secondary = "#E0F7FA", glow = false },
	},
	{
		id = "drone_beetle",
		order = 4,
		name = "Scarabée-drone",
		rarity = rarities.rare,
		description = "Graisse les rotors : drones plus rapides.",
		effects = { drones = { min = 0.05, max = 0.15 } },
		model = { shape = "beetle", primary = "#546E7A", secondary = "#FF7043", glow = false },
	},
	{
		id = "moon_moth",
		order = 5,
		name = "Phalène lunaire",
		rarity = rarities.epic,
		description = "Sa poudre d'argent attire les mutations : chance augmentée.",
		effects = { luck = { min = 0.10, max = 0.30 } },
		model = { shape = "moth", primary = "#9575CD", secondary = "#E1BEE7", glow = true },
	},
	{
		id = "primal_wisp",
		order = 6,
		name = "Feu follet primal",
		rarity = rarities.legendary,
		description = "Une étincelle des origines : un peu de tout.",
		effects = {
			value = { min = 0.03, max = 0.08 },
			growth = { min = 0.02, max = 0.06 },
			luck = { min = 0.05, max = 0.12 },
			drones = { min = 0.02, max = 0.06 },
			manual = { min = 0.10, max = 0.25 },
		},
		model = { shape = "wisp", primary = "#FF6E40", secondary = "#FFD180", glow = true },
	},
}

local eggs: { EggDef } = {
	{
		id = "meadow",
		order = 1,
		name = "Œuf de prairie",
		price = 5000,
		weights = {
			{ petId = "sproutling", weight = 40 },
			{ petId = "solar_bunny", weight = 40 },
			{ petId = "crystal_fox", weight = 8 },
			{ petId = "drone_beetle", weight = 8 },
			{ petId = "moon_moth", weight = 4 },
		},
		color = "#AED581",
	},
	{
		id = "crystal",
		order = 2,
		name = "Œuf cristallin",
		price = 75000,
		weights = {
			{ petId = "sproutling", weight = 10 },
			{ petId = "solar_bunny", weight = 10 },
			{ petId = "crystal_fox", weight = 30 },
			{ petId = "drone_beetle", weight = 30 },
			{ petId = "moon_moth", weight = 17 },
			{ petId = "primal_wisp", weight = 3 },
		},
		color = "#80DEEA",
	},
	{
		id = "mission",
		order = 3,
		name = "Œuf des missions",
		price = nil, -- jamais vendu : récompense de missions (jalon D) et d'objectifs
		weights = {
			{ petId = "sproutling", weight = 25 },
			{ petId = "solar_bunny", weight = 25 },
			{ petId = "crystal_fox", weight = 18 },
			{ petId = "drone_beetle", weight = 18 },
			{ petId = "moon_moth", weight = 10 },
			{ petId = "primal_wisp", weight = 4 },
		},
		color = "#FFD180",
	},
}

local byId: { [string]: PetDef } = {}
for _, def in list do
	byId[def.id] = def
end
local eggById: { [string]: EggDef } = {}
for _, egg in eggs do
	eggById[egg.id] = egg
end

local PetConfig = {
	Rarities = rarities,
	List = list,
	ById = byId,
	Eggs = eggs,
	EggById = eggById,
	Slots = 3, -- familiers équipés en même temps
	InventoryCapacity = 50, -- familiers possédés au plus (un œuf ne s'ouvre pas si l'inventaire est plein)
	MaxFreeEggs = 99, -- œufs gratuits en réserve par type
	Level = {
		Max = 15,
		XpBase = 30, -- XP du niveau 1 au niveau 2
		XpGrowth = 1.35, -- coût du niveau L -> L + 1 = ceil(XpBase × XpGrowth^(L − 1))
	},
	Xp = {
		PerHarvest = 1, -- toute récolte validée (joueur ou drone)
		PerfectBonus = 1, -- récolte manuelle « Parfait »
	},
	-- Plafonds du CUMUL des familiers équipés (par effet). Les plafonds globaux toutes sources (pousse, drones,
	-- chance totale) restent ceux d'UpgradeConfig.Caps.
	Caps = {
		growth = 0.30,
		value = 0.40,
		luck = 0.60,
		drones = 0.30,
		manual = 1.50,
	},
	MaxIdLength = 32,
	HatchCooldown = 3, -- secondes entre deux éclosions (une sauvegarde par éclosion)
}

return Deep.freeze(PetConfig)
