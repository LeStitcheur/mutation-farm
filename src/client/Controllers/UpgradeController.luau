--!strict
-- UpgradeController — panneau Améliorations (UI/ModalPanel) à deux onglets : Mutation Essence (conservées au
-- rebirth, perdues au prestige) et Primal Cores (permanentes). Chaque ligne : nom, niveau / maximum, effet actuel
-- → suivant (ou « maximum »), coût et bouton d'achat (vert si abordable). Touche U, manette L2.
-- Le client n'envoie que l'identifiant et le niveau affiché : le serveur revalide tout (UpgradeService).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local UpgradeConfig = require(Shared.Config.UpgradeConfig)
local BigNum = require(Shared.Util.BigNum)
local Format = require(Shared.Util.Format)
local Upgrades = require(Shared.Util.Upgrades)
local Net = require(Shared.Net)
local StateController = require(script.Parent.StateController)
local Builder = require(script.Parent.Parent.UI.Builder)
local ModalPanel = require(script.Parent.Parent.UI.ModalPanel)
local Theme = require(script.Parent.Parent.UI.Theme)

type TreeId = UpgradeConfig.TreeId
type UpgradeDef = UpgradeConfig.UpgradeDef

local PANEL_SIZE = Vector2.new(720, 600)
local ROW_HEIGHT = 62
local ROW_GAP = 6
local TREES: { TreeId } = { "essence", "cores" }
local TREE_COLORS: { [TreeId]: Color3 } = { essence = Theme.Colors.Gold, cores = Theme.Colors.Violet }
local COST_UNITS: { [TreeId]: string } = { essence = "Essence", cores = "Cores" }

type Row = {
	def: UpgradeDef,
	frame: Frame,
	name: TextLabel,
	detail: TextLabel,
	button: TextButton,
	level: number,
	affordable: boolean,
}

local tabs: { [TreeId]: TextButton } = {}
local rows: { [TreeId]: { Row } } = {}
local balanceLabel: TextLabel? = nil
local currentTree: TreeId = "essence"

local UpgradeController = {}

-- Donnée partielle suffisante pour les règles pures (Upgrades.level / balance).
local function partialData(state: Types.ClientState): any
	local upgrades = state.upgrades or { rebirth = {}, permanent = {} }
	return {
		currencies = {
			essence = BigNum.sanitize(state.essence),
			primalCores = BigNum.sanitize(state.primalCores),
		},
		upgrades = upgrades,
	}
end

local function render(state: Types.ClientState)
	local balance = balanceLabel
	if not balance then
		return
	end
	local data = partialData(state)
	local tree = UpgradeConfig.Trees[currentTree]
	local funds = Upgrades.balance(data, currentTree)
	balance.Text = string.format("Solde : %s %s · %s", Format.bigNum(funds), tree.name, tree.note)
	for _, treeId: TreeId in TREES do
		local selected = treeId == currentTree
		local tab = tabs[treeId]
		if tab then
			tab.BackgroundColor3 = if selected then TREE_COLORS[treeId] else Theme.Colors.Grey
		end
		local treeRows: { Row } = rows[treeId] or {}
		for _, row in treeRows do
			row.frame.Visible = selected
			local def = row.def
			local level = Upgrades.level(data, def.id)
			row.level = level
			row.name.Text = string.format("%s  ·  niv. %d/%d", def.name, level, def.maxLevel)
			if level >= def.maxLevel then
				row.detail.Text = Upgrades.describe(def, level) .. " (maximum atteint)"
				row.button.Text = "MAX"
				row.button.BackgroundColor3 = Theme.Colors.Grey
				row.button.AutoButtonColor = false
				row.affordable = false
			else
				local cost = Upgrades.cost(def, level)
				row.affordable = not BigNum.lt(Upgrades.balance(data, def.tree), cost)
				row.detail.Text = if level == 0
					then "Niveau 1 : " .. Upgrades.describe(def, 1)
					else Upgrades.describe(def, level) .. "  →  " .. Upgrades.describe(def, level + 1)
				row.button.Text = string.format("%s %s", Format.bigNum(cost), COST_UNITS[def.tree])
				row.button.BackgroundColor3 = if row.affordable then Theme.Colors.Green else Theme.Colors.Grey
				row.button.AutoButtonColor = row.affordable
			end
		end
	end
end

local function rerender()
	local state = StateController.Get()
	if state then
		render(state)
	end
end

local function selectTree(treeId: TreeId)
	currentTree = treeId
	rerender()
	local tab = tabs[treeId]
	if tab then
		ModalPanel.focus(tab)
	end
end

local function purchase(row: Row)
	if row.affordable and row.level < row.def.maxLevel then
		Net.event(Net.Events.UpgradePurchase):FireServer(row.def.id, row.level)
	end
end

local function buildRow(parent: Frame, def: UpgradeDef, index: number): Row
	local frame = Builder.new("Frame", {
		Name = def.id,
		Position = UDim2.fromOffset(20, 158 + (index - 1) * (ROW_HEIGHT + ROW_GAP)),
		Size = UDim2.new(1, -40, 0, ROW_HEIGHT),
		BackgroundColor3 = Theme.Colors.PanelRow,
		Visible = false,
		Parent = parent,
	}, { Builder.corner(12) }) :: Frame
	local name = ModalPanel.text({
		Name = "Name",
		Position = UDim2.fromOffset(14, 6),
		Size = UDim2.new(1, -230, 0, 24),
		TextSize = 19,
		Parent = frame,
	})
	local detail = ModalPanel.text({
		Name = "Detail",
		Position = UDim2.fromOffset(14, 32),
		Size = UDim2.new(1, -230, 0, 22),
		TextSize = 15,
		TextColor3 = Theme.Colors.TextMuted,
		Parent = frame,
	})
	local button = Builder.button({
		Name = "Buy",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(200, 46),
		TextSize = 18,
		BackgroundColor3 = Theme.Colors.Grey,
		Text = "…",
		Parent = frame,
	})
	local row: Row = {
		def = def,
		frame = frame,
		name = name,
		detail = detail,
		button = button,
		level = 0,
		affordable = false,
	}
	button.Activated:Connect(function()
		purchase(row)
	end)
	return row
end

function UpgradeController.Init()
	local hud = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MutationFarmHUD")
	local created = ModalPanel.new({
		id = "Upgrades",
		title = "Améliorations",
		parent = hud,
		size = PANEL_SIZE,
		menu = hud:WaitForChild("Menu"),
		menuText = "Améliorations",
		menuOrder = 4,
		menuColor = Theme.Colors.Blue,
		keys = { Enum.KeyCode.U, Enum.KeyCode.ButtonL2 },
		keyboardHint = "U",
		gamepadHint = "L2",
		onOpen = function()
			selectTree(currentTree)
		end,
	})
	local frame = created.frame
	for index, treeId: TreeId in TREES do
		local tab = Builder.button({
			Name = "Tab_" .. treeId,
			Position = UDim2.new((index - 1) * 0.5, if index == 1 then 20 else 6, 0, 72),
			Size = UDim2.new(0.5, -26, 0, 46),
			Text = UpgradeConfig.Trees[treeId].name,
			TextSize = 20,
			BackgroundColor3 = Theme.Colors.Grey,
			Parent = frame,
		})
		tab.Activated:Connect(function()
			selectTree(treeId)
		end)
		tabs[treeId] = tab
		local list: { Row } = {}
		for rowIndex, def in Upgrades.list(treeId) do
			table.insert(list, buildRow(frame, def, rowIndex))
		end
		rows[treeId] = list
	end
	balanceLabel = ModalPanel.text({
		Name = "Balance",
		Position = UDim2.fromOffset(20, 126),
		Size = UDim2.new(1, -40, 0, 24),
		TextSize = 17,
		Parent = frame,
	})
end

function UpgradeController.Start()
	StateController.Changed:Connect(render)
	rerender()
end

return UpgradeController
