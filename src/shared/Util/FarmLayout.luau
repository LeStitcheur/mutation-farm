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

-- Pavé (centre et dimensions, coordonnées locales) et emprise au sol (plan XZ).
export type Box = { center: Vec3, size: Vec3 }
export type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }

local TILE_SIZE = 8
local TILE_PITCH = 10
local MAX_SLOTS = 8
local SLOT_COLUMNS = 4
local SLOT_SPACING_X = 130
local SLOT_SPACING_Z = 150
local BORDER_THICKNESS = 0.8 -- bordures en bois autour d'une parcelle (FarmService)
local TERRACE_MARGIN = 1 -- le socle d'une terrasse dépasse de 1 stud autour des cases
-- Escalier des parcelles surélevées : marches de 1 stud (franchissables sans saut), 2 studs de profondeur.
local STAIR_RISE = 1
local STAIR_RUN = 2
local STAIR_WIDTH = 8

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
	BorderThickness = BORDER_THICKNESS,
	TerraceMargin = TERRACE_MARGIN,
	StairRise = STAIR_RISE,
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
		-- Point d'attente central des drones, au-dessus de « main » et du niveau de la terrasse (sol à 11) : les
		-- allers-retours vers la terrasse passent au-dessus de son socle.
		droneHome = { x = 0, y = 12, z = 0 } :: Vec3,
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

-- Emprise au sol d'une parcelle (cases + bordures, ou socle pour une terrasse), coordonnées locales.
function FarmLayout.plotRect(plotId: string): Rect?
	local plot = plotById[plotId]
	if not plot then
		return nil
	end
	local margin = if plot.origin.y > 0 then math.max(TERRACE_MARGIN, BORDER_THICKNESS) else BORDER_THICKNESS
	local halfWidth = plot.cols * TILE_PITCH / 2 + margin
	local halfDepth = plot.rows * TILE_PITCH / 2 + margin
	return {
		minX = plot.origin.x - halfWidth,
		maxX = plot.origin.x + halfWidth,
		minZ = plot.origin.z - halfDepth,
		maxZ = plot.origin.z + halfDepth,
	}
end

-- Escalier d'accès d'une parcelle surélevée (vide pour une parcelle au sol) : marches pleines posées sur le socle de
-- la ferme, le long du flanc +X, de la plus basse (loin du flanc) à la plus haute (contre le socle, au niveau du
-- sol de la terrasse). Chaque marche monte de StairRise (≤ 1 stud : franchissable sans saut, testé).
function FarmLayout.stairs(plotId: string): { Box }
	local plot = plotById[plotId]
	local steps: { Box } = {}
	if not plot or plot.origin.y <= 0 then
		return steps
	end
	local groundTop = FarmLayout.Features.groundTop
	local face = plot.origin.x + plot.cols * TILE_PITCH / 2 + TERRACE_MARGIN
	local count = math.ceil(plot.origin.y / STAIR_RISE - 1e-9)
	for index = 1, count do
		local height = math.min(index * STAIR_RISE, plot.origin.y)
		table.insert(steps, {
			center = { x = face + (count - index + 0.5) * STAIR_RUN, y = groundTop + height / 2, z = plot.origin.z },
			size = { x = STAIR_RUN, y = height, z = STAIR_WIDTH },
		})
	end
	return steps
end

-- Emprise au sol de l'escalier d'une parcelle (nil sans escalier).
function FarmLayout.stairsRect(plotId: string): Rect?
	local steps = FarmLayout.stairs(plotId)
	if #steps == 0 then
		return nil
	end
	local rect: Rect = { minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge }
	for _, step in steps do
		rect.minX = math.min(rect.minX, step.center.x - step.size.x / 2)
		rect.maxX = math.max(rect.maxX, step.center.x + step.size.x / 2)
		rect.minZ = math.min(rect.minZ, step.center.z - step.size.z / 2)
		rect.maxZ = math.max(rect.maxZ, step.center.z + step.size.z / 2)
	end
	return rect
end

-- Emprise du socle de la ferme (coordonnées locales) : tout élément d'une ferme doit y tenir (testé).
function FarmLayout.farmRect(): Rect
	local features = FarmLayout.Features
	local center, size = features.platformCenter, features.platformSize
	return {
		minX = center.x - size.x / 2,
		maxX = center.x + size.x / 2,
		minZ = center.z - size.z / 2,
		maxZ = center.z + size.z / 2,
	}
end

-- Emprise MONDE du socle de la ferme de l'emplacement `slot` (orientations 0 ou π : rectangle aligné aux axes).
function FarmLayout.slotRect(slot: number): Rect
	local x, z, yaw = FarmLayout.slotTransform(slot)
	local rect = FarmLayout.farmRect()
	local sign = if math.abs(yaw) < 1e-6 then 1 else -1
	local a, b = x + sign * rect.minX, x + sign * rect.maxX
	local c, d = z + sign * rect.minZ, z + sign * rect.maxZ
	return { minX = math.min(a, b), maxX = math.max(a, b), minZ = math.min(c, d), maxZ = math.max(c, d) }
end

-- Emprises au sol des éléments fixes construits par FarmService et DroneService (marché, panneau, station des
-- drones, zone d'apparition), coordonnées locales : aucune parcelle ni escalier ne doit les recouvrir (testé).
function FarmLayout.featureRects(): { [string]: Rect }
	local features = FarmLayout.Features
	local function around(point: Vec3, halfX: number, halfZ: number): Rect
		return { minX = point.x - halfX, maxX = point.x + halfX, minZ = point.z - halfZ, maxZ = point.z + halfZ }
	end
	return {
		sellStand = around(features.sellStand, 4.75, 2.25), -- toit 9,5 × 4,5
		sign = around(features.sign, 4.5, 0.5), -- panneau 9 × 0,6
		droneStation = around(features.droneStation, 3.5, 3.5), -- socle 7 × 7
		spawn = around(features.spawn, 3, 3),
	}
end

function FarmLayout.rectsOverlap(a: Rect, b: Rect): boolean
	return a.minX < b.maxX and b.minX < a.maxX and a.minZ < b.maxZ and b.minZ < a.maxZ
end

function FarmLayout.rectInside(inner: Rect, outer: Rect): boolean
	return inner.minX >= outer.minX
		and inner.maxX <= outer.maxX
		and inner.minZ >= outer.minZ
		and inner.maxZ <= outer.maxZ
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
