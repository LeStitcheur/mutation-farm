--!strict
-- HudController — HUD responsive PC / mobile / console : Coins, sac, boutique de graines,
-- notifications et écran de chargement. Toutes les actions passent par des requêtes serveur.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local PlantConfig = require(Shared.Config.PlantConfig)
local Types = require(Shared.Types)
local BigNum = require(Shared.Util.BigNum)
local Format = require(Shared.Util.Format)
local Net = require(Shared.Net)
local StateController = require(script.Parent.StateController)
local Builder = require(script.Parent.Parent.UI.Builder)
local Theme = require(script.Parent.Parent.UI.Theme)

type SeedAction = "select" | "unlock" | "none"

type SeedRow = {
	plantId: string,
	button: TextButton,
	action: SeedAction,
}

type Ui = {
	hud: ScreenGui,
	coinsLabel: TextLabel,
	bagLabel: TextLabel,
	bagFill: Frame,
	seedsButton: TextButton,
	seedPanel: Frame,
	seedRows: { SeedRow },
	toastList: Frame,
	loadingGui: ScreenGui,
	loadingText: TextLabel,
	keyHint: TextLabel,
	closeButton: TextButton,
}

local TOGGLE_ACTION = "MutationFarm_ToggleSeeds"
local CLOSE_ACTION = "MutationFarm_CloseSeeds"
local MAX_TOASTS = 4
local TOAST_DURATION = 3

type ScaleEntry = { scale: UIScale, fit: Vector2? }

local SEED_PANEL_SIZE = Vector2.new(600, 420)

local localPlayer = Players.LocalPlayer
local scales: { ScaleEntry } = {}
local ui: Ui? = nil
local panelOpen = false
local toastCounter = 0
local loadingHidden = false
local viewportConnection: RBXScriptConnection? = nil

local HudController = {}

-- `fit` : taille de conception d'un panneau qui doit toujours tenir entièrement à l'écran.
local function addScale(target: GuiObject, fit: Vector2?)
	local scale = Instance.new("UIScale")
	scale.Parent = target
	table.insert(scales, { scale = scale, fit = fit })
end

local function updateScale()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local viewport = camera.ViewportSize
	local base = Theme.scaleFor(viewport, UserInputService.TouchEnabled)
	for _, entry in scales do
		local fit = entry.fit
		entry.scale.Scale = if fit then Theme.fitScale(base, viewport, fit) else base
	end
end

local function usingGamepad(): boolean
	local last = UserInputService:GetLastInputType()
	return last.Name:sub(1, 7) == "Gamepad"
end

-- Indications de touches selon le périphérique utilisé en dernier (clavier : G / X, manette : Y / B).
local function updateInputHints()
	local current = ui
	if not current then
		return
	end
	local gamepad = usingGamepad()
	local keyboard = UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled
	current.keyHint.Text = if gamepad then "Y" else "G"
	current.keyHint.Visible = gamepad or keyboard
	current.closeButton.Text = if gamepad then "B" else "X"
end

local function pill(name: string, width: number, parent: Instance): Frame
	return Builder.new("Frame", {
		Name = name,
		Size = UDim2.fromOffset(width, 54),
		BackgroundColor3 = Theme.Colors.PanelDark,
		BackgroundTransparency = 0.1,
		Parent = parent,
	}, { Builder.corner(27), Builder.stroke(Theme.Colors.Outline, 3), Builder.padding(8) }) :: Frame
end

local function buildTopBar(hud: ScreenGui): (TextLabel, TextLabel, Frame)
	local topBar = Builder.new("Frame", {
		Name = "TopBar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(470, 58),
		BackgroundTransparency = 1,
		Parent = hud,
	}, {
		Builder.list(Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	}) :: Frame
	addScale(topBar)

	local coinsPill = pill("Coins", 240, topBar)
	coinsPill.LayoutOrder = 1
	Builder.new("Frame", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(36, 36),
		BackgroundColor3 = Theme.Colors.Coin,
		Parent = coinsPill,
	}, {
		Builder.corner(18),
		Builder.stroke(Theme.Colors.CoinDark, 3),
		Builder.label({
			Size = UDim2.fromScale(1, 1),
			Text = "C",
			TextSize = 22,
			TextColor3 = Theme.Colors.CoinDark,
			TextXAlignment = Enum.TextXAlignment.Center,
		}),
	})
	local coinsLabel = Builder.label({
		Name = "Amount",
		Position = UDim2.fromOffset(46, 0),
		Size = UDim2.new(1, -46, 1, 0),
		Text = "0",
		TextSize = 28,
		Parent = coinsPill,
	})

	local bagPill = pill("Bag", 210, topBar)
	bagPill.LayoutOrder = 2
	local bagLabel = Builder.label({
		Name = "Count",
		Size = UDim2.new(1, 0, 0.58, 0),
		Text = "Sac 0/0",
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = bagPill,
	})
	local bar = Builder.new("Frame", {
		Name = "Bar",
		Position = UDim2.fromScale(0, 0.68),
		Size = UDim2.fromScale(1, 0.3),
		BackgroundColor3 = Theme.Colors.BarBack,
		Parent = bagPill,
	}, { Builder.corner(6) }) :: Frame
	local bagFill = Builder.new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Colors.Coin,
		Parent = bar,
	}, { Builder.corner(6) }) :: Frame

	return coinsLabel, bagLabel, bagFill
end

local function buildSeedPanel(
	hud: ScreenGui,
	onSeedButton: (SeedRow) -> (),
	onClose: () -> ()
): (Frame, { SeedRow }, TextButton)
	local panel = Builder.new("Frame", {
		Name = "SeedPanel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(SEED_PANEL_SIZE.X, SEED_PANEL_SIZE.Y),
		BackgroundColor3 = Theme.Colors.Panel,
		Visible = false,
		Parent = hud,
	}, { Builder.corner(18), Builder.stroke(Theme.Colors.Outline, 4) }) :: Frame
	addScale(panel, SEED_PANEL_SIZE)

	Builder.label({
		Name = "Title",
		Position = UDim2.fromOffset(20, 10),
		Size = UDim2.new(1, -90, 0, 44),
		Text = "Graines",
		TextSize = 34,
		TextColor3 = Theme.Colors.Text,
		Parent = panel,
	})
	Builder.label({
		Name = "Subtitle",
		Position = UDim2.fromOffset(20, 52),
		Size = UDim2.new(1, -40, 0, 24),
		Text = "La graine choisie remplace tes cultures à chaque récolte.",
		TextSize = 18,
		TextColor3 = Theme.Colors.TextMuted,
		Parent = panel,
	})
	local close = Builder.button({
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(56, 56),
		BackgroundColor3 = Theme.Colors.Red,
		Text = "X",
		Parent = panel,
	})
	close.Activated:Connect(onClose)

	local list = Builder.new("ScrollingFrame", {
		Name = "List",
		Position = UDim2.fromOffset(16, 88),
		Size = UDim2.new(1, -32, 1, -104),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Theme.Colors.Outline,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Selectable = false,
		Parent = panel,
	}, { Builder.list(Enum.FillDirection.Vertical, 8) }) :: ScrollingFrame

	local rows: { SeedRow } = {}
	for index, plant in PlantConfig.List do
		local rowFrame = Builder.new("Frame", {
			Name = plant.id,
			LayoutOrder = index,
			Size = UDim2.new(1, -12, 0, 82),
			BackgroundColor3 = Theme.Colors.PanelRow,
			Parent = list,
		}, { Builder.corner(12) }) :: Frame
		Builder.new("Frame", {
			Name = "Swatch",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 12, 0.5, 0),
			Size = UDim2.fromOffset(52, 52),
			BackgroundColor3 = Color3.fromHex(plant.color),
			Parent = rowFrame,
		}, { Builder.corner(26), Builder.stroke(Theme.Colors.Outline, 3) })
		Builder.label({
			Name = "Name",
			Position = UDim2.fromOffset(78, 8),
			Size = UDim2.new(1, -276, 0, 32),
			Text = plant.name,
			TextSize = 24,
			TextColor3 = Theme.Colors.Text,
			Parent = rowFrame,
		})
		Builder.label({
			Name = "Details",
			Position = UDim2.fromOffset(78, 42),
			Size = UDim2.new(1, -276, 0, 26),
			Text = string.format(
				"Pousse %s · Vaut %s",
				Format.duration(plant.growTime),
				Format.number(plant.baseValue)
			),
			TextSize = 19,
			TextColor3 = Theme.Colors.TextMuted,
			Parent = rowFrame,
		})
		local button = Builder.button({
			Name = "Action",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.fromOffset(180, 58),
			TextScaled = true,
			Text = "",
			Parent = rowFrame,
		})
		-- Texte adaptatif (prix à suffixes longs) sans dépasser 20 px.
		local sizeLimit = Instance.new("UITextSizeConstraint")
		sizeLimit.MaxTextSize = 20
		sizeLimit.Parent = button
		Builder.padding(6).Parent = button
		local row: SeedRow = { plantId = plant.id, button = button, action = "none" }
		button.Activated:Connect(function()
			onSeedButton(row)
		end)
		table.insert(rows, row)
	end
	return panel, rows, close
end

local function buildLoading(playerGui: Instance): (ScreenGui, TextLabel)
	local gui = Builder.new("ScreenGui", {
		Name = "MutationFarmLoading",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 100,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}) :: ScreenGui
	local background = Builder.new("Frame", {
		Name = "Background",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(46, 84, 52),
		Parent = gui,
	}) :: Frame
	local content = Builder.new("Frame", {
		Name = "Content",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(640, 180),
		BackgroundTransparency = 1,
		Parent = background,
	}) :: Frame
	addScale(content)
	Builder.label({
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 90),
		Text = "MUTATION FARM",
		TextSize = 64,
		TextColor3 = Theme.Colors.Coin,
		TextStrokeTransparency = 0,
		TextStrokeColor3 = Theme.Colors.Outline,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = content,
	})
	local status = Builder.label({
		Name = "Status",
		Position = UDim2.fromOffset(0, 110),
		Size = UDim2.new(1, 0, 0, 40),
		Text = "Chargement de ta ferme…",
		TextSize = 24,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = content,
	})
	gui.Parent = playerGui
	return gui, status
end

local function hideLoading(current: Ui)
	if loadingHidden then
		return
	end
	loadingHidden = true
	local fade = TweenInfo.new(0.5)
	for _, descendant in current.loadingGui:GetDescendants() do
		if descendant:IsA("TextLabel") then
			TweenService:Create(descendant, fade, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		elseif descendant:IsA("Frame") and descendant.BackgroundTransparency < 1 then
			TweenService:Create(descendant, fade, { BackgroundTransparency = 1 }):Play()
		end
	end
	task.delay(0.5, function()
		current.loadingGui:Destroy()
	end)
end

local function toast(kind: Types.NotifyKind, text: string)
	local current = ui
	if not current then
		return
	end
	local color = if kind == "success"
		then Theme.Colors.Green
		elseif kind == "error" then Theme.Colors.Red
		else Theme.Colors.Blue
	toastCounter += 1
	-- Hauteur automatique : un message long passe sur deux lignes au lieu d'être tronqué
	-- (46 px = hauteur minimale d'une ligne, marges comprises).
	local item = Builder.new("Frame", {
		Name = "Toast",
		LayoutOrder = toastCounter,
		Size = UDim2.fromOffset(440, 46),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Colors.PanelDark,
		BackgroundTransparency = 0.08,
		Parent = current.toastList,
	}, { Builder.corner(12), Builder.stroke(color, 3), Builder.padding(8) }) :: Frame
	local label = Builder.label({
		Size = UDim2.new(1, 0, 0, 30),
		AutomaticSize = Enum.AutomaticSize.Y,
		Text = text,
		TextSize = 18,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = item,
	})

	local toasts: { Instance } = {}
	for _, child in current.toastList:GetChildren() do
		if child:IsA("Frame") then
			table.insert(toasts, child)
		end
	end
	if #toasts > MAX_TOASTS then
		table.sort(toasts, function(a, b)
			return (a :: Frame).LayoutOrder < (b :: Frame).LayoutOrder
		end)
		toasts[1]:Destroy()
	end

	task.delay(TOAST_DURATION, function()
		if item.Parent then
			local info = TweenInfo.new(0.35)
			TweenService:Create(item, info, { BackgroundTransparency = 1 }):Play()
			TweenService:Create(label, info, { TextTransparency = 1 }):Play()
			task.delay(0.35, function()
				item:Destroy()
			end)
		end
	end)
end

local function renderSeeds(current: Ui, state: Types.ClientState)
	local coins = BigNum.sanitize(state.coins)
	for _, row in current.seedRows do
		local plant = PlantConfig.get(row.plantId)
		if not plant then
			continue
		end
		local unlocked = state.seedsUnlocked[plant.id] == true
		local previous = PlantConfig.previous(plant.id)
		local available = not unlocked and (previous == nil or state.seedsUnlocked[previous.id] == true)
		local affordable = BigNum.gte(coins, BigNum.fromNumber(plant.unlockPrice))
		local button = row.button
		local text: string
		local color: Color3
		if unlocked and state.selectedSeed == plant.id then
			text, color, row.action = "En culture", Theme.Colors.Green, "none"
		elseif unlocked then
			text, color, row.action = "Planter", Theme.Colors.Blue, "select"
		elseif available then
			text = "Débloquer " .. Format.number(plant.unlockPrice)
			color = if affordable then Theme.Colors.Gold else Theme.Colors.Grey
			row.action = if affordable then "unlock" else "none"
		else
			text, color, row.action = "Verrouillée", Theme.Colors.Grey, "none"
		end
		button.Text = text
		button.BackgroundColor3 = color
		button.AutoButtonColor = row.action ~= "none"
	end
end

local function render(state: Types.ClientState)
	local current = ui
	if not current then
		return
	end
	hideLoading(current)
	current.coinsLabel.Text = Format.bigNum(BigNum.sanitize(state.coins))
	local capacity = math.max(1, state.bagCapacity)
	local ratio = math.clamp(state.bagCount / capacity, 0, 1)
	current.bagLabel.Text = string.format("Sac %d/%d", state.bagCount, state.bagCapacity)
	current.bagFill.Size = UDim2.fromScale(ratio, 1)
	current.bagFill.BackgroundColor3 = if ratio >= 1 then Theme.Colors.Red else Theme.Colors.Coin
	renderSeeds(current, state)
end

local function setPanelOpen(open: boolean)
	local current = ui
	if not current or panelOpen == open then
		return
	end
	panelOpen = open
	current.seedPanel.Visible = open
	if open then
		ContextActionService:BindAction(CLOSE_ACTION, function(_, inputState: Enum.UserInputState)
			if inputState == Enum.UserInputState.Begin then
				setPanelOpen(false)
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.ButtonB)
		if usingGamepad() and current.seedRows[1] then
			GuiService.SelectedObject = current.seedRows[1].button
		end
	else
		ContextActionService:UnbindAction(CLOSE_ACTION)
		if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(current.seedPanel) then
			GuiService.SelectedObject = nil
		end
	end
end

local function onSeedButton(row: SeedRow)
	if row.action == "select" then
		Net.event(Net.Events.SelectSeed):FireServer(row.plantId)
	elseif row.action == "unlock" then
		Net.event(Net.Events.UnlockSeed):FireServer(row.plantId)
	end
end

function HudController.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local loadingGui, loadingText = buildLoading(playerGui)

	local hud = Builder.new("ScreenGui", {
		Name = "MutationFarmHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 5,
	}) :: ScreenGui

	local coinsLabel, bagLabel, bagFill = buildTopBar(hud)

	local menu = Builder.new("Frame", {
		Name = "Menu",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(170, 130),
		BackgroundTransparency = 1,
		Parent = hud,
	}, { Builder.list(Enum.FillDirection.Vertical, 10) }) :: Frame
	addScale(menu)
	local seedsButton = Builder.button({
		Name = "Seeds",
		Size = UDim2.fromOffset(170, 58),
		Text = "Graines",
		TextSize = 24,
		BackgroundColor3 = Theme.Colors.Green,
		Parent = menu,
	})
	local keyHint = Builder.label({
		Name = "KeyHint",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -6, 1, -2),
		Size = UDim2.fromOffset(30, 20),
		Text = "G",
		TextSize = 14,
		TextTransparency = 0.25,
		TextXAlignment = Enum.TextXAlignment.Right,
		Visible = false,
		Parent = seedsButton,
	})
	seedsButton.Activated:Connect(function()
		setPanelOpen(not panelOpen)
	end)

	local seedPanel, seedRows, closeButton = buildSeedPanel(hud, onSeedButton, function()
		setPanelOpen(false)
	end)

	local toastList = Builder.new("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -130),
		Size = UDim2.fromOffset(440, 230),
		BackgroundTransparency = 1,
		Parent = hud,
	}, {
		Builder.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom),
	}) :: Frame
	addScale(toastList)

	hud.Parent = playerGui
	ui = {
		hud = hud,
		coinsLabel = coinsLabel,
		bagLabel = bagLabel,
		bagFill = bagFill,
		seedsButton = seedsButton,
		seedPanel = seedPanel,
		seedRows = seedRows,
		toastList = toastList,
		loadingGui = loadingGui,
		loadingText = loadingText,
		keyHint = keyHint,
		closeButton = closeButton,
	}
end

function HudController.Start()
	updateScale()
	local function watchCamera()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
		local camera = Workspace.CurrentCamera
		if camera then
			viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
			updateScale()
		end
	end
	watchCamera()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)

	updateInputHints()
	UserInputService.LastInputTypeChanged:Connect(updateInputHints)

	ContextActionService:BindAction(TOGGLE_ACTION, function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			setPanelOpen(not panelOpen)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.G, Enum.KeyCode.ButtonY)

	StateController.Changed:Connect(render)
	StateController.LoadStatusChanged:Connect(function(status: Types.LoadStatus)
		local current = ui
		if current and not loadingHidden and status.message ~= "" then
			current.loadingText.Text = status.message
		end
	end)
	Net.event(Net.Events.Notify).OnClientEvent:Connect(function(notification: Types.Notification)
		toast(notification.kind, notification.text)
	end)

	local state = StateController.Get()
	if state then
		render(state)
	end
end

return HudController
