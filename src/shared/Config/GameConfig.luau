--!strict
-- Réglages globaux publics (répliqués). Les probabilités secrètes vivent dans ServerScriptService.Server.Config.

local Deep = require(script.Parent.Parent.Util.Deep)

local GameConfig = {
	StarterSeed = "carrot",

	Harvest = {
		PromptDistance = 9, -- distance d'activation de l'invite client (studs)
		MaxDistance = 20, -- distance maximale acceptée par le serveur (studs)
		PerfectWindow = 1.5, -- secondes après maturité
		GoodWindow = 5,
		PerfectBonus = 0.5, -- fraction de la valeur de base versée en Coins immédiats
		GoodBonus = 0.2,
		RequestsPerSecond = 8,
		BagFullNoticeInterval = 2,
	},

	Bag = {
		BaseCapacity = 40,
	},

	Mutations = {
		NotifyMinMultiplier = 8, -- notification à la récolte à partir de Cristallisée (×8)
	},

	-- Réglages globaux des drones (réglages par type : Config/DroneConfig).
	Drones = {
		TickInterval = 0.25, -- cadence de l'unique boucle serveur des drones (s)
		BagFullNoticeInterval = 30, -- « Tes drones attendent : sac plein » au plus toutes les N secondes
		BuyRequestsPerSecond = 2,
	},

	Sell = {
		Cooldown = 0.5,
	},

	Seeds = {
		RequestsPerSecond = 4,
	},

	Offline = {
		MaxSeconds = 7200, -- production automatisée hors ligne plafonnée à 2 h (Phase 4)
	},

	Sync = {
		Interval = 0.1, -- réplication d'état coalescée (s)
	},

	Data = {
		StoreName = "MutationFarm_PlayerData_v1",
		KeyPrefix = "player_",
		RecordFormat = 1,
		AutosaveInterval = 45,
		LockTimeout = 120, -- verrou considéré périmé sans heartbeat depuis N secondes
		LoadRetryInterval = 5,
		LoadMaxWait = 130,
		SaveRetries = 3,
		MaxReceipts = 200,
		ShutdownTimeout = 25,
		ForceMemoryStoreInStudio = false, -- true : jamais de DataStore réel en Studio
	},

	-- Formules contractuelles Phase 5 (voir docs/ECONOMY.md §4).
	Rebirth = {
		BaseCost = 5e7,
		CostGrowth = 6,
		MultiplierBase = 1.5,
		TokensPerRebirth = 1,
	},

	Prestige = {
		BaseRebirths = 8,
		RebirthsPerPrestige = 4,
		CoreBase = 2,
		CoreGrowth = 1.35,
	},
}

return Deep.freeze(GameConfig)
