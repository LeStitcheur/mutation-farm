--!strict
-- HarvestService — récolte manuelle validée côté serveur : propriété, maturité (horloge serveur),
-- distance, capacité du sac ; bonus de précision ; replantation automatique.
-- API : Harvest.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local MutationConfig = require(Shared.Config.MutationConfig)
local PlantConfig = require(Shared.Config.PlantConfig)
local Types = require(Shared.Types)
local BigNum = require(Shared.Util.BigNum)
local Economy = require(Shared.Util.Economy)
local Growth = require(Shared.Util.Growth)
local Inventory = require(Shared.Util.Inventory)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local FarmService = require(script.Parent.FarmService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

export type HarvestFailure = "not_loaded" | "invalid_tile" | "empty" | "not_ripe" | "too_far" | "bag_full"

local MAX_TILE_ID_LENGTH = 32

local limiter = RateLimiter.new(GameConfig.Harvest.RequestsPerSecond)

local HarvestService = {}

local function isNear(player: Player, part: BasePart): boolean
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not root or not root:IsA("BasePart") then
		return false
	end
	return (root.Position - part.Position).Magnitude <= GameConfig.Harvest.MaxDistance
end

function HarvestService.Harvest(player: Player, tileId: string): (boolean, HarvestFailure?)
	local data = DataService.GetData(player)
	if not data then
		return false, "not_loaded"
	end
	local part = FarmService.GetTilePart(player, tileId)
	if not part or not FarmService.OwnsTile(player, tileId) then
		return false, "invalid_tile"
	end
	local tile = data.farm.tiles[tileId]
	if not tile then
		return false, "empty"
	end
	local now = Workspace:GetServerTimeNow()
	if not Growth.isRipe(tile, now) then
		return false, "not_ripe"
	end
	if not isNear(player, part) then
		return false, "too_far"
	end
	local capacity = Economy.bagCapacity(data)
	if Inventory.isFull(data.bag.items, capacity) then
		Notifier.sendThrottled(
			player,
			"bag_full",
			GameConfig.Harvest.BagFullNoticeInterval,
			"error",
			"Sac plein ! Va vendre au marché."
		)
		return false, "bag_full"
	end

	local plantId = tile.plantId
	local mutation = tile.mutation or MutationConfig.NORMAL
	local tier: Types.PrecisionTier = Growth.precisionTier(now - Growth.ripeAt(tile))
	local bonus = Economy.precisionBonus(plantId, tier)
	local key = Economy.itemKey(plantId, mutation)

	DataService.Update(player, function(d)
		Inventory.add(d.bag.items, key, 1, capacity)
		d.stats.harvests += 1
		if tier == "perfect" then
			d.stats.perfectHarvests += 1
		end
		d.farm.tiles[tileId] = nil
	end)
	if not BigNum.isZero(bonus) then
		EconomyService.AddCoins(player, bonus)
	end
	FarmService.PlantTile(player, tileId)

	local result: Types.HarvestResult = {
		tileId = tileId,
		plantId = plantId,
		mutation = mutation,
		tier = tier,
		bonus = bonus,
	}
	Net.event(Net.Events.HarvestResult):FireClient(player, result)
	local mutationDef = MutationConfig.get(mutation)
	local plant = PlantConfig.get(plantId)
	if mutationDef and plant and mutationDef.multiplier >= GameConfig.Mutations.NotifyMinMultiplier then
		Notifier.send(
			player,
			"success",
			string.format("Mutation %s ×%d récoltée : %s", mutationDef.name, mutationDef.multiplier, plant.name)
		)
	end
	return true, nil
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
