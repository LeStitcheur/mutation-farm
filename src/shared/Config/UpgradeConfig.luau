--!strict
-- Améliorations (Phase 3, jalon C ; Phase 5, jalon B) : trois arbres, valeurs publiques et gelées.
--   • Arbre « coins » (améliorations normales, Phase 5) : payé en Coins, stocké dans upgrades.normal — perdu au
--     rebirth et au prestige (Resets).
--   • Arbre « essence » : payé en Mutation Essence, stocké dans upgrades.rebirth — conservé au rebirth, perdu au
--     prestige.
--   • Arbre « cores » : payé en Primal Cores, stocké dans upgrades.permanent — jamais réinitialisé.
-- Les arbres partagent les mêmes effets : ils se cumulent (produit) sous les mêmes plafonds globaux (Caps).
-- Identifiants STABLES (clés de sauvegarde) : ne jamais renommer ; retirer une amélioration = la laisser en
-- quarantaine au chargement (DataSchema), jamais la supprimer silencieusement.
-- Coût du niveau L → L + 1 : ceil(costBase × costGrowth^L). Effet au niveau L : perLevel × L (voir Upgrades.luau).
-- Plafonds globaux (Caps) : aucun cumul ne rend un cycle instantané (docs/PROGRESSION.md §4).

local Deep = require(script.Parent.Parent.Util.Deep)

export type TreeId = "coins" | "essence" | "cores"
export type Effect =
	"value" -- multiplicateur de revenu : × (1 + perLevel × L) (ventes et bonus de précision)
	| "growth" -- durée de pousse : × (1 − perLevel × L)
	| "luck" -- chance de mutation : + perLevel × L (poids non normaux)
	| "droneSpeed" -- intervalle des drones : × (1 − perLevel × L) (le délai de grâce de 5 s ne change pas)
	| "bag" -- capacité du sac : + perLevel × L places
	| "essence" -- Mutation Essence des rebirths : × (1 + perLevel × L)
	| "startDrones" -- drones récolteurs offerts au début de chaque cycle
	| "legacySeeds" -- graines (après la Carotte, dans l'ordre) conservées après rebirth et prestige

export type UpgradeDef = {
	id: string,
	tree: TreeId,
	order: number,
	name: string,
	description: string,
	effect: Effect,
	perLevel: number,
	maxLevel: number,
	costBase: number,
	costGrowth: number,
}

export type TreeDef = {
	id: TreeId,
	name: string,
	currency: "coins" | "essence" | "primalCores", -- champ de data.currencies
	storage: "normal" | "rebirth" | "permanent", -- champ de data.upgrades
	note: string,
}

local trees: { [TreeId]: TreeDef } = {
	coins = {
		id = "coins",
		name = "Coins",
		currency = "coins",
		storage = "normal",
		note = "Perdues au rebirth et au prestige",
	},
	essence = {
		id = "essence",
		name = "Mutation Essence",
		currency = "essence",
		storage = "rebirth",
		note = "Conservées au rebirth, perdues au prestige",
	},
	cores = {
		id = "cores",
		name = "Primal Cores",
		currency = "primalCores",
		storage = "permanent",
		note = "Permanentes : jamais réinitialisées",
	},
}

local list: { UpgradeDef } = {
	-- Arbre Coins (améliorations normales, Phase 5) : remis à zéro à chaque rebirth ; équilibrage docs/ECONOMY.md §13.
	{
		id = "coins_growth",
		tree = "coins",
		order = 1,
		name = "Arrosage rapide",
		description = "Vitesse de croissance : réduit la durée de pousse des nouvelles cultures.",
		effect = "growth",
		perLevel = 0.03,
		maxLevel = 10,
		costBase = 4000,
		costGrowth = 2,
	},
	{
		id = "coins_value",
		tree = "coins",
		order = 2,
		name = "Récoltes de qualité",
		description = "Valeur des récoltes : augmente la valeur des ventes et des bonus de précision.",
		effect = "value",
		perLevel = 0.05,
		maxLevel = 10,
		costBase = 2500,
		costGrowth = 1.9,
	},
	{
		id = "coins_bag",
		tree = "coins",
		order = 3,
		name = "Grand sac",
		description = "Capacité du sac : ajoute des places dans le sac.",
		effect = "bag",
		perLevel = 10,
		maxLevel = 5,
		costBase = 1500,
		costGrowth = 2.2,
	},
	-- Arbre Mutation Essence ------------------------------------------------------------------------------------
	{
		id = "essence_value",
		tree = "essence",
		order = 1,
		name = "Valeur de vente",
		description = "Augmente la valeur des ventes et des bonus de précision.",
		effect = "value",
		perLevel = 0.10,
		maxLevel = 10,
		costBase = 40,
		costGrowth = 1.55,
	},
	{
		id = "essence_growth",
		tree = "essence",
		order = 2,
		name = "Vitesse de croissance",
		description = "Réduit la durée de pousse des nouvelles cultures.",
		effect = "growth",
		perLevel = 0.04,
		maxLevel = 10,
		costBase = 50,
		costGrowth = 1.6,
	},
	{
		id = "essence_luck",
		tree = "essence",
		order = 3,
		name = "Chance de mutation",
		description = "Rend toutes les mutations plus fréquentes.",
		effect = "luck",
		perLevel = 0.10,
		maxLevel = 10,
		costBase = 60,
		costGrowth = 1.6,
	},
	{
		id = "essence_drones",
		tree = "essence",
		order = 4,
		name = "Efficacité des drones",
		description = "Les drones récoltent plus souvent (le délai de grâce de 5 s ne change pas).",
		effect = "droneSpeed",
		perLevel = 0.05,
		maxLevel = 8,
		costBase = 50,
		costGrowth = 1.55,
	},
	{
		id = "essence_bag",
		tree = "essence",
		order = 5,
		name = "Capacité du sac",
		description = "Ajoute des places dans le sac.",
		effect = "bag",
		perLevel = 10,
		maxLevel = 10,
		costBase = 30,
		costGrowth = 1.5,
	},
	-- Arbre Primal Cores ----------------------------------------------------------------------------------------
	{
		id = "superior_genetics",
		tree = "cores",
		order = 1,
		name = "Génétique supérieure",
		description = "Augmente durablement la valeur des ventes et des bonus de précision.",
		effect = "value",
		perLevel = 0.05,
		maxLevel = 10,
		costBase = 4,
		costGrowth = 1.45,
	},
	{
		id = "ancestral_growth",
		tree = "cores",
		order = 2,
		name = "Croissance ancestrale",
		description = "Réduit durablement la durée de pousse.",
		effect = "growth",
		perLevel = 0.03,
		maxLevel = 10,
		costBase = 5,
		costGrowth = 1.5,
	},
	{
		id = "primal_automation",
		tree = "cores",
		order = 3,
		name = "Automatisation primordiale",
		description = "Chaque cycle commence avec des drones récolteurs offerts.",
		effect = "startDrones",
		perLevel = 1,
		maxLevel = 2,
		costBase = 12,
		costGrowth = 2.5,
	},
	{
		id = "collector_instinct",
		tree = "cores",
		order = 4,
		name = "Instinct du collectionneur",
		description = "Augmente la Mutation Essence gagnée à chaque rebirth.",
		effect = "essence",
		perLevel = 0.10,
		maxLevel = 10,
		costBase = 4,
		costGrowth = 1.45,
	},
	{
		id = "farming_legacy",
		tree = "cores",
		order = 5,
		name = "Héritage agricole",
		description = "Garde les premières graines débloquées après chaque rebirth et prestige.",
		effect = "legacySeeds",
		perLevel = 1,
		maxLevel = 3,
		costBase = 6,
		costGrowth = 2.2,
	},
	{
		id = "mutagenic_energy",
		tree = "cores",
		order = 6,
		name = "Énergie mutagène",
		description = "Rend durablement toutes les mutations plus fréquentes.",
		effect = "luck",
		perLevel = 0.10,
		maxLevel = 5,
		costBase = 6,
		costGrowth = 1.6,
	},
}

local byId: { [string]: UpgradeDef } = {}
for _, def in list do
	assert(byId[def.id] == nil, "UpgradeConfig : identifiant dupliqué " .. def.id)
	assert(trees[def.tree] ~= nil, "UpgradeConfig : arbre inconnu " .. def.tree)
	byId[def.id] = def
end

Deep.freeze(list)
Deep.freeze(trees)
table.freeze(byId)

local UpgradeConfig = {
	Trees = trees,
	List = list,
	ById = byId,
	Caps = table.freeze({
		MaxLuck = 2.5, -- chance des améliorations (1 = base) : E(2,5) ≈ 1,99 contre 1,505 sans amélioration
		-- Plafonds TOUTES SOURCES (améliorations, familiers, événements ; Util/Bonuses) :
		MaxTotalLuck = 5, -- P(normale) ≥ 46 % ; E(5) ≈ 2,44 (rendements décroissants)
		MinGrowthFactor = 0.4, -- la pousse ne descend jamais sous 40 % de la durée de base
		MinDroneIntervalFactor = 0.5, -- l'intervalle des drones ne descend jamais sous 50 %
	}),
	MaxIdLength = 32,
}

return table.freeze(UpgradeConfig)
