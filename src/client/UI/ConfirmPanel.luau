--!strict
-- ConfirmPanel — panneau à deux vues (information, puis confirmation) partagé par Rebirth et Prestige, bâti sur
-- UI/ModalPanel (menu, raccourcis, échelle, X / B, PanelHub, chat masqué) :
--   • vue d'information : contenu fourni par le contrôleur (`info`) + bouton d'action en bas ;
--   • vue de confirmation : récapitulatif, « Annuler » sélectionné par défaut à la manette, « Confirmer » inactif
--     pendant `confirmDelay` et, si `acknowledgment` est fourni, tant que la case « J'ai compris » n'est pas cochée
--     (confirmation renforcée) ; B revient à l'information puis ferme.
-- Le panneau n'envoie rien au serveur : `onConfirm` (contrôleur) envoie l'intention, le serveur revalide tout.

local Builder = require(script.Parent.Builder)
local ModalPanel = require(script.Parent.ModalPanel)
local Theme = require(script.Parent.Theme)

local ACTION_AREA = 84
local ACK_HEIGHT = 52

export type Options = {
	id: string,
	title: string,
	parent: Instance,
	size: Vector2,
	menu: Instance,
	menuText: string,
	menuOrder: number,
	menuColor: Color3,
	keys: { Enum.KeyCode },
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

local ConfirmPanel = {
	text = ModalPanel.text,
	progressBar = ModalPanel.progressBar,
}

function ConfirmPanel.new(options: Options): Panel
	local header = ModalPanel.HEADER_HEIGHT
	local confirming = false
	local delayElapsed = false
	local acknowledged = false
	local actionEnabled = false
	local token = 0
	local showInfo: () -> ()

	local modal = ModalPanel.new({
		id = options.id,
		title = options.title,
		parent = options.parent,
		size = options.size,
		menu = options.menu,
		menuText = options.menuText,
		menuOrder = options.menuOrder,
		menuColor = options.menuColor,
		keys = options.keys,
		keyboardHint = options.keyboardHint,
		gamepadHint = options.gamepadHint,
		onOpen = function()
			showInfo()
		end,
		onClose = function()
			confirming = false
			token += 1
		end,
		onBack = function(): boolean
			if confirming then
				showInfo()
				return true
			end
			return false
		end,
	})
	local frame = modal.frame

	local infoView = Builder.new("Frame", {
		Name = "InfoView",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = frame,
	}) :: Frame
	local info = Builder.new("Frame", {
		Name = "Info",
		Position = UDim2.fromOffset(20, header),
		Size = UDim2.new(1, -40, 1, -(header + ACTION_AREA)),
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
		Position = UDim2.fromOffset(20, header),
		Size = UDim2.new(1, -40, 1, -header),
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

	showInfo = function()
		confirming = false
		delayElapsed = false
		acknowledged = false
		token += 1
		infoView.Visible = true
		confirmView.Visible = false
		refreshConfirm()
		ModalPanel.focus(actionButton)
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
		ModalPanel.focus(cancelButton)
		task.delay(options.confirmDelay, function()
			if confirming and current == token then
				delayElapsed = true
				refreshConfirm()
			end
		end)
	end

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
			modal.setOpen(false)
		end
	end)

	return {
		frame = frame,
		info = info,
		isOpen = modal.isOpen,
		isConfirming = function(): boolean
			return confirming
		end,
		setOpen = modal.setOpen,
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
