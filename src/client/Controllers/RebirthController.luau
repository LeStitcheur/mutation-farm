--!strict
-- RebirthController — panneau Rebirth du HUD : rebirths réalisés, seuil et progression (Coins GAGNÉS pendant le
-- cycle), récompense, multiplicateur actuel et futur, liste exacte perdu / conservé, confirmation en deux étapes
-- (« Annuler » sélectionné par défaut, « Confirmer » actif après 1,5 s). Ouverture : bouton « Rebirth », touche R,
-- manette L1 ; B revient en arrière puis ferme. Le client n'envoie que la révision affichée : le serveur revalide
-- tout (RebirthService). Un seul panneau à la fois et chat masqué : UI/PanelHub.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local BigNum = require(Shared.Util.BigNum)
local Format = require(Shared.Util.Format)
local ProgressionMath = require(Shared.Util.ProgressionMath)
local Net = require(Shared.Net)
local StateController = require(script.Parent.StateController)
local Builder = require(script.Parent.Parent.UI.Builder)
local PanelHub = require(script.Parent.Parent.UI.PanelHub)
local Theme = require(script.Parent.Parent.UI.Theme)

local PANEL_ID = "rebirth"
local TOGGLE_ACTION = "MutationFarm_ToggleRebirth"
local BACK_ACTION = "MutationFarm_RebirthBack"
local PANEL_SIZE = Vector2.new(620, 480)
local CONFIRM_DELAY = 1.5

-- Doit rester aligné sur Resets.resetEconomy (perdu) et sur ce qu'il ne touche pas (conservé).
local LOST_TEXT = "Coins · graines débloquées · améliorations normales · drones · cultures plantées et sac"
local KEPT_TEXT =
	"Parcelles · Mutation Essence · améliorations de rebirth · Mutadex · cosmétiques et achats · statistiques"

type Ui = {
	panel: Frame,
	scale: UIScale,
	info: Frame,
	confirm: Frame,
	rebirthLabel: TextLabel,
	thresholdLabel: TextLabel,
	progressFill: Frame,
	progressLabel: TextLabel,
	rewardLabel: TextLabel,
	multiplierLabel: TextLabel,
	actionButton: TextButton,
	confirmText: TextLabel,
	cancelButton: TextButton,
	confirmButton: TextButton,
	closeButton: TextButton,
	keyHint: TextLabel,
}

local ui: Ui? = nil
local isOpen = false
local confirming = false
local confirmReady = false
local confirmToken = 0
local lastPreview: ProgressionMath.RebirthPreview? = nil

local RebirthController = {}

local function usingGamepad(): boolean
	return UserInputService:GetLastInputType().Name:sub(1, 7) == "Gamepad"
end

-- Texte sombre sur le fond clair du panneau.
local function darkLabel(props: Builder.Props): TextLabel
	props.TextColor3 = props.TextColor3 or Theme.Colors.Text
	props.TextWrapped = true
	return Builder.label(props)
end

local function updateScale()
	local current = ui
	local camera = Workspace.CurrentCamera
	if not current or not camera then
		return
	end
	local viewport = camera.ViewportSize
	local base = Theme.scaleFor(viewport, UserInputService.TouchEnabled)
	current.scale.Scale = Theme.fitScale(base, viewport, PANEL_SIZE)
end

local function computePreview(state: Types.ClientState): ProgressionMath.RebirthPreview
	local partial = { progression = { rebirths = state.rebirths, cycleCoins = BigNum.sanitize(state.cycleCoins) } }
	return ProgressionMath.rebirthPreview(partial :: any)
end

local function focusButton(button: TextButton)
	if usingGamepad() then
		GuiService.SelectedObject = button
	end
end

local function showInfo()
	local current = ui
	if not current then
		return
	end
	confirming = false
	confirmReady = false
	confirmToken += 1
	current.info.Visible = true
	current.confirm.Visible = false
	focusButton(current.actionButton)
end

local function showConfirm()
	local current = ui
	local preview = lastPreview
	if not current or not preview or not preview.eligible then
		return
	end
	confirming = true
	confirmReady = false
	confirmToken += 1
	local token = confirmToken
	current.confirmText.Text = string.format(
		"Confirmer le rebirth n° %d ?\n\nTu perds : %s.\n\nTu gagnes : +%s Mutation Essence et des revenus %s.",
		preview.rebirths + 1,
		string.lower(LOST_TEXT),
		Format.bigNum(preview.essence),
		Format.multiplier(preview.nextMultiplier)
	)
	current.info.Visible = false
	current.confirm.Visible = true
	current.confirmButton.Text = "Confirmer…"
	current.confirmButton.BackgroundColor3 = Theme.Colors.Grey
	current.confirmButton.AutoButtonColor = false
	focusButton(current.cancelButton)
	task.delay(CONFIRM_DELAY, function()
		local later = ui
		if confirming and token == confirmToken and later then
			confirmReady = true
			later.confirmButton.Text = "Confirmer"
			later.confirmButton.BackgroundColor3 = Theme.Colors.Red
			later.confirmButton.AutoButtonColor = true
		end
	end)
end

local setOpen: (boolean) -> ()

local function confirmRebirth()
	local state = StateController.Get()
	if not confirming or not confirmReady or not state then
		return
	end
	Net.event(Net.Events.RebirthRequest):FireServer(state.revision)
	setOpen(false)
end

setOpen = function(value: boolean)
	local current = ui
	if not current or isOpen == value then
		return
	end
	isOpen = value
	current.panel.Visible = value
	if value then
		PanelHub.opened(PANEL_ID)
		updateScale()
		showInfo()
		ContextActionService:BindAction(BACK_ACTION, function(_, inputState: Enum.UserInputState)
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
		confirmReady = false
		confirmToken += 1
		ContextActionService:UnbindAction(BACK_ACTION)
		if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(current.panel) then
			GuiService.SelectedObject = nil
		end
		PanelHub.closed(PANEL_ID)
	end
end

local function render(state: Types.ClientState)
	local current = ui
	if not current then
		return
	end
	local preview = computePreview(state)
	lastPreview = preview
	current.rebirthLabel.Text = string.format("Rebirths réalisés : %d", preview.rebirths)
	current.thresholdLabel.Text = string.format(
		"Rebirth n° %d : gagne %s Coins pendant ce cycle (ventes et bonus ; le solde actuel ne compte pas).",
		preview.rebirths + 1,
		Format.bigNum(preview.threshold)
	)
	current.progressFill.Size = UDim2.fromScale(preview.progress, 1)
	current.progressLabel.Text = string.format(
		"%s / %s (%d %%)",
		Format.bigNum(preview.cycleCoins),
		Format.bigNum(preview.threshold),
		math.floor(preview.progress * 100)
	)
	current.rewardLabel.Text = if preview.eligible
		then "Récompense : +" .. Format.bigNum(preview.essence) .. " Mutation Essence"
		else "Récompense : de la Mutation Essence, dès le seuil atteint"
	current.multiplierLabel.Text = string.format(
		"Revenus : %s maintenant → %s après ce rebirth",
		Format.multiplier(preview.multiplier),
		Format.multiplier(preview.nextMultiplier)
	)
	current.actionButton.Text = if preview.eligible then "Rebirth…" else "Seuil non atteint"
	current.actionButton.BackgroundColor3 = if preview.eligible then Theme.Colors.Gold else Theme.Colors.Grey
	current.actionButton.AutoButtonColor = preview.eligible
	if confirming and not preview.eligible then
		showInfo()
	end
end

local function updateInputHints()
	local current = ui
	if not current then
		return
	end
	local gamepad = usingGamepad()
	current.keyHint.Text = if gamepad then "L1" else "R"
	current.keyHint.Visible = gamepad or (UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled)
	current.closeButton.Text = if gamepad then "B" else "X"
end

local function buildInfo(panel: Frame): Frame
	return Builder.new("Frame", {
		Name = "Info",
		Position = UDim2.fromOffset(20, 72),
		Size = UDim2.new(1, -40, 1, -72),
		BackgroundTransparency = 1,
		Parent = panel,
	}) :: Frame
end

function RebirthController.Init()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local hud = playerGui:WaitForChild("MutationFarmHUD")
	local menu = hud:WaitForChild("Menu")

	local menuButton = Builder.button({
		Name = "Rebirth",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(170, 58),
		Text = "Rebirth",
		TextSize = 24,
		BackgroundColor3 = Theme.Colors.Gold,
		Parent = menu,
	})
	local keyHint = Builder.label({
		Name = "KeyHint",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -6, 1, -2),
		Size = UDim2.fromOffset(30, 20),
		Text = "R",
		TextSize = 14,
		TextTransparency = 0.25,
		TextXAlignment = Enum.TextXAlignment.Right,
		Visible = false,
		Parent = menuButton,
	})

	local panel = Builder.new("Frame", {
		Name = "RebirthPanel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(PANEL_SIZE.X, PANEL_SIZE.Y),
		BackgroundColor3 = Theme.Colors.Panel,
		Visible = false,
		ZIndex = 5,
		Parent = hud,
	}, { Builder.corner(18), Builder.stroke(Theme.Colors.Outline, 4) }) :: Frame
	local scale = Instance.new("UIScale")
	scale.Parent = panel

	darkLabel({
		Name = "Title",
		Position = UDim2.fromOffset(20, 12),
		Size = UDim2.new(1, -100, 0, 44),
		Text = "Rebirth",
		TextSize = 34,
		Parent = panel,
	})
	local closeButton = Builder.button({
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(56, 56),
		BackgroundColor3 = Theme.Colors.Red,
		Text = "X",
		Parent = panel,
	})

	local info = buildInfo(panel)
	local rebirthLabel = darkLabel({ Size = UDim2.new(1, 0, 0, 26), TextSize = 21, Parent = info })
	local thresholdLabel = darkLabel({
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, 44),
		TextSize = 16,
		TextColor3 = Theme.Colors.TextMuted,
		Parent = info,
	})
	local bar = Builder.new("Frame", {
		Name = "Progress",
		Position = UDim2.fromOffset(0, 78),
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = Theme.Colors.BarBack,
		Parent = info,
	}, { Builder.corner(10) }) :: Frame
	local progressFill = Builder.new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Colors.Coin,
		Parent = bar,
	}, { Builder.corner(10) }) :: Frame
	local progressLabel = Builder.label({
		Name = "Value",
		Size = UDim2.fromScale(1, 1),
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.2,
		ZIndex = 2,
		Parent = bar,
	})
	local rewardLabel = darkLabel({ Position = UDim2.fromOffset(0, 116), Size = UDim2.new(1, 0, 0, 26), Parent = info })
	local multiplierLabel =
		darkLabel({ Position = UDim2.fromOffset(0, 144), Size = UDim2.new(1, 0, 0, 26), Parent = info })
	darkLabel({
		Position = UDim2.fromOffset(0, 180),
		Size = UDim2.new(1, 0, 0, 22),
		Text = "Perdu au rebirth",
		TextSize = 18,
		TextColor3 = Theme.Colors.Red,
		Parent = info,
	})
	darkLabel({
		Position = UDim2.fromOffset(0, 202),
		Size = UDim2.new(1, 0, 0, 40),
		Text = LOST_TEXT,
		TextSize = 16,
		Parent = info,
	})
	darkLabel({
		Position = UDim2.fromOffset(0, 246),
		Size = UDim2.new(1, 0, 0, 22),
		Text = "Conservé",
		TextSize = 18,
		TextColor3 = Theme.Colors.Green,
		Parent = info,
	})
	darkLabel({
		Position = UDim2.fromOffset(0, 268),
		Size = UDim2.new(1, 0, 0, 40),
		Text = KEPT_TEXT,
		TextSize = 16,
		Parent = info,
	})
	local actionButton = Builder.button({
		Name = "Action",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(300, 56),
		BackgroundColor3 = Theme.Colors.Grey,
		Text = "Seuil non atteint",
		Parent = info,
	})

	local confirm = buildInfo(panel)
	confirm.Name = "Confirm"
	confirm.Visible = false
	local confirmText = darkLabel({
		Size = UDim2.new(1, 0, 1, -90),
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = confirm,
	})
	local cancelButton = Builder.button({
		Name = "Cancel",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -14),
		Size = UDim2.new(0.47, 0, 0, 56),
		BackgroundColor3 = Theme.Colors.Blue,
		Text = "Annuler",
		Parent = confirm,
	})
	local confirmButton = Builder.button({
		Name = "ConfirmButton",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, -14),
		Size = UDim2.new(0.47, 0, 0, 56),
		BackgroundColor3 = Theme.Colors.Grey,
		AutoButtonColor = false,
		Text = "Confirmer…",
		Parent = confirm,
	})

	ui = {
		panel = panel,
		scale = scale,
		info = info,
		confirm = confirm,
		rebirthLabel = rebirthLabel,
		thresholdLabel = thresholdLabel,
		progressFill = progressFill,
		progressLabel = progressLabel,
		rewardLabel = rewardLabel,
		multiplierLabel = multiplierLabel,
		actionButton = actionButton,
		confirmText = confirmText,
		cancelButton = cancelButton,
		confirmButton = confirmButton,
		closeButton = closeButton,
		keyHint = keyHint,
	}

	PanelHub.register(PANEL_ID, function()
		setOpen(false)
	end)
	menuButton.Activated:Connect(function()
		setOpen(not isOpen)
	end)
	closeButton.Activated:Connect(function()
		setOpen(false)
	end)
	actionButton.Activated:Connect(showConfirm)
	cancelButton.Activated:Connect(showInfo)
	confirmButton.Activated:Connect(confirmRebirth)
end

function RebirthController.Start()
	ContextActionService:BindAction(TOGGLE_ACTION, function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			setOpen(not isOpen)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.R, Enum.KeyCode.ButtonL1)

	StateController.Changed:Connect(render)
	local state = StateController.Get()
	if state then
		render(state)
	end

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
end

return RebirthController
