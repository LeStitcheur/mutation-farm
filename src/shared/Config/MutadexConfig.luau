--!strict
-- Mutadex (Phase 4, jalon A) : raretés d'affichage et paliers de collection. Valeurs publiques et gelées.
-- Le catalogue lui-même est DÉRIVÉ (toutes les plantes × toutes les mutations, Util/Mutadex.luau) : ajouter une
-- plante ou une mutation l'ajoute au Mutadex sans autre modification. Identifiant d'entrée stable = clé d'objet
-- « plante|mutation » (Economy.itemKey), déjà utilisée par le sac et les sauvegardes.
-- Récompenses : cosmétiques (titres, cadre, aura) et confort (places de sac) — jamais de multiplicateur de revenu.

local Deep = require(script.Parent.Parent.Util.Deep)

export type RarityDef = {
	id: string,
	order: number, -- 1 (commune) … 7 (divine) : tri et filtres
	name: string,
	color: string, -- bandeau des cartes
}

export type RewardDef = {
	kind: "cosmetic" | "bag",
	id: string?, -- cosmétique : clé de cosmetics.owned (stable)
	amount: number?, -- sac : places supplémentaires (permanentes)
	label: string,
}

export type MilestoneDef = {
	id: string, -- clé stable de mutadexRewards
	percent: number, -- palier de complétion
	rewards: { RewardDef },
}

-- Rareté d'une entrée = rareté de sa mutation (la plante ne change pas la rareté du tirage).
local rarityByMutation: { [string]: RarityDef } = {
	normal = { id = "common", order = 1, name = "Commune", color = "#B0BEC5" },
	shiny = { id = "uncommon", order = 2, name = "Peu commune", color = "#FFD23F" },
	giant = { id = "rare", order = 3, name = "Rare", color = "#81C784" },
	crystal = { id = "epic", order = 4, name = "Épique", color = "#80DEEA" },
	radioactive = { id = "legendary", order = 5, name = "Légendaire", color = "#76FF03" },
	astral = { id = "mythic", order = 6, name = "Mythique", color = "#B388FF" },
	divine = { id = "divine", order = 7, name = "Divine", color = "#FFD700" },
}

local milestones: { MilestoneDef } = {
	{
		id = "mutadex_10",
		percent = 10,
		rewards = { { kind = "cosmetic", id = "title_curious_botanist", label = "Titre « Botaniste curieux »" } },
	},
	{
		id = "mutadex_25",
		percent = 25,
		rewards = { { kind = "bag", amount = 5, label = "+5 places de sac" } },
	},
	{
		id = "mutadex_50",
		percent = 50,
		rewards = {
			{ kind = "cosmetic", id = "title_geneticist", label = "Titre « Généticien »" },
			{ kind = "cosmetic", id = "frame_golden", label = "Cadre doré" },
		},
	},
	{
		id = "mutadex_75",
		percent = 75,
		rewards = { { kind = "bag", amount = 10, label = "+10 places de sac" } },
	},
	{
		id = "mutadex_100",
		percent = 100,
		rewards = {
			{ kind = "cosmetic", id = "title_mutadex_master", label = "Titre « Maître du Mutadex »" },
			{ kind = "cosmetic", id = "aura_mutadex", label = "Aura de collection" },
		},
	},
}

local MutadexConfig = {
	RarityByMutation = rarityByMutation,
	Milestones = milestones,
	HistoryLength = 8, -- premières découvertes affichées dans l'historique
	RarestLength = 3, -- mutations les plus rares mises en avant
}

return Deep.freeze(MutadexConfig)
