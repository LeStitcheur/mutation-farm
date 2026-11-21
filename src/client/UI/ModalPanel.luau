--!strict
-- ModalPanel — base commune des panneaux ouverts depuis le menu latéral du HUD (Rebirth, Prestige, Améliorations) :
--   • bouton de menu (avec indice de touche clavier / manette) et raccourcis ContextActionService ;
--   • cadre mis à l'échelle (Theme.fitScale, suivi de la fenêtre), titre, bouton X (B à la manette) ;
--   • un seul panneau ouvert à la fois et chat Roblox masqué pendant l'ouverture (PanelHub) ;
--   • B : `onBack` peut le traiter (retour à une vue précédente), sinon le panneau se ferme.
-- Le contenu est placé par l'appelant dans `frame`, sous l'en-tête (HEADER_HEIGHT).

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Builder = require(script.Parent.Builder)
local PanelHub = require(script.Parent.PanelHub)
local Theme = require(script.Parent.Theme)

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
	onOpen: (() -> ())?, -- vue par défaut et sélection manette
	onClose: (() -> ())?,
	onBack: (() -> boolean)?, -- B : true si traité (retour), false pour fermer
}

export type Modal = {
	frame: Frame,
	menuButton: TextButton, -- bouton du menu latéral (animations de notification)
	isOpen: () -> boolean,
	setOpen: (boolean) -> (),
}

local ModalPanel = {
	HEADER_HEIGHT = 72,
}

local function usingGamepad(): boolean
	return UserInputService:GetLastInputType().Name:sub(1, 7) == "Gamepad"
end

-- Sélectionne `target` à la manette (sans effet à la souris ou au toucher).
function ModalPanel.focus(target: GuiObject)
	if usingGamepad() then
		GuiService.SelectedObject = target
	end
end

-- Texte sombre, à la ligne automatique, sur le fond clair du panneau.
function ModalPanel.text(props: Builder.Props): TextLabel
	props.TextColor3 = props.TextColor3 or Theme.Colors.Text
	props.TextWrapped = true
	return Builder.label(props)
end

-- Barre de progression (remplissage + valeur centrée) à la position verticale `y` de `parent`.
function ModalPanel.progressBar(parent: Instance, y: number, height: number): (Frame, TextLabel)
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

function ModalPanel.new(options: Options): Modal
	local backAction = "MutationFarm_" .. options.id .. "_Back"
	local toggleAction = "MutationFarm_" .. options.id .. "_Toggle"
	local open = false

	local menuButton = Builder.button({
		Name = options.menuText,
		LayoutOrder = options.menuOrder,
		Size = UDim2.fromOffset(160, 50), -- taille fixée par la grille du menu (HudController)
		Text = options.menuText,
		TextSize = 20,
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

	local function updateScale()
		local camera = Workspace.CurrentCamera
		if camera then
			local viewport = camera.ViewportSize
			local base = Theme.scaleFor(viewport, UserInputService.TouchEnabled)
			scale.Scale = Theme.fitScale(base, viewport, options.size)
		end
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
			if options.onOpen then
				options.onOpen()
			end
			ContextActionService:BindAction(backAction, function(_, inputState: Enum.UserInputState)
				if inputState == Enum.UserInputState.Begin then
					local handled = if options.onBack then options.onBack() else false
					if not handled then
						setOpen(false)
					end
				end
				return Enum.ContextActionResult.Sink
			end, false, Enum.KeyCode.ButtonB)
		else
			if options.onClose then
				options.onClose()
			end
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
		menuButton = menuButton,
		isOpen = function(): boolean
			return open
		end,
		setOpen = setOpen,
	}
end

return ModalPanel
