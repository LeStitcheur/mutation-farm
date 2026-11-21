--!strict
-- QuestController — panneau Missions (UI/ModalPanel) : onglets Quotidiennes / Hebdomadaires, temps restant avant
-- le renouvellement (horloge serveur), boosts actifs, une ligne par mission (difficulté, objectif, barre de
-- progression, récompenses, bouton Récupérer). Pastille sur le bouton du menu quand une récompense attend.
-- Touche J, manette R3. Le client n'envoie que l'identifiant de la mission à récupérer (QuestClaim).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local QuestConfig = require(Shared.Config.QuestConfig)
local Format = require(Shared.Util.Format)
local Quests = require(Shared.Util.Quests)
local Net = require(Shared.Net)
local StateController = require(script.Parent.StateController)
local Builder = require(script.Parent.Parent.UI.Builder)
local ModalPanel = require(script.Parent.Parent.UI.ModalPanel)
local Theme = require(script.Parent.Parent.UI.Theme)

local PANEL_SIZE = Vector2.new(820, 600)
local ROW_HEIGHT = 112
local MAX_ROWS = 3
local CLOCK_INTERVAL = 1

local DIFFICULTY_COLORS: { [string]: Color3 } = {
	easy = Theme.Colors.Green,
	medium = Theme.Colors.Blue,
	hard = Theme.Colors.Violet,
}

type Row = {
	frame: Frame,
	chip: TextLabel,
	label: TextLabel,
	fill: Frame,
	value: TextLabel,
	rewards: TextLabel,
	claim: TextButton,
	missionId: string?,
	claimable: boolean,
}

type Ui = {
	dailyTab: TextButton,
	weeklyTab: TextButton,
	timer: TextLabel,
	boosts: TextLabel,
	empty: TextLabel,
	badge: TextLabel,
}

local modal: ModalPanel.Modal? = nil
local ui: Ui? = nil
local rows: { Row } = {}
local tab: QuestConfig.Kind = "daily"
local lastSignature: string? = nil

local QuestController = {}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function partialData(state: Types.ClientState): any
	local quests: any = state.quests or {}
	return {
		quests = { daily = quests.daily, weekly = quests.weekly },
		boosts = state.boosts or {},
	}
end

local function formatDuration(seconds: number): string
	local whole = math.max(0, math.floor(seconds))
	local hours, minutes = whole // 3600, (whole % 3600) // 60
	if hours >= 24 then
		return string.format("%d j %d h", hours // 24, hours % 24)
	elseif hours > 0 then
		return string.format("%d h %02d", hours, minutes)
	end
	return string.format("%d:%02d", minutes, whole % 60)
end

-- Empreinte de ce que la liste affiche (onglet, période courante, progression et récupération des missions).
local function signature(state: Types.ClientState): string
	local parts: { string } = { tab, tostring(Quests.periodOf(tab, serverNow())) }
	local data = partialData(state)
	for _, kind: QuestConfig.Kind in { "daily", "weekly" } :: { QuestConfig.Kind } do
		local board = Quests.board(data, kind)
		if board then
			table.insert(parts, kind .. tostring(board.period))
			for _, mission in board.missions do
				table.insert(parts, string.format("%s:%d:%s", mission.id, mission.progress, tostring(mission.claimed)))
			end
		end
	end
	return table.concat(parts, "|")
end

-- Horloges (renouvellement, boosts) : rafraîchies chaque seconde tant que le panneau est ouvert.
local function renderClock(state: Types.ClientState)
	local current = ui
	if not current then
		return
	end
	local now = serverNow()
	local period = Quests.periodOf(tab, now)
	current.timer.Text = string.format(
		"%s dans %s",
		if tab == "daily" then "Nouvelles missions" else "Nouvelle semaine",
		formatDuration(Quests.periodEnd(tab, period) - now)
	)
	local data = partialData(state)
	local active: { string } = {}
	for id, def in QuestConfig.Boosts do
		local remaining = Quests.boostRemaining(data, id, now)
		if remaining > 0 then
			table.insert(active, string.format("%s %s", def.name, formatDuration(remaining)))
		end
	end
	table.sort(active)
	current.boosts.Text = if #active > 0
		then "Boosts actifs : " .. table.concat(active, " · ")
		else "Aucun boost actif (certaines missions en offrent)."
end

local function renderBadge(state: Types.ClientState)
	local current = ui
	if not current then
		return
	end
	local count = Quests.claimable(partialData(state), serverNow())
	current.badge.Visible = count > 0
	current.badge.Text = tostring(count)
end

local function render(state: Types.ClientState)
	renderBadge(state)
	local current = ui
	local panel = modal
	if not current or not panel or not panel.isOpen() then
		return
	end
	renderClock(state)
	local key = signature(state)
	if key == lastSignature then
		return
	end
	lastSignature = key
	current.dailyTab.BackgroundColor3 = if tab == "daily" then Theme.Colors.Gold else Theme.Colors.Grey
	current.weeklyTab.BackgroundColor3 = if tab == "weekly" then Theme.Colors.Gold else Theme.Colors.Grey
	local data = partialData(state)
	local board = Quests.board(data, tab)
	local currentPeriod = Quests.periodOf(tab, serverNow())
	local missions: { Types.Mission } = if board and board.period == currentPeriod then board.missions else {}
	current.empty.Visible = #missions == 0
	for index, row in rows do
		local mission = missions[index]
		row.frame.Visible = mission ~= nil
		row.missionId = if mission then mission.id else nil
		row.claimable = false
		if mission then
			row.chip.Text = (QuestConfig.DifficultyNames :: any)[mission.difficulty] or mission.difficulty
			row.chip.BackgroundColor3 = DIFFICULTY_COLORS[mission.difficulty] or Theme.Colors.Grey
			row.label.Text = Quests.describe(mission)
			row.fill.Size = UDim2.fromScale(math.clamp(mission.progress / mission.target, 0, 1), 1)
			row.value.Text = string.format("%s / %s", Format.number(mission.progress), Format.number(mission.target))
			row.rewards.Text = "Récompense : " .. Quests.rewardText(mission, Format.bigNum)
			local complete = Quests.isComplete(mission)
			row.claimable = complete and not mission.claimed
			row.claim.Text = if mission.claimed then "Récupérée" elseif complete then "Récupérer" else "En cours"
			row.claim.Active = row.claimable
			row.claim.AutoButtonColor = row.claimable
			row.claim.BackgroundColor3 = if row.claimable then Theme.Colors.Green else Theme.Colors.Grey
		end
	end
end

local function rerender()
	lastSignature = nil
	local state = StateController.Get()
	if state then
		render(state)
	end
end

local function buildRow(parent: Instance, index: number): Row
	local frame = Builder.new("Frame", {
		Name = "Mission" .. index,
		LayoutOrder = index,
		Size = UDim2.new(1, -10, 0, ROW_HEIGHT),
		BackgroundColor3 = Theme.Colors.PanelRow,
		Visible = false,
		Parent = parent,
	}, { Builder.corner(12) }) :: Frame
	local chip = Builder.label({
		Name = "Difficulty",
		Position = UDim2.fromOffset(12, 10),
		Size = UDim2.fromOffset(110, 26),
		BackgroundTransparency = 0,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = frame,
	})
	Builder.corner(8).Parent = chip
	local label = ModalPanel.text({
		Name = "Objective",
		Position = UDim2.fromOffset(134, 8),
		Size = UDim2.new(1, -310, 0, 30),
		TextSize = 20,
		Parent = frame,
	})
	local bar = Builder.new("Frame", {
		Name = "Progress",
		Position = UDim2.fromOffset(12, 46),
		Size = UDim2.new(1, -190, 0, 22),
		BackgroundColor3 = Theme.Colors.BarBack,
		Parent = frame,
	}, { Builder.corner(8) })
	local fill = Builder.new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Colors.Coin,
		Parent = bar,
	}, { Builder.corner(8) }) :: Frame
	local value = Builder.label({
		Name = "Value",
		Size = UDim2.fromScale(1, 1),
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 2,
		Parent = bar,
	})
	local rewards = ModalPanel.text({
		Name = "Rewards",
		Position = UDim2.fromOffset(12, 74),
		Size = UDim2.new(1, -190, 0, 32),
		TextSize = 14,
		TextColor3 = Theme.Colors.TextMuted,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = frame,
	})
	local claim = Builder.button({
		Name = "Claim",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(160, 56),
		TextSize = 18,
		BackgroundColor3 = Theme.Colors.Grey,
		Text = "En cours",
		Parent = frame,
	})
	local row: Row = {
		frame = frame,
		chip = chip,
		label = label,
		fill = fill,
		value = value,
		rewards = rewards,
		claim = claim,
		missionId = nil,
		claimable = false,
	}
	claim.Activated:Connect(function()
		local id = row.missionId
		if id and row.claimable then
			row.claimable = false
			claim.Active = false
			Net.event(Net.Events.QuestClaim):FireServer(id)
		end
	end)
	return row
end

function QuestController.Init()
	local root = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MutationFarmHUD")
	local created = ModalPanel.new({
		id = "Quests",
		title = "Missions",
		parent = root,
		size = PANEL_SIZE,
		menu = root:WaitForChild("Menu"),
		menuText = "Missions",
		menuOrder = 7,
		menuColor = Theme.Colors.Gold,
		keys = { Enum.KeyCode.J, Enum.KeyCode.ButtonR3 },
		keyboardHint = "J",
		gamepadHint = "R3",
		onOpen = function()
			rerender()
			local first = rows[1]
			local current = ui
			if first and first.claimable then
				ModalPanel.focus(first.claim)
			elseif current then
				ModalPanel.focus(current.dailyTab)
			end
		end,
	})
	modal = created

	local badge = Builder.label({
		Name = "ClaimBadge",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 4, 0, -8),
		Size = UDim2.fromOffset(26, 22),
		BackgroundColor3 = Theme.Colors.Red,
		BackgroundTransparency = 0,
		Text = "",
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		ZIndex = 3,
		Parent = created.menuButton,
	})
	Builder.corner(10).Parent = badge

	local content = Builder.new("Frame", {
		Name = "Content",
		Position = UDim2.fromOffset(20, ModalPanel.HEADER_HEIGHT),
		Size = UDim2.new(1, -40, 1, -(ModalPanel.HEADER_HEIGHT + 16)),
		BackgroundTransparency = 1,
		Parent = created.frame,
	}) :: Frame
	local function tabButton(name: string, text: string, x: number): TextButton
		return Builder.button({
			Name = name,
			Position = UDim2.fromOffset(x, 0),
			Size = UDim2.fromOffset(190, 42),
			TextSize = 18,
			BackgroundColor3 = Theme.Colors.Grey,
			Text = text,
			Parent = content,
		})
	end
	local dailyTab = tabButton("DailyTab", "Quotidiennes", 0)
	local weeklyTab = tabButton("WeeklyTab", "Hebdomadaires", 198)
	local timer = ModalPanel.text({
		Name = "Timer",
		Position = UDim2.fromOffset(400, 0),
		Size = UDim2.new(1, -400, 0, 42),
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = content,
	})
	local boosts = ModalPanel.text({
		Name = "Boosts",
		Position = UDim2.fromOffset(0, 50),
		Size = UDim2.new(1, 0, 0, 24),
		TextSize = 15,
		TextColor3 = Theme.Colors.TextMuted,
		Parent = content,
	})
	local list = Builder.new("ScrollingFrame", {
		Name = "Missions",
		Position = UDim2.fromOffset(0, 84),
		Size = UDim2.new(1, 0, 1, -84),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = content,
	}, { Builder.list(Enum.FillDirection.Vertical, 8) })
	for index = 1, MAX_ROWS do
		table.insert(rows, buildRow(list, index))
	end
	local empty = ModalPanel.text({
		Name = "Empty",
		Position = UDim2.fromOffset(0, 120),
		Size = UDim2.new(1, 0, 0, 40),
		Text = "Missions en préparation…",
		TextSize = 17,
		TextColor3 = Theme.Colors.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		Parent = content,
	})
	ui = {
		dailyTab = dailyTab,
		weeklyTab = weeklyTab,
		timer = timer,
		boosts = boosts,
		empty = empty,
		badge = badge,
	}
	dailyTab.Activated:Connect(function()
		tab = "daily"
		rerender()
	end)
	weeklyTab.Activated:Connect(function()
		tab = "weekly"
		rerender()
	end)
end

function QuestController.Start()
	StateController.Changed:Connect(render)
	task.spawn(function()
		while true do
			task.wait(CLOCK_INTERVAL)
			local state = StateController.Get()
			local panel = modal
			if state then
				renderBadge(state)
				if panel and panel.isOpen() then
					render(state) -- horloges chaque seconde ; liste seulement si son empreinte a changé
				end
			end
		end
	end)
end

return QuestController
