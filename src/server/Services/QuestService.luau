--!strict
-- QuestService — missions quotidiennes et hebdomadaires (Phase 4, jalon D), côté serveur uniquement.
-- Tirage : au chargement du profil puis à chaque changement de période (contrôle toutes les 15 s), par la règle pure
-- Quests.refresh (déterministe par joueur et période, puis SAUVEGARDÉ : un changement de serveur ne retire rien).
-- Progression : enregistrée dans le mutateur de chaque action (HarvestRules pour les récoltes, EconomyService pour
-- les ventes, PetService pour les éclosions, RebirthService pour les rebirths) ; ce service annonce les missions
-- terminées par les récoltes (signal HarvestService.Harvested).
-- Récupération : le client n'envoie que l'identifiant (QuestClaim : chaîne ≤ 32, 4 req/s, aucune transition en
-- cours) ; Quests.claim vérifie période, achèvement et récupération dans UN mutateur → une seule récompense.
-- API : Refresh, Claim, Record (outillage Studio).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local QuestConfig = require(Shared.Config.QuestConfig)
local Types = require(Shared.Types)
local Format = require(Shared.Util.Format)
local Quests = require(Shared.Util.Quests)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local HarvestService = require(script.Parent.HarvestService)
local ProgressionService = require(script.Parent.ProgressionService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)
local QuestNotifier = require(script.Parent.Parent.Infra.QuestNotifier)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

local limiter = RateLimiter.new(4, 4)

local QuestService = {}

local CLAIM_MESSAGES: { [string]: string } = {
	expired = "Cette mission a expiré : de nouvelles missions sont disponibles.",
	not_completed = "Mission pas encore terminée.",
	reserve_full = "Réserve d'Œufs des missions pleine : ouvre des œufs, puis récupère cette récompense.",
}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- Tire les missions des périodes échues. `announce` : prévient le joueur (changement de période en jeu).
function QuestService.Refresh(player: Player, announce: boolean)
	local data = DataService.GetData(player)
	if not data or not Quests.needsRefresh(data, serverNow()) then
		return
	end
	local renewed: { QuestConfig.Kind } = {}
	DataService.Update(player, function(d)
		renewed = Quests.refresh(d, player.UserId, serverNow())
	end)
	if announce then
		for _, kind in renewed do
			Notifier.send(
				player,
				"info",
				if kind == "daily"
					then "Nouvelles missions quotidiennes disponibles !"
					else "Nouvelles missions de la semaine disponibles !"
			)
		end
	end
end

function QuestService.Claim(player: Player, missionId: string): (boolean, string?)
	if ProgressionService.IsBusy(player) or not DataService.GetData(player) then
		return false, "busy"
	end
	local outcome: Quests.ClaimOutcome? = nil
	local failure: Quests.ClaimFailure? = nil
	DataService.Update(player, function(data)
		outcome, failure = Quests.claim(data, missionId, serverNow())
	end)
	local result = outcome
	if not result then
		local message = if failure then CLAIM_MESSAGES[failure] else nil
		if message then
			Notifier.send(player, "error", message)
		end
		if failure == "expired" then
			QuestService.Refresh(player, true)
		end
		return false, failure
	end
	Notifier.send(
		player,
		"success",
		string.format("Récompense récupérée : %s", Quests.rewardText(result.mission, Format.bigNum))
	)
	if result.eggsOverflow > 0 then -- garde-fou : la récupération est refusée avant d'en arriver là
		warn(string.format("[QuestService] %d œuf(s) non ajoutés pour %d", result.eggsOverflow, player.UserId))
	end
	return true, nil
end

-- Outillage Studio (DevService) : progression directe d'un objectif, comme par l'action réelle.
function QuestService.Record(player: Player, objective: string, amount: number, plantId: string?): number
	local completed: { Types.Mission } = {}
	DataService.Update(player, function(data)
		completed = Quests.record(data, objective, amount, serverNow(), plantId)
	end)
	QuestNotifier.completed(player, completed)
	return #completed
end

function QuestService.Init()
	DataService.ProfileLoaded:Connect(function(player: Player)
		QuestService.Refresh(player, false)
	end)
	HarvestService.Harvested:Connect(function(player: Player, outcome)
		QuestNotifier.completed(player, outcome.questsCompleted)
	end)
	Net.event(Net.Events.QuestClaim).OnServerEvent:Connect(function(player: Player, missionId: unknown)
		if typeof(missionId) ~= "string" then
			return
		end
		local id = missionId :: string
		if #id == 0 or #id > QuestConfig.MaxIdLength or not limiter:allow(player) then
			return
		end
		QuestService.Claim(player, id)
	end)
end

function QuestService.Start()
	task.spawn(function()
		while true do
			task.wait(QuestConfig.RefreshInterval)
			for _, player in Players:GetPlayers() do
				-- Une donnée inattendue chez un joueur ne doit pas arrêter le renouvellement pour tous les autres.
				xpcall(QuestService.Refresh, function(err: any)
					warn(
						string.format(
							"[QuestService] Renouvellement en échec pour %d : %s",
							player.UserId,
							tostring(err)
						)
					)
				end, player, true)
			end
		end
	end)
end

return QuestService
