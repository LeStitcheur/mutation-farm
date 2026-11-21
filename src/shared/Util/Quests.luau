--!strict
-- Règles PURES des missions (Phase 4, jalon D ; testées en Lune) : périodes UTC (jour, semaine commençant le lundi),
-- tirage déterministe par joueur et période parmi les modèles éligibles, progression enregistrée DANS le mutateur
-- de l'action (récolte, vente, éclosion, rebirth), récupération atomique et unique, boosts temporaires.
-- Les missions d'une période sont tirées une seule fois puis sauvegardées : un changement de serveur ou une
-- reconnexion ne régénère rien (refresh ne tire que si la période sauvegardée n'est pas la période courante).
-- Le client n'envoie que l'identifiant de la mission à récupérer : jamais une progression ni une récompense.

local Types = require(script.Parent.Parent.Types)
local QuestConfig = require(script.Parent.Parent.Config.QuestConfig)
local MutationConfig = require(script.Parent.Parent.Config.MutationConfig)
local PlantConfig = require(script.Parent.Parent.Config.PlantConfig)
local BigNum = require(script.Parent.BigNum)
local Hash = require(script.Parent.Hash)
local Mutadex = require(script.Parent.Mutadex)
local Pets = require(script.Parent.Pets)
local ProgressionMath = require(script.Parent.ProgressionMath)

type PlayerData = Types.PlayerData
type Mission = Types.Mission
type QuestBoard = Types.QuestBoard
type Kind = QuestConfig.Kind
type Difficulty = QuestConfig.Difficulty
type TemplateDef = QuestConfig.TemplateDef

export type ClaimFailure = "unknown_mission" | "expired" | "not_completed" | "already_claimed"

export type ClaimOutcome = {
	mission: Mission,
	coins: Types.BigNum,
	eggs: number, -- œufs réellement ajoutés à la réserve
	eggsOverflow: number, -- œufs non ajoutés (réserve pleine) : signalés au joueur
	boost: string?,
	decoration: string?,
}

-- Récolte validée, vue par les missions.
export type HarvestFacts = {
	plantId: string,
	mutation: string,
	tier: Types.PrecisionTier,
	source: Types.HarvestSource,
	discovered: boolean,
}

local DAY = 86400
local KINDS: { Kind } = { "daily", "weekly" }
local KIND_CODE: { [Kind]: number } = { daily = 1, weekly = 2 }
local RARE_MULTIPLIER = 8

local Quests = {}

-- Période d'un instant : jour UTC (00:00 UTC) ou semaine commençant le lundi 00:00 UTC (le 1er janvier 1970 était
-- un jeudi : décalage de 3 jours).
function Quests.periodOf(kind: Kind, t: number): number
	local day = math.floor(t / DAY)
	return if kind == "daily" then day else (day + 3) // 7
end

-- Instant de fin (exclu) d'une période.
function Quests.periodEnd(kind: Kind, period: number): number
	return if kind == "daily" then (period + 1) * DAY else ((period + 1) * 7 - 3) * DAY
end

local function boardOf(data: any, kind: Kind): QuestBoard?
	local quests = if type(data) == "table" then data.quests else nil
	local board = if type(quests) == "table" then quests[kind] else nil
	return if type(board) == "table" and type(board.missions) == "table" then board else nil
end

function Quests.board(data: PlayerData, kind: Kind): QuestBoard?
	return boardOf(data, kind)
end

function Quests.isCurrent(data: PlayerData, kind: Kind, now: number): boolean
	local board = boardOf(data, kind)
	return board ~= nil and board.period == Quests.periodOf(kind, now)
end

function Quests.isComplete(mission: Mission): boolean
	return mission.progress >= mission.target
end

-- Texte d'une mission (« Récolte 60 plantes : Tomate »).
function Quests.describe(mission: Mission): string
	local template = QuestConfig.ById[mission.template]
	if not template then
		return "Mission inconnue"
	end
	if template.objective == "harvest_plant" then
		local plant = if mission.plantId then PlantConfig.get(mission.plantId) else nil
		return string.format(template.label, mission.target, if plant then plant.name else "?")
	end
	return string.format(template.label, mission.target)
end

-- Plantes débloquées, dans l'ordre de progression (candidates de « harvest_plant »).
local function unlockedPlants(data: PlayerData): { string }
	local list: { string } = {}
	for _, plant in PlantConfig.List do
		if data.seeds.unlocked[plant.id] then
			table.insert(list, plant.id)
		end
	end
	return list
end

-- Éligibilité d'un modèle pour un joueur (objectif atteignable avec ce qu'il possède).
function Quests.eligible(data: PlayerData, template: TemplateDef, kind: Kind, difficulty: Difficulty): boolean
	local target = (template :: any)[kind][difficulty]
	if type(target) ~= "number" then
		return false
	end
	local requirement = template.requires
	if requirement == "drone" then
		local count = 0
		for _, owned in data.machines.drones do
			count += if type(owned) == "number" then owned else 0
		end
		return count > 0
	elseif requirement == "unlockedPlant" then
		return #unlockedPlants(data) > 0
	elseif requirement == "mutadexRemaining" then
		return Mutadex.total() - Mutadex.discoveredCount(data) >= target
	elseif requirement == "rebirthDone" then
		return data.stats.totalRebirths >= 1
	end
	return true
end

local function pickDecoration(data: PlayerData, seed: { number }): string?
	local decorations = QuestConfig.Decorations
	local start = math.floor(Hash.unit(seed) * #decorations)
	for offset = 0, #decorations - 1 do
		local decoration = decorations[(start + offset) % #decorations + 1]
		if not data.cosmetics.owned[decoration.id] then
			return decoration.id
		end
	end
	return nil
end

-- Tirage des missions d'une période (déterministe : même joueur, même période, même état → mêmes missions).
function Quests.generate(data: PlayerData, kind: Kind, period: number, userId: number): { Mission }
	local missions: { Mission } = {}
	local used: { [string]: boolean } = {}
	local income = ProgressionMath.incomeMultiplier(data)
	local prefix = if kind == "daily" then "d" else "w"
	local code = KIND_CODE[kind]
	for slot, difficulty in QuestConfig.Slots[kind] do
		local candidates: { TemplateDef } = {}
		for _, template in QuestConfig.Templates do
			if not used[template.id] and Quests.eligible(data, template, kind, difficulty) then
				table.insert(candidates, template)
			end
		end
		if #candidates > 0 then
			local index = math.floor(Hash.unit({ userId, period, code, slot }) * #candidates) + 1
			local template = candidates[math.min(index, #candidates)]
			used[template.id] = true
			local reward = (QuestConfig.Rewards :: any)[kind][difficulty] :: QuestConfig.RewardDef
			local plantId: string? = nil
			if template.objective == "harvest_plant" then
				local plants = unlockedPlants(data)
				plantId = plants[math.floor(Hash.unit({ userId, period, code, slot, 7 }) * #plants) + 1]
			end
			local decoration = if reward.decoration
				then pickDecoration(data, { userId, period, code, slot, 11 })
				else nil
			table.insert(missions, {
				id = string.format("%s:%d:%d", prefix, period, slot),
				template = template.id,
				difficulty = difficulty,
				target = (template :: any)[kind][difficulty] :: number,
				progress = 0,
				plantId = plantId,
				claimed = false,
				rewards = {
					coins = BigNum.fromNumber(math.floor(reward.coins * income)),
					-- Décorations toutes possédées : un œuf de plus à la place.
					eggs = reward.eggs + (if reward.decoration and not decoration then 1 else 0),
					boost = reward.boost,
					decoration = decoration,
				},
			})
		end
	end
	return missions
end

function Quests.needsRefresh(data: PlayerData, now: number): boolean
	for _, kind: Kind in KINDS do
		if not Quests.isCurrent(data, kind, now) then
			return true
		end
	end
	return false
end

-- Tire les missions des périodes échues (et seulement elles). Retourne les types renouvelés.
function Quests.refresh(data: PlayerData, userId: number, now: number): { Kind }
	local renewed: { Kind } = {}
	for _, kind: Kind in KINDS do
		if not Quests.isCurrent(data, kind, now) then
			local period = Quests.periodOf(kind, now)
			data.quests[kind] = { period = period, missions = Quests.generate(data, kind, period, userId) }
			table.insert(renewed, kind)
		end
	end
	return renewed
end

-- Ajoute `amount` aux missions courantes de l'objectif donné (plante précise pour « harvest_plant »).
-- Retourne les missions qui viennent d'être terminées. Une période échue ne progresse plus.
function Quests.record(data: PlayerData, objective: string, amount: number, now: number, plantId: string?): { Mission }
	local completed: { Mission } = {}
	if amount <= 0 then
		return completed
	end
	for _, kind: Kind in KINDS do
		local board = boardOf(data, kind)
		if board and board.period == Quests.periodOf(kind, now) then
			for _, mission in board.missions do
				local template = QuestConfig.ById[mission.template]
				local matches = template ~= nil
					and template.objective == objective
					and (objective ~= "harvest_plant" or mission.plantId == plantId)
				if matches and not mission.claimed and mission.progress < mission.target then
					mission.progress = math.min(mission.target, mission.progress + amount)
					if mission.progress >= mission.target then
						table.insert(completed, mission)
					end
				end
			end
		end
	end
	return completed
end

-- Progression d'une récolte validée (appelée par HarvestRules dans le mutateur de récolte).
function Quests.recordHarvest(data: PlayerData, facts: HarvestFacts, now: number): { Mission }
	local completed: { Mission } = {}
	local function add(objective: string, plantId: string?)
		for _, mission in Quests.record(data, objective, 1, now, plantId) do
			table.insert(completed, mission)
		end
	end
	add("harvest")
	add("harvest_plant", facts.plantId)
	if facts.source == "player" then
		add("harvest_manual")
		if facts.tier == "perfect" then
			add("harvest_perfect")
		end
	else
		add("drone_harvest")
	end
	local mutation = MutationConfig.get(facts.mutation)
	if mutation and facts.mutation ~= MutationConfig.NORMAL then
		add("mutation")
		if mutation.multiplier >= RARE_MULTIPLIER then
			add("mutation_rare")
		end
	end
	if facts.discovered then
		add("discover")
	end
	return completed
end

function Quests.find(data: PlayerData, missionId: string): (Mission?, Kind?)
	for _, kind: Kind in KINDS do
		local board = boardOf(data, kind)
		if board then
			for _, mission in board.missions do
				if mission.id == missionId then
					return mission, kind
				end
			end
		end
	end
	return nil, nil
end

-- Active (ou prolonge) un boost, sans dépasser QuestConfig.MaxBoostDuration restantes.
function Quests.activateBoost(data: PlayerData, boostId: string, now: number): boolean
	local def = QuestConfig.Boosts[boostId]
	if not def then
		return false
	end
	local current = data.boosts[boostId]
	local base = if type(current) == "number" and current > now then current else now
	data.boosts[boostId] = math.min(base + def.duration, now + QuestConfig.MaxBoostDuration)
	return true
end

-- Récupération ATOMIQUE et unique : mission courante terminée et non récupérée → récompenses accordées.
function Quests.claim(data: PlayerData, missionId: string, now: number): (ClaimOutcome?, ClaimFailure?)
	local mission: Mission?, kind: Kind? = Quests.find(data, missionId)
	if not mission or not kind then
		return nil, "unknown_mission"
	end
	if not Quests.isCurrent(data, kind, now) then
		return nil, "expired"
	end
	if mission.claimed then
		return nil, "already_claimed"
	end
	if not Quests.isComplete(mission) then
		return nil, "not_completed"
	end
	mission.claimed = true
	data.quests.claimed += 1
	local rewards = mission.rewards
	local coins = BigNum.sanitize(rewards.coins)
	if not BigNum.isZero(coins) then
		data.currencies.coins = BigNum.add(data.currencies.coins, coins)
		ProgressionMath.recordEarnings(data, coins)
	end
	local eggs = if rewards.eggs > 0 then Pets.addFreeEggs(data, QuestConfig.MissionEgg, rewards.eggs) else 0
	if rewards.boost then
		Quests.activateBoost(data, rewards.boost, now)
	end
	if rewards.decoration then
		data.cosmetics.owned[rewards.decoration] = true
	end
	return {
		mission = mission,
		coins = coins,
		eggs = eggs,
		eggsOverflow = math.max(0, rewards.eggs - eggs),
		boost = rewards.boost,
		decoration = rewards.decoration,
	},
		nil
end

-- Secondes restantes d'un boost (0 s'il est inactif).
function Quests.boostRemaining(data: PlayerData, boostId: string, now: number): number
	local boosts = (data :: any).boosts
	local expiresAt = if type(boosts) == "table" then boosts[boostId] else nil
	return if type(expiresAt) == "number" then math.max(0, expiresAt - now) else 0
end

-- Part de valeur versée à la récolte par les boosts actifs (Engrais).
function Quests.valueBoost(data: PlayerData, now: number): number
	local total = 0
	for id, def in QuestConfig.Boosts do
		if def.kind == "value" and Quests.boostRemaining(data, id, now) > 0 then
			total += def.amount
		end
	end
	return total
end

-- Facteur de chance à la plantation des boosts actifs (Rosée chanceuse), plafonné ensuite par Bonuses.luck.
function Quests.luckBoost(data: PlayerData, now: number): number
	local factor = 1
	for id, def in QuestConfig.Boosts do
		if def.kind == "luck" and Quests.boostRemaining(data, id, now) > 0 then
			factor *= def.amount
		end
	end
	return factor
end

-- Missions terminées et non récupérées de la période courante (pastille du menu).
function Quests.claimable(data: PlayerData, now: number): number
	local count = 0
	for _, kind: Kind in KINDS do
		local board = boardOf(data, kind)
		if board and board.period == Quests.periodOf(kind, now) then
			for _, mission in board.missions do
				if not mission.claimed and mission.progress >= mission.target then
					count += 1
				end
			end
		end
	end
	return count
end

-- Texte des récompenses d'une mission (« 4 000 Coins · Engrais 10 min »).
function Quests.rewardText(mission: Mission, formatCoins: (Types.BigNum) -> string): string
	local parts: { string } = {}
	local rewards = mission.rewards
	table.insert(parts, formatCoins(BigNum.sanitize(rewards.coins)) .. " Coins")
	if rewards.eggs > 0 then
		table.insert(parts, string.format("%d Œuf%s des missions", rewards.eggs, if rewards.eggs > 1 then "s" else ""))
	end
	local boost = if rewards.boost then QuestConfig.Boosts[rewards.boost] else nil
	if boost then
		table.insert(parts, string.format("%s %d min", boost.name, boost.duration // 60))
	end
	if rewards.decoration then
		for _, decoration in QuestConfig.Decorations do
			if decoration.id == rewards.decoration then
				table.insert(parts, "Décoration : " .. decoration.name)
			end
		end
	end
	return table.concat(parts, " · ")
end

return table.freeze(Quests)
