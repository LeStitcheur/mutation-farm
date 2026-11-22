--!strict
-- OfflineController — écran « Pendant ton absence » (Phase 5, jalon D) : affiché quand le serveur a réglé une absence
-- (ClientState.offline.report non lu) : durée d'absence et durée prise en compte (plafond de 2 h), récoltes des
-- drones, ventes du comptoir et Coins, objets ajoutés au sac, conseils. Textes : Offline.describeReport (testé).
-- Un seul panneau à la fois et chat masqué (UI/PanelHub) ; « Super ! » (ou B à la manette) ferme l'écran et le
-- signale lu au serveur (OfflineReportSeen, sans charge utile).

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Offline = require(Shared.Util.Offline)
local Net = require(Shared.Net)
local StateController = require(script.Parent.StateController)
local Builder = require(script.Parent.Parent.UI.Builder)
local ModalPanel = require(script.Parent.Parent.UI.ModalPanel)
local PanelHub = require(script.Parent.Parent.UI.PanelHub)
local Theme = require(script.Parent.Parent.UI.Theme)

local PANEL_ID = "Offline"
local PANEL_SIZE = Vector2.new(640, 430)
local BACK_ACTION = "MutationFarm_Offline_Back"

type Ui = {
	frame: Frame,
	scale: UIScale,
	body: TextLabel,
	ok: TextButton,
}

local ui: Ui? = nil
local shownAt: number? = nil -- horodatage du bilan affiché (un bilan n'est montré qu'une fois)

local OfflineController = {}

local function updateScale()
	local current = ui
	local camera = Workspace.CurrentCamera
	if current and camera then
		local base = Theme.scaleFor(camera.ViewportSize, UserInputService.TouchEnabled)
		current.scale.Scale = Theme.fitScale(base, camera.ViewportSize, PANEL_SIZE)
	end
end

local function close()
	local current = ui
	if not current or not current.frame.Visible then
		return
	end
	current.frame.Visible = false
	ContextActionService:UnbindAction(BACK_ACTION)
	PanelHub.closed(PANEL_ID)
	Net.event(Net.Events.OfflineReportSeen):FireServer()
end

local function open(report: Types.OfflineReport)
	local current = ui
	if not current then
		return
	end
	shownAt = report.at
	current.body.Text = table.concat(Offline.describeReport(report), "\n\n")
	updateScale()
	current.frame.Visible = true
	PanelHub.opened(PANEL_ID)
	ContextActionService:BindAction(BACK_ACTION, function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			close()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.ButtonB)
	ModalPanel.focus(current.ok)
end

local function onState(state: Types.ClientState)
	local offline = state.offline
	local report = if offline then offline.report else nil
	if not report or report.seen or report.at <= 0 or shownAt == report.at then
		return
	end
	open(report)
end

function OfflineController.Init()
	local hud = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MutationFarmHUD")
	local frame = Builder.new("Frame", {
		Name = "OfflinePanel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(PANEL_SIZE.X, PANEL_SIZE.Y),
		BackgroundColor3 = Theme.Colors.Panel,
		Visible = false,
		ZIndex = 5,
		Parent = hud,
	}, { Builder.corner(18), Builder.stroke(Theme.Colors.Outline, 4) }) :: Frame
	local scale = Instance.new("UIScale")
	scale.Parent = frame
	Builder.label({
		Name = "Title",
		Position = UDim2.fromOffset(24, 16),
		Size = UDim2.new(1, -48, 0, 44),
		Text = "Pendant ton absence",
		TextSize = 34,
		TextColor3 = Theme.Colors.Text,
		ZIndex = 6,
		Parent = frame,
	})
	local body = ModalPanel.text({
		Name = "Body",
		Position = UDim2.fromOffset(24, 72),
		Size = UDim2.new(1, -48, 1, -160),
		TextSize = 20,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 6,
		Parent = frame,
	})
	local ok = Builder.button({
		Name = "Ok",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -20),
		Size = UDim2.fromOffset(240, 56),
		Text = "Super !",
		TextSize = 24,
		BackgroundColor3 = Theme.Colors.Green,
		ZIndex = 6,
		Parent = frame,
	})
	ok.Activated:Connect(close)
	PanelHub.register(PANEL_ID, function()
		-- Un autre panneau s'ouvre : l'écran se ferme (et compte comme lu).
		close()
	end)
	ui = { frame = frame, scale = scale, body = body, ok = ok }
end

function OfflineController.Start()
	local function watchCamera()
		local camera = Workspace.CurrentCamera
		if camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
		end
		updateScale()
	end
	watchCamera()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	StateController.Changed:Connect(onState)
	local state = StateController.Get()
	if state then
		onState(state)
	end
end

return OfflineController
