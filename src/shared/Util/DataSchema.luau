--!strict
-- Schéma persistant des joueurs : gabarit, migrations, réconciliation, assainissement, validation JSON.
-- Règle : toute évolution du schéma incrémente VERSION et ajoute une entrée dans MIGRATIONS (+ test).

local Types = require(script.Parent.Parent.Types)
local DroneConfig = require(script.Parent.Parent.Config.DroneConfig)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local PlantConfig = require(script.Parent.Parent.Config.PlantConfig)
local MutationConfig = require(script.Parent.Parent.Config.MutationConfig)
local UpgradeConfig = require(script.Parent.Parent.Config.UpgradeConfig)
local MutadexConfig = require(script.Parent.Parent.Config.MutadexConfig)
local BigNum = require(script.Parent.BigNum)
local Deep = require(script.Parent.Deep)
local Economy = require(script.Parent.Economy)
local Mutadex = require(script.Parent.Mutadex)
local FarmLayout = require(script.Parent.FarmLayout)

type PlayerData = Types.PlayerData
type Migration = (any) -> any

local VERSION = 3
local MAX_DEPTH = 16

-- Copie défensive d'un BigNum stocké (zéro si absent ou corrompu).
local function storedBigNum(value: any): any
	return if BigNum.isValid(value) then Deep.copy(value) else BigNum.zero()
end

-- MIGRATIONS[v] transforme une donnée de version v-1 en version v. Elles ne suppriment jamais de champ.
-- Documentation : docs/DATA_MIGRATIONS.md.
local MIGRATIONS: { [number]: Migration } = {
	-- v2 (Phase 3, rebirth) : compteurs de cycle, révision de progression, historique des rebirths, quarantaine.
	-- Aucun rebirth/prestige n'existait en v1 : tous les Coins gagnés appartiennent au cycle en cours.
	[2] = function(data: any): any
		if type(data.progression) ~= "table" then
			data.progression = {}
		end
		if type(data.stats) ~= "table" then
			data.stats = {}
		end
		local progression = data.progression
		local rebirths = if type(progression.rebirths) == "number" then progression.rebirths else 0
		local prestiges = if type(progression.prestiges) == "number" then progression.prestiges else 0
		local earned = storedBigNum(data.stats.coinsEarned)
		progression.revision = 0
		progression.cycleCoins = if rebirths == 0 and prestiges == 0 then Deep.copy(earned) else BigNum.zero()
		progression.prestigeCoins = if prestiges == 0 then Deep.copy(earned) else BigNum.zero()
		data.stats.totalRebirths = rebirths
		return data
	end,
	-- v3 (Phase 4, Mutadex) : une entrée devient { firstAt, count }. L'ancien format (un horodatage) n'a jamais été
	-- écrit par le jeu ; s'il existe, il est converti (count = 1 : la récolte de découverte). Rien n'est supprimé ;
	-- les paliers (mutadexRewards) sont ajoutés vides par la réconciliation.
	[3] = function(data: any): any
		if type(data.mutadex) == "table" then
			for key, value in data.mutadex do
				if type(value) == "number" then
					data.mutadex[key] = { firstAt = value, count = 1 }
				end
			end
		end
		return data
	end,
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
			revision = 0,
			cycleCoins = BigNum.zero(),
			prestigeCoins = BigNum.zero(),
		},
		mutadex = {},
		mutadexRewards = {},
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
			totalRebirths = 0,
		},
		receipts = {},
		meta = {
			createdAt = now,
			lastSeen = now,
			quarantine = {},
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
export type Replacement = { path: string, value: any }

-- Complète `target` avec les champs manquants du gabarit. Une valeur présente mais d'un autre type que le gabarit
-- est remplacée par la valeur par défaut ; si `replaced` est fourni, elle y est consignée (chemin, valeur d'origine)
-- pour être mise en quarantaine par `load` : jamais de suppression silencieuse.
function DataSchema.reconcile(
	target: { [any]: any },
	template: { [any]: any },
	replaced: { Replacement }?,
	prefix: string?
)
	for key, templateValue in template do
		local value = target[key]
		local path = if prefix then prefix .. "." .. tostring(key) else tostring(key)
		if value == nil then
			target[key] = Deep.copy(templateValue)
		elseif type(value) ~= type(templateValue) then
			if replaced then
				table.insert(replaced, { path = path, value = value })
			end
			target[key] = Deep.copy(templateValue)
		elseif type(templateValue) == "table" then
			DataSchema.reconcile(value, templateValue, replaced, path)
		end
	end
end

-- Horodatage Unix plausible : nombre fini ≥ 0.
local function isTimestamp(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

local function isNonNegativeInteger(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value % 1 == 0 and value < math.huge
end

-- Met une donnée retirée ou corrigée en quarantaine (meta.quarantine, FIFO borné) et la signale.
-- La valeur d'origine est conservée telle quelle si elle est sérialisable en JSON, sinon sous forme de texte.
local function quarantine(data: PlayerData, notes: { string }, path: string, value: any, reason: string, now: number)
	local entries = data.meta.quarantine
	local safe = if DataSchema.validate(value) then Deep.copy(value) else tostring(value)
	table.insert(entries, { path = path, value = safe, reason = reason, at = now })
	while #entries > GameConfig.Data.MaxQuarantine do
		table.remove(entries, 1)
	end
	table.insert(notes, string.format("%s : %s (mis en quarantaine)", path, reason))
end

-- Corrige les incohérences (config modifiée, valeurs corrompues). Retourne la liste des corrections.
-- Rien n'est supprimé silencieusement : toute valeur retirée ou remplacée part en quarantaine avec une note.
function DataSchema.sanitize(data: PlayerData, now: number?): { string }
	local notes: { string } = {}
	local at = now or 0
	if type(data.meta.quarantine) ~= "table" then
		local previous = data.meta.quarantine
		data.meta.quarantine = {}
		quarantine(data, notes, "meta.quarantine", previous, "liste de quarantaine invalide", at)
	end

	for _, field in { "coins", "essence", "primalCores" } do
		local currencies = data.currencies :: any
		if not BigNum.isValid(currencies[field]) then
			quarantine(data, notes, "currencies." .. field, currencies[field], "montant invalide -> 0", at)
			currencies[field] = BigNum.zero()
		end
	end
	if not BigNum.isValid(data.stats.coinsEarned) then
		quarantine(data, notes, "stats.coinsEarned", data.stats.coinsEarned, "montant invalide -> 0", at)
		data.stats.coinsEarned = BigNum.zero()
	end
	for _, field in { "cycleCoins", "prestigeCoins" } do
		local progression = data.progression :: any
		if not BigNum.isValid(progression[field]) or BigNum.isNegative(progression[field]) then
			quarantine(data, notes, "progression." .. field, progression[field], "montant invalide -> 0", at)
			progression[field] = BigNum.zero()
		end
	end

	-- Parcelles : uniquement des identifiants connus ; la parcelle principale est toujours débloquée.
	for plotId, unlocked in data.farm.plots do
		if not FarmLayout.getPlot(plotId) then
			data.farm.plots[plotId] = nil
			quarantine(data, notes, "farm.plots." .. tostring(plotId), unlocked, "parcelle inconnue", at)
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
			quarantine(
				data,
				notes,
				"farm.tiles." .. tostring(tileId),
				tile,
				"culture invalide ou parcelle verrouillée",
				at
			)
		end
	end

	-- Sac : objets connus, quantités entières positives.
	for key, quantity in data.bag.items do
		if not Economy.isValidItemKey(key) or not isNonNegativeInteger(quantity) or quantity == 0 then
			data.bag.items[key] = nil
			quarantine(data, notes, "bag.items." .. tostring(key), quantity, "objet inconnu ou quantité invalide", at)
		end
	end

	-- Graines : identifiants connus, graine de départ toujours débloquée, sélection valide.
	for plantId, unlocked in data.seeds.unlocked do
		if not PlantConfig.get(plantId) then
			data.seeds.unlocked[plantId] = nil
			quarantine(data, notes, "seeds.unlocked." .. tostring(plantId), unlocked, "graine inconnue", at)
		end
	end
	data.seeds.unlocked[GameConfig.StarterSeed] = true
	if not data.seeds.unlocked[data.seeds.selected] then
		quarantine(data, notes, "seeds.selected", data.seeds.selected, "graine non débloquée -> départ", at)
		data.seeds.selected = GameConfig.StarterSeed
	end

	-- Drones : types connus, nombres entiers strictement positifs, plafonnés à maxOwned.
	for droneId, count in data.machines.drones do
		local def = DroneConfig.get(droneId)
		if not def or not isNonNegativeInteger(count) or count == 0 then
			data.machines.drones[droneId] = nil
			quarantine(
				data,
				notes,
				"machines.drones." .. tostring(droneId),
				count,
				"drone inconnu ou nombre invalide",
				at
			)
		elseif count > def.maxOwned then
			quarantine(data, notes, "machines.drones." .. droneId, count, "au-delà du maximum -> plafonné", at)
			data.machines.drones[droneId] = def.maxOwned
		end
	end

	-- Améliorations des arbres Essence (upgrades.rebirth) et Primal Cores (upgrades.permanent) : identifiants connus
	-- dans le bon arbre, niveaux entiers ≥ 1, plafonnés au maximum. upgrades.normal : pas encore de catalogue.
	for _, tree in UpgradeConfig.Trees do
		local container = (data.upgrades :: any)[tree.storage]
		if type(container) ~= "table" then
			quarantine(data, notes, "upgrades." .. tree.storage, container, "liste d'améliorations invalide", at);
			(data.upgrades :: any)[tree.storage] = {}
			continue
		end
		for upgradeId, level in container do
			local def = if type(upgradeId) == "string" then UpgradeConfig.ById[upgradeId] else nil
			local path = "upgrades." .. tree.storage .. "." .. tostring(upgradeId)
			if not def or def.tree ~= tree.id or not isNonNegativeInteger(level) or level == 0 then
				container[upgradeId] = nil
				quarantine(data, notes, path, level, "amélioration inconnue ou niveau invalide", at)
			elseif level > def.maxLevel then
				quarantine(data, notes, path, level, "au-delà du niveau maximum -> plafonné", at)
				container[upgradeId] = def.maxLevel
			end
		end
	end

	-- Mutadex (Phase 4) : entrées { firstAt, count } ; paliers horodatés. Jamais réinitialisé.
	-- Une entrée BIEN FORMÉE hors catalogue (plante ou mutation retirée de la configuration, palier supprimé) reste en
	-- place, en sommeil : le Mutadex ne compte que le catalogue courant, et elle redevient active si le contenu
	-- revient (un palier déjà accordé n'est donc jamais accordé deux fois). Seules les valeurs malformées partent en
	-- quarantaine : la quarantaine est bornée (FIFO) et ne doit pas servir de stockage à des découvertes valides.
	local raw = data :: any
	if type(raw.mutadex) ~= "table" then
		quarantine(data, notes, "mutadex", raw.mutadex, "Mutadex invalide", at)
		raw.mutadex = {}
	end
	for key, value in raw.mutadex do
		local valid = type(key) == "string"
			and type(value) == "table"
			and isTimestamp(value.firstAt)
			and isNonNegativeInteger(value.count)
		if not valid then
			raw.mutadex[key] = nil
			quarantine(data, notes, "mutadex." .. tostring(key), value, "entrée du Mutadex invalide", at)
		elseif Mutadex.get(key) == nil then
			table.insert(notes, "Mutadex : entrée hors catalogue conservée en sommeil (" .. key .. ")")
		end
	end
	if type(raw.mutadexRewards) ~= "table" then
		quarantine(data, notes, "mutadexRewards", raw.mutadexRewards, "paliers du Mutadex invalides", at)
		raw.mutadexRewards = {}
	end
	local knownMilestones: { [string]: boolean } = {}
	for _, milestone in MutadexConfig.Milestones do
		knownMilestones[milestone.id] = true
	end
	for key, value in raw.mutadexRewards do
		if type(key) ~= "string" or not isTimestamp(value) then
			raw.mutadexRewards[key] = nil
			quarantine(data, notes, "mutadexRewards." .. tostring(key), value, "palier du Mutadex invalide", at)
		elseif not knownMilestones[key] then
			table.insert(notes, "Mutadex : palier hors configuration conservé en sommeil (" .. key .. ")")
		end
	end

	-- Compteurs.
	local counters: { { container: any, field: string, path: string } } = {
		{ container = data.progression, field = "rebirths", path = "progression.rebirths" },
		{ container = data.progression, field = "prestiges", path = "progression.prestiges" },
		{ container = data.progression, field = "revision", path = "progression.revision" },
		{ container = data.stats, field = "totalRebirths", path = "stats.totalRebirths" },
		{ container = data.currencies, field = "rebirthTokens", path = "currencies.rebirthTokens" },
	}
	for _, counter in counters do
		local value = counter.container[counter.field]
		if not isNonNegativeInteger(value) then
			quarantine(data, notes, counter.path, value, "compteur invalide -> 0", at)
			counter.container[counter.field] = 0
		end
	end

	-- Reçus : chaînes uniquement, FIFO borné (les plus anciens sont retirés en premier, avec une note).
	local receipts: { string } = {}
	for index, receipt in data.receipts do
		if type(receipt) == "string" then
			table.insert(receipts, receipt)
		else
			quarantine(data, notes, "receipts." .. tostring(index), receipt, "reçu non textuel", at)
		end
	end
	local trimmed = 0
	while #receipts > GameConfig.Data.MaxReceipts do
		table.remove(receipts, 1)
		trimmed += 1
	end
	if trimmed > 0 then
		table.insert(notes, string.format("receipts : %d reçu(s) les plus anciens retirés (FIFO borné)", trimmed))
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
	local replaced: { Replacement } = {}
	DataSchema.reconcile(data, DataSchema.template(now) :: any, replaced)
	data.version = VERSION
	local typed = data :: PlayerData
	-- Valeurs d'un type incompatible remplacées par la réconciliation : conservées en quarantaine.
	for _, item in replaced do
		quarantine(typed, notes, item.path, item.value, "type incompatible -> valeur par défaut", now)
	end
	for _, note in DataSchema.sanitize(typed, now) do
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
