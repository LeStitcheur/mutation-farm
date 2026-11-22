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
		MaxSeconds = 7200, -- production automatisée hors ligne plafonnée à 2 h (Phase 5, jalon D)
		MinSeconds = 60, -- absence plus courte : rien n'est compté (changements rapides de serveur)
		SeenRequestsPerSecond = 1, -- « écran Pendant ton absence lu » (remote OfflineReportSeen)
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
		MaxQuarantine = 100, -- entrées conservées dans meta.quarantine (FIFO)
		ShutdownTimeout = 25,
		ForceMemoryStoreInStudio = false, -- true : jamais de DataStore réel en Studio
	},
	-- Rebirth, prestige et améliorations : Config/ProgressionConfig (Phase 3).
}

return Deep.freeze(GameConfig)
