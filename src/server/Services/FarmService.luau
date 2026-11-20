--!strict
-- FarmService — parcelles : attribution d'un emplacement, construction de la géométrie, état des cases
-- (attributs répliqués) et replantation automatique. Le rendu des plantes est fait par les clients.
-- API : PlantTile, GetTilePart, OwnsTile, GetPlotModel.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local MutationConfig = require(Shared.Config.MutationConfig)
local Types = require(Shared.Types)
local FarmLayout = require(Shared.Util.FarmLayout)
local SlotAllocator = require(Shared.Util.SlotAllocator)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local MutationService = require(script.Parent.MutationService)
local PlantService = require(script.Parent.PlantService)

type PlayerData = Types.PlayerData
type TileState = Types.TileState

type PlotRecord = {
	slot: number,
	model: Model,
	origin: CFrame,
	tiles: { [string]: BasePart },
}

local TILE_TAG = "FarmTile"
local FARMS_FOLDER = "Farms"

local COLORS = {
	platform = Color3.fromRGB(116, 178, 84),
	soil = Color3.fromRGB(122, 84, 54),
	border = Color3.fromRGB(150, 105, 62),
	wood = Color3.fromRGB(168, 118, 70),
	roof = Color3.fromRGB(214, 74, 74),
	board = Color3.fromRGB(240, 220, 170),
	stone = Color3.fromRGB(160, 160, 150),
}

local plots: { [Player]: PlotRecord } = {}
local slots: SlotAllocator.SlotAllocator<Player> = SlotAllocator.new(FarmLayout.MaxSlots)
local farmsFolder: Folder? = nil

local FarmService = {}

local function getFarmsFolder(): Folder
	if farmsFolder then
		return farmsFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = FARMS_FOLDER
	folder.Parent = Workspace
	farmsFolder = folder
	return folder
end

local function localCFrame(origin: CFrame, point: FarmLayout.Vec3, yOffset: number?): CFrame
	return origin * CFrame.new(point.x, point.y + (yOffset or 0), point.z)
end

local function makePart(
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	parent: Instance
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function makeBillboard(adornee: BasePart, text: string, offsetY: number, color: Color3)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromOffset(280, 56)
	gui.StudsOffset = Vector3.new(0, offsetY, 0)
	gui.MaxDistance = 150
	gui.LightInfluence = 0
	gui.Adornee = adornee
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.25
	label.Text = text
	label.Parent = gui
	gui.Parent = adornee
end

-- Écrit l'état d'une case dans ses attributs (lus par PlantRenderer et HarvestController).
local function applyTile(part: BasePart, tile: TileState?)
	if tile then
		part:SetAttribute("PlantedAt", tile.plantedAt)
		part:SetAttribute("GrowTime", tile.growTime)
		part:SetAttribute("Mutation", tile.mutation or "normal")
		part:SetAttribute("PlantId", tile.plantId)
	else
		part:SetAttribute("PlantedAt", 0)
		part:SetAttribute("GrowTime", 0)
		part:SetAttribute("Mutation", "normal")
		part:SetAttribute("PlantId", "")
	end
end

-- Bordure en bois (et socle pour les terrasses) autour d'une zone de culture.
local function buildArea(model: Model, origin: CFrame, plotDef: FarmLayout.PlotDef)
	local groundTop = FarmLayout.Features.groundTop
	local width = plotDef.cols * FarmLayout.TilePitch
	local depth = plotDef.rows * FarmLayout.TilePitch
	local center = plotDef.origin
	if center.y > 0 then
		makePart(
			"TerraceBase",
			Vector3.new(width + 2, center.y, depth + 2),
			localCFrame(origin, { x = center.x, y = groundTop + center.y / 2, z = center.z }),
			COLORS.stone,
			Enum.Material.Cobblestone,
			model
		)
	end
	local y = groundTop + center.y + 0.4
	local thickness = 0.8
	local borders = {
		{ size = Vector3.new(width + thickness * 2, 0.8, thickness), x = 0, z = -(depth / 2 + thickness / 2) },
		{ size = Vector3.new(width + thickness * 2, 0.8, thickness), x = 0, z = depth / 2 + thickness / 2 },
		{ size = Vector3.new(thickness, 0.8, depth), x = -(width / 2 + thickness / 2), z = 0 },
		{ size = Vector3.new(thickness, 0.8, depth), x = width / 2 + thickness / 2, z = 0 },
	}
	for _, border in borders do
		local part = makePart(
			"Border",
			border.size,
			localCFrame(origin, { x = center.x + border.x, y = y, z = center.z + border.z }),
			COLORS.border,
			Enum.Material.Wood,
			model
		)
		part.CanQuery = false
	end
end

local function buildSellStand(model: Model, cframe: CFrame)
	local counter = makePart(
		"SellCounter",
		Vector3.new(8, 3, 3),
		cframe * CFrame.new(0, 1.5, 0),
		COLORS.wood,
		Enum.Material.WoodPlanks,
		model
	)
	for _, x in { -3.6, 3.6 } do
		makePart(
			"SellPost",
			Vector3.new(0.6, 4, 0.6),
			cframe * CFrame.new(x, 5, 0),
			COLORS.wood,
			Enum.Material.Wood,
			model
		)
	end
	makePart(
		"SellRoof",
		Vector3.new(9.5, 0.6, 4.5),
		cframe * CFrame.new(0, 7.3, 0),
		COLORS.roof,
		Enum.Material.SmoothPlastic,
		model
	)
	makeBillboard(counter, "MARCHÉ", 7.5, Color3.fromRGB(255, 214, 79))

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SellPrompt"
	prompt.ActionText = "Vendre tout"
	prompt.ObjectText = "Marché"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = counter
	prompt.Triggered:Connect(function(player: Player)
		EconomyService.SellAll(player)
	end)
end

local function buildSign(model: Model, cframe: CFrame, player: Player)
	makePart("SignPost", Vector3.new(0.8, 4, 0.8), cframe * CFrame.new(0, 2, 0), COLORS.wood, Enum.Material.Wood, model)
	local board = makePart(
		"SignBoard",
		Vector3.new(9, 3, 0.6),
		cframe * CFrame.new(0, 5, 0),
		COLORS.board,
		Enum.Material.WoodPlanks,
		model
	)
	makeBillboard(board, "Ferme de " .. player.DisplayName, 3.4, Color3.new(1, 1, 1))
end

local function buildPlot(player: Player, slot: number, data: PlayerData): PlotRecord
	local x, z, yaw = FarmLayout.slotTransform(slot)
	local origin = CFrame.new(x, 0, z) * CFrame.Angles(0, yaw, 0)
	local features = FarmLayout.Features

	local model = Instance.new("Model")
	model.Name = string.format("Plot_%d", slot)
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("Slot", slot)

	local size = features.platformSize
	makePart(
		"Platform",
		Vector3.new(size.x, size.y, size.z),
		localCFrame(origin, features.platformCenter),
		COLORS.platform,
		Enum.Material.Grass,
		model
	)

	local tiles: { [string]: BasePart } = {}
	for _, plotDef in FarmLayout.Plots do
		if data.farm.plots[plotDef.id] then
			buildArea(model, origin, plotDef)
			for _, tileId in FarmLayout.tileIds(plotDef.id) do
				local position = FarmLayout.tileLocalPosition(tileId)
				if position then
					local part = makePart(
						"Tile_" .. tileId,
						Vector3.new(FarmLayout.TileSize, FarmLayout.TileHeight, FarmLayout.TileSize),
						localCFrame(origin, position, features.groundTop + FarmLayout.TileHeight / 2),
						COLORS.soil,
						Enum.Material.Ground,
						model
					)
					part:SetAttribute("TileId", tileId)
					part:SetAttribute("OwnerUserId", player.UserId)
					applyTile(part, data.farm.tiles[tileId])
					CollectionService:AddTag(part, TILE_TAG)
					tiles[tileId] = part
				end
			end
		end
	end

	buildSellStand(model, localCFrame(origin, features.sellStand))
	buildSign(model, localCFrame(origin, features.sign), player)
	model.Parent = getFarmsFolder()
	return { slot = slot, model = model, origin = origin, tiles = tiles }
end

local function spawnCFrame(record: PlotRecord): CFrame
	local spawn = FarmLayout.Features.spawn
	local position = (record.origin * CFrame.new(spawn.x, spawn.y, spawn.z)).Position
	local target = (record.origin * CFrame.new(0, spawn.y, 0)).Position
	return CFrame.lookAt(position, target)
end

local function teleportToPlot(player: Player)
	local record = plots[player]
	local character = player.Character
	if not record or not character then
		return
	end
	if character:WaitForChild("HumanoidRootPart", 5) and plots[player] == record and player.Character == character then
		character:PivotTo(spawnCFrame(record))
	end
end

local function releasePlot(player: Player)
	local record = plots[player]
	if record then
		plots[player] = nil
		record.model:Destroy()
		SlotAllocator.release(slots, record.slot, player)
	end
end

-- Plante la graine sélectionnée sur une case débloquée (écrase la culture existante).
-- La mutation du cycle est tirée ICI, côté serveur, puis sauvegardée avec la case (nil = normale).
function FarmService.PlantTile(player: Player, tileId: string): boolean
	local data = DataService.GetData(player)
	local record = plots[player]
	if not data or not record or not FarmLayout.isTileUnlocked(data.farm.plots, tileId) then
		return false
	end
	local plantId = PlantService.GetSelectedSeed(data)
	local mutation = MutationService.Roll()
	local tile: TileState = {
		plantId = plantId,
		plantedAt = Workspace:GetServerTimeNow(),
		growTime = PlantService.ComputeGrowTime(data, plantId),
		mutation = if mutation ~= MutationConfig.NORMAL then mutation else nil,
	}
	DataService.Update(player, function(d)
		d.farm.tiles[tileId] = tile
	end)
	local part = record.tiles[tileId]
	if part then
		applyTile(part, tile)
	end
	return true
end

-- Plantation automatique de toutes les cases vides.
local function ensurePlanted(player: Player)
	local data = DataService.GetData(player)
	local record = plots[player]
	if not data or not record then
		return
	end
	for tileId in record.tiles do
		if data.farm.tiles[tileId] == nil then
			FarmService.PlantTile(player, tileId)
		end
	end
end

function FarmService.GetTilePart(player: Player, tileId: string): BasePart?
	local record = plots[player]
	return if record then record.tiles[tileId] else nil
end

function FarmService.OwnsTile(player: Player, tileId: string): boolean
	local data = DataService.GetData(player)
	return data ~= nil and plots[player] ~= nil and FarmLayout.isTileUnlocked(data.farm.plots, tileId)
end

function FarmService.GetPlotModel(player: Player): Model?
	local record = plots[player]
	return if record then record.model else nil
end

local function onProfileLoaded(player: Player, data: PlayerData)
	if plots[player] or player.Parent ~= Players then
		return
	end
	local slot = SlotAllocator.claim(slots, player)
	if not slot then
		player:Kick("Serveur complet : aucune parcelle libre. Rejoins un autre serveur.")
		return
	end
	local ok, err = pcall(function()
		plots[player] = buildPlot(player, slot, data)
	end)
	if not ok then
		SlotAllocator.release(slots, slot, player)
		warn(
			string.format(
				"[FarmService] Construction de la parcelle impossible pour %s : %s",
				player.Name,
				tostring(err)
			)
		)
		-- Sans parcelle le joueur ne peut rien faire : on l'expulse (ses données ne sont pas modifiées).
		player:Kick("Ta ferme n'a pas pu être construite. Rejoins à nouveau dans un instant.")
		return
	end
	ensurePlanted(player)
	teleportToPlot(player)
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function()
		task.defer(teleportToPlot, player)
	end)
end

function FarmService.Init()
	getFarmsFolder()
	DataService.ProfileLoaded:Connect(onProfileLoaded)
	DataService.ProfileReleasing:Connect(function(player: Player)
		releasePlot(player)
	end)
	Players.PlayerRemoving:Connect(releasePlot)
	Players.PlayerAdded:Connect(onPlayerAdded)
end

function FarmService.Start()
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return FarmService
