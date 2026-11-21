--!strict
-- MutadexService — annonces du Mutadex (Phase 4, jalon A). L'enregistrement des récoltes et l'attribution des paliers
-- sont faits par les règles pures (HarvestRules.apply → Mutadex.record / claimMilestones) DANS le mutateur de récolte,
-- pour le joueur comme pour les drones : ce service annonce les premières découvertes et les paliers accordés, et
-- accorde au chargement d'un profil les paliers déjà atteints mais pas encore accordés (configuration modifiée).
-- API : OnHarvest.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local MutadexConfig = require(Shared.Config.MutadexConfig)
local Mutadex = require(Shared.Util.Mutadex)
local DataService = require(script.Parent.DataService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)

local MutadexService = {}

local function announceMilestone(player: Player, milestone: MutadexConfig.MilestoneDef)
	local labels: { string } = {}
	for _, reward in milestone.rewards do
		table.insert(labels, reward.label)
	end
	Notifier.send(
		player,
		"success",
		string.format("Mutadex %d %% atteint ! Récompense : %s", milestone.percent, table.concat(labels, ", "))
	)
end

-- Annonce le résultat d'une récolte validée (première découverte, paliers accordés par cette découverte).
function MutadexService.OnHarvest(
	player: Player,
	plantId: string,
	mutationId: string,
	discovered: boolean,
	milestones: { MutadexConfig.MilestoneDef }
)
	if discovered then
		local entry = Mutadex.get(Mutadex.entryId(plantId, mutationId))
		if entry then
			Notifier.send(
				player,
				"success",
				string.format("Mutadex : nouvelle découverte — %s (%s) !", entry.name, entry.rarity.name)
			)
		end
	end
	for _, milestone in milestones do
		announceMilestone(player, milestone)
	end
end

function MutadexService.Init()
	DataService.ProfileLoaded:Connect(function(player: Player)
		local granted: { MutadexConfig.MilestoneDef } = {}
		DataService.Update(player, function(data)
			granted = Mutadex.claimMilestones(data, Workspace:GetServerTimeNow())
		end)
		if #granted == 0 then
			return
		end
		-- Annonces différées : ProfileLoaded est émis juste AVANT l'état « ready » envoyé au client.
		task.defer(function()
			if player.Parent == nil then
				return
			end
			for _, milestone in granted do
				announceMilestone(player, milestone)
			end
		end)
	end)
end

function MutadexService.Start() end

return MutadexService
