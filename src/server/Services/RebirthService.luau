--!strict
-- RebirthService — rebirth (Phase 3, jalon A). Le client n'envoie qu'une intention et la révision de progression
-- qu'il affiche (entier validé, débit limité). La transition (verrou partagé, mutateur unique, replantation, flotte,
-- sauvegarde) est exécutée par ProgressionService.Run avec la règle pure Resets.rebirth.
-- API : Rebirth.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Types = require(Shared.Types)
local Format = require(Shared.Util.Format)
local Quests = require(Shared.Util.Quests)
local Resets = require(Shared.Util.Resets)
local Net = require(Shared.Net)
local ProgressionService = require(script.Parent.ProgressionService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)
local QuestNotifier = require(script.Parent.Parent.Infra.QuestNotifier)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

local limiter = RateLimiter.new(ProgressionConfig.Rebirth.RequestsPerSecond, 1)

local RebirthService = {}

function RebirthService.Rebirth(player: Player, expectedRevision: number): (boolean, string?)
	local completed: { Types.Mission } = {}
	local outcome, failure = ProgressionService.Run(player, "rebirth", function(data)
		local result, reason = Resets.rebirth(data, expectedRevision)
		if result then
			-- Missions « rebirth » : même mutateur que la transition (jamais comptée deux fois).
			completed = Quests.record(data, "rebirth", 1, Workspace:GetServerTimeNow())
		end
		return result, reason
	end, function(result: Resets.RebirthOutcome)
		QuestNotifier.completed(player, completed)
		Notifier.send(
			player,
			"success",
			string.format(
				"Rebirth %d ! +%s Mutation Essence · revenus %s",
				result.rebirths,
				Format.bigNum(result.essence),
				Format.multiplier(result.multiplier)
			)
		)
	end)
	if outcome == nil and failure == "below_threshold" then
		Notifier.send(player, "error", "Pas encore assez de Coins gagnés pendant ce cycle pour un rebirth.")
	end
	return outcome ~= nil, failure
end

function RebirthService.Init()
	Net.event(Net.Events.RebirthRequest).OnServerEvent:Connect(function(player: Player, expectedRevision: unknown)
		if not ProgressionService.IsValidRevision(expectedRevision) or not limiter:allow(player) then
			return
		end
		RebirthService.Rebirth(player, expectedRevision :: number)
	end)
end

function RebirthService.Start() end

return RebirthService
