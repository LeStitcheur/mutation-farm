--!strict
-- FarmService — fermes : attribution d'un emplacement, construction de la géométrie, état des cases (attributs
-- répliqués) et replantation automatique. Le rendu des plantes est fait par les clients.
-- Extensions (Phase 5, jalon A) : chaque parcelle de FarmLayout est construite ou démontée séparément selon
-- farm.plots (SyncPlots : au chargement, après un achat, après un rebirth / prestige). Une parcelle achetable non
-- possédée affiche un panneau « À vendre » avec une invite SERVEUR (propriétaire seulement, appui 0,5 s) : le client
-- ne fournit ni prix ni parcelle arbitraire ; l'achat est la règle pure Expansions.purchase dans UN mutateur.
-- API : PlantTile, ReplantEmpty, GetTilePart, OwnsTile, GetPlotModel, GetPlotOrigin, BuyPlot, SyncPlots ;
-- signal PlotReady.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local ExpansionConfig = require(Shared.Config.ExpansionConfig)
local MutationConfig = require(Shared.Config.MutationConfig)
local Types = require(Shared.Types)
local Expansions = require(Shared.Util.Expansions)
local FarmLayout = require(Shared.Util.FarmLayout)
local Format = require(Shared.Util.Format)
local Signal = require(Shared.Util.Signal)
local SlotAllocator = require(Shared.Util.SlotAllocator)
local Bonuses = require(Shared.Util.Bonuses)
local Quests = require(Shared.Util.Quests)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local EventService = require(script.Parent.EventService)
local MutationService = require(script.Parent.MutationService)
local PlantService = require(script.Parent.PlantService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

type PlayerData = Types.PlayerData
type TileState = Types.TileState

type PlotRecord = {
	player: Player,
	slot: number,
	model: Model,
	origin: CFrame,
	tiles: { [string]: BasePart },
	areas: { [string]: Model }, -- parcelles construites (bordures, socle, escalier, cases)
	sales: { [string]: { model: Model, prompt: ProximityPrompt, label: TextLabel } }, -- emplacements à vendre
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
	sale = Color3.fromRGB(255, 214, 79),
}

local BUY_FAILURES: { [string]: string } = {
	insufficient_funds = "Pas assez de Coins pour cette extension.",
	locked_order = "Achète d'abord l'extension précédente.",
	owned = "Tu possèdes déjà cette extension.",
}

local plots: { [Player]: PlotRecord } = {}
local slots: SlotAllocator.SlotAllocator<Player> = SlotAllocator.new(FarmLayout.MaxSlots)
local farmsFolder: Folder? = nil
local buyLimiter = RateLimiter.new(ExpansionConfig.PurchaseRequestsPerSecond)

local FarmService = {
	-- Parcelle construite et plantée (le propriétaire peut jouer) : DroneService y installe station et drones.
	PlotReady = Signal.new() :: Signal.Signal<Player>,
}

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

local function makeBillboard(adornee: BasePart, text: string, offsetY: number, color: Color3): TextLabel
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
	return label
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

-- Socle et marches d'une parcelle surélevée, en pavés locaux (vide pour une parcelle au sol).
local function raisedBoxes(plotDef: FarmLayout.PlotDef): { FarmLayout.Box }
	local boxes: { FarmLayout.Box } = {}
	if plotDef.origin.y <= 0 then
		return boxes
	end
	local margin = FarmLayout.TerraceMargin * 2
	table.insert(boxes, {
		center = {
			x = plotDef.origin.x,
			y = FarmLayout.Features.groundTop + plotDef.origin.y / 2,
			z = plotDef.origin.z,
		},
		size = {
			x = plotDef.cols * FarmLayout.TilePitch + margin,
			y = plotDef.origin.y,
			z = plotDef.rows * FarmLayout.TilePitch + margin,
		},
	})
	for _, step in FarmLayout.stairs(plotDef.id) do
		table.insert(boxes, step)
	end
	return boxes
end

-- Socle et escalier (terrasses), bordure en bois autour de la zone de culture.
local function buildFrame(model: Model, origin: CFrame, plotDef: FarmLayout.PlotDef)
	local groundTop = FarmLayout.Features.groundTop
	local width = plotDef.cols * FarmLayout.TilePitch
	local depth = plotDef.rows * FarmLayout.TilePitch
	local center = plotDef.origin
	for index, box in raisedBoxes(plotDef) do
		makePart(
			if index == 1 then "TerraceBase" else "Stair_" .. (index - 1),
			Vector3.new(box.size.x, box.size.y, box.size.z),
			localCFrame(origin, box.center),
			COLORS.stone,
			if index == 1 then Enum.Material.Cobblestone else Enum.Material.Slate,
			model
		)
	end
	local y = groundTop + center.y + 0.4
	local thickness = FarmLayout.BorderThickness
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

-- Un socle de terrasse (et son escalier) apparaît d'un coup : tout personnage qui se tenait à cet endroit (l'acheteur
-- devant le panneau, un visiteur) est posé dessus au lieu d'être enfermé dans la pierre (constaté en Studio).
local LIFT_MARGIN = 2.5 -- un personnage déjà au-dessus d'un pavé n'est pas déplacé
local LIFT_HEIGHT = 3.5 -- hauteur du HumanoidRootPart au-dessus de la surface d'arrivée
local function liftCharacters(record: PlotRecord, plotDef: FarmLayout.PlotDef)
	local boxes = raisedBoxes(plotDef)
	if #boxes == 0 then
		return
	end
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if character and root and root:IsA("BasePart") then
			local point = record.origin:PointToObjectSpace(root.Position)
			for _, box in boxes do
				local top = box.center.y + box.size.y / 2
				local inside = math.abs(point.X - box.center.x) <= box.size.x / 2
					and math.abs(point.Z - box.center.z) <= box.size.z / 2
					and point.Y < top + LIFT_MARGIN
				if inside then
					local target = record.origin * CFrame.new(point.X, top + LIFT_HEIGHT, point.Z)
					character:PivotTo(CFrame.new(target.Position) * root.CFrame.Rotation)
					break
				end
			end
		end
	end
end

-- Construit une parcelle possédée : cadre puis cases (taguées, attributs à jour).
local function buildArea(record: PlotRecord, plotDef: FarmLayout.PlotDef, data: PlayerData)
	local area = Instance.new("Model")
	area.Name = "Area_" .. plotDef.id
	buildFrame(area, record.origin, plotDef)
	for _, tileId in FarmLayout.tileIds(plotDef.id) do
		local position = FarmLayout.tileLocalPosition(tileId)
		if position then
			local part = makePart(
				"Tile_" .. tileId,
				Vector3.new(FarmLayout.TileSize, FarmLayout.TileHeight, FarmLayout.TileSize),
				localCFrame(record.origin, position, FarmLayout.Features.groundTop + FarmLayout.TileHeight / 2),
				COLORS.soil,
				Enum.Material.Ground,
				area
			)
			part:SetAttribute("TileId", tileId)
			part:SetAttribute("OwnerUserId", record.player.UserId)
			applyTile(part, data.farm.tiles[tileId])
			CollectionService:AddTag(part, TILE_TAG)
			record.tiles[tileId] = part
		end
	end
	area.Parent = record.model
	record.areas[plotDef.id] = area
	liftCharacters(record, plotDef)
end

-- Démonte une parcelle reprise (prestige) : cases retirées du registre puis détruites (les clients reçoivent la
-- suppression des tags : plantes et invites locales disparaissent).
local function destroyArea(record: PlotRecord, plotId: string)
	local area = record.areas[plotId]
	if not area then
		return
	end
	for _, tileId in FarmLayout.tileIds(plotId) do
		record.tiles[tileId] = nil
	end
	record.areas[plotId] = nil
	area:Destroy()
end

-- Emplacement à vendre : contour au sol et panneau avec invite d'achat (serveur, propriétaire seulement).
local function buildSale(record: PlotRecord, def: ExpansionConfig.ExpansionDef)
	local plotDef = FarmLayout.getPlot(def.plotId)
	local rect = FarmLayout.plotRect(def.plotId)
	if not plotDef or not rect then
		return
	end
	local model = Instance.new("Model")
	model.Name = "Sale_" .. def.plotId
	local groundTop = FarmLayout.Features.groundTop
	local centerX, centerZ = (rect.minX + rect.maxX) / 2, (rect.minZ + rect.maxZ) / 2
	local width, depth = rect.maxX - rect.minX, rect.maxZ - rect.minZ
	local outline = {
		{ x = centerX, z = rect.minZ + 0.3, sx = width, sz = 0.6 },
		{ x = centerX, z = rect.maxZ - 0.3, sx = width, sz = 0.6 },
		{ x = rect.minX + 0.3, z = centerZ, sx = 0.6, sz = depth },
		{ x = rect.maxX - 0.3, z = centerZ, sx = 0.6, sz = depth },
	}
	for _, line in outline do
		local part = makePart(
			"SaleOutline",
			Vector3.new(line.sx, 0.2, line.sz),
			localCFrame(record.origin, { x = line.x, y = groundTop + 0.1, z = line.z }),
			COLORS.sale,
			Enum.Material.Neon,
			model
		)
		part.Transparency = 0.35
		part.CanCollide = false
		part.CanQuery = false
		part.CastShadow = false
	end
	local base = localCFrame(record.origin, { x = plotDef.origin.x, y = groundTop, z = plotDef.origin.z })
	makePart("SalePost", Vector3.new(0.8, 4, 0.8), base * CFrame.new(0, 2, 0), COLORS.wood, Enum.Material.Wood, model)
	local board = makePart(
		"SaleBoard",
		Vector3.new(7, 3, 0.6),
		base * CFrame.new(0, 5, 0),
		COLORS.board,
		Enum.Material.WoodPlanks,
		model
	)
	local label = makeBillboard(board, "", 3.4, COLORS.sale)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BuyPlot"
	prompt.HoldDuration = 0.5 -- évite un achat accidentel
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = board
	local player = record.player
	prompt.Triggered:Connect(function(buyer: Player)
		if buyer ~= player then
			Notifier.send(buyer, "error", "Cette parcelle appartient à une autre ferme.")
			return
		end
		FarmService.BuyPlot(player, def.plotId)
	end)
	model.Parent = record.model
	record.sales[def.plotId] = { model = model, prompt = prompt, label = label }
end

-- Textes des panneaux : prix pour la prochaine extension, prérequis pour les suivantes.
local function refreshSales(record: PlotRecord, data: PlayerData)
	for plotId, sale in record.sales do
		local def = Expansions.get(plotId)
		if def then
			local price = Format.bigNum(Expansions.price(def))
			local previous = Expansions.previous(plotId)
			if previous and not Expansions.isOwned(data, previous.plotId) then
				sale.label.Text = string.format("%s · après : %s", def.name, previous.name)
				sale.prompt.ActionText = "Verrouillé"
				sale.prompt.ObjectText = string.format("%s · %s Coins", def.name, price)
			else
				sale.label.Text = string.format("À VENDRE · %s · %s Coins", def.name, price)
				sale.prompt.ActionText = "Acheter"
				sale.prompt.ObjectText = string.format("%s · %s Coins", def.name, price)
			end
		end
	end
end

-- Aligne la géométrie sur farm.plots : parcelles possédées construites, parcelles reprises démontées, panneaux
-- « À vendre » sur les emplacements achetables restants.
local function syncRecord(record: PlotRecord, data: PlayerData)
	for _, plotDef in FarmLayout.Plots do
		local owned = data.farm.plots[plotDef.id] == true
		if owned then
			local sale = record.sales[plotDef.id]
			if sale then
				record.sales[plotDef.id] = nil
				sale.model:Destroy()
			end
			if not record.areas[plotDef.id] then
				buildArea(record, plotDef, data)
			end
		else
			destroyArea(record, plotDef.id)
			local def = Expansions.get(plotDef.id)
			if def and not record.sales[plotDef.id] then
				buildSale(record, def)
			end
		end
	end
	refreshSales(record, data)
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

	local record: PlotRecord = {
		player = player,
		slot = slot,
		model = model,
		origin = origin,
		tiles = {},
		areas = {},
		sales = {},
	}
	syncRecord(record, data)
	buildSellStand(model, localCFrame(origin, features.sellStand))
	buildSign(model, localCFrame(origin, features.sign), player)
	model.Parent = getFarmsFolder()
	return record
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
	-- Chance : améliorations + familiers, × Pluie mutagène et × Rosée chanceuse (boost de mission) actives À LA
	-- PLANTATION, plafonnée à UpgradeConfig.Caps.MaxTotalLuck.
	local plantedAt = Workspace:GetServerTimeNow()
	local luckFactor = EventService.LuckFactor() * Quests.luckBoost(data, plantedAt)
	local mutation = MutationService.Roll(Bonuses.luck(data, luckFactor))
	local tile: TileState = {
		plantId = plantId,
		plantedAt = plantedAt,
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

-- Plantation automatique de toutes les cases vides ; attributs des cases déjà plantées resynchronisés (cultures
-- modifiées hors de PlantTile, ex. production hors ligne).
local function ensurePlanted(player: Player)
	local data = DataService.GetData(player)
	local record = plots[player]
	if not data or not record then
		return
	end
	for tileId, part in record.tiles do
		local tile = data.farm.tiles[tileId]
		if tile == nil then
			FarmService.PlantTile(player, tileId)
		else
			applyTile(part, tile)
		end
	end
end

-- Replante les cases vides (après un rebirth : toutes, avec la graine de départ et de nouveaux tirages).
function FarmService.ReplantEmpty(player: Player)
	ensurePlanted(player)
end

-- Aligne la géométrie de la ferme sur les parcelles possédées (après un achat, un rebirth ou un prestige).
function FarmService.SyncPlots(player: Player)
	local data = DataService.GetData(player)
	local record = plots[player]
	if data and record then
		syncRecord(record, data)
	end
end

-- Achat d'une extension par son propriétaire (invite serveur du panneau « À vendre »).
function FarmService.BuyPlot(player: Player, plotId: string): (boolean, string?)
	if not buyLimiter:allow(player) then
		return false, "rate_limited"
	end
	if not DataService.GetData(player) or not plots[player] then
		return false, "not_loaded"
	end
	local outcome: Expansions.PurchaseOutcome? = nil
	local failure: Expansions.BuyFailure? = nil
	DataService.Update(player, function(data)
		outcome, failure = Expansions.purchase(data, plotId)
	end)
	local result = outcome
	if not result then
		local message = if failure then BUY_FAILURES[failure] else nil
		if message then
			Notifier.send(player, "error", message)
		end
		return false, failure
	end
	FarmService.SyncPlots(player)
	ensurePlanted(player)
	Notifier.send(
		player,
		"success",
		string.format("%s débloqué ! +%d cases (−%s Coins)", result.name, result.tiles, Format.bigNum(result.price))
	)
	return true, nil
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

-- Repère monde de la parcelle : les positions LOCALES de FarmLayout s'y appliquent (origin * CFrame.new(x, y, z)).
function FarmService.GetPlotOrigin(player: Player): CFrame?
	local record = plots[player]
	return if record then record.origin else nil
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
	FarmService.PlotReady:Fire(player)
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
