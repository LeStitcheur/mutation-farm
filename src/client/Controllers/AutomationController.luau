--!strict
-- AutomationController — panneau Automatisation (UI/ModalPanel, Phase 5, jalon C) :
--   • comptoir de vente automatique : installation (prix), activation, seuil de vente (50 / 75 / 100 % du sac) ;
--   • drones récolteurs : nombre, débit, mise en pause ;
--   • production automatique : débits de la ferme et des drones (facteur limitant), sac, statistiques depuis
--     toujours et depuis la connexion.
-- Touche K, manette croix droite. Le client n'envoie qu'une action et une valeur (AutomationRequest) : le serveur
-- revalide tout (AutomationService).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local AutomationConfig = require(Shared.Config.AutomationConfig)
local Automation = require(Shared.Util.Automation)
local BigNum = require(Shared.Util.BigNum)
local DroneLogic = require(Shared.Util.DroneLogic)
local Format = require(Shared.Util.Format)
local Net = require(Shared.Net)
local StateController = require(script.Parent.StateController)
local Builder = require(script.Parent.Parent.UI.Builder)
local ModalPanel = require(script.Parent.Parent.UI.ModalPanel)
local Theme = require(script.Parent.Parent.UI.Theme)

local PANEL_SIZE = Vector2.new(720, 590)

type Ui = {
	sellerDetail: TextLabel,
	sellerButton: TextButton,
	thresholdButtons: { [number]: TextButton },
	dronesTitle: TextLabel,
	dronesDetail: TextLabel,
	dronesButton: TextButton,
	production: TextLabel,
}

local ui: Ui? = nil
local sessionStart: Types.AutomationStats? = nil -- statistiques au premier état reçu (statistiques de session)
local lastState: Types.ClientState? = nil

local AutomationController = {}

-- Donnée partielle suffisante pour les règles pures (Automation, DroneLogic, Economy, Expansions).
local function partialData(state: Types.ClientState): any
	local automation: any = state.automation or {}
	local upgrades: any = state.upgrades or {}
	return {
		currencies = { coins = BigNum.sanitize(state.coins) },
		machines = { drones = state.drones or {}, autoSeller = automation.sellerOwned == true },
		automation = {
			dronesEnabled = automation.dronesEnabled ~= false,
			autoSellEnabled = automation.autoSellEnabled == true,
			autoSellThreshold = automation.autoSellThreshold,
			stats = automation.stats,
		},
		upgrades = {
			normal = upgrades.normal or {},
			rebirth = upgrades.rebirth or {},
			permanent = upgrades.permanent or {},
		},
		pets = state.pets or { instances = {}, equipped = {} },
		mutadexRewards = state.mutadexRewards or {},
		mutadex = state.mutadex or {},
		bag = { items = state.bagItems or {} },
		farm = { plots = state.plots or {}, tiles = {} },
		seeds = { unlocked = state.seedsUnlocked or {}, selected = state.selectedSeed },
	}
end

local function send(action: string, value: any)
	Net.event(Net.Events.AutomationRequest):FireServer(action, value)
end

local function setButton(button: TextButton, text: string, color: Color3, active: boolean)
	button.Text = text
	button.BackgroundColor3 = color
	button.AutoButtonColor = active
end

local function formatRate(value: number): string
	return if value >= 10 then string.format("%d", math.floor(value + 0.5)) else string.format("%.1f", value)
end

local function statsLine(label: string, droneHarvests: number, autoSells: number, coins: Types.BigNum): string
	return string.format(
		"%s : %s récolte(s) de drones · %s vente(s) auto · +%s Coins",
		label,
		Format.number(droneHarvests),
		Format.number(autoSells),
		Format.bigNum(coins)
	)
end

local function render(state: Types.ClientState)
	lastState = state
	local current = ui
	local automation = state.automation
	if not current or not automation then
		return
	end
	local stats = automation.stats
	if not sessionStart and stats then
		sessionStart = {
			droneHarvests = stats.droneHarvests,
			autoSells = stats.autoSells,
			autoSellCoins = BigNum.sanitize(stats.autoSellCoins),
		}
	end
	local data = partialData(state)

	-- Comptoir automatique.
	local thresholdCount = Automation.thresholdCount(data)
	if not automation.sellerOwned then
		local price = Automation.sellerPrice()
		local affordable = not BigNum.lt(BigNum.sanitize(state.coins), price)
		current.sellerDetail.Text = "Non installé · vend ton sac à ta place, au prix du marché"
		setButton(
			current.sellerButton,
			string.format("Installer : %s Coins", Format.bigNum(price)),
			if affordable then Theme.Colors.Green else Theme.Colors.Grey,
			affordable
		)
	elseif automation.autoSellEnabled then
		current.sellerDetail.Text =
			string.format("Activé · vend à %d %% du sac (%d objets)", Automation.threshold(data), thresholdCount)
		setButton(current.sellerButton, "Activé", Theme.Colors.Green, true)
	else
		current.sellerDetail.Text = "Coupé · vends ton sac au marché"
		setButton(current.sellerButton, "Coupé", Theme.Colors.Grey, true)
	end
	for percent, button in current.thresholdButtons do
		local selected = Automation.threshold(data) == percent
		setButton(
			button,
			string.format("%d %%", percent),
			if selected then Theme.Colors.Blue else Theme.Colors.Grey,
			not selected
		)
	end

	-- Drones.
	local rates = Automation.rates(data)
	local owned = #DroneLogic.fleet(data)
	current.dronesTitle.Text = string.format("Drones récolteurs  ·  %d possédé(s)", owned)
	if owned == 0 then
		current.dronesDetail.Text = "Achète-les à la station DRONES"
	elseif automation.dronesEnabled then
		current.dronesDetail.Text =
			string.format("Actifs · jusqu'à %s récoltes/min (grâce de 5 s)", formatRate(rates.dronesPerMinute))
	else
		current.dronesDetail.Text = "En pause · aucune récolte automatique"
	end
	setButton(
		current.dronesButton,
		if automation.dronesEnabled then "Actifs" else "En pause",
		if automation.dronesEnabled then Theme.Colors.Green else Theme.Colors.Grey,
		true
	)

	-- Production et statistiques.
	local limiting = if owned == 0 or not automation.dronesEnabled
		then "aucune production automatique"
		elseif rates.dronesPerMinute < rates.farmPerMinute then "limitée par les drones"
		else "limitée par les cases"
	local bagCount, bagCapacity = state.bagCount or 0, state.bagCapacity or 0
	local bagLine = string.format("Sac : %d/%d", bagCount, bagCapacity)
	if bagCount >= bagCapacity and not Automation.autoSellActive(data) then
		bagLine ..= " · PLEIN : tes drones attendent (vends au marché ou active le comptoir)"
	elseif Automation.autoSellActive(data) then
		bagLine ..= string.format(" · vente automatique à %d", thresholdCount)
	end
	local lines = {
		string.format(
			"Ferme : %d cases · %s récoltes/min avec la graine actuelle · %s",
			rates.tiles,
			formatRate(rates.farmPerMinute),
			limiting
		),
		bagLine,
	}
	if stats then
		table.insert(lines, statsLine("Depuis toujours", stats.droneHarvests, stats.autoSells, stats.autoSellCoins))
		local start = sessionStart
		if start then
			table.insert(
				lines,
				statsLine(
					"Cette session",
					math.max(0, stats.droneHarvests - start.droneHarvests),
					math.max(0, stats.autoSells - start.autoSells),
					BigNum.max(BigNum.zero(), BigNum.sub(BigNum.sanitize(stats.autoSellCoins), start.autoSellCoins))
				)
			)
		end
	end
	-- Production hors ligne (Phase 5, jalon D) : totaux depuis toujours (2 h au plus par absence).
	local offline = state.offline
	if offline then
		table.insert(
			lines,
			string.format(
				"Hors ligne : %s comptées au total · +%s Coins (2 h au plus par absence)",
				Format.duration(offline.totalSeconds or 0),
				Format.bigNum(BigNum.sanitize(offline.totalCoins))
			)
		)
	end
	current.production.Text = table.concat(lines, "\n")
end

local function rerender()
	local state = lastState or StateController.Get()
	if state then
		render(state)
	end
end

local function card(parent: Frame, name: string, y: number, height: number): Frame
	return Builder.new("Frame", {
		Name = name,
		Position = UDim2.fromOffset(20, y),
		Size = UDim2.new(1, -40, 0, height),
		BackgroundColor3 = Theme.Colors.PanelRow,
		Parent = parent,
	}, { Builder.corner(12) }) :: Frame
end

local function title(parent: Frame, text: string, width: number): TextLabel
	return ModalPanel.text({
		Name = "Title",
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.new(1, -width, 0, 24),
		Text = text,
		TextSize = 20,
		Parent = parent,
	})
end

local function detail(parent: Frame, y: number, width: number): TextLabel
	return ModalPanel.text({
		Name = "Detail",
		Position = UDim2.fromOffset(14, y),
		Size = UDim2.new(1, -width, 0, 22),
		TextSize = 15,
		TextColor3 = Theme.Colors.TextMuted,
		Parent = parent,
	})
end

local function sideButton(parent: Frame, name: string, width: number): TextButton
	return Builder.button({
		Name = name,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(width, 46),
		TextSize = 18,
		BackgroundColor3 = Theme.Colors.Grey,
		Text = "…",
		Parent = parent,
	})
end

function AutomationController.Init()
	local hud = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MutationFarmHUD")
	local created = ModalPanel.new({
		id = "Automation",
		title = "Automatisation",
		parent = hud,
		size = PANEL_SIZE,
		menu = hud:WaitForChild("Menu"),
		menuText = "Automatisation",
		menuOrder = 8,
		menuColor = Theme.Colors.Teal,
		keys = { Enum.KeyCode.K, Enum.KeyCode.DPadRight },
		keyboardHint = "K",
		gamepadHint = "→",
		onOpen = function()
			rerender()
			local current = ui
			if current then
				ModalPanel.focus(current.sellerButton)
			end
		end,
	})
	local frame = created.frame

	local seller = card(frame, "Seller", 80, 74)
	title(seller, AutomationConfig.AutoSeller.Name .. " (perdu au rebirth)", 250)
	local sellerDetail = detail(seller, 38, 250)
	local sellerButton = sideButton(seller, "Toggle", 220)
	sellerButton.Activated:Connect(function()
		local state = lastState
		local automation = if state then state.automation else nil
		if not automation then
			return
		end
		if not automation.sellerOwned then
			if sellerButton.AutoButtonColor then
				send("buy_seller", true)
			end
		else
			send("autosell", not automation.autoSellEnabled)
		end
	end)

	local threshold = card(frame, "Threshold", 162, 60)
	title(threshold, "Vendre quand le sac atteint", 400)
	local thresholdButtons: { [number]: TextButton } = {}
	for index, percent in AutomationConfig.Thresholds do
		local button = Builder.button({
			Name = "Threshold_" .. percent,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10 - (#AutomationConfig.Thresholds - index) * 118, 0.5, 0),
			Size = UDim2.fromOffset(110, 42),
			TextSize = 18,
			BackgroundColor3 = Theme.Colors.Grey,
			Text = string.format("%d %%", percent),
			Parent = threshold,
		})
		button.Activated:Connect(function()
			send("threshold", percent)
		end)
		thresholdButtons[percent] = button
	end

	local drones = card(frame, "Drones", 230, 74)
	local dronesTitle = title(drones, "Drones récolteurs", 250)
	local dronesDetail = detail(drones, 38, 250)
	local dronesButton = sideButton(drones, "Toggle", 220)
	dronesButton.Activated:Connect(function()
		local state = lastState
		local automation = if state then state.automation else nil
		if automation then
			send("drones", not automation.dronesEnabled)
		end
	end)

	local production = card(frame, "Production", 312, 258)
	title(production, "Production automatique", 40)
	local productionText = ModalPanel.text({
		Name = "Lines",
		Position = UDim2.fromOffset(14, 40),
		Size = UDim2.new(1, -28, 1, -50),
		TextSize = 19,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = production,
	})

	ui = {
		sellerDetail = sellerDetail,
		sellerButton = sellerButton,
		thresholdButtons = thresholdButtons,
		dronesTitle = dronesTitle,
		dronesDetail = dronesDetail,
		dronesButton = dronesButton,
		production = productionText,
	}
end

function AutomationController.Start()
	StateController.Changed:Connect(render)
	rerender()
end

return AutomationController
