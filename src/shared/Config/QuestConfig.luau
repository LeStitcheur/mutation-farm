--!strict
-- Missions (Phase 4, jalon D) : catalogue de modèles (objectif, objectifs chiffrés par difficulté, éligibilité),
-- emplacements par période, récompenses proportionnelles à la difficulté, boosts, décorations. Valeurs gelées.
-- Périodes UTC : quotidienne (00:00 UTC), hebdomadaire (lundi 00:00 UTC). Les missions d'une période sont tirées
-- UNE fois par le serveur (Util/Quests, tirage déterministe par joueur et période) puis sauvegardées : changer de
-- serveur ne régénère rien. Les Coins de récompense sont multipliés par le multiplicateur de revenu du joueur au
-- moment du tirage (récompense lisible et stable pendant toute la période).

local Deep = require(script.Parent.Parent.Util.Deep)

export type Kind = "daily" | "weekly"
export type Difficulty = "easy" | "medium" | "hard"
export type Objective =
	"harvest" -- toute récolte validée (joueur ou drone)
	| "harvest_manual" -- récolte du joueur
	| "harvest_perfect" -- récolte manuelle « Parfait »
	| "harvest_plant" -- récolte d'une plante donnée (débloquée)
	| "mutation" -- récolte d'une plante mutée
	| "mutation_rare" -- récolte d'une mutation ×8 ou plus
	| "drone_harvest" -- récolte faite par un drone
	| "sell" -- vente du sac
	| "discover" -- première découverte au Mutadex
	| "hatch" -- éclosion d'un œuf
	| "rebirth" -- rebirth effectué

export type Requirement = "drone" | "unlockedPlant" | "mutadexRemaining" | "rebirthDone"

export type TemplateDef = {
	id: string, -- identifiant stable (sauvegardes)
	order: number,
	objective: Objective,
	label: string, -- %d : objectif chiffré ; %s : nom de la plante (harvest_plant)
	daily: { [Difficulty]: number },
	weekly: { [Difficulty]: number },
	requires: Requirement?,
}

export type RewardDef = {
	coins: number, -- × multiplicateur de revenu du joueur au tirage
	eggs: number, -- Œufs des missions (gratuits)
	boost: string?, -- boost temporaire activé à la récupération
	decoration: boolean, -- décoration (cosmétique) non encore possédée
}

export type BoostDef = {
	id: string,
	name: string,
	kind: "value" | "luck",
	amount: number, -- valeur : part de la valeur versée à la récolte ; chance : facteur à la plantation
	duration: number, -- secondes ajoutées à chaque activation
	description: string,
}

export type DecorationDef = { id: string, name: string }

local templates: { TemplateDef } = {
	{
		id = "harvest",
		order = 1,
		objective = "harvest",
		label = "Récolte %d plantes",
		daily = { easy = 40, medium = 120, hard = 300 },
		weekly = { medium = 800, hard = 2000 },
	},
	{
		id = "harvest_manual",
		order = 2,
		objective = "harvest_manual",
		label = "Récolte %d plantes à la main",
		daily = { easy = 25, medium = 80, hard = 200 },
		weekly = { medium = 500, hard = 1200 },
	},
	{
		id = "harvest_perfect",
		order = 3,
		objective = "harvest_perfect",
		label = "Réussis %d récoltes Parfait",
		daily = { easy = 10, medium = 30, hard = 75 },
		weekly = { medium = 200, hard = 500 },
	},
	{
		id = "harvest_plant",
		order = 4,
		objective = "harvest_plant",
		label = "Récolte %d plantes : %s",
		daily = { easy = 20, medium = 60, hard = 150 },
		weekly = { medium = 400, hard = 1000 },
		requires = "unlockedPlant",
	},
	{
		id = "mutation",
		order = 5,
		objective = "mutation",
		label = "Récolte %d plantes mutées",
		daily = { easy = 5, medium = 15, hard = 40 },
		weekly = { medium = 100, hard = 250 },
	},
	{
		id = "mutation_rare",
		order = 6,
		objective = "mutation_rare",
		label = "Récolte %d mutations ×8 ou plus",
		daily = { medium = 1, hard = 3 },
		weekly = { medium = 10, hard = 25 },
	},
	{
		id = "drone_harvest",
		order = 7,
		objective = "drone_harvest",
		label = "Laisse tes drones récolter %d plantes",
		daily = { easy = 30, medium = 100, hard = 250 },
		weekly = { medium = 600, hard = 1500 },
		requires = "drone",
	},
	{
		id = "sell",
		order = 8,
		objective = "sell",
		label = "Vends ton sac %d fois",
		daily = { easy = 5, medium = 12, hard = 25 },
		weekly = { medium = 60, hard = 150 },
	},
	{
		id = "discover",
		order = 9,
		objective = "discover",
		label = "Découvre %d combinaisons du Mutadex",
		daily = {},
		weekly = { medium = 1, hard = 3 },
		requires = "mutadexRemaining",
	},
	{
		id = "hatch",
		order = 10,
		objective = "hatch",
		label = "Ouvre %d œufs",
		daily = {},
		weekly = { medium = 2, hard = 5 },
	},
	{
		id = "rebirth",
		order = 11,
		objective = "rebirth",
		label = "Fais %d rebirth(s)",
		daily = {},
		weekly = { medium = 1, hard = 3 },
		requires = "rebirthDone",
	},
}

local byId: { [string]: TemplateDef } = {}
for _, template in templates do
	byId[template.id] = template
end

local boosts: { [string]: BoostDef } = {
	fertilizer = {
		id = "fertilizer",
		name = "Engrais",
		kind = "value",
		amount = 0.25,
		duration = 600,
		description = "+25 % de la valeur de chaque récolte, versés à la récolte",
	},
	lucky_dew = {
		id = "lucky_dew",
		name = "Rosée chanceuse",
		kind = "luck",
		amount = 1.5,
		duration = 900,
		description = "Chance de mutation ×1,5 à la plantation",
	},
}

local QuestConfig = {
	Templates = templates,
	ById = byId,
	-- Emplacements d'une période, dans l'ordre d'affichage (une difficulté par emplacement, modèles distincts).
	Slots = {
		daily = { "easy", "medium", "hard" } :: { Difficulty },
		weekly = { "medium", "hard" } :: { Difficulty },
	},
	Rewards = {
		daily = {
			easy = { coins = 1500, eggs = 0, decoration = false },
			medium = { coins = 4000, eggs = 0, boost = "fertilizer", decoration = false },
			hard = { coins = 10000, eggs = 1, decoration = false },
		} :: { [Difficulty]: RewardDef },
		weekly = {
			medium = { coins = 40000, eggs = 2, boost = "lucky_dew", decoration = false },
			hard = { coins = 100000, eggs = 3, decoration = true },
		} :: { [Difficulty]: RewardDef },
	},
	Boosts = boosts,
	-- Décorations : cosmétiques possédés (cosmetics.owned) ; leur placement sur la parcelle viendra en Phase 5.
	Decorations = {
		{ id = "deco_mutant_gnome", name = "Nain de jardin mutant" },
		{ id = "deco_crystal_scarecrow", name = "Épouvantail de cristal" },
		{ id = "deco_neon_windmill", name = "Moulin néon" },
	} :: { DecorationDef },
	MissionEgg = "mission",
	MaxBoostDuration = 3 * 3600, -- un boost se prolonge à chaque activation, sans dépasser 3 h
	MaxIdLength = 32,
	RefreshInterval = 15, -- secondes : contrôle du changement de période des joueurs connectés
	DifficultyNames = { easy = "Facile", medium = "Moyenne", hard = "Difficile" } :: { [Difficulty]: string },
}

return Deep.freeze(QuestConfig)
