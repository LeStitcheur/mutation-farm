--!strict
-- HarvestService — récoltes validées côté serveur, communes au joueur et aux drones : propriété, maturité
-- (horloge serveur), proximité (personnage du joueur ou portée du drone), capacité du sac ; bonus de précision
-- pour le joueur seulement ; replantation automatique (nouveau tirage de mutation).
-- Anti-duplication : la validation est REFAITE puis appliquée dans le même mutateur synchrone (HarvestRules),
-- donc un joueur et un drone ne peuvent jamais récolter deux fois la même culture.
-- API : Harvest (joueur), HarvestForDrone (DroneService) ; signal Harvested(player, outcome, source) émis après
-- chaque récolte validée (familiers : passages de niveau ; missions : progression).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local MutationConfig = require(Shared.Config.MutationConfig)
local PlantConfig = require(Shared.Config.PlantConfig)
local Types = require(Shared.Types)
local Automation = require(Shared.Util.Automation)
local BigNum = require(Shared.Util.BigNum)
local DroneLogic = require(Shared.Util.DroneLogic)
local FarmLayout = require(Shared.Util.FarmLayout)
local HarvestRules = require(Shared.Util.HarvestRules)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local EventService = require(script.Parent.EventService)
local FarmService = require(script.Parent.FarmService)
local MutadexService = require(script.Parent.MutadexService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

export type HarvestFailure =
	"not_loaded"
	| "invalid_tile"
	| "empty"
	| "not_ripe"
	| "too_far"
	| "out_of_range"
	| "bag_full"

local MAX_TILE_ID_LENGTH = 32

local limiter = RateLimiter.new(GameConfig.Harvest.RequestsPerSecond)

local HarvestService = {
	Harvested = Signal.new() :: Signal.Signal<Player, HarvestRules.Outcome, Types.HarvestSource>,
}

local function isCharacterNear(player: Player, part: BasePart): boolean
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not root or not root:IsA("BasePart") then
		return false
	end
	return (root.Position - part.Position).Magnitude <= GameConfig.Harvest.MaxDistance
end

local function notifyBagFull(player: Player, source: Types.HarvestSource)
	if source == "player" then
		Notifier.sendThrottled(
			player,
			"bag_full",
			GameConfig.Harvest.BagFullNoticeInterval,
			"error",
			"Sac plein ! Va vendre au marché."
		)
	else
		-- Conseil adapté : installer le comptoir automatique, ou le réactiver s'il est coupé (panneau Automatisation).
		local data = DataService.GetData(player)
		local hint = if data and Automation.hasSeller(data)
			then "Réactive la vente automatique (panneau Automatisation)."
			else "Va vendre au marché ou installe un comptoir automatique (panneau Automatisation)."
		Notifier.sendThrottled(
			player,
			"drone_bag_full",
			GameConfig.Drones.BagFullNoticeInterval,
			"info",
			"Tes drones attendent : sac plein ! " .. hint
		)
	end
end

-- Récolte commune. `isNear` : proximité propre à la source (personnage ou portée du drone).
local function harvest(
	player: Player,
	tileId: string,
	source: Types.HarvestSource,
	isNear: (BasePart) -> boolean,
	farFailure: HarvestFailure
): (boolean, HarvestFailure?)
	local data = DataService.GetData(player)
	if not data then
		return false, "not_loaded"
	end
	local part = FarmService.GetTilePart(player, tileId)
	if not part or not FarmService.OwnsTile(player, tileId) then
		return false, "invalid_tile"
	end
	local now = Workspace:GetServerTimeNow()
	-- Annotation explicite : sans elle, l'inférence élargit l'union de littéraux en `string`.
	local valid: boolean, failure: HarvestRules.Failure? = HarvestRules.check(data, tileId, now)
	if not valid and failure ~= "bag_full" then
		return false, failure
	end
	if not isNear(part) then
		return false, farFailure
	end
	if failure == "bag_full" then
		-- Sac plein : le comptoir automatique (s'il est installé et activé) vend d'abord, puis la récolte continue.
		if not EconomyService.AutoSell(player) then
			notifyBagFull(player, source)
			return false, "bag_full"
		end
	end

	-- Revalidation + application atomiques (aucun yield entre les deux). Floraison dorée lue à cet instant précis.
	local eventValueBonus = EventService.ValueBonus()
	local outcome: HarvestRules.Outcome? = nil
	DataService.Update(player, function(d)
		if HarvestRules.check(d, tileId, now) then
			outcome = HarvestRules.apply(d, tileId, now, source, eventValueBonus)
		end
	end)
	local result = outcome
	if not result then
		return false, "not_ripe"
	end
	local credit = BigNum.add(result.bonus, result.eventBonus)
	if not BigNum.isZero(credit) then
		EconomyService.AddCoins(player, credit)
	end
	-- Comptoir automatique : le sac est vendu dès qu'il atteint le seuil choisi (même règle que le marché).
	EconomyService.AutoSell(player)
	FarmService.PlantTile(player, tileId)

	local payload: Types.HarvestResult = {
		tileId = tileId,
		plantId = result.plantId,
		mutation = result.mutation,
		tier = result.tier,
		bonus = result.bonus,
		source = source,
		discovered = result.discovered,
		eventBonus = result.eventBonus,
	}
	Net.event(Net.Events.HarvestResult):FireClient(player, payload)
	MutadexService.OnHarvest(player, result.plantId, result.mutation, result.discovered, result.milestones)
	HarvestService.Harvested:Fire(player, result, source)
	local mutationDef = MutationConfig.get(result.mutation)
	local plant = PlantConfig.get(result.plantId)
	if mutationDef and plant and mutationDef.multiplier >= GameConfig.Mutations.NotifyMinMultiplier then
		Notifier.send(
			player,
			"success",
			string.format("Mutation %s ×%d récoltée : %s", mutationDef.name, mutationDef.multiplier, plant.name)
		)
	end
	return true, nil
end

-- Récolte manuelle (requête du client) : le personnage doit être à portée de la case.
function HarvestService.Harvest(player: Player, tileId: string): (boolean, HarvestFailure?)
	return harvest(player, tileId, "player", function(part: BasePart): boolean
		return isCharacterNear(player, part)
	end, "too_far")
end

-- Récolte par un drone du joueur : la case doit être à portée de son point d'attente (coordonnées locales).
function HarvestService.HarvestForDrone(
	player: Player,
	tileId: string,
	home: FarmLayout.Vec3,
	range: number
): (boolean, HarvestFailure?)
	return harvest(player, tileId, "drone", function(_part: BasePart): boolean
		return DroneLogic.inRange(home, tileId, range)
	end, "out_of_range")
end

function HarvestService.Init()
	Net.event(Net.Events.HarvestRequest).OnServerEvent:Connect(function(player: Player, tileId: unknown)
		if typeof(tileId) ~= "string" or #tileId == 0 or #tileId > MAX_TILE_ID_LENGTH then
			return
		end
		if not limiter:allow(player) then
			return
		end
		HarvestService.Harvest(player, tileId)
	end)
end

function HarvestService.Start() end

return HarvestService
