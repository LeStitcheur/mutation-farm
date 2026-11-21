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
-- Chance de base ; la chance du joueur (améliorations, plafonnée par Upgrades.luck) la multiplie.
local weights = MutationRoll.applyLuck(MutationOdds.Weights, MutationOdds.Luck.Base)
local weightsByLuck: { [number]: typeof(weights) } = { [1] = weights }

local MutationService = {}

-- Mutation de la prochaine culture : identifiant de MutationConfig (MutationConfig.NORMAL le plus souvent).
-- `luck` (≥ 1, calculée par le serveur à partir des améliorations) multiplie les poids non normaux.
function MutationService.Roll(luck: number?): string
	local factor = if luck and luck == luck and luck > 0 then luck else 1
	local scaled = weightsByLuck[factor]
	if not scaled then
		scaled = MutationRoll.applyLuck(MutationOdds.Weights, MutationOdds.Luck.Base * factor)
		weightsByLuck[factor] = scaled
	end
	return MutationRoll.pick(scaled, rng:NextNumber())
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
