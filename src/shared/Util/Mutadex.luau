--!strict
-- Règles PURES du Mutadex (Phase 4, jalon A ; testées en Lune) : catalogue dérivé (plantes × mutations),
-- enregistrement des récoltes, progression, paliers accordés une seule fois, historique, recherche.
-- `record` est appelé par HarvestRules.apply DANS le mutateur de récolte : une culture n'est comptée qu'une fois
-- (joueur ou drone) et une combinaison n'est « découverte » qu'une fois. Le Mutadex n'est jamais réinitialisé.

local Types = require(script.Parent.Parent.Types)
local MutadexConfig = require(script.Parent.Parent.Config.MutadexConfig)
local MutationConfig = require(script.Parent.Parent.Config.MutationConfig)
local PlantConfig = require(script.Parent.Parent.Config.PlantConfig)

type PlayerData = Types.PlayerData
type MutadexEntry = Types.MutadexEntry
type RarityDef = MutadexConfig.RarityDef
type MilestoneDef = MutadexConfig.MilestoneDef

export type CatalogEntry = {
	id: string, -- clé stable « plante|mutation » (= Economy.itemKey)
	plantId: string,
	mutationId: string,
	plantName: string,
	mutationName: string,
	name: string,
	rarity: RarityDef,
	multiplier: number,
	plantOrder: number,
}

export type Progress = {
	discovered: number,
	total: number,
	percent: number, -- 0–100
	harvests: number, -- plantes récoltées (stats.harvests)
}

local catalog: { CatalogEntry } = {}
local byId: { [string]: CatalogEntry } = {}

do
	local mutations = table.clone(MutationConfig.List)
	table.sort(mutations, function(a, b)
		return a.order < b.order
	end)
	for _, plant in PlantConfig.List do
		for _, mutation in mutations do
			local id = plant.id .. "|" .. mutation.id
			local rarity = MutadexConfig.RarityByMutation[mutation.id]
			assert(rarity, "MutadexConfig : rareté manquante pour la mutation " .. mutation.id)
			local entry: CatalogEntry = {
				id = id,
				plantId = plant.id,
				mutationId = mutation.id,
				plantName = plant.name,
				mutationName = mutation.name,
				name = if mutation.id == MutationConfig.NORMAL
					then plant.name
					else plant.name .. " · " .. mutation.name,
				rarity = rarity,
				multiplier = mutation.multiplier,
				plantOrder = plant.order,
			}
			table.freeze(entry)
			table.insert(catalog, entry)
			byId[id] = entry
		end
	end
	table.freeze(catalog)
	table.freeze(byId)
end

local Mutadex = {}

function Mutadex.catalog(): { CatalogEntry }
	return catalog
end

function Mutadex.total(): number
	return #catalog
end

function Mutadex.entryId(plantId: string, mutationId: string?): string
	return plantId .. "|" .. (mutationId or MutationConfig.NORMAL)
end

function Mutadex.get(id: string): CatalogEntry?
	return byId[id]
end

-- Entrée enregistrée valide (table { firstAt, count } de nombres finis), sinon nil.
function Mutadex.entry(data: PlayerData, id: string): MutadexEntry?
	local mutadex = (data :: any).mutadex
	local value = if type(mutadex) == "table" then mutadex[id] else nil
	if type(value) ~= "table" or type(value.firstAt) ~= "number" or type(value.count) ~= "number" then
		return nil
	end
	return value
end

function Mutadex.isDiscovered(data: PlayerData, id: string): boolean
	return Mutadex.entry(data, id) ~= nil
end

-- Compte une récolte de `plantId` avec la mutation réelle `mutationId`. Retourne true pour une PREMIÈRE découverte.
-- Une combinaison hors catalogue (configuration retirée) est ignorée.
function Mutadex.record(data: PlayerData, plantId: string, mutationId: string, now: number): boolean
	local id = Mutadex.entryId(plantId, mutationId)
	if not byId[id] then
		return false
	end
	local existing = Mutadex.entry(data, id)
	if existing then
		existing.count += 1
		return false
	end
	data.mutadex[id] = { firstAt = now, count = 1 }
	return true
end

function Mutadex.discoveredCount(data: PlayerData): number
	local count = 0
	for _, entry in catalog do
		if Mutadex.isDiscovered(data, entry.id) then
			count += 1
		end
	end
	return count
end

function Mutadex.progress(data: PlayerData): Progress
	local discovered = Mutadex.discoveredCount(data)
	local stats = (data :: any).stats
	return {
		discovered = discovered,
		total = #catalog,
		percent = 100 * discovered / #catalog,
		harvests = if type(stats) == "table" and type(stats.harvests) == "number" then stats.harvests else 0,
	}
end

-- Découvertes nécessaires pour un palier : ceil(total × pourcentage / 100).
function Mutadex.requirement(milestone: MilestoneDef): number
	return math.ceil(#catalog * milestone.percent / 100 - 1e-9)
end

function Mutadex.isClaimed(data: PlayerData, milestone: MilestoneDef): boolean
	local rewards = (data :: any).mutadexRewards
	return type(rewards) == "table" and type(rewards[milestone.id]) == "number"
end

-- Accorde les paliers atteints et pas encore accordés (une seule fois chacun). Retourne les paliers accordés.
function Mutadex.claimMilestones(data: PlayerData, now: number): { MilestoneDef }
	local discovered = Mutadex.discoveredCount(data)
	local granted: { MilestoneDef } = {}
	for _, milestone in MutadexConfig.Milestones do
		if not Mutadex.isClaimed(data, milestone) and discovered >= Mutadex.requirement(milestone) then
			data.mutadexRewards[milestone.id] = now
			for _, reward in milestone.rewards do
				if reward.kind == "cosmetic" and reward.id then
					data.cosmetics.owned[reward.id] = true
				end
			end
			table.insert(granted, milestone)
		end
	end
	return granted
end

-- Places de sac des paliers accordés (récompense de confort permanente).
function Mutadex.bagBonus(data: PlayerData): number
	local bonus = 0
	for _, milestone in MutadexConfig.Milestones do
		if Mutadex.isClaimed(data, milestone) then
			for _, reward in milestone.rewards do
				if reward.kind == "bag" and reward.amount then
					bonus += reward.amount
				end
			end
		end
	end
	return bonus
end

-- Prochain palier non accordé (nil quand tout est accordé).
function Mutadex.nextMilestone(data: PlayerData): MilestoneDef?
	for _, milestone in MutadexConfig.Milestones do
		if not Mutadex.isClaimed(data, milestone) then
			return milestone
		end
	end
	return nil
end

type Discovery = { entry: CatalogEntry, firstAt: number }

local function discoveries(data: PlayerData): { Discovery }
	local list: { Discovery } = {}
	for _, entry in catalog do
		local record = Mutadex.entry(data, entry.id)
		if record then
			table.insert(list, { entry = entry, firstAt = record.firstAt })
		end
	end
	return list
end

-- Premières découvertes, de la plus récente à la plus ancienne.
function Mutadex.history(data: PlayerData, limit: number): { Discovery }
	local list = discoveries(data)
	table.sort(list, function(a, b)
		if a.firstAt ~= b.firstAt then
			return a.firstAt > b.firstAt
		end
		return a.entry.id < b.entry.id
	end)
	local result: { Discovery } = {}
	for index = 1, math.min(limit, #list) do
		table.insert(result, list[index])
	end
	return result
end

-- Découvertes les plus rares (rareté puis rang de la plante décroissants, puis la plus ancienne).
function Mutadex.rarest(data: PlayerData, limit: number): { CatalogEntry }
	local list = discoveries(data)
	table.sort(list, function(a, b)
		if a.entry.rarity.order ~= b.entry.rarity.order then
			return a.entry.rarity.order > b.entry.rarity.order
		end
		if a.entry.plantOrder ~= b.entry.plantOrder then
			return a.entry.plantOrder > b.entry.plantOrder
		end
		return a.firstAt < b.firstAt
	end)
	local result: { CatalogEntry } = {}
	for index = 1, math.min(limit, #list) do
		table.insert(result, list[index].entry)
	end
	return result
end

-- Minuscules sans accents (recherche tolérante : « geante » trouve « Géante »).
local ACCENTS: { [string]: string } = {
	["à"] = "a",
	["â"] = "a",
	["ä"] = "a",
	["À"] = "a",
	["Â"] = "a",
	["é"] = "e",
	["è"] = "e",
	["ê"] = "e",
	["ë"] = "e",
	["É"] = "e",
	["È"] = "e",
	["Ê"] = "e",
	["î"] = "i",
	["ï"] = "i",
	["Î"] = "i",
	["ô"] = "o",
	["ö"] = "o",
	["Ô"] = "o",
	["ù"] = "u",
	["û"] = "u",
	["ü"] = "u",
	["Û"] = "u",
	["ç"] = "c",
	["Ç"] = "c",
}

function Mutadex.normalize(text: string): string
	local folded = string.gsub(text, "\195[\128-\191]", function(char: string): string
		return ACCENTS[char] or char
	end)
	return string.lower(folded)
end

-- Filtres du panneau : plante (nil = toutes), rareté (nil = toutes), recherche par nom. Le nom d'une entrée non
-- découverte reste caché : la recherche ne la révèle pas.
function Mutadex.matches(
	data: PlayerData,
	entry: CatalogEntry,
	plantId: string?,
	rarityId: string?,
	query: string?
): boolean
	if plantId and entry.plantId ~= plantId then
		return false
	end
	if rarityId and entry.rarity.id ~= rarityId then
		return false
	end
	if query and query ~= "" then
		if not Mutadex.isDiscovered(data, entry.id) then
			return false
		end
		return string.find(Mutadex.normalize(entry.name), Mutadex.normalize(query), 1, true) ~= nil
	end
	return true
end

return table.freeze(Mutadex)
