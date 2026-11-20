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
		rebirthTokens: number,
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
	},
	progression: {
		rebirths: number,
		prestiges: number,
	},
	mutadex: { [ItemKey]: number }, -- découverte -> timestamp Unix
	cosmetics: {
		owned: { [string]: boolean },
		equipped: { [string]: string },
	},
	pets: {
		owned: { [string]: number },
		equipped: { string },
	},
	stats: {
		harvests: number,
		perfectHarvests: number,
		sells: number,
		coinsEarned: BigNum,
		playTime: number,
	},
	receipts: { string }, -- PurchaseId traités (FIFO borné)
	meta: {
		createdAt: number,
		lastSeen: number,
	},
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
	harvests: number,
	perfectHarvests: number,
}

export type HarvestResult = {
	tileId: TileId,
	plantId: PlantId,
	mutation: MutationId,
	tier: PrecisionTier,
	bonus: BigNum,
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

return {}
