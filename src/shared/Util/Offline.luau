--!strict
-- Production hors ligne, règle PURE (Phase 5, jalon D ; testée en Lune ; hypothèses : docs/AUTOMATION.md §8).
-- Exécutée par le serveur dans UN mutateur au chargement du profil (OfflineService) :
--   • fenêtre = [max(dernière sauvegarde, dernier règlement), maintenant], plafonnée à GameConfig.Offline.MaxSeconds
--     (2 h) ; une absence plus courte que MinSeconds ne rapporte rien (changements rapides de serveur) ;
--   • seule la production RÉELLEMENT AUTOMATISABLE à la déconnexion compte : les drones possédés et actifs, avec
--     leurs intervalles effectifs, leur portée, le délai de grâce et leur capacité ; le sac (capacité) ; le comptoir
--     automatique s'il est installé et activé ; les bonus équipés (améliorations, familiers) ;
--   • aucune simulation image par image : les actions des drones sont rejouées de l'une à la suivante, en sautant les
--     périodes d'attente (prochaine plante éligible), avec les MÊMES règles que le serveur en ligne (HarvestRules,
--     Automation.autoSell, replantation avec un tirage de mutation serveur injecté) ;
--   • idempotence : `offline.settledAt` = maintenant ; une reconnexion ne recompte jamais une période déjà réglée ;
--   • une révision de progression différente de celle attendue (reset intervenu) ne rapporte rien.
-- Écarts assumés par rapport à une session active : docs/AUTOMATION.md §8.

local Types = require(script.Parent.Parent.Types)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local MutationConfig = require(script.Parent.Parent.Config.MutationConfig)
local PlantConfig = require(script.Parent.Parent.Config.PlantConfig)
local Automation = require(script.Parent.Automation)
local BigNum = require(script.Parent.BigNum)
local Bonuses = require(script.Parent.Bonuses)
local DroneLogic = require(script.Parent.DroneLogic)
local Economy = require(script.Parent.Economy)
local Expansions = require(script.Parent.Expansions)
local Format = require(script.Parent.Format)
local HarvestRules = require(script.Parent.HarvestRules)
local Inventory = require(script.Parent.Inventory)
local ProgressionMath = require(script.Parent.ProgressionMath)
local Quests = require(script.Parent.Quests)
local Selling = require(script.Parent.Selling)

type PlayerData = Types.PlayerData
type DroneDef = Types.DroneDef
type OfflineReport = Types.OfflineReport

-- Tirage de mutation d'une replantation (serveur : MutationService.Roll ; tests : tirage déterministe).
export type Roll = (luck: number) -> string

export type Options = {
	roll: Roll,
	expectedRevision: number?, -- révision lue au chargement : un reset intervenu entre-temps ne rapporte rien
	-- Pause coopérative injectée par le serveur (task.wait) toutes les `yieldEvery` actions de drone : le calcul du
	-- pire cas (≈ 9 000 récoltes) ne bloque pas le serveur. Aucune dans les tests (module pur).
	yield: (() -> ())?,
	yieldEvery: number?,
}

type DroneRun = {
	def: DroneDef,
	interval: number,
	nextAt: number,
	reach: { string }, -- cases débloquées à portée, triées (départage des égalités comme DroneLogic.selectTargets)
}

-- Absence assez longue pour montrer l'écran même sans production (conseil : acheter ou réactiver des drones).
local TIP_SECONDS = 600

local Offline = {}

local function isTime(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

-- Fenêtre d'absence : début, absence réelle, durée prise en compte (≤ MaxSeconds). Horodatages serveur uniquement :
-- `meta.lastSeen` (écrit par le serveur à chaque sauvegarde) et `offline.settledAt` (dernier règlement).
function Offline.window(data: PlayerData, now: number): (number, number, number)
	local lastSeen = data.meta.lastSeen
	local settledAt = data.offline.settledAt
	local start = if isTime(lastSeen) then lastSeen else now
	if isTime(settledAt) and settledAt > start then
		start = settledAt
	end
	start = math.min(start, now) -- horodatage futur (horloges décalées, donnée trafiquée) : aucune absence
	local away = now - start
	return start, away, math.min(away, GameConfig.Offline.MaxSeconds)
end

local function newReport(now: number, away: number): OfflineReport
	return {
		at = now,
		awaySeconds = math.floor(away),
		countedSeconds = 0,
		harvests = 0,
		sales = 0,
		coins = BigNum.zero(),
		bagAdded = 0,
		discoveries = 0,
		levelUps = 0,
		missions = 0,
		stoppedBagFull = false,
		reason = "ok",
		seen = false,
	}
end

local function selectedSeed(data: PlayerData): string
	local selected = data.seeds.selected
	if PlantConfig.get(selected) and data.seeds.unlocked[selected] then
		return selected
	end
	return GameConfig.StarterSeed
end

-- Cases éligibles d'un drone à l'instant `at` (mûres depuis au moins le délai de grâce), la plus anciennement mûre
-- d'abord, au plus `capacity` (mêmes règles que DroneLogic.selectTargets, sans analyse de chaînes répétée).
local function pickTargets(data: PlayerData, run: DroneRun, at: number): { string }
	-- Cas courant (capacité 1) : simple recherche du minimum, sans table intermédiaire ni tri (pire cas : ≈ 9 000
	-- actions pour 2 h).
	if run.def.capacity == 1 then
		local bestId: string? = nil
		local bestRipe = math.huge
		for _, tileId in run.reach do
			local tile = data.farm.tiles[tileId]
			if tile then
				local ripeAt = tile.plantedAt + tile.growTime
				if
					at - ripeAt >= run.def.graceDelay
					and (ripeAt < bestRipe or (ripeAt == bestRipe and bestId ~= nil and tileId < bestId))
				then
					bestId, bestRipe = tileId, ripeAt
				end
			end
		end
		return if bestId then { bestId } else {}
	end
	local candidates: { { id: string, ripeAt: number } } = {}
	for _, tileId in run.reach do
		local tile = data.farm.tiles[tileId]
		if tile then
			local ripeAt = tile.plantedAt + tile.growTime
			if at - ripeAt >= run.def.graceDelay then
				table.insert(candidates, { id = tileId, ripeAt = ripeAt })
			end
		end
	end
	table.sort(candidates, function(a, b)
		if a.ripeAt ~= b.ripeAt then
			return a.ripeAt < b.ripeAt
		end
		return a.id < b.id
	end)
	local picked: { string } = {}
	for index = 1, math.min(run.def.capacity, #candidates) do
		table.insert(picked, candidates[index].id)
	end
	return picked
end

-- Premier instant où une case à portée deviendra éligible (nil : aucune culture à portée).
local function nextEligible(data: PlayerData, run: DroneRun): number?
	local earliest: number? = nil
	for _, tileId in run.reach do
		local tile = data.farm.tiles[tileId]
		if tile then
			local at = tile.plantedAt + tile.growTime + run.def.graceDelay
			if earliest == nil or at < earliest then
				earliest = at
			end
		end
	end
	return earliest
end

-- Replantation après une récolte (comme FarmService.PlantTile, à l'instant de la récolte) : graine sélectionnée,
-- pousse effective (bonus équipés), tirage de mutation serveur avec la chance du moment (améliorations, familiers,
-- Rosée chanceuse active ; la Pluie mutagène n'est pas rejouée hors ligne).
local function replant(data: PlayerData, tileId: string, at: number, seed: string, roll: Roll)
	local luck = Bonuses.luck(data, Quests.luckBoost(data, at))
	local mutation = roll(luck)
	data.farm.tiles[tileId] = {
		plantId = seed,
		plantedAt = at,
		growTime = Economy.growTime(data, seed),
		mutation = if mutation ~= MutationConfig.NORMAL and MutationConfig.get(mutation) then mutation else nil,
	}
end

local function credit(data: PlayerData, report: OfflineReport, amount: Types.BigNum)
	if BigNum.isZero(amount) then
		return
	end
	data.currencies.coins = BigNum.add(data.currencies.coins, amount)
	ProgressionMath.recordEarnings(data, amount)
	report.coins = BigNum.add(report.coins, amount)
end

local function recordSale(report: OfflineReport, sale: Selling.SaleOutcome?): boolean
	if not sale then
		return false
	end
	report.sales += 1
	report.coins = BigNum.add(report.coins, sale.total)
	return true
end

-- Rejoue les actions des drones sur [start, stopAt] (événement par événement). Retourne (sac plein sans comptoir
-- actif, au moins une vente faite).
local function runDrones(
	data: PlayerData,
	report: OfflineReport,
	start: number,
	stopAt: number,
	options: Options
): (boolean, boolean)
	local roll = options.roll
	local pause = options.yield
	local pauseEvery = math.max(1, options.yieldEvery or 500)
	local actions = 0
	local fleet = DroneLogic.fleet(data)
	local tiles = Expansions.unlockedTiles(data)
	table.sort(tiles)
	local runs: { DroneRun } = {}
	for index, def in fleet do
		local home = DroneLogic.homePosition(index, #fleet)
		local reach: { string } = {}
		for _, tileId in tiles do
			if DroneLogic.inRange(home, tileId, def.range) then
				table.insert(reach, tileId)
			end
		end
		local interval = DroneLogic.interval(def, data)
		-- Premières actions étalées comme DroneService.layoutDrones.
		table.insert(
			runs,
			{ def = def, interval = interval, nextAt = start + interval * index / #fleet, reach = reach }
		)
	end
	local seed = selectedSeed(data)
	local soldOnce = false
	while true do
		local run: DroneRun? = nil
		for _, candidate in runs do
			if candidate.nextAt <= stopAt and (run == nil or candidate.nextAt < run.nextAt) then
				run = candidate
			end
		end
		local current = run
		if not current then
			return false, soldOnce
		end
		local at = current.nextAt
		current.nextAt = at + current.interval
		actions += 1
		if pause and actions % pauseEvery == 0 then
			pause()
		end
		local targets = pickTargets(data, current, at)
		if #targets == 0 then
			-- Saut des attentes : prochaine action utile sur la grille d'intervalles de ce drone.
			local eligible = nextEligible(data, current)
			if not eligible or eligible > stopAt then
				current.nextAt = math.huge
			elseif eligible > at then
				current.nextAt = at + math.ceil((eligible - at) / current.interval - 1e-9) * current.interval
			end
			continue
		end
		for _, tileId in targets do
			local valid: boolean, failure: HarvestRules.Failure? = HarvestRules.check(data, tileId, at)
			if not valid and failure == "bag_full" then
				-- Sac plein : le comptoir (installé et activé) vend d'abord, comme HarvestService en ligne.
				if recordSale(report, Automation.autoSell(data, at)) then
					soldOnce = true
					valid, failure = HarvestRules.check(data, tileId, at)
				end
			end
			if not valid then
				if failure == "bag_full" then
					return true, soldOnce -- plus rien ne libère le sac : les drones attendent jusqu'au retour
				end
				continue
			end
			-- Événements du monde non rejoués hors ligne (part de valeur 0) ; un boost Engrais actif à `at` compte.
			local outcome = HarvestRules.apply(data, tileId, at, "drone", 0)
			report.harvests += 1
			if outcome.discovered then
				report.discoveries += 1
			end
			report.levelUps += #outcome.petLevelUps
			report.missions += #outcome.questsCompleted
			credit(data, report, outcome.eventBonus)
			replant(data, tileId, at, seed, roll)
			if recordSale(report, Automation.autoSell(data, at)) then
				soldOnce = true
			end
		end
	end
end

-- Règle la production hors ligne depuis la dernière sauvegarde ou le dernier règlement. Modifie `data` (récoltes,
-- cultures, sac, Coins gagnés, statistiques, Mutadex, familiers, missions) et retourne le bilan. Le bilan est
-- conservé dans `offline.report` sauf pour une absence trop courte ou une révision périmée (aucun écran).
function Offline.settle(data: PlayerData, now: number, options: Options): OfflineReport
	local start, away, counted = Offline.window(data, now)
	local report = newReport(now, away)
	local offline = data.offline
	offline.settledAt = math.max(if isTime(offline.settledAt) then offline.settledAt else 0, now)

	if options.expectedRevision ~= nil and data.progression.revision ~= options.expectedRevision then
		report.reason = "stale_revision"
		report.seen = true
		return report
	end
	if away < GameConfig.Offline.MinSeconds then
		report.reason = "too_short"
		report.seen = true
		return report
	end
	local fleetSize = #DroneLogic.fleet(data)
	if fleetSize == 0 or not Automation.dronesEnabled(data) then
		report.reason = if fleetSize == 0 then "no_drones" else "paused"
		report.seen = away < TIP_SECONDS
		offline.report = report
		return report
	end

	local before = Inventory.count(data.bag.items)
	local stoppedBagFull, sold = runDrones(data, report, start, start + counted, options)
	local after = Inventory.count(data.bag.items)
	report.stoppedBagFull = stoppedBagFull
	report.countedSeconds = math.floor(counted)
	-- Objets laissés par l'absence : après une vente, le sac ne contient plus que des récoltes hors ligne.
	report.bagAdded = if sold then after else math.max(0, after - before)
	offline.totalSeconds += report.countedSeconds
	offline.totalCoins = BigNum.add(offline.totalCoins, report.coins)
	offline.report = report
	return report
end

-- Lignes de l'écran « Pendant ton absence » (texte français, testé) : durée d'absence et durée prise en compte,
-- gains, puis conseils selon la raison (aucun drone, drones en pause, sac plein sans comptoir).
function Offline.describeReport(report: OfflineReport): { string }
	local lines: { string } = {}
	local counted = report.countedSeconds
	if report.reason == "ok" then
		local capped = counted >= GameConfig.Offline.MaxSeconds and report.awaySeconds > counted
		table.insert(
			lines,
			string.format(
				"Absent %s · production comptée : %s%s",
				Format.duration(report.awaySeconds),
				Format.duration(counted),
				if capped then " (plafond de 2 h)" else ""
			)
		)
		table.insert(lines, string.format("Tes drones ont récolté %s plante(s).", Format.number(report.harvests)))
		if report.sales > 0 then
			table.insert(
				lines,
				string.format(
					"Le comptoir a vendu %s fois : +%s Coins.",
					Format.number(report.sales),
					Format.bigNum(report.coins)
				)
			)
		elseif not BigNum.isZero(report.coins) then
			table.insert(lines, string.format("Bonus de récolte : +%s Coins.", Format.bigNum(report.coins)))
		end
		if report.bagAdded > 0 then
			table.insert(lines, string.format("Ajouté à ton sac : %s objet(s).", Format.number(report.bagAdded)))
		end
		local extras: { string } = {}
		if report.discoveries > 0 then
			table.insert(extras, string.format("%d découverte(s) au Mutadex", report.discoveries))
		end
		if report.levelUps > 0 then
			table.insert(extras, string.format("+%d niveau(x) de familiers", report.levelUps))
		end
		if report.missions > 0 then
			table.insert(extras, string.format("%d mission(s) terminée(s)", report.missions))
		end
		if #extras > 0 then
			table.insert(lines, table.concat(extras, " · ") .. ".")
		end
		if report.stoppedBagFull then
			table.insert(
				lines,
				"Ton sac s'est rempli : tes drones se sont arrêtés. Le comptoir automatique vend pour toi en ton absence."
			)
		end
	elseif report.reason == "no_drones" then
		table.insert(
			lines,
			string.format("Absent %s : aucun drone, rien n'a été récolté.", Format.duration(report.awaySeconds))
		)
		table.insert(lines, "Achète des drones à la station DRONES : ils récoltent en ton absence (2 h au plus).")
	elseif report.reason == "paused" then
		table.insert(
			lines,
			string.format("Absent %s : tes drones étaient en pause.", Format.duration(report.awaySeconds))
		)
		table.insert(lines, "Réactive-les dans le panneau Automatisation pour produire en ton absence.")
	end
	return lines
end

return table.freeze(Offline)
