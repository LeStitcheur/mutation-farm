--!strict
-- ConfirmPanel — panneau modal à deux vues (information, puis confirmation) partagé par Rebirth et Prestige :
--   • bouton de menu (avec indice de touche clavier / manette) et raccourcis ContextActionService ;
--   • cadre mis à l'échelle (Theme.fitScale, suivi de la fenêtre), bouton X / B ;
--   • un seul panneau ouvert à la fois et chat Roblox masqué pendant l'ouverture (PanelHub) ;
--   • vue d'information : contenu fourni par le contrôleur (`info`) + bouton d'action en bas ;
--   • vue de confirmation : récapitulatif, « Annuler » sélectionné par défaut à la manette, « Confirmer » inactif
--     pendant `confirmDelay` et, si `acknowledgment` est fourni, tant que la case « J'ai compris » n'est pas cochée
--     (confirmation renforcée) ; B revient à l'information puis ferme.
-- Le panneau n'envoie rien au serveur : `onConfirm` (contrôleur) envoie l'intention, le serveur revalide tout.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Builder = require(script.Parent.Builder)
local PanelHub = require(script.Parent.PanelHub)
local Theme = require(script.Parent.Theme)

local HEADER_HEIGHT = 72
local ACTION_AREA = 84
local ACK_HEIGHT = 52

export type Options = {
	id: string, -- identifiant PanelHub (et des actions ContextActionService)
	title: string,
	parent: Instance, -- ScreenGui du HUD
	size: Vector2, -- taille de conception (avant mise à l'échelle)
	menu: Instance, -- cadre du menu latéral (UIListLayout)
	menuText: string,
	menuOrder: number,
	menuColor: Color3,
	keys: { Enum.KeyCode }, -- raccourcis d'ouverture / fermeture
	keyboardHint: string,
	gamepadHint: string,
	confirmDelay: number,
	acknowledgment: string?, -- texte de la case à cocher obligatoire (confirmation renforcée)
	onAction: () -> (), -- bouton d'action de la vue d'information (le contrôleur appelle showConfirm)
	onConfirm: () -> (), -- confirmation validée ; le panneau se ferme ensuite
}

export type Panel = {
	frame: Frame,
	info: Frame, -- zone de contenu de la vue d'information, au-dessus du bouton d'action
	isOpen: () -> boolean,
	isConfirming: () -> boolean,
	setOpen: (boolean) -> (),
	showInfo: () -> (),
	showConfirm: (summary: string) -> (),
	setAction: (text: string, enabled: boolean, color: Color3) -> (),
}

local ConfirmPanel = {}

local function usingGamepad(): boolean
	return UserInputService:GetLastInputType().Name:sub(1, 7) == "Gamepad"
end

local function focus(button: GuiObject)
	if usingGamepad() then
		GuiService.SelectedObject = button
	end
end

-- Texte sombre, à la ligne automatique, sur le fond clair du panneau.
function ConfirmPanel.text(props: Builder.Props): TextLabel
	props.TextColor3 = props.TextColor3 or Theme.Colors.Text
	props.TextWrapped = true
	return Builder.label(props)
end

-- Barre de progression (remplissage + valeur centrée) à la position verticale `y` de `parent`.
function ConfirmPanel.progressBar(parent: Instance, y: number, height: number): (Frame, TextLabel)
	local bar = Builder.new("Frame", {
		Name = "Progress",
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = Theme.Colors.BarBack,
		Parent = parent,
	}, { Builder.corner(10) })
	local fill = Builder.new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Colors.Coin,
		Parent = bar,
	}, { Builder.corner(10) }) :: Frame
	local value = Builder.label({
		Name = "Value",
		Size = UDim2.fromScale(1, 1),
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.2,
		ZIndex = 2,
		Parent = bar,
	})
	return fill, value
end

function ConfirmPanel.new(options: Options): Panel
	local backAction = "MutationFarm_" .. options.id .. "_Back"
	local toggleAction = "MutationFarm_" .. options.id .. "_Toggle"
	local open = false
	local confirming = false
	local delayElapsed = false
	local acknowledged = false
	local actionEnabled = false
	local token = 0

	local menuButton = Builder.button({
		Name = options.menuText,
		LayoutOrder = options.menuOrder,
		Size = UDim2.fromOffset(170, 58),
		Text = options.menuText,
		TextSize = 24,
		BackgroundColor3 = options.menuColor,
		Parent = options.menu,
	})
	local keyHint = Builder.label({
		Name = "KeyHint",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -6, 1, -2),
		Size = UDim2.fromOffset(30, 20),
		Text = options.keyboardHint,
		TextSize = 14,
		TextTransparency = 0.25,
		TextXAlignment = Enum.TextXAlignment.Right,
		Visible = false,
		Parent = menuButton,
	})

	local frame = Builder.new("Frame", {
		Name = options.id .. "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(options.size.X, options.size.Y),
		BackgroundColor3 = Theme.Colors.Panel,
		Visible = false,
		Parent = options.parent,
	}, { Builder.corner(18), Builder.stroke(Theme.Colors.Outline, 4) }) :: Frame
	local scale = Instance.new("UIScale")
	scale.Parent = frame

	Builder.label({
		Name = "Title",
		Position = UDim2.fromOffset(20, 12),
		Size = UDim2.new(1, -100, 0, 44),
		Text = options.title,
		TextSize = 34,
		TextColor3 = Theme.Colors.Text,
		Parent = frame,
	})
	local closeButton = Builder.button({
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(56, 56),
		BackgroundColor3 = Theme.Colors.Red,
		Text = "X",
		Parent = frame,
	})

	local infoView = Builder.new("Frame", {
		Name = "InfoView",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = frame,
	}) :: Frame
	local info = Builder.new("Frame", {
		Name = "Info",
		Position = UDim2.fromOffset(20, HEADER_HEIGHT),
		Size = UDim2.new(1, -40, 1, -(HEADER_HEIGHT + ACTION_AREA)),
		BackgroundTransparency = 1,
		Parent = infoView,
	}) :: Frame
	local actionButton = Builder.button({
		Name = "Action",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(320, 56),
		BackgroundColor3 = Theme.Colors.Grey,
		AutoButtonColor = false,
		Text = "…",
		Parent = infoView,
	})

	local confirmView = Builder.new("Frame", {
		Name = "Confirm",
		Position = UDim2.fromOffset(20, HEADER_HEIGHT),
		Size = UDim2.new(1, -40, 1, -HEADER_HEIGHT),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = frame,
	}) :: Frame
	local ackText = options.acknowledgment
	local summaryHeight = -(ACTION_AREA + 6 + (if ackText then ACK_HEIGHT + 12 else 0))
	local summary = Builder.label({
		Name = "Summary",
		Size = UDim2.new(1, 0, 1, summaryHeight),
		TextSize = 20,
		TextWrapped = true,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = confirmView,
	})
	local ackButton: TextButton? = nil
	if ackText then
		ackButton = Builder.button({
			Name = "Acknowledge",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, -(ACTION_AREA + 6)),
			Size = UDim2.new(1, 0, 0, ACK_HEIGHT),
			BackgroundColor3 = Theme.Colors.PanelRow,
			TextColor3 = Theme.Colors.Text,
			TextSize = 17,
			TextWrapped = true,
			Parent = confirmView,
		})
	end
	local cancelButton = Builder.button({
		Name = "Cancel",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -14),
		Size = UDim2.new(0.47, 0, 0, 56),
		BackgroundColor3 = Theme.Colors.Blue,
		Text = "Annuler",
		Parent = confirmView,
	})
	local confirmButton = Builder.button({
		Name = "ConfirmButton",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, -14),
		Size = UDim2.new(0.47, 0, 0, 56),
		BackgroundColor3 = Theme.Colors.Grey,
		AutoButtonColor = false,
		Text = "Confirmer…",
		Parent = confirmView,
	})

	local function updateScale()
		local camera = Workspace.CurrentCamera
		if camera then
			local viewport = camera.ViewportSize
			local base = Theme.scaleFor(viewport, UserInputService.TouchEnabled)
			scale.Scale = Theme.fitScale(base, viewport, options.size)
		end
	end

	local function ready(): boolean
		return confirming and delayElapsed and (ackText == nil or acknowledged)
	end

	local function refreshConfirm()
		local isReady = ready()
		confirmButton.Text = if isReady then "Confirmer" else "Confirmer…"
		confirmButton.BackgroundColor3 = if isReady then Theme.Colors.Red else Theme.Colors.Grey
		confirmButton.AutoButtonColor = isReady
		local ack = ackButton
		if ack and ackText then
			ack.Text = (if acknowledged then "☑  " else "☐  ") .. ackText
			ack.BackgroundColor3 = if acknowledged then Theme.Colors.Green else Theme.Colors.PanelRow
			ack.TextColor3 = if acknowledged then Theme.Colors.TextLight else Theme.Colors.Text
		end
	end

	local function showInfo()
		confirming = false
		delayElapsed = false
		acknowledged = false
		token += 1
		infoView.Visible = true
		confirmView.Visible = false
		refreshConfirm()
		focus(actionButton)
	end

	local function showConfirm(text: string)
		confirming = true
		delayElapsed = false
		acknowledged = false
		token += 1
		local current = token
		summary.Text = text
		infoView.Visible = false
		confirmView.Visible = true
		refreshConfirm()
		focus(cancelButton)
		task.delay(options.confirmDelay, function()
			if confirming and current == token then
				delayElapsed = true
				refreshConfirm()
			end
		end)
	end

	local function setOpen(value: boolean)
		if open == value then
			return
		end
		open = value
		frame.Visible = value
		if value then
			PanelHub.opened(options.id)
			updateScale()
			showInfo()
			ContextActionService:BindAction(backAction, function(_, inputState: Enum.UserInputState)
				if inputState == Enum.UserInputState.Begin then
					if confirming then
						showInfo()
					else
						setOpen(false)
					end
				end
				return Enum.ContextActionResult.Sink
			end, false, Enum.KeyCode.ButtonB)
		else
			confirming = false
			token += 1
			ContextActionService:UnbindAction(backAction)
			if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(frame) then
				GuiService.SelectedObject = nil
			end
			PanelHub.closed(options.id)
		end
	end

	local function updateInputHints()
		local gamepad = usingGamepad()
		keyHint.Text = if gamepad then options.gamepadHint else options.keyboardHint
		keyHint.Visible = gamepad or (UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled)
		closeButton.Text = if gamepad then "B" else "X"
	end

	PanelHub.register(options.id, function()
		setOpen(false)
	end)
	menuButton.Activated:Connect(function()
		setOpen(not open)
	end)
	closeButton.Activated:Connect(function()
		setOpen(false)
	end)
	actionButton.Activated:Connect(function()
		if actionEnabled then
			options.onAction()
		end
	end)
	cancelButton.Activated:Connect(showInfo)
	local ack = ackButton
	if ack then
		ack.Activated:Connect(function()
			if confirming then
				acknowledged = not acknowledged
				refreshConfirm()
			end
		end)
	end
	confirmButton.Activated:Connect(function()
		if ready() then
			options.onConfirm()
			setOpen(false)
		end
	end)

	ContextActionService:BindAction(toggleAction, function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			setOpen(not open)
		end
		return Enum.ContextActionResult.Sink
	end, false, table.unpack(options.keys))
	updateInputHints()
	UserInputService.LastInputTypeChanged:Connect(updateInputHints)
	local function watchCamera()
		local camera = Workspace.CurrentCamera
		if camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
		end
		updateScale()
	end
	watchCamera()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)

	return {
		frame = frame,
		info = info,
		isOpen = function(): boolean
			return open
		end,
		isConfirming = function(): boolean
			return confirming
		end,
		setOpen = setOpen,
		showInfo = showInfo,
		showConfirm = showConfirm,
		setAction = function(text: string, enabled: boolean, color: Color3)
			actionEnabled = enabled
			actionButton.Text = text
			actionButton.BackgroundColor3 = color
			actionButton.AutoButtonColor = enabled
		end,
	}
end

return ConfirmPanel
