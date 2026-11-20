--!strict
-- Schéma persistant des joueurs : gabarit, migrations, réconciliation, assainissement, validation JSON.
-- Règle : toute évolution du schéma incrémente VERSION et ajoute une entrée dans MIGRATIONS (+ test).

local Types = require(script.Parent.Parent.Types)
local DroneConfig = require(script.Parent.Parent.Config.DroneConfig)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local PlantConfig = require(script.Parent.Parent.Config.PlantConfig)
local MutationConfig = require(script.Parent.Parent.Config.MutationConfig)
local BigNum = require(script.Parent.BigNum)
local Deep = require(script.Parent.Deep)
local Economy = require(script.Parent.Economy)
local FarmLayout = require(script.Parent.FarmLayout)

type PlayerData = Types.PlayerData
type Migration = (any) -> any

local VERSION = 1
local MAX_DEPTH = 16

-- MIGRATIONS[v] transforme une donnée de version v-1 en version v.
local MIGRATIONS: { [number]: Migration } = {
	-- [2] = function(data) ... return data end,
}

local DataSchema = {
	VERSION = VERSION,
}

function DataSchema.template(now: number): PlayerData
	return {
		version = VERSION,
		currencies = {
			coins = BigNum.zero(),
			essence = BigNum.zero(),
			primalCores = BigNum.zero(),
			rebirthTokens = 0,
		},
		farm = {
			plots = FarmLayout.defaultPlots(),
			tiles = {},
		},
		seeds = {
			unlocked = { [GameConfig.StarterSeed] = true },
			selected = GameConfig.StarterSeed,
		},
		bag = {
			items = {},
		},
		upgrades = {
			normal = {},
			rebirth = {},
			permanent = {},
		},
		machines = {
			drones = {},
		},
		progression = {
			rebirths = 0,
			prestiges = 0,
		},
		mutadex = {},
		cosmetics = {
			owned = {},
			equipped = {},
		},
		pets = {
			owned = {},
			equipped = {},
		},
		stats = {
			harvests = 0,
			perfectHarvests = 0,
			sells = 0,
			coinsEarned = BigNum.zero(),
			playTime = 0,
		},
		receipts = {},
		meta = {
			createdAt = now,
			lastSeen = now,
		},
	}
end

-- Applique les migrations de `fromVersion` à `toVersion`. `migrations` est injectable pour les tests.
function DataSchema.migrate(
	raw: any,
	fromVersion: number,
	toVersion: number?,
	migrations: { [number]: Migration }?
): any
	local target = toVersion or VERSION
	local steps = migrations or MIGRATIONS
	local data = raw
	for version = fromVersion + 1, target do
		local step = steps[version]
		if step then
			data = step(data)
		end
		data.version = version
	end
	return data
end

-- Complète récursivement les champs manquants ou mal typés à partir du gabarit (n'écrase jamais une valeur valide).
function DataSchema.reconcile(target: { [any]: any }, template: { [any]: any })
	for key, templateValue in template do
		local value = target[key]
		if value == nil or type(value) ~= type(templateValue) then
			target[key] = Deep.copy(templateValue)
		elseif type(templateValue) == "table" then
			DataSchema.reconcile(value, templateValue)
		end
	end
end

local function isNonNegativeInteger(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value % 1 == 0 and value < math.huge
end

-- Corrige les incohérences (config modifiée, valeurs corrompues). Retourne la liste des corrections.
function DataSchema.sanitize(data: PlayerData): { string }
	local notes: { string } = {}

	for _, field in { "coins", "essence", "primalCores" } do
		local currencies = data.currencies :: any
		if not BigNum.isValid(currencies[field]) then
			table.insert(notes, "currencies." .. field .. " invalide -> 0")
			currencies[field] = BigNum.zero()
		end
	end
	if not BigNum.isValid(data.stats.coinsEarned) then
		data.stats.coinsEarned = BigNum.zero()
		table.insert(notes, "stats.coinsEarned invalide -> 0")
	end

	-- Parcelles : uniquement des identifiants connus ; la parcelle principale est toujours débloquée.
	for plotId in data.farm.plots do
		if not FarmLayout.getPlot(plotId) then
			data.farm.plots[plotId] = nil
			table.insert(notes, "parcelle inconnue retirée : " .. tostring(plotId))
		end
	end
	for plotId, unlocked in FarmLayout.defaultPlots() do
		data.farm.plots[plotId] = unlocked
	end

	-- Cases : plante connue, nombres finis, case existante et débloquée.
	for tileId, tile in data.farm.tiles do
		local valid = type(tile) == "table"
			and type(tile.plantId) == "string"
			and PlantConfig.get(tile.plantId) ~= nil
			and type(tile.plantedAt) == "number"
			and tile.plantedAt == tile.plantedAt
			and type(tile.growTime) == "number"
			and tile.growTime > 0
			and tile.growTime < math.huge
			and (tile.mutation == nil or MutationConfig.get(tile.mutation) ~= nil)
			and FarmLayout.isTileUnlocked(data.farm.plots, tileId)
		if not valid then
			data.farm.tiles[tileId] = nil
			table.insert(notes, "case invalide retirée : " .. tostring(tileId))
		end
	end

	-- Sac : objets connus, quantités entières positives.
	for key, quantity in data.bag.items do
		if not Economy.isValidItemKey(key) or not isNonNegativeInteger(quantity) or quantity == 0 then
			data.bag.items[key] = nil
			table.insert(notes, "objet invalide retiré : " .. tostring(key))
		end
	end

	-- Graines : identifiants connus, graine de départ toujours débloquée, sélection valide.
	for plantId in data.seeds.unlocked do
		if not PlantConfig.get(plantId) then
			data.seeds.unlocked[plantId] = nil
			table.insert(notes, "graine inconnue retirée : " .. tostring(plantId))
		end
	end
	data.seeds.unlocked[GameConfig.StarterSeed] = true
	if not data.seeds.unlocked[data.seeds.selected] then
		data.seeds.selected = GameConfig.StarterSeed
		table.insert(notes, "graine sélectionnée invalide -> graine de départ")
	end

	-- Drones : types connus, nombres entiers strictement positifs, plafonnés à maxOwned.
	for droneId, count in data.machines.drones do
		local def = DroneConfig.get(droneId)
		if not def or not isNonNegativeInteger(count) or count == 0 then
			data.machines.drones[droneId] = nil
			table.insert(notes, "drone invalide retiré : " .. tostring(droneId))
		elseif count > def.maxOwned then
			data.machines.drones[droneId] = def.maxOwned
			table.insert(notes, "drones plafonnés : " .. droneId)
		end
	end

	-- Compteurs.
	for _, field in { "rebirths", "prestiges" } do
		local progression = data.progression :: any
		if not isNonNegativeInteger(progression[field]) then
			progression[field] = 0
			table.insert(notes, "progression." .. field .. " invalide -> 0")
		end
	end
	if not isNonNegativeInteger(data.currencies.rebirthTokens) then
		data.currencies.rebirthTokens = 0
	end

	-- Reçus : chaînes uniquement, FIFO borné.
	local receipts: { string } = {}
	for _, receipt in data.receipts do
		if type(receipt) == "string" then
			table.insert(receipts, receipt)
		end
	end
	while #receipts > GameConfig.Data.MaxReceipts do
		table.remove(receipts, 1)
	end
	data.receipts = receipts

	return notes
end

export type LoadError = "future_version"

-- Transforme une donnée brute du DataStore en PlayerData utilisable.
-- Retourne (nil, "future_version") si la donnée vient d'une version plus récente du jeu : le serveur NE DOIT PAS l'écraser.
function DataSchema.load(raw: any, now: number): (PlayerData?, LoadError?, { string })
	local notes: { string } = {}
	if raw == nil then
		return DataSchema.template(now), nil, notes
	end
	if type(raw) ~= "table" then
		table.insert(notes, "donnée non tabulaire remplacée par un gabarit")
		return DataSchema.template(now), nil, notes
	end
	local version = if type(raw.version) == "number" then raw.version else 0
	if version > VERSION then
		return nil, "future_version", notes
	end
	local data = raw
	if version < VERSION then
		data = DataSchema.migrate(raw, version)
		table.insert(notes, string.format("migration v%d -> v%d", version, VERSION))
	end
	DataSchema.reconcile(data, DataSchema.template(now) :: any)
	data.version = VERSION
	local typed = data :: PlayerData
	for _, note in DataSchema.sanitize(typed) do
		table.insert(notes, note)
	end
	return typed, nil, notes
end

-- Vérifie qu'une valeur est sérialisable en JSON par DataStoreService (sans perte).
function DataSchema.validate(value: any): (boolean, string?)
	local function check(node: any, path: string, depth: number): (boolean, string?)
		local kind = type(node)
		if kind == "number" then
			if node ~= node or node == math.huge or node == -math.huge then
				return false, path .. " : nombre non fini"
			end
			return true, nil
		elseif kind == "string" then
			if utf8.len(node) == nil then
				return false, path .. " : UTF-8 invalide"
			end
			return true, nil
		elseif kind == "boolean" then
			return true, nil
		elseif kind == "table" then
			if depth > MAX_DEPTH then
				return false, path .. " : profondeur excessive"
			end
			local length = #node
			local hasStringKey, hasNumberKey = false, false
			for key, child in node do
				if type(key) == "string" then
					hasStringKey = true
				elseif type(key) == "number" then
					hasNumberKey = true
					if key % 1 ~= 0 or key < 1 or key > length then
						return false, path .. " : tableau à trous ou clé numérique invalide"
					end
				else
					return false, path .. " : type de clé non sérialisable"
				end
				local ok, reason = check(child, path .. "." .. tostring(key), depth + 1)
				if not ok then
					return false, reason
				end
			end
			if hasStringKey and hasNumberKey then
				return false, path .. " : table mixte (tableau + dictionnaire)"
			end
			return true, nil
		end
		return false, path .. " : type " .. kind .. " non sérialisable"
	end
	return check(value, "data", 0)
end

return DataSchema
