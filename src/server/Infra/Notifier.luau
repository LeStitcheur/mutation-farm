--!strict
-- Notifications (toasts) envoyées au client, avec variante anti-spam.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)

local lastSent: { [Player]: { [string]: number } } = {}

Players.PlayerRemoving:Connect(function(player: Player)
	lastSent[player] = nil
end)

local Notifier = {}

function Notifier.send(player: Player, kind: Types.NotifyKind, text: string)
	local payload: Types.Notification = { kind = kind, text = text }
	Net.event(Net.Events.Notify):FireClient(player, payload)
end

-- N'envoie pas deux fois la même notification `key` en moins de `interval` secondes.
function Notifier.sendThrottled(player: Player, key: string, interval: number, kind: Types.NotifyKind, text: string)
	local now = os.clock()
	local perPlayer = lastSent[player]
	if not perPlayer then
		perPlayer = {}
		lastSent[player] = perPlayer
	end
	local previous = perPlayer[key]
	if previous and now - previous < interval then
		return
	end
	perPlayer[key] = now
	Notifier.send(player, kind, text)
end

return Notifier
