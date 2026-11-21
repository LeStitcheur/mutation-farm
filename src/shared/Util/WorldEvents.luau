--!strict
-- Règles PURES des événements du monde (Phase 4, jalon C ; testées en Lune). Calendrier déterministe dérivé de
-- l'heure UTC : tranches de EventConfig.Schedule.SlotLength secondes, au plus un événement par tranche (planifié à
-- heure fixe, sinon tiré par un hachage 32 bits stable de la tranche et de la graine). L'événement d'une tranche
-- commence au moins MinGap / 2 après son début et finit au moins MinGap / 2 avant sa fin : deux événements
-- consécutifs sont toujours séparés d'au moins MinGap, et un seul est actif à la fois.
-- Un événement FORCÉ (outillage Studio) est prioritaire ; un événement planifié qui le chevauche (± MinGap) est
-- annulé. Aucune donnée joueur : rien n'est sauvegardé, aucun bonus ne survit à la fin de la fenêtre.

local EventConfig = require(script.Parent.Parent.Config.EventConfig)

type EventDef = EventConfig.EventDef

export type Window = {
	id: string,
	startsAt: number, -- secondes Unix (horloge serveur)
	endsAt: number,
	forced: boolean,
}

local TWO_32 = 4294967296
local DAY = 86400

local WorldEvents = {}

-- Produit modulo 2^32 sans dépasser la précision des nombres flottants (moitiés de 16 bits).
local function mul32(a: number, b: number): number
	local aHi, aLo = bit32.rshift(a, 16), bit32.band(a, 0xFFFF)
	local bHi, bLo = bit32.rshift(b, 16), bit32.band(b, 0xFFFF)
	local high = (aHi * bLo + aLo * bHi) % 0x10000
	return (high * 0x10000 + aLo * bLo) % TWO_32
end

local function hash32(value: number): number
	local x = value % TWO_32
	x = bit32.bxor(x, bit32.rshift(x, 16))
	x = mul32(x, 0x7FEB352D)
	x = bit32.bxor(x, bit32.rshift(x, 15))
	x = mul32(x, 0x846CA68B)
	x = bit32.bxor(x, bit32.rshift(x, 16))
	return x
end

-- Aléa stable ∈ [0, 1[ d'une tranche pour un usage donné (`salt`).
function WorldEvents.random(slot: number, salt: number): number
	local seeded = hash32(slot + EventConfig.Schedule.Seed)
	return hash32(bit32.bxor(seeded, hash32(salt * 7919 + 13))) / TWO_32
end

function WorldEvents.get(eventId: string): EventDef?
	return EventConfig.ById[eventId]
end

function WorldEvents.slotOf(t: number): number
	return math.floor(t / EventConfig.Schedule.SlotLength)
end

local function window(def: EventDef, slotStart: number, offset: number): Window
	local startsAt = slotStart + offset
	return { id = def.id, startsAt = startsAt, endsAt = startsAt + def.duration, forced = false }
end

-- Événement d'une tranche (nil si aucun) : planifié à heure fixe, sinon tirage contrôlé.
function WorldEvents.scheduled(slot: number): Window?
	local schedule = EventConfig.Schedule
	local length = schedule.SlotLength
	local half = schedule.MinGap / 2
	local slotStart = slot * length
	local secondOfDay = slotStart % DAY
	for _, fixed in schedule.Fixed do
		if fixed.hour * 3600 == secondOfDay then
			local def = EventConfig.ById[fixed.eventId]
			return if def then window(def, slotStart, half) else nil
		end
	end
	if WorldEvents.random(slot, 1) >= schedule.Chance then
		return nil
	end
	local total = 0
	for _, def in EventConfig.List do
		total += def.weight
	end
	local target = WorldEvents.random(slot, 2) * total
	local chosen = EventConfig.List[#EventConfig.List]
	local accumulated = 0
	for _, def in EventConfig.List do
		accumulated += def.weight
		if target < accumulated then
			chosen = def
			break
		end
	end
	local room = math.max(0, length - chosen.duration - 2 * half)
	return window(chosen, slotStart, half + math.floor(WorldEvents.random(slot, 3) * room))
end

local function overlaps(a: Window, b: Window, margin: number): boolean
	return a.startsAt < b.endsAt + margin and b.startsAt < a.endsAt + margin
end

-- Événement actif à l'instant `t` (horloge serveur), compte tenu d'un éventuel événement forcé.
function WorldEvents.activeAt(t: number, forced: Window?): Window?
	if forced and forced.startsAt <= t and t < forced.endsAt then
		return forced
	end
	local planned = WorldEvents.scheduled(WorldEvents.slotOf(t))
	if not planned or t < planned.startsAt or t >= planned.endsAt then
		return nil
	end
	if forced and overlaps(planned, forced, EventConfig.Schedule.MinGap) then
		return nil -- un seul événement à la fois, écart minimal respecté autour de l'événement forcé
	end
	return planned
end

-- Prochain événement planifié commençant après `t` (au plus `maxSlots` tranches plus loin).
function WorldEvents.nextAfter(t: number, maxSlots: number?): Window?
	local slot = WorldEvents.slotOf(t)
	for index = slot, slot + (maxSlots or 96) do
		local planned = WorldEvents.scheduled(index)
		if planned and planned.startsAt > t then
			return planned
		end
	end
	return nil
end

-- Événement forcé (outillage Studio) commençant à `now`, durée bornée.
function WorldEvents.force(eventId: string, now: number, duration: number?): Window?
	local def = EventConfig.ById[eventId]
	if not def then
		return nil
	end
	local length = math.clamp(duration or def.duration, 1, EventConfig.MaxForcedDuration)
	local forced: Window = { id = def.id :: string, startsAt = now, endsAt = now + length, forced = true }
	return forced
end

-- Bonus de valeur à la récolte (Floraison dorée) de l'événement actif : 0 sans événement.
function WorldEvents.valueBonus(active: Window?): number
	local def = if active then EventConfig.ById[active.id] else nil
	return if def then def.valueBonus else 0
end

-- Facteur de chance de l'événement actif (Pluie mutagène) : `rainFactor` vient de la configuration serveur.
function WorldEvents.luckFactor(active: Window?, rainFactor: number): number
	local def = if active then EventConfig.ById[active.id] else nil
	return if def and def.luck then math.max(1, rainFactor) else 1
end

-- Secondes restantes (0 si terminé).
function WorldEvents.remaining(active: Window?, now: number): number
	return if active then math.max(0, active.endsAt - now) else 0
end

return table.freeze(WorldEvents)
