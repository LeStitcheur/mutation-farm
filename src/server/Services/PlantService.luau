--!strict
-- PlantService — catalogue de graines du joueur : déblocage (Coins), sélection, durée de pousse effective.
-- API : GetSelectedSeed, ComputeGrowTime, UnlockSeed, SelectSeed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local PlantConfig = require(Shared.Config.PlantConfig)
local Types = require(Shared.Types)
local BigNum = require(Shared.Util.BigNum)
local Economy = require(Shared.Util.Economy)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

type PlayerData = Types.PlayerData

local MAX_ID_LENGTH = 32

local FAILURE_MESSAGES: { [string]: string } = {
	insufficient_funds = "Pas assez de Coins pour débloquer cette graine.",
	locked_order = "Débloque d'abord la graine précédente.",
	locked = "Cette graine n'est pas encore débloquée.",
}

local limiter = RateLimiter.new(GameConfig.Seeds.RequestsPerSecond)

local PlantService = {}

-- Graine utilisée pour les prochaines plantations (toujours valide et débloquée).
function PlantService.GetSelectedSeed(data: PlayerData): string
	local selected = data.seeds.selected
	if PlantConfig.get(selected) and data.seeds.unlocked[selected] then
		return selected
	end
	return GameConfig.StarterSeed
end

-- Durée de pousse effective, figée à la plantation. Phase 3 : améliorations et événements.
function PlantService.ComputeGrowTime(_data: PlayerData, plantId: string): number
	local plant = PlantConfig.get(plantId)
	assert(plant, "PlantService.ComputeGrowTime : plante inconnue " .. plantId)
	return plant.growTime
end

function PlantService.UnlockSeed(player: Player, plantId: string): (boolean, string?)
	local data = DataService.GetData(player)
	if not data then
		return false, "not_loaded"
	end
	local allowed, reason = Economy.canUnlockSeed(data, plantId)
	if not allowed then
		return false, reason
	end
	local plant = PlantConfig.get(plantId)
	if not plant then
		return false, "unknown"
	end
	if not EconomyService.TrySpendCoins(player, BigNum.fromNumber(plant.unlockPrice)) then
		return false, "insufficient_funds"
	end
	DataService.Update(player, function(d)
		d.seeds.unlocked[plantId] = true
		d.seeds.selected = plantId
	end)
	Notifier.send(
		player,
		"success",
		string.format("%s débloquée ! Elle remplacera tes cultures à chaque récolte.", plant.name)
	)
	return true, nil
end

function PlantService.SelectSeed(player: Player, plantId: string): (boolean, string?)
	local data = DataService.GetData(player)
	if not data then
		return false, "not_loaded"
	end
	if not PlantConfig.get(plantId) or not data.seeds.unlocked[plantId] then
		return false, "locked"
	end
	if data.seeds.selected == plantId then
		return true, nil
	end
	DataService.Update(player, function(d)
		d.seeds.selected = plantId
	end)
	return true, nil
end

local function handleRequest(player: Player, plantId: unknown, action: (Player, string) -> (boolean, string?))
	if typeof(plantId) ~= "string" or #plantId == 0 or #plantId > MAX_ID_LENGTH then
		return
	end
	if not limiter:allow(player) then
		return
	end
	local ok, reason = action(player, plantId)
	if not ok and reason then
		local message = FAILURE_MESSAGES[reason]
		if message then
			Notifier.send(player, "error", message)
		end
	end
end

function PlantService.Init()
	Net.event(Net.Events.UnlockSeed).OnServerEvent:Connect(function(player: Player, plantId: unknown)
		handleRequest(player, plantId, PlantService.UnlockSeed)
	end)
	Net.event(Net.Events.SelectSeed).OnServerEvent:Connect(function(player: Player, plantId: unknown)
		handleRequest(player, plantId, PlantService.SelectSeed)
	end)
end

function PlantService.Start() end

return PlantService
