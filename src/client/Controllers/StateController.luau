--!strict
-- StateController — dernier état joueur reçu du serveur (lecture seule côté client).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)

local current: Types.ClientState? = nil

local StateController = {
	Changed = Signal.new() :: Signal.Signal<Types.ClientState>,
	LoadStatusChanged = Signal.new() :: Signal.Signal<Types.LoadStatus>,
}

function StateController.Get(): Types.ClientState?
	return current
end

function StateController.Init()
	Net.event(Net.Events.StateSync).OnClientEvent:Connect(function(state: Types.ClientState)
		current = state
		StateController.Changed:Fire(state)
	end)
	Net.event(Net.Events.LoadStatus).OnClientEvent:Connect(function(status: Types.LoadStatus)
		StateController.LoadStatusChanged:Fire(status)
	end)
end

function StateController.Start() end

return StateController
