--!strict
-- DroneRenderer — rendu LOCAL des drones (ancres serveur taguées « FarmDrone ») : vol stationnaire, pales qui
-- tournent, aller-retour vers la case récoltée (attributs TargetTile / ActionAt) et bulle « Sac plein ! » (Status).
-- Purement visuel : le serveur a déjà récolté quand l'animation démarre. Mise à jour à 30 Hz.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local DroneConfig = require(ReplicatedStorage.Shared.Config.DroneConfig)

local DRONE_TAG = "FarmDrone"
local TILE_TAG = "FarmTile"
local UPDATE_INTERVAL = 1 / 30
local FLIGHT_TIME = 1.6 -- aller-retour vers la case (s)
local HOVER_ABOVE_TILE = 3
local BLADE_SPEED = 25 -- rad/s

type Piece = { part: BasePart, offset: CFrame, spin: boolean }

type Visual = {
	anchor: BasePart,
	model: Model,
	pieces: { Piece },
	label: BillboardGui,
	seed: number,
	target: BasePart?,
	actionAt: number,
	connections: { RBXScriptConnection },
}

local visuals: { [BasePart]: Visual } = {}
local container: Folder? = nil

local DroneRenderer = {}

local function getContainer(): Folder
	if container and container.Parent then
		return container
	end
	local folder = Instance.new("Folder")
	folder.Name = "ClientDrones"
	folder.Parent = Workspace
	container = folder
	return folder
end

local function newPiece(
	model: Model,
	shape: Enum.PartType,
	size: Vector3,
	color: Color3,
	material: Enum.Material
): BasePart
	local part = Instance.new("Part")
	part.Shape = shape
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

local function findTile(anchor: BasePart, tileId: string): BasePart?
	local owner = anchor:GetAttribute("OwnerUserId")
	for _, tile in CollectionService:GetTagged(TILE_TAG) do
		if
			tile:IsA("BasePart")
			and tile:GetAttribute("OwnerUserId") == owner
			and tile:GetAttribute("TileId") == tileId
		then
			return tile
		end
	end
	return nil
end

local function refreshAction(visual: Visual)
	local tileId = visual.anchor:GetAttribute("TargetTile")
	local actionAt = visual.anchor:GetAttribute("ActionAt")
	visual.target = if type(tileId) == "string" and tileId ~= "" then findTile(visual.anchor, tileId) else nil
	visual.actionAt = if type(actionAt) == "number" then actionAt else 0
end

-- Bulle d'état : « Sac plein ! » (rouge) ou « En pause » (gris, drones coupés dans le panneau Automatisation).
local function refreshStatus(visual: Visual)
	local status = visual.anchor:GetAttribute("Status")
	local text = visual.label:FindFirstChildOfClass("TextLabel")
	visual.label.Enabled = status == "bag_full" or status == "paused"
	if text then
		text.Text = if status == "paused" then "En pause" else "Sac plein !"
		text.TextColor3 = if status == "paused" then Color3.fromRGB(176, 190, 197) else Color3.fromRGB(239, 83, 80)
	end
end

local function build(anchor: BasePart): Visual
	local droneType = anchor:GetAttribute("DroneType")
	local def = if type(droneType) == "string" then DroneConfig.get(droneType) else nil
	local color = if def then Color3.fromHex(def.color) else Color3.new(1, 1, 1)
	local dark = Color3.fromRGB(55, 71, 79)

	local model = Instance.new("Model")
	model.Name = "Drone_" .. anchor.Name
	local pieces: { Piece } = {}
	local vertical = CFrame.Angles(0, 0, math.rad(90)) -- axe des cylindres Roblox = X

	local body = newPiece(model, Enum.PartType.Cylinder, Vector3.new(0.6, 1.9, 1.9), color, Enum.Material.SmoothPlastic)
	table.insert(pieces, { part = body, offset = vertical, spin = false })
	local dome = newPiece(
		model,
		Enum.PartType.Ball,
		Vector3.new(0.9, 0.9, 0.9),
		Color3.fromRGB(178, 235, 242),
		Enum.Material.Neon
	)
	table.insert(pieces, { part = dome, offset = CFrame.new(0, 0.35, 0), spin = false })
	for _, angle in { 45, -45 } do
		local arm = newPiece(model, Enum.PartType.Block, Vector3.new(3.4, 0.15, 0.25), dark, Enum.Material.Metal)
		table.insert(pieces, { part = arm, offset = CFrame.Angles(0, math.rad(angle), 0), spin = false })
	end
	for _, corner in
		{
			Vector3.new(1.2, 0.3, 1.2),
			Vector3.new(-1.2, 0.3, 1.2),
			Vector3.new(1.2, 0.3, -1.2),
			Vector3.new(-1.2, 0.3, -1.2),
		}
	do
		local blade =
			newPiece(model, Enum.PartType.Block, Vector3.new(1.3, 0.06, 0.18), dark, Enum.Material.SmoothPlastic)
		blade.Transparency = 0.2
		table.insert(pieces, { part = blade, offset = CFrame.new(corner), spin = true })
	end

	local label = Instance.new("BillboardGui")
	label.Name = "Status"
	label.Size = UDim2.fromOffset(150, 36)
	label.StudsOffset = Vector3.new(0, 2.2, 0)
	label.LightInfluence = 0
	label.Enabled = false
	label.Adornee = body
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = Color3.fromRGB(239, 83, 80)
	text.TextStrokeTransparency = 0.2
	text.Text = "Sac plein !"
	text.Parent = label
	label.Parent = body

	model.Parent = getContainer()
	local visual: Visual = {
		anchor = anchor,
		model = model,
		pieces = pieces,
		label = label,
		seed = math.random() * 10,
		target = nil,
		actionAt = 0,
		connections = {},
	}
	table.insert(
		visual.connections,
		anchor:GetAttributeChangedSignal("ActionAt"):Connect(function()
			refreshAction(visual)
		end)
	)
	table.insert(
		visual.connections,
		anchor:GetAttributeChangedSignal("Status"):Connect(function()
			refreshStatus(visual)
		end)
	)
	refreshAction(visual)
	refreshStatus(visual)
	return visual
end

local function place(visual: Visual, serverNow: number, clock: number)
	local position = visual.anchor.Position + Vector3.new(0, math.sin(clock * 2 + visual.seed) * 0.35, 0)
	local target = visual.target
	local elapsed = serverNow - visual.actionAt
	if target and elapsed >= 0 and elapsed < FLIGHT_TIME then
		local goal = target.Position + Vector3.new(0, HOVER_ABOVE_TILE, 0)
		position = position:Lerp(goal, math.sin(math.pi * elapsed / FLIGHT_TIME))
	end
	local center = CFrame.new(position)
	local spin = CFrame.Angles(0, clock * BLADE_SPEED, 0)
	for _, piece in visual.pieces do
		piece.part.CFrame = if piece.spin then center * piece.offset * spin else center * piece.offset
	end
end

local function addDrone(instance: Instance)
	if not instance:IsA("BasePart") or visuals[instance] then
		return
	end
	visuals[instance] = build(instance)
end

local function removeDrone(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local visual = visuals[instance]
	if not visual then
		return
	end
	for _, connection in visual.connections do
		connection:Disconnect()
	end
	visual.model:Destroy()
	visuals[instance] = nil
end

function DroneRenderer.Init() end

function DroneRenderer.Start()
	for _, anchor in CollectionService:GetTagged(DRONE_TAG) do
		addDrone(anchor)
	end
	CollectionService:GetInstanceAddedSignal(DRONE_TAG):Connect(addDrone)
	CollectionService:GetInstanceRemovedSignal(DRONE_TAG):Connect(removeDrone)

	local elapsed = 0
	RunService.Heartbeat:Connect(function(deltaTime: number)
		elapsed += deltaTime
		if elapsed < UPDATE_INTERVAL then
			return
		end
		elapsed = 0
		local serverNow = Workspace:GetServerTimeNow()
		local clock = os.clock()
		for _, visual in visuals do
			place(visual, serverNow, clock)
		end
	end)
end

return DroneRenderer
