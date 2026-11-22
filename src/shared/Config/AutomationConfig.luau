--!strict
-- Automatisation avancée (Phase 5, jalon C ; docs/AUTOMATION.md) : comptoir de vente automatique, réglages et
-- statistiques. Valeurs publiques et gelées.
-- Le comptoir est une MACHINE (comme les drones) : achetée en Coins, perdue au rebirth et au prestige. Les réglages
-- (drones actifs, vente automatique, seuil) sont des préférences du joueur : jamais réinitialisés.

local Deep = require(script.Parent.Parent.Util.Deep)

local AutomationConfig = {
	AutoSeller = {
		Name = "Comptoir automatique",
		Price = 5000, -- Coins (≈ 2 min de revenu au stade Tomate ; rebirth : à racheter)
	},
	-- Seuils proposés : le sac est vendu dès qu'il contient ce pourcentage de sa capacité (100 = sac plein).
	Thresholds = { 50, 75, 100 },
	DefaultThreshold = 100,
	RequestsPerSecond = 4,
	ActionMaxLength = 16,
	SaleNoticeInterval = 20, -- « Vente automatique : +X Coins » au plus toutes les N secondes
}

return Deep.freeze(AutomationConfig)
