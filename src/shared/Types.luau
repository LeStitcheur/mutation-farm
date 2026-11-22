--!strict
-- Contrats de données partagés serveur/client.
-- Toute modification de PlayerData (schéma persistant) exige une migration dans Util/DataSchema + un test.

export type BigNum = { m: number, e: number }

export type PlantId = string
export type MutationId = string -- "normal" | "shiny" | "giant" | "crystal" | "radioactive" | "astral" | "divine"
export type PlotId = string -- "main" | "west" | "east" | "terrace"
export type TileId = string -- "<plotId>:<index>", ex. "main:5"
export type ItemKey = string -- "<plantId>|<mutationId>", ex. "carrot|normal"
export type PrecisionTier = "perfect" | "good" | "normal"

-- Culture d'une case. Case vide = absente de farm.tiles.
export type TileState = {
	plantId: PlantId,
	plantedAt: number, -- secondes Unix (workspace:GetServerTimeNow)
	growTime: number, -- durée effective figée à la plantation (s)
	mutation: MutationId?, -- nil = normale (Phase 2)
}

export type PlayerData = {
	version: number,
	currencies: {
		coins: BigNum,
		essence: BigNum,
		primalCores: BigNum,
		rebirthTokens: number, -- obsolète (ancien contrat Phase 5), conservé tel quel ; plus utilisé
	},
	farm: {
		plots: { [PlotId]: boolean },
		tiles: { [TileId]: TileState },
	},
	seeds: {
		unlocked: { [PlantId]: boolean },
		selected: PlantId,
	},
	bag: {
		items: { [ItemKey]: number },
	},
	upgrades: {
		normal: { [string]: number },
		rebirth: { [string]: number },
		permanent: { [string]: number },
	},
	machines: {
		drones: { [string]: number },
		autoSeller: boolean, -- v6 : comptoir de vente automatique installé (machine : perdu au rebirth)
	},
	automation: { -- v6 : réglages du joueur (jamais réinitialisés) et statistiques de production automatique
		dronesEnabled: boolean,
		autoSellEnabled: boolean,
		autoSellThreshold: number, -- % de la capacité du sac (AutomationConfig.Thresholds)
		stats: AutomationStats,
	},
	progression: {
		rebirths: number, -- rebirths depuis le dernier prestige (n des seuils, R du multiplicateur)
		prestiges: number, -- prestiges réalisés (jamais réinitialisé)
		revision: number, -- +1 à chaque rebirth/prestige : invalide toute opération lancée avant le reset
		cycleCoins: BigNum, -- Coins gagnés depuis le dernier rebirth (seuil de rebirth)
		prestigeCoins: BigNum, -- Coins gagnés depuis le dernier prestige (seuil de prestige)
	},
	mutadex: { [ItemKey]: MutadexEntry }, -- Phase 4 : découvertes « plante|mutation » (jamais réinitialisé)
	mutadexRewards: { [string]: number }, -- paliers du Mutadex accordés -> horodatage Unix (une seule fois)
	cosmetics: {
		owned: { [string]: boolean },
		equipped: { [string]: string },
	},
	pets: {
		owned: { [string]: number }, -- obsolète (contrat v1 jamais écrit par le jeu), conservé tel quel depuis la v4
		equipped: { string }, -- v4 : identifiants d'INSTANCES équipées (≤ PetConfig.Slots), sans doublon
		instances: { [string]: PetInstance }, -- v4 : familiers possédés, identifiant unique « p<n> »
		nextSerial: number, -- v4 : prochain numéro d'instance (jamais réutilisé)
		hatched: number, -- v4 : œufs ouverts (révision attendue : idempotence des éclosions)
		freeEggs: { [string]: number }, -- v4 : œufs gagnés (missions, objectifs) non ouverts, par type
	},
	quests: { -- v5 : missions de la période courante (tirées une fois par le serveur, puis sauvegardées)
		daily: QuestBoard,
		weekly: QuestBoard,
		claimed: number, -- missions récupérées au total (statistique)
	},
	boosts: { [string]: number }, -- v5 : boosts temporaires actifs -> fin (horodatage serveur Unix)
	stats: {
		harvests: number,
		perfectHarvests: number,
		sells: number,
		coinsEarned: BigNum,
		playTime: number,
		totalRebirths: number, -- historique (jamais réinitialisé)
	},
	receipts: { string }, -- PurchaseId traités (FIFO borné)
	meta: {
		createdAt: number,
		lastSeen: number,
		quarantine: { QuarantineEntry }, -- données retirées par l'assainissement, conservées pour récupération
	},
}

-- Statistiques de production automatique (Phase 5, jalon C ; historique, jamais réinitialisé).
export type AutomationStats = {
	droneHarvests: number, -- récoltes faites par les drones
	autoSells: number, -- ventes du comptoir automatique
	autoSellCoins: BigNum, -- Coins rapportés par le comptoir automatique
}

-- Réglages et statistiques d'automatisation répliqués au client (panneau Automatisation).
export type ClientAutomation = {
	sellerOwned: boolean,
	dronesEnabled: boolean,
	autoSellEnabled: boolean,
	autoSellThreshold: number,
	stats: AutomationStats,
}

-- Entrée du Mutadex : première découverte (horodatage serveur Unix) et nombre de récoltes de la combinaison.
export type MutadexEntry = {
	firstAt: number,
	count: number,
}

-- Familier possédé (Phase 4, jalon B). Jamais réinitialisé.
export type PetInstance = {
	petId: string, -- espèce (PetConfig)
	level: number, -- 1 … PetConfig.Level.Max
	xp: number, -- XP vers le niveau suivant (0 au niveau maximum)
	obtainedAt: number, -- horodatage serveur Unix
}

-- Missions (Phase 4, jalon D).
export type MissionRewards = {
	coins: BigNum, -- déjà multiplié par le revenu du joueur au tirage
	eggs: number, -- Œufs des missions
	boost: string?, -- QuestConfig.Boosts
	decoration: string?, -- QuestConfig.Decorations (cosmétique)
}

export type Mission = {
	id: string, -- « d:<période>:<emplacement> » / « w:… » : unique et stable
	template: string, -- QuestConfig.Templates
	difficulty: string, -- "easy" | "medium" | "hard"
	target: number,
	progress: number, -- ≤ target
	plantId: string?, -- objectif « harvest_plant »
	claimed: boolean,
	rewards: MissionRewards,
}

export type QuestBoard = {
	period: number, -- jour UTC (quotidien) ou semaine commençant le lundi (hebdomadaire) ; −1 = jamais tirée
	missions: { Mission },
}

-- Familiers répliqués au client (panneau, aperçus des bonus).
export type ClientPets = {
	instances: { [string]: PetInstance },
	equipped: { string },
	hatched: number,
	freeEggs: { [string]: number },
}

-- Résultat d'une éclosion, envoyé APRÈS la tentative de sauvegarde (PetHatched).
export type HatchResult = {
	eggId: string,
	instanceId: string,
	petId: string,
	saved: boolean, -- false : écriture différée (stockage indisponible) ; le familier reste acquis en mémoire
}

-- Donnée inconnue ou incompatible mise de côté au chargement (jamais supprimée silencieusement).
export type QuarantineEntry = {
	path: string, -- ex. "farm.tiles.main:2"
	value: any, -- valeur d'origine si sérialisable en JSON, sinon sa représentation texte
	reason: string,
	at: number, -- secondes Unix
}

-- Vue répliquée au client (sous-ensemble de PlayerData).
export type ClientState = {
	coins: BigNum,
	essence: BigNum,
	primalCores: BigNum,
	bagItems: { [ItemKey]: number },
	bagCount: number,
	bagCapacity: number,
	seedsUnlocked: { [PlantId]: boolean },
	selectedSeed: PlantId,
	rebirths: number,
	prestiges: number,
	revision: number,
	cycleCoins: BigNum,
	prestigeCoins: BigNum,
	upgrades: { -- niveaux (panneau Améliorations)
		normal: { [string]: number },
		rebirth: { [string]: number },
		permanent: { [string]: number },
	},
	mutadex: { [ItemKey]: MutadexEntry },
	mutadexRewards: { [string]: number },
	pets: ClientPets,
	quests: { daily: QuestBoard, weekly: QuestBoard },
	boosts: { [string]: number },
	automation: ClientAutomation,
	drones: { [string]: number }, -- drones possédés par type (panneau Automatisation)
	plots: { [string]: boolean }, -- parcelles possédées (débits du panneau Automatisation)
	harvests: number,
	perfectHarvests: number,
}

export type HarvestSource = "player" | "drone"

export type HarvestResult = {
	tileId: TileId,
	plantId: PlantId,
	mutation: MutationId,
	tier: PrecisionTier,
	bonus: BigNum,
	source: HarvestSource,
	discovered: boolean, -- première récolte de cette combinaison (Mutadex)
	eventBonus: BigNum, -- Floraison dorée : Coins versés à la récolte (0 hors événement)
}

export type NotifyKind = "info" | "success" | "error"
export type Notification = { kind: NotifyKind, text: string }

export type LoadStatusKind = "loading" | "waiting_lock" | "ready" | "failed"
export type LoadStatus = { status: LoadStatusKind, message: string }

export type PlantDef = {
	id: PlantId,
	order: number,
	name: string,
	description: string,
	growTime: number,
	baseValue: number,
	unlockPrice: number,
	color: string, -- hexadécimal "#RRGGBB" (UI)
}

export type MutationDef = {
	id: MutationId,
	order: number,
	name: string,
	multiplier: number,
	essence: number,
	color: string,
}

export type MutationWeight = { id: MutationId, weight: number }

-- Type de drone (Config/DroneConfig). Nombre possédé : PlayerData.machines.drones[id].
export type DroneDef = {
	id: string,
	order: number,
	name: string,
	description: string,
	price: number, -- prix du premier exemplaire (Coins)
	priceGrowth: number, -- prix × priceGrowth par exemplaire déjà possédé
	maxOwned: number,
	interval: number, -- secondes entre deux actions
	capacity: number, -- plantes récoltées par action
	range: number, -- portée horizontale (studs) autour du point d'attente
	graceDelay: number, -- secondes après maturité avant qu'un drone vise une plante (bonus laissés au joueur)
	color: string, -- "#RRGGBB" (corps du drone)
}

return {}
