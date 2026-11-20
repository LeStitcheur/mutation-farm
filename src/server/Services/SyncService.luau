--!strict
-- SyncService — réplique l'état joueur (ClientView) au client, coalescé à ≤ 10 Hz et seulement si modifié.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Types = require(Shared.Types)
local ClientView = require(Shared.Util.ClientView)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

local dirty: { [Player]: boolean } = {}
local readyLimiter = RateLimiter.new(1, 2)

local SyncService = {}

local function flush(player: Player)
	dirty[player] = nil
	local data = DataService.GetData(player)
	if data and player.Parent == Players then
		Net.event(Net.Events.StateSync):FireClient(player, ClientView.build(data))
	end
end

-- Envoi immédiat (hors cadence).
function SyncService.Flush(player: Player)
	flush(player)
end

function SyncService.Init()
	local function markDirty(player: Player)
		dirty[player] = true
	end
	DataService.ProfileLoaded:Connect(markDirty)
	DataService.Changed:Connect(markDirty)
	Players.PlayerRemoving:Connect(function(player: Player)
		dirty[player] = nil
	end)
	-- Poignée de main : les événements émis avant la connexion des écouteurs client peuvent être perdus.
	-- Le client signale qu'il est prêt ; si le profil est déjà chargé, on renvoie statut + état complet.
	Net.event(Net.Events.ClientReady).OnServerEvent:Connect(function(player: Player)
		if not readyLimiter:allow(player) or not DataService.IsLoaded(player) then
			return
		end
		local status: Types.LoadStatus = { status = "ready", message = "" }
		Net.event(Net.Events.LoadStatus):FireClient(player, status)
		flush(player)
	end)
end

function SyncService.Start()
	local elapsed = 0
	RunService.Heartbeat:Connect(function(deltaTime: number)
		elapsed += deltaTime
		if elapsed < GameConfig.Sync.Interval then
			return
		end
		elapsed = 0
		for player in dirty do
			flush(player)
		end
	end)
end

return SyncService
