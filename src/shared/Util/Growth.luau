--!strict
-- Croissance par timestamps et paliers de précision (pur, partagé serveur/client).

local Types = require(script.Parent.Parent.Types)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)

export type Growable = { plantedAt: number, growTime: number }

local Growth = {}

function Growth.ripeAt(tile: Growable): number
	return tile.plantedAt + tile.growTime
end

-- Progression dans [0, 1].
function Growth.progress(tile: Growable, now: number): number
	if tile.growTime <= 0 then
		return 1
	end
	return math.clamp((now - tile.plantedAt) / tile.growTime, 0, 1)
end

function Growth.isRipe(tile: Growable, now: number): boolean
	return now >= Growth.ripeAt(tile)
end

-- lateness = secondes écoulées depuis la maturité.
function Growth.precisionTier(lateness: number): Types.PrecisionTier
	if lateness < 0 then
		return "normal"
	end
	if lateness <= GameConfig.Harvest.PerfectWindow then
		return "perfect"
	end
	if lateness <= GameConfig.Harvest.GoodWindow then
		return "good"
	end
	return "normal"
end

return Growth
