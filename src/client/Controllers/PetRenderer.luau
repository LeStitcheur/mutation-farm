--!strict
-- PetRenderer — rendu LOCAL des familiers équipés de chaque joueur (attribut « Pets » publié par PetService :
-- « espèce:niveau;… »). Modèles stylisés de quelques pièces (aucun maillage importé), qui suivent leur propriétaire
-- par interpolation locale, avec une animation simple : sautillement (au sol), battement d'ailes et flottement
-- (volants), rotor (Scarabée-drone). Purement visuel : aucun effet de jeu, rien n'est envoyé au serveur.
-- Mobile d'entrée de gamme : pièces ancrées sans collision ni ombre, déplacement groupé (BulkMoveTo) à 30 Hz,
-- familiers éloignés de la caméra masqués, lumière réservée aux familiers lumineux du joueur local.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local PetConfig = require(Shared.Config.PetConfig)
local Pets = require(Shared.Util.Pets)

local ATTRIBUTE = "Pets"
local UPDATE_INTERVAL = 1 / 30
local FOLLOW_SPEED = 7 -- rapidité du rattrapage (1 − e^(−v·dt))
local CULL_DISTANCE = 160 -- au-delà (studs, depuis la caméra), les familiers d'un joueur sont masqués
local GROUND_OFFSET = 2.6 -- hauteur approximative du HumanoidRootPart au-dessus du sol
local SLOT_OFFSETS = { Vector3.new(-3.2, 0, 2.4), Vector3.new(3.2, 0, 2.4), Vector3.new(0, 0, 4.2) }

type Kind = "static" | "wingL" | "wingR" | "spin"

type Piece = {
	part: BasePart,
	hinge: CFrame, -- position de l'articulation par rapport au centre
	extension: CFrame, -- décalage après la rotation animée
	kind: Kind,
}

type Visual = {
	def: PetConfig.PetDef,
	model: Model,
	pieces: { Piece },
	position: Vector3,
	slot: number,
	seed: number,
	flying: boolean,
}

type Owner = {
	player: Player,
	summary: string,
	visuals: { Visual },
	folder: Folder,
	shown: boolean,
	connection: RBXScriptConnection,
}

local owners: { [Player]: Owner } = {}
local container: Folder? = nil

local PetRenderer = {}

local function getContainer(): Folder
	if container and container.Parent then
		return container
	end
	local folder = Instance.new("Folder")
	folder.Name = "ClientPets"
	folder.Parent = Workspace
	container = folder
	return folder
end

local function newPart(model: Model, shape: Enum.PartType, size: Vector3, color: Color3, material: Enum.Material): Part
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

-- Construit la silhouette d'une espèce (taille légèrement croissante avec le niveau).
local function build(def: PetConfig.PetDef, level: number, isLocal: boolean): (Model, { Piece })
	local model = Instance.new("Model")
	model.Name = def.id
	local scale = 1 + (math.clamp(level, 1, PetConfig.Level.Max) - 1) * 0.02
	local primary = Color3.fromHex(def.model.primary)
	local secondary = Color3.fromHex(def.model.secondary)
	local dark = Color3.fromRGB(40, 30, 26)
	local pieces: { Piece } = {}
	local function add(
		shape: Enum.PartType,
		size: Vector3,
		color: Color3,
		position: Vector3,
		rotation: Vector3?,
		kind: Kind?,
		material: Enum.Material?
	): Part
		local part = newPart(model, shape, size * scale, color, material or Enum.Material.SmoothPlastic)
		local angles = rotation or Vector3.zero
		local hinge = CFrame.new(position * scale)
			* CFrame.Angles(math.rad(angles.X), math.rad(angles.Y), math.rad(angles.Z))
		table.insert(
			pieces,
			{ part = part, hinge = hinge, extension = CFrame.identity, kind = (kind or "static") :: Kind } :: Piece
		)
		return part
	end
	local function wing(side: number)
		local part = newPart(
			model,
			Enum.PartType.Block,
			Vector3.new(1.2, 0.08, 0.9) * scale,
			secondary,
			Enum.Material.SmoothPlastic
		)
		part.Transparency = 0.15
		table.insert(
			pieces,
			{
				part = part,
				hinge = CFrame.new(Vector3.new(0.15 * side, 0.1, 0) * scale),
				extension = CFrame.new(Vector3.new(0.6 * side, 0, 0) * scale),
				kind = (if side < 0 then "wingL" else "wingR") :: Kind,
			} :: Piece
		)
	end
	local function eyes(x: number, y: number, z: number, size: number)
		for _, side in { -1, 1 } do
			add(Enum.PartType.Ball, Vector3.one * size, dark, Vector3.new(x * side, y, z))
		end
	end

	local shape = def.model.shape
	local body: BasePart
	if shape == "sprout" then
		body = add(Enum.PartType.Ball, Vector3.one * 1.4, primary, Vector3.zero)
		add(
			Enum.PartType.Block,
			Vector3.new(0.2, 0.9, 0.5),
			secondary,
			Vector3.new(-0.25, 0.95, 0),
			Vector3.new(0, 0, 25)
		)
		add(
			Enum.PartType.Block,
			Vector3.new(0.2, 0.9, 0.5),
			secondary,
			Vector3.new(0.25, 0.95, 0),
			Vector3.new(0, 0, -25)
		)
		eyes(0.28, 0.2, -0.62, 0.22)
	elseif shape == "fox" then
		body = add(Enum.PartType.Block, Vector3.new(1.0, 0.9, 1.5), primary, Vector3.new(0, 0, 0.1))
		add(Enum.PartType.Ball, Vector3.one * 1.0, primary, Vector3.new(0, 0.45, -0.75))
		add(Enum.PartType.Block, Vector3.new(0.25, 0.45, 0.2), secondary, Vector3.new(-0.25, 1.05, -0.75))
		add(Enum.PartType.Block, Vector3.new(0.25, 0.45, 0.2), secondary, Vector3.new(0.25, 1.05, -0.75))
		add(
			Enum.PartType.Block,
			Vector3.new(0.4, 0.4, 0.9),
			secondary,
			Vector3.new(0, 0.3, 1.15),
			Vector3.new(30, 0, 0)
		)
		eyes(0.22, 0.55, -1.2, 0.18)
	elseif shape == "moth" then
		body = add(Enum.PartType.Ball, Vector3.one * 0.8, primary, Vector3.zero)
		wing(-1)
		wing(1)
		eyes(0.18, 0.15, -0.36, 0.14)
	elseif shape == "beetle" then
		body = add(Enum.PartType.Ball, Vector3.one * 1.2, primary, Vector3.zero)
		add(Enum.PartType.Block, Vector3.new(1.1, 0.35, 1.2), secondary, Vector3.new(0, 0.45, 0.05))
		add(Enum.PartType.Block, Vector3.new(1.6, 0.06, 0.18), dark, Vector3.new(0, 0.85, 0), nil, "spin")
		eyes(0.25, 0.15, -0.55, 0.18)
	elseif shape == "bunny" then
		body = add(Enum.PartType.Ball, Vector3.one * 1.2, primary, Vector3.zero)
		add(Enum.PartType.Ball, Vector3.one * 0.9, primary, Vector3.new(0, 0.75, -0.3))
		add(Enum.PartType.Block, Vector3.new(0.22, 0.8, 0.12), secondary, Vector3.new(-0.18, 1.45, -0.3))
		add(Enum.PartType.Block, Vector3.new(0.22, 0.8, 0.12), secondary, Vector3.new(0.18, 1.45, -0.3))
		eyes(0.18, 0.85, -0.72, 0.14)
	else -- wisp
		body = add(Enum.PartType.Ball, Vector3.one * 0.8, primary, Vector3.zero, nil, nil, Enum.Material.Neon)
		local halo = add(Enum.PartType.Ball, Vector3.one * 1.4, secondary, Vector3.zero, nil, nil, Enum.Material.Neon)
		halo.Transparency = 0.65
		eyes(0.15, 0.1, -0.38, 0.12)
	end
	if def.model.glow and isLocal then
		local light = Instance.new("PointLight")
		light.Range = 8
		light.Brightness = 0.8
		light.Color = primary
		light.Parent = body
	end
	return model, pieces
end

local function clear(owner: Owner)
	for _, visual in owner.visuals do
		visual.model:Destroy()
	end
	table.clear(owner.visuals)
end

local function rebuild(owner: Owner)
	local text = owner.player:GetAttribute(ATTRIBUTE)
	local summary = if type(text) == "string" then text else ""
	if summary == owner.summary then
		return
	end
	owner.summary = summary
	clear(owner)
	local isLocal = owner.player == Players.LocalPlayer
	for slot, entry in Pets.parseSummary(summary) do
		local def = Pets.get(entry.petId)
		if def then
			local model, pieces = build(def, entry.level, isLocal)
			model.Parent = owner.folder
			table.insert(owner.visuals, {
				def = def,
				model = model,
				pieces = pieces,
				position = Vector3.new(0, -1e4, 0), -- placé au premier rafraîchissement
				slot = slot,
				seed = math.random() * 10,
				flying = def.model.shape == "moth" or def.model.shape == "wisp",
			})
		end
	end
end

local function track(player: Player)
	if owners[player] then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "Pets_" .. player.UserId
	folder.Parent = getContainer()
	local owner: Owner = {
		player = player,
		summary = "",
		visuals = {},
		folder = folder,
		shown = true,
		connection = player:GetAttributeChangedSignal(ATTRIBUTE):Connect(function()
			local current = owners[player]
			if current then
				rebuild(current)
			end
		end),
	}
	owners[player] = owner
	rebuild(owner)
end

local function untrack(player: Player)
	local owner = owners[player]
	if not owner then
		return
	end
	owners[player] = nil
	owner.connection:Disconnect()
	clear(owner)
	owner.folder:Destroy()
end

local parts: { BasePart } = {}
local frames: { CFrame } = {}

local function step(dt: number, clock: number)
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else Vector3.zero
	table.clear(parts)
	table.clear(frames)
	local alpha = 1 - math.exp(-FOLLOW_SPEED * dt)
	for _, owner in owners do
		local character = owner.player.Character
		local found = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local root = if found and found:IsA("BasePart") then found else nil
		local visible = root ~= nil and (root.Position - cameraPosition).Magnitude <= CULL_DISTANCE
		if visible ~= owner.shown then
			owner.shown = visible
			owner.folder.Parent = if visible then getContainer() else nil
		end
		if visible and root then
			local rootCFrame = root.CFrame
			local look = Vector3.new(rootCFrame.LookVector.X, 0, rootCFrame.LookVector.Z)
			local facing = if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
			local moving = root.AssemblyLinearVelocity.Magnitude > 1
			local flat = CFrame.lookAt(rootCFrame.Position, rootCFrame.Position + facing)
			for _, visual in owner.visuals do
				local offset = SLOT_OFFSETS[visual.slot] or SLOT_OFFSETS[1]
				local goal = flat:PointToWorldSpace(offset)
				local bounce = if moving
					then math.abs(math.sin(clock * 9 + visual.seed)) * 0.6
					else math.sin(clock * 2 + visual.seed) * 0.08
				local height = if visual.flying
					then 1.2 + math.sin(clock * 2.2 + visual.seed) * 0.4
					else -GROUND_OFFSET + 0.7 + bounce
				goal = Vector3.new(goal.X, rootCFrame.Position.Y + height, goal.Z)
				if (visual.position - goal).Magnitude > 40 then
					visual.position = goal -- téléportation, réapparition : pas de traversée de la carte
				else
					visual.position = visual.position:Lerp(goal, alpha)
				end
				local center = CFrame.lookAt(visual.position, visual.position + facing)
				local flap = math.sin(clock * 16 + visual.seed) * 0.6
				for _, piece in visual.pieces do
					local cf: CFrame
					if piece.kind == "wingL" then
						cf = center * piece.hinge * CFrame.Angles(0, 0, flap) * piece.extension
					elseif piece.kind == "wingR" then
						cf = center * piece.hinge * CFrame.Angles(0, 0, -flap) * piece.extension
					elseif piece.kind == "spin" then
						cf = center * piece.hinge * CFrame.Angles(0, clock * 20, 0)
					else
						cf = center * piece.hinge
					end
					table.insert(parts, piece.part)
					table.insert(frames, cf)
				end
			end
		end
	end
	if #parts > 0 then
		Workspace:BulkMoveTo(parts, frames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function PetRenderer.Init() end

function PetRenderer.Start()
	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(untrack)
	local accumulated = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulated += dt
		if accumulated < UPDATE_INTERVAL then
			return
		end
		step(accumulated, os.clock())
		accumulated = 0
	end)
end

return PetRenderer
