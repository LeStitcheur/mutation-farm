--!strict
-- QuestNotifier — annonce des missions terminées (Phase 4, jalon D). Les progressions sont enregistrées dans le
-- mutateur de chaque action (récolte, vente, éclosion, rebirth) par la règle pure Util/Quests ; les services
-- concernés passent ici la liste des missions terminées. Ne dépend que de Notifier (aucune dépendance circulaire).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Quests = require(ReplicatedStorage.Shared.Util.Quests)
local Notifier = require(script.Parent.Notifier)

local QuestNotifier = {}

function QuestNotifier.completed(player: Player, missions: { Types.Mission })
	for _, mission in missions do
		Notifier.send(
			player,
			"success",
			string.format("Mission terminée : %s — récupère ta récompense (touche J) !", Quests.describe(mission))
		)
	end
end

return table.freeze(QuestNotifier)
