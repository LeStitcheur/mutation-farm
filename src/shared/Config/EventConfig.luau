--!strict
-- Événements du monde (Phase 4, jalon C) : définitions, durées, effets publics et planification. Valeurs gelées.
-- Planification DÉTERMINISTE, dérivée de l'heure UTC (Util/WorldEvents) : le temps est découpé en tranches ; chaque
-- tranche contient au plus un événement, tiré par un hachage stable (graine ci-dessous) ou planifié à heure fixe.
-- Tous les serveurs calculent donc le même calendrier sans communiquer (aucun MessagingService), et un joueur qui
-- arrive en cours d'événement en reçoit l'état exact.
-- Le facteur de chance de la Pluie mutagène est une donnée de probabilité : il reste côté serveur
-- (Server/Config/MutationOdds.Luck.MutagenicRain), plafonné par UpgradeConfig.Caps.MaxTotalLuck.

local Deep = require(script.Parent.Parent.Util.Deep)

export type EventId = "mutagenic_rain" | "golden_bloom"

export type EventDef = {
	id: EventId,
	order: number,
	name: string,
	summary: string, -- bandeau (court)
	announceStart: string,
	announceEnd: string,
	duration: number, -- secondes
	weight: number, -- poids parmi les événements aléatoires
	luck: boolean, -- Pluie mutagène : chance de mutation des plantes SEMÉES pendant l'événement
	valueBonus: number, -- Floraison dorée : + part de la valeur de chaque plante RÉCOLTÉE pendant l'événement
	color: string,
	visual: "rain" | "bloom",
}

export type FixedSlot = { hour: number, eventId: EventId } -- tranche commençant à hour:00 UTC

local list: { EventDef } = {
	{
		id = "mutagenic_rain",
		order = 1,
		name = "Pluie mutagène",
		summary = "Chance de mutation augmentée pour les plantes semées",
		announceStart = "Pluie mutagène ! Pendant 5 min, les plantes semées ont bien plus de chances de muter.",
		announceEnd = "La Pluie mutagène est terminée.",
		duration = 300,
		weight = 60,
		luck = true,
		valueBonus = 0,
		color = "#B388FF",
		visual = "rain",
	},
	{
		id = "golden_bloom",
		order = 2,
		name = "Floraison dorée",
		summary = "+50 % de la valeur de chaque récolte, versés à la récolte",
		announceStart = "Floraison dorée ! Pendant 10 min, chaque récolte rapporte +50 % de sa valeur, tout de suite.",
		announceEnd = "La Floraison dorée est terminée.",
		duration = 600,
		weight = 40,
		luck = false,
		valueBonus = 0.5,
		color = "#FFD54F",
		visual = "bloom",
	},
}

local byId: { [string]: EventDef } = {}
for _, def in list do
	byId[def.id] = def
end

local EventConfig = {
	List = list,
	ById = byId,
	Schedule = {
		SlotLength = 1800, -- secondes : une tranche de 30 min (UTC) contient au plus un événement
		Chance = 0.5, -- probabilité qu'une tranche non planifiée contienne un événement (≈ 1 par heure)
		MinGap = 300, -- secondes : écart minimal entre la fin d'un événement et le début du suivant
		Seed = 20261121, -- graine du calendrier (la changer redistribue les événements aléatoires)
		Fixed = { -- rendez-vous quotidiens, en début de tranche (+ MinGap / 2)
			{ hour = 12, eventId = "golden_bloom" },
			{ hour = 20, eventId = "golden_bloom" },
		} :: { FixedSlot },
	},
	MaxForcedDuration = 3600, -- outillage Studio (DevService) : durée maximale d'un événement forcé
}

return Deep.freeze(EventConfig)
