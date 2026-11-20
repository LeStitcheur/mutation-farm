--!strict
-- MutationService — tirage pondéré EXCLUSIF des mutations, côté serveur uniquement : un tirage par plantation
-- (un cycle de culture = une mutation principale au plus). Les poids viennent de Server.Config.MutationOdds
-- (jamais répliqués) ; le client ne fournit ni aléa ni résultat, il ne lit que l'attribut `Mutation` des cases.
-- API : Roll.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MutationConfig = require(Shared.Config.MutationConfig)
local MutationRoll = require(Shared.Util.MutationRoll)
local MutationOdds = require(script.Parent.Parent.Config.MutationOdds)

local rng = Random.new()
-- Chance de base (événements et améliorations de chance : phases ultérieures).
local weights = MutationRoll.applyLuck(MutationOdds.Weights, MutationOdds.Luck.Base)

local MutationService = {}

-- Mutation de la prochaine culture : identifiant de MutationConfig (MutationConfig.NORMAL le plus souvent).
function MutationService.Roll(): string
	return MutationRoll.pick(weights, rng:NextNumber())
end

function MutationService.Init()
	local ok, reason = MutationRoll.validate(weights)
	assert(ok, "MutationService : poids invalides (" .. tostring(reason) .. ")")
	for _, entry in weights do
		assert(MutationConfig.get(entry.id) ~= nil, "MutationService : mutation inconnue " .. entry.id)
	end
end

function MutationService.Start() end

return MutationService
