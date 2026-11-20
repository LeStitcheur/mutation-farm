--!strict
-- Géométrie des fermes en coordonnées LOCALES (studs), indépendante de l'API Roblox.
-- Le serveur convertit ces positions en CFrame. Axe +Z local = avant de la parcelle (marché, apparition).

export type Vec3 = { x: number, y: number, z: number }

export type PlotDef = {
	id: string,
	order: number,
	origin: Vec3,
	rows: number,
	cols: number,
	default: boolean,
}

local TILE_SIZE = 8
local TILE_PITCH = 10
local MAX_SLOTS = 8
local SLOT_COLUMNS = 4
local SLOT_SPACING_X = 130
local SLOT_SPACING_Z = 150

local plots: { PlotDef } = {
	{ id = "main", order = 1, origin = { x = 0, y = 0, z = 0 }, rows = 3, cols = 3, default = true },
	{ id = "west", order = 2, origin = { x = -34, y = 0, z = 0 }, rows = 3, cols = 3, default = false },
	{ id = "east", order = 3, origin = { x = 34, y = 0, z = 0 }, rows = 3, cols = 3, default = false },
	{ id = "terrace", order = 4, origin = { x = 0, y = 10, z = -34 }, rows = 3, cols = 3, default = false },
}

local plotById: { [string]: PlotDef } = {}
for _, def in plots do
	plotById[def.id] = def
end

local FarmLayout = {
	TileSize = TILE_SIZE,
	TilePitch = TILE_PITCH,
	TileHeight = 0.6,
	MaxSlots = MAX_SLOTS,
	Plots = plots,
	-- Éléments fixes de la parcelle (y = 0 : sol du monde ; socle de 1 stud).
	Features = {
		platformCenter = { x = 0, y = 0.5, z = -6 } :: Vec3,
		platformSize = { x = 104, y = 1, z = 96 } :: Vec3,
		groundTop = 1,
		sellStand = { x = 14, y = 1, z = 26 } :: Vec3,
		sign = { x = -14, y = 1, z = 26 } :: Vec3,
		spawn = { x = 0, y = 4, z = 36 } :: Vec3,
		droneStation = { x = -32, y = 1, z = 26 } :: Vec3, -- station d'achat des drones (avant gauche)
		droneHome = { x = 0, y = 9, z = 0 } :: Vec3, -- point d'attente central des drones (au-dessus de « main »)
		droneSpacing = 6, -- écart entre les points d'attente de deux drones (studs)
	},
}

function FarmLayout.getPlot(id: string): PlotDef?
	return plotById[id]
end

function FarmLayout.tileId(plotId: string, index: number): string
	return plotId .. ":" .. tostring(index)
end

function FarmLayout.parseTileId(tileId: string): (string?, number?)
	local plotId, indexText = string.match(tileId, "^(%a+):(%d+)$")
	if not plotId or not indexText then
		return nil, nil
	end
	local plot = plotById[plotId]
	local index = tonumber(indexText)
	if not plot or not index or index < 1 or index > plot.rows * plot.cols then
		return nil, nil
	end
	return plotId, index
end

function FarmLayout.tileIds(plotId: string): { string }
	local plot = plotById[plotId]
	local result: { string } = {}
	if plot then
		for index = 1, plot.rows * plot.cols do
			table.insert(result, FarmLayout.tileId(plotId, index))
		end
	end
	return result
end

-- Centre de la case au niveau du sol de la parcelle (avant socle).
function FarmLayout.tileLocalPosition(tileId: string): Vec3?
	local plotId, index = FarmLayout.parseTileId(tileId)
	if not plotId or not index then
		return nil
	end
	local plot = plotById[plotId]
	local row = (index - 1) // plot.cols + 1
	local col = (index - 1) % plot.cols + 1
	return {
		x = plot.origin.x + (col - (plot.cols + 1) / 2) * TILE_PITCH,
		y = plot.origin.y,
		z = plot.origin.z + (row - (plot.rows + 1) / 2) * TILE_PITCH,
	}
end

function FarmLayout.defaultPlots(): { [string]: boolean }
	local result: { [string]: boolean } = {}
	for _, def in plots do
		if def.default then
			result[def.id] = true
		end
	end
	return result
end

function FarmLayout.isTileUnlocked(unlockedPlots: { [string]: boolean }, tileId: string): boolean
	local plotId = FarmLayout.parseTileId(tileId)
	return plotId ~= nil and unlockedPlots[plotId] == true
end

-- Position monde (x, z) et orientation (yaw, radians) de l'emplacement `slot` (1..MaxSlots).
-- Deux rangées face à face : l'avant de chaque parcelle regarde l'allée centrale.
function FarmLayout.slotTransform(slot: number): (number, number, number)
	assert(slot >= 1 and slot <= MAX_SLOTS and slot % 1 == 0, "FarmLayout.slotTransform : emplacement invalide")
	local row = (slot - 1) // SLOT_COLUMNS
	local col = (slot - 1) % SLOT_COLUMNS
	local x = (col - (SLOT_COLUMNS - 1) / 2) * SLOT_SPACING_X
	if row == 0 then
		return x, -SLOT_SPACING_Z / 2, 0
	end
	return x, SLOT_SPACING_Z / 2, math.pi
end

return table.freeze(FarmLayout)
