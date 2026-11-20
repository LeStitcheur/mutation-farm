--!strict
-- Tirage pondéré EXCLUSIF des mutations (un seul résultat par plantation).
-- Pur et déterministe : l'aléa `r` ∈ [0, 1) est fourni par l'appelant (serveur : Random:NextNumber()).

local Types = require(script.Parent.Parent.Types)

type Weight = Types.MutationWeight

local NORMAL = "normal"

local MutationRoll = {}

function MutationRoll.validate(weights: { Weight }): (boolean, string?)
	if #weights == 0 then
		return false, "table de poids vide"
	end
	local seen: { [string]: boolean } = {}
	local total = 0
	local hasNormal = false
	for _, entry in weights do
		if type(entry.id) ~= "string" or entry.id == "" then
			return false, "identifiant invalide"
		end
		if seen[entry.id] then
			return false, "identifiant dupliqué : " .. entry.id
		end
		seen[entry.id] = true
		local w = entry.weight
		if type(w) ~= "number" or w ~= w or w < 0 or w == math.huge then
			return false, "poids invalide pour " .. entry.id
		end
		if entry.id == NORMAL then
			hasNormal = true
		end
		total += w
	end
	if not hasNormal then
		return false, "le résultat 'normal' est obligatoire"
	end
	if total <= 0 then
		return false, "somme des poids nulle"
	end
	return true, nil
end

function MutationRoll.total(weights: { Weight }): number
	local total = 0
	for _, entry in weights do
		total += entry.weight
	end
	return total
end

-- Multiplie tous les poids non normaux par `luck` (≥ 0). Retourne une nouvelle table.
function MutationRoll.applyLuck(weights: { Weight }, luck: number): { Weight }
	local factor = math.max(0, luck)
	local result: { Weight } = {}
	for _, entry in weights do
		local weight = if entry.id == NORMAL then entry.weight else entry.weight * factor
		table.insert(result, { id = entry.id, weight = weight })
	end
	return result
end

function MutationRoll.pick(weights: { Weight }, r: number): string
	local total = MutationRoll.total(weights)
	local target = math.clamp(r, 0, 1) * total
	local accumulated = 0
	local lastPositive = NORMAL
	for _, entry in weights do
		if entry.weight > 0 then
			accumulated += entry.weight
			lastPositive = entry.id
			if target < accumulated then
				return entry.id
			end
		end
	end
	return lastPositive
end

function MutationRoll.probabilities(weights: { Weight }): { [string]: number }
	local total = MutationRoll.total(weights)
	local result: { [string]: number } = {}
	for _, entry in weights do
		result[entry.id] = if total > 0 then entry.weight / total else 0
	end
	return result
end

function MutationRoll.expectedMultiplier(weights: { Weight }, multipliers: { [string]: number }): number
	local expected = 0
	for id, probability in MutationRoll.probabilities(weights) do
		expected += probability * (multipliers[id] or 1)
	end
	return expected
end

return MutationRoll
