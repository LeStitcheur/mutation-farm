--!strict
-- Règles PURES des familiers (Phase 4, jalon B ; testées en Lune) : œufs (probabilités, tirage à partir d'un aléa
-- fourni par le serveur), éclosion atomique et idempotente, inventaire, emplacements, XP et niveaux, bonus cumulés
-- et plafonnés. Le serveur exécute chaque opération dans UN mutateur de DataService.Update ; le client n'envoie que
-- des intentions (œuf, nombre d'éclosions affiché, identifiant d'instance).
-- Les fonctions de lecture tolèrent une donnée partielle (aperçus côté client) : champ absent ou invalide = vide.

local Types = require(script.Parent.Parent.Types)
local PetConfig = require(script.Parent.Parent.Config.PetConfig)
local BigNum = require(script.Parent.BigNum)

type PlayerData = Types.PlayerData
type PetInstance = Types.PetInstance
type PetDef = PetConfig.PetDef
type EggDef = PetConfig.EggDef
type Effect = PetConfig.Effect

export type HatchFailure =
	"unknown_egg"
	| "stale" -- nombre d'éclosions attendu périmé (double clic, paquet rejoué)
	| "inventory_full"
	| "not_for_sale" -- œuf jamais vendu (gagné uniquement)
	| "no_free_egg"
	| "insufficient_funds"

export type HatchOutcome = {
	eggId: string,
	instanceId: string,
	petId: string,
	free: boolean, -- œuf gratuit consommé (sinon payé en Coins)
	price: Types.BigNum, -- Coins dépensés (0 si gratuit)
}

export type ActionFailure =
	"unknown_pet" -- instance inexistante ou malformée
	| "dormant" -- espèce retirée de la configuration : conservée, mais ni équipable ni active
	| "already_equipped"
	| "slots_full"
	| "not_equipped"
	| "equipped" -- un familier équipé ne peut pas être relâché

export type LevelUp = { instanceId: string, petId: string, level: number }

export type Effects = { growth: number, value: number, luck: number, drones: number, manual: number }

export type Owned = { id: string, instance: PetInstance, def: PetDef, equipped: boolean }

export type Odds = { petId: string, probability: number }

local EFFECTS: { Effect } = { "growth", "value", "luck", "drones", "manual" }

local Pets = {}

function Pets.get(petId: string): PetDef?
	return PetConfig.ById[petId]
end

function Pets.egg(eggId: string): EggDef?
	return PetConfig.EggById[eggId]
end

-- Probabilités affichées d'un œuf (poids / somme), dans l'ordre du pool.
function Pets.odds(egg: EggDef): { Odds }
	local total = 0
	for _, entry in egg.weights do
		total += entry.weight
	end
	local result: { Odds } = {}
	for _, entry in egg.weights do
		table.insert(result, { petId = entry.petId, probability = if total > 0 then entry.weight / total else 0 })
	end
	return result
end

-- Tirage pondéré : `r` ∈ [0, 1[ fourni par le serveur (Random), jamais par le client.
function Pets.draw(egg: EggDef, r: number): string
	local total = 0
	for _, entry in egg.weights do
		total += entry.weight
	end
	local target = math.clamp(r, 0, 1) * total
	local accumulated = 0
	local last = egg.weights[#egg.weights].petId
	for _, entry in egg.weights do
		if entry.weight > 0 then
			accumulated += entry.weight
			last = entry.petId
			if target < accumulated then
				return entry.petId
			end
		end
	end
	return last
end

local function petsOf(data: any): { [string]: any }?
	local pets = if type(data) == "table" then data.pets else nil
	return if type(pets) == "table" then pets else nil
end

local function isValidInstance(value: any): boolean
	return type(value) == "table"
		and type(value.petId) == "string"
		and type(value.level) == "number"
		and value.level >= 1
		and value.level % 1 == 0
		and type(value.xp) == "number"
		and value.xp >= 0
		and value.xp == value.xp
		and type(value.obtainedAt) == "number"
end

-- Instance valide (structure correcte), qu'elle soit active ou en sommeil.
function Pets.instance(data: PlayerData, instanceId: string): PetInstance?
	local pets = petsOf(data)
	local instances = if pets and type(pets.instances) == "table" then pets.instances else nil
	local value = if instances then instances[instanceId] else nil
	return if isValidInstance(value) then value else nil
end

-- Nombre de familiers possédés (y compris en sommeil) : capacité de l'inventaire.
function Pets.count(data: PlayerData): number
	local pets = petsOf(data)
	local count = 0
	if pets and type(pets.instances) == "table" then
		for _ in pets.instances do
			count += 1
		end
	end
	return count
end

function Pets.hatchedCount(data: PlayerData): number
	local pets = petsOf(data)
	local value = if pets then pets.hatched else nil
	return if type(value) == "number" then value else 0
end

function Pets.freeEggs(data: PlayerData, eggId: string): number
	local pets = petsOf(data)
	local eggs = if pets and type(pets.freeEggs) == "table" then pets.freeEggs else nil
	local value = if eggs then eggs[eggId] else nil
	return if type(value) == "number" and value >= 0 then math.floor(value) else 0
end

function Pets.equippedIds(data: PlayerData): { string }
	local pets = petsOf(data)
	local equipped = if pets and type(pets.equipped) == "table" then pets.equipped else nil
	local result: { string } = {}
	if equipped then
		for _, id in equipped do
			if type(id) == "string" then
				table.insert(result, id)
			end
		end
	end
	return result
end

function Pets.isEquipped(data: PlayerData, instanceId: string): boolean
	return table.find(Pets.equippedIds(data), instanceId) ~= nil
end

-- XP nécessaire du niveau `level` au suivant (math.huge au niveau maximum).
function Pets.xpToNext(level: number): number
	if level >= PetConfig.Level.Max then
		return math.huge
	end
	return math.ceil(PetConfig.Level.XpBase * PetConfig.Level.XpGrowth ^ (level - 1) - 1e-9)
end

-- Bonus d'un effet pour une espèce à un niveau donné (interpolation linéaire niveau 1 → niveau maximum).
function Pets.bonus(def: PetDef, effect: Effect, level: number): number
	local range = def.effects[effect]
	if not range then
		return 0
	end
	local clamped = math.clamp(level, 1, PetConfig.Level.Max)
	local t = (clamped - 1) / (PetConfig.Level.Max - 1)
	return range.min + (range.max - range.min) * t
end

-- XP d'une récolte validée : toute récolte (joueur ou drone), + bonus pour une récolte manuelle « Parfait ».
function Pets.harvestXp(source: Types.HarvestSource, tier: Types.PrecisionTier): number
	local xp = PetConfig.Xp.PerHarvest
	if source == "player" and tier == "perfect" then
		xp += PetConfig.Xp.PerfectBonus
	end
	return xp
end

-- Cumul des bonus des familiers équipés (espèces connues uniquement), plafonné par effet.
function Pets.effects(data: PlayerData): Effects
	local totals: { [string]: number } = { growth = 0, value = 0, luck = 0, drones = 0, manual = 0 }
	for _, id in Pets.equippedIds(data) do
		local instance = Pets.instance(data, id)
		local def = if instance then PetConfig.ById[instance.petId] else nil
		if instance and def then
			for _, effect: Effect in EFFECTS do
				totals[effect] += Pets.bonus(def, effect, instance.level)
			end
		end
	end
	local caps = PetConfig.Caps :: any
	return {
		growth = math.min(totals.growth, caps.growth),
		value = math.min(totals.value, caps.value),
		luck = math.min(totals.luck, caps.luck),
		drones = math.min(totals.drones, caps.drones),
		manual = math.min(totals.manual, caps.manual),
	}
end

function Pets.valueMultiplier(data: PlayerData): number
	return 1 + Pets.effects(data).value
end

function Pets.growthFactor(data: PlayerData): number
	return 1 - Pets.effects(data).growth
end

function Pets.luckBonus(data: PlayerData): number
	return Pets.effects(data).luck
end

function Pets.droneFactor(data: PlayerData): number
	return 1 - Pets.effects(data).drones
end

function Pets.manualMultiplier(data: PlayerData): number
	return 1 + Pets.effects(data).manual
end

-- Vérifie une éclosion sans rien modifier (ordre : œuf, révision, inventaire, paiement).
function Pets.canHatch(
	data: PlayerData,
	eggId: string,
	expectedHatched: number,
	useFree: boolean
): (boolean, HatchFailure?)
	local egg = PetConfig.EggById[eggId]
	if not egg then
		return false, "unknown_egg"
	end
	if expectedHatched ~= Pets.hatchedCount(data) then
		return false, "stale"
	end
	if Pets.count(data) >= PetConfig.InventoryCapacity then
		return false, "inventory_full"
	end
	if useFree then
		if Pets.freeEggs(data, eggId) < 1 then
			return false, "no_free_egg"
		end
	else
		local price = egg.price
		if not price then
			return false, "not_for_sale"
		end
		if BigNum.lt(data.currencies.coins, BigNum.fromNumber(price)) then
			return false, "insufficient_funds"
		end
	end
	return true, nil
end

-- Éclosion ATOMIQUE (dans un seul mutateur) : paiement (Coins ou œuf gratuit), tirage, nouvelle instance au numéro
-- unique, compteur d'éclosions + 1. Une révision attendue périmée n'ouvre rien (idempotence).
function Pets.hatch(
	data: PlayerData,
	eggId: string,
	expectedHatched: number,
	useFree: boolean,
	r: number,
	now: number
): (HatchOutcome?, HatchFailure?)
	local ok: boolean, failure: HatchFailure? = Pets.canHatch(data, eggId, expectedHatched, useFree)
	if not ok then
		return nil, failure
	end
	local egg = PetConfig.EggById[eggId]
	local pets = data.pets
	-- Identifiant vérifié AVANT tout paiement (un mutateur n'a pas de retour arrière).
	local instanceId = "p" .. pets.nextSerial
	assert(pets.instances[instanceId] == nil, "Pets.hatch : identifiant d'instance déjà utilisé " .. instanceId)
	local price = BigNum.zero()
	if useFree then
		pets.freeEggs[eggId] = Pets.freeEggs(data, eggId) - 1
	else
		price = BigNum.fromNumber(egg.price :: number)
		data.currencies.coins = BigNum.sub(data.currencies.coins, price)
	end
	local petId = Pets.draw(egg, r)
	pets.nextSerial += 1
	pets.hatched = Pets.hatchedCount(data) + 1
	pets.instances[instanceId] = { petId = petId, level = 1, xp = 0, obtainedAt = now }
	return { eggId = eggId, instanceId = instanceId, petId = petId, free = useFree, price = price }, nil
end

-- Ajoute des œufs gratuits (récompenses), plafonnés à MaxFreeEggs. Retourne le nombre réellement ajouté.
function Pets.addFreeEggs(data: PlayerData, eggId: string, amount: number): number
	if not PetConfig.EggById[eggId] or amount <= 0 then
		return 0
	end
	local current = Pets.freeEggs(data, eggId)
	local added = math.min(math.floor(amount), PetConfig.MaxFreeEggs - current)
	if added <= 0 then
		return 0
	end
	data.pets.freeEggs[eggId] = current + added
	return added
end

local function activeDef(data: PlayerData, instanceId: string): (PetInstance?, PetDef?, ActionFailure?)
	local instance = Pets.instance(data, instanceId)
	if not instance then
		return nil, nil, "unknown_pet"
	end
	local def = PetConfig.ById[instance.petId]
	if not def then
		return instance, nil, "dormant"
	end
	return instance, def, nil
end

function Pets.equip(data: PlayerData, instanceId: string): (boolean, ActionFailure?)
	local _, _, failure: ActionFailure? = activeDef(data, instanceId)
	if failure then
		return false, failure
	end
	if Pets.isEquipped(data, instanceId) then
		return false, "already_equipped"
	end
	if #Pets.equippedIds(data) >= PetConfig.Slots then
		return false, "slots_full"
	end
	table.insert(data.pets.equipped, instanceId)
	return true, nil
end

function Pets.unequip(data: PlayerData, instanceId: string): (boolean, ActionFailure?)
	local index = table.find(data.pets.equipped, instanceId)
	if not index then
		return false, "not_equipped"
	end
	table.remove(data.pets.equipped, index)
	return true, nil
end

-- Relâche un familier NON équipé (choix explicite du joueur, libère une place d'inventaire).
function Pets.release(data: PlayerData, instanceId: string): (boolean, ActionFailure?)
	if not Pets.instance(data, instanceId) then
		return false, "unknown_pet"
	end
	if Pets.isEquipped(data, instanceId) then
		return false, "equipped"
	end
	data.pets.instances[instanceId] = nil
	return true, nil
end

-- XP aux familiers équipés actifs (chacun reçoit `amount`). Retourne les passages de niveau.
function Pets.grantXp(data: PlayerData, amount: number): { LevelUp }
	local levelUps: { LevelUp } = {}
	if amount <= 0 then
		return levelUps
	end
	for _, id in Pets.equippedIds(data) do
		local instance, def = activeDef(data, id)
		if instance and def and instance.level < PetConfig.Level.Max then
			instance.xp += amount
			while instance.level < PetConfig.Level.Max and instance.xp >= Pets.xpToNext(instance.level) do
				instance.xp -= Pets.xpToNext(instance.level)
				instance.level += 1
				table.insert(levelUps, { instanceId = id, petId = def.id, level = instance.level })
			end
			if instance.level >= PetConfig.Level.Max then
				instance.xp = 0
			end
		end
	end
	return levelUps
end

local function serial(instanceId: string): number
	return tonumber(string.match(instanceId, "^p(%d+)$")) or math.huge
end

-- Inventaire trié : équipés d'abord, puis rareté, niveau, espèce et ancienneté ; espèces en sommeil exclues.
function Pets.sorted(data: PlayerData): { Owned }
	local pets = petsOf(data)
	local list: { Owned } = {}
	if pets and type(pets.instances) == "table" then
		for id, _ in pets.instances do
			local key = tostring(id)
			local instance = Pets.instance(data, key)
			local def = if instance then PetConfig.ById[instance.petId] else nil
			if instance and def then
				table.insert(list, { id = key, instance = instance, def = def, equipped = Pets.isEquipped(data, key) })
			end
		end
	end
	table.sort(list, function(a, b)
		if a.equipped ~= b.equipped then
			return a.equipped
		end
		if a.def.rarity.order ~= b.def.rarity.order then
			return a.def.rarity.order > b.def.rarity.order
		end
		if a.instance.level ~= b.instance.level then
			return a.instance.level > b.instance.level
		end
		if a.def.order ~= b.def.order then
			return a.def.order < b.def.order
		end
		return serial(a.id) < serial(b.id)
	end)
	return list
end

-- Exemplaires possédés par espèce (doublons affichés).
function Pets.speciesCount(data: PlayerData): { [string]: number }
	local counts: { [string]: number } = {}
	for _, owned in Pets.sorted(data) do
		counts[owned.def.id] = (counts[owned.def.id] or 0) + 1
	end
	return counts
end

-- Résumé des familiers équipés actifs, pour l'attribut répliqué du joueur (rendu chez tous les clients) :
-- « espèce:niveau » séparés par « ; ».
function Pets.equippedSummary(data: PlayerData): string
	local parts: { string } = {}
	for _, id in Pets.equippedIds(data) do
		local instance, def = activeDef(data, id)
		if instance and def then
			table.insert(parts, def.id .. ":" .. instance.level)
		end
	end
	return table.concat(parts, ";")
end

-- Lecture du résumé (client) : espèces connues uniquement, au plus PetConfig.Slots.
function Pets.parseSummary(text: string): { { petId: string, level: number } }
	local result: { { petId: string, level: number } } = {}
	for petId, level in string.gmatch(text, "([%w_]+):(%d+)") do
		if PetConfig.ById[petId] and #result < PetConfig.Slots then
			table.insert(result, { petId = petId, level = tonumber(level) or 1 })
		end
	end
	return result
end

local LABELS: { [string]: string } = {
	growth = "pousse",
	value = "revenu",
	luck = "chance",
	drones = "drones",
	manual = "précision",
}

-- Texte court des bonus pour l'interface (« +12 % revenu »).
function Pets.describe(def: PetDef, level: number): string
	local parts: { string } = {}
	for _, effect: Effect in EFFECTS do
		local bonus = Pets.bonus(def, effect, level)
		if bonus > 0 then
			local percent = math.floor(bonus * 100 + 0.5)
			if effect == "luck" then
				table.insert(parts, string.format("+%.2f %s", bonus, LABELS[effect]))
			elseif effect == "growth" or effect == "drones" then
				table.insert(parts, string.format("−%d %% %s", percent, LABELS[effect]))
			else
				table.insert(parts, string.format("+%d %% %s", percent, LABELS[effect]))
			end
		end
	end
	return table.concat(parts, " · ")
end

return table.freeze(Pets)
