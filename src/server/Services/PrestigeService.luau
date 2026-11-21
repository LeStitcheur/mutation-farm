--!strict
-- PrestigeService — prestige (Phase 3, jalon B). Le client n'envoie qu'une intention et la révision de progression
-- qu'il affiche (entier validé, débit limité). Mêmes garanties que le rebirth : ProgressionService.Run (verrou
-- partagé avec le rebirth, mutateur unique, replantation, flotte, sauvegarde) avec la règle pure Resets.prestige.
-- Une requête répétée trouve une révision périmée : jamais plusieurs récompenses.
-- API : Prestige.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Format = require(Shared.Util.Format)
local Resets = require(Shared.Util.Resets)
local Net = require(Shared.Net)
local ProgressionService = require(script.Parent.ProgressionService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

local FAILURE_MESSAGES: { [string]: string } = {
	not_enough_rebirths = "Pas encore assez de rebirths pour un prestige.",
	not_enough_coins = "Pas encore assez de Coins gagnés depuis le dernier prestige.",
}

local limiter = RateLimiter.new(ProgressionConfig.Prestige.RequestsPerSecond, 1)

local PrestigeService = {}

function PrestigeService.Prestige(player: Player, expectedRevision: number): (boolean, string?)
	local outcome, failure = ProgressionService.Run(player, "prestige", function(data)
		return Resets.prestige(data, expectedRevision)
	end, function(result: Resets.PrestigeOutcome)
		Notifier.send(
			player,
			"success",
			string.format(
				"Prestige %d ! +%s Primal Cores · multiplicateur de prestige %s",
				result.prestiges,
				Format.bigNum(result.cores),
				Format.multiplier(result.multiplier)
			)
		)
	end)
	local message = if outcome == nil and failure then FAILURE_MESSAGES[failure] else nil
	if message then
		Notifier.send(player, "error", message)
	end
	return outcome ~= nil, failure
end

function PrestigeService.Init()
	Net.event(Net.Events.PrestigeRequest).OnServerEvent:Connect(function(player: Player, expectedRevision: unknown)
		if not ProgressionService.IsValidRevision(expectedRevision) or not limiter:allow(player) then
			return
		end
		PrestigeService.Prestige(player, expectedRevision :: number)
	end)
end

function PrestigeService.Start() end

return PrestigeService
