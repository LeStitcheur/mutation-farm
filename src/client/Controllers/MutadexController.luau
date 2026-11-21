--!strict
-- MutadexController — panneau Mutadex (UI/ModalPanel) : progression (découvertes / total, %), plantes récoltées,
-- découvertes les plus rares, paliers et prochaine récompense, filtres (plante, rareté), recherche par nom, cartes
-- de collection (silhouettes « ??? » pour les combinaisons inconnues) et historique des premières découvertes.
-- Animations discrètes : pulsation du bouton du menu et badge « Nouveau » à chaque découverte, cartes nouvelles
-- mises en valeur à l'ouverture. Touche M, manette R2. Lecture seule : le serveur décide de tout (HarvestRules).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local MutadexConfig = require(Shared.Config.MutadexConfig)
local PlantConfig = require(Shared.Config.PlantConfig)
local Format = require(Shared.Util.Format)
local Mutadex = require(Shared.Util.Mutadex)
local Net = require(Shared.Net)
local StateController = require(script.Parent.StateController)
local Builder = require(script.Parent.Parent.UI.Builder)
local ModalPanel = require(script.Parent.Parent.UI.ModalPanel)
local Theme = require(script.Parent.Parent.UI.Theme)

local PANEL_SIZE = Vector2.new(780, 640)
local CARD_SIZE = Vector2.new(98, 112)
local CONTENT_TOP = 136

type Card = {
	entry: Mutadex.CatalogEntry,
	frame: Frame,
	band: Frame,
	name: TextLabel,
	detail: TextLabel,
	stroke: UIStroke,
}

type Ui = {
	progressFill: Frame,
	progressValue: TextLabel,
	stats: TextLabel,
	milestones: TextLabel,
	plantButton: TextButton,
	rarityButton: TextButton,
	search: TextBox,
	historyButton: TextButton,
	grid: ScrollingFrame,
	history: ScrollingFrame,
	empty: TextLabel,
	badge: TextLabel,
	pulse: UIScale,
}

local modal: ModalPanel.Modal? = nil
local ui: Ui? = nil
local cards: { Card } = {}
local plantFilter: string? = nil
local rarityFilter: MutadexConfig.RarityDef? = nil
local showHistory = false
local fresh: { [string]: boolean } = {} -- découvertes depuis la dernière ouverture du panneau
local lastSignature: string? = nil -- dernier état affiché (évite de tout redessiner à chaque synchronisation)
local dateCache: { [number]: string } = {}

local rarities: { MutadexConfig.RarityDef } = {}
for _, rarity in MutadexConfig.RarityByMutation do
	table.insert(rarities, rarity)
end
table.sort(rarities, function(a, b)
	return a.order < b.order
end)

local MutadexController = {}

local function partialData(state: Types.ClientState): any
	return {
		mutadex = state.mutadex or {},
		mutadexRewards = state.mutadexRewards or {},
		stats = { harvests = state.harvests },
	}
end

local function formatDate(timestamp: number): string
	local seconds = math.floor(timestamp)
	local cached = dateCache[seconds]
	if cached then
		return cached
	end
	local ok, text = pcall(function(): string
		return DateTime.fromUnixTimestamp(seconds):FormatLocalTime("DD/MM HH:mm", "fr-fr")
	end)
	local result = if ok then text else "—"
	dateCache[seconds] = result
	return result
end

-- Empreinte de ce que le panneau affiche : l'état est resynchronisé à chaque gain de Coins ou passage de drone,
-- mais le panneau ne change que si le Mutadex, les paliers, les récoltes ou les filtres changent.
local function signature(state: Types.ClientState, query: string): string
	local entries, harvested, rewards = 0, 0, 0
	local mutadex: { [string]: any } = state.mutadex or {}
	local claimed: { [string]: any } = state.mutadexRewards or {}
	for _, value in mutadex do
		entries += 1
		if type(value) == "table" and type(value.count) == "number" then
			harvested += value.count
		end
	end
	for _ in claimed do
		rewards += 1
	end
	return table.concat({
		tostring(entries),
		tostring(harvested),
		tostring(rewards),
		tostring(state.harvests),
		plantFilter or "",
		if rarityFilter then rarityFilter.id else "",
		if showHistory then "h" else "c",
		query,
	}, "|")
end

local function rewardLabels(milestone: MutadexConfig.MilestoneDef): string
	local labels: { string } = {}
	for _, reward in milestone.rewards do
		table.insert(labels, reward.label)
	end
	return table.concat(labels, ", ")
end

local function renderHistory(current: Ui, data: any)
	for _, child in current.history:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	local list = Mutadex.history(data, MutadexConfig.HistoryLength)
	for index, item in list do
		ModalPanel.text({
			Name = "Discovery" .. index,
			LayoutOrder = index,
			Size = UDim2.new(1, -12, 0, 30),
			Text = string.format(
				"%s — %s (%s, ×%d)",
				formatDate(item.firstAt),
				item.entry.name,
				item.entry.rarity.name,
				item.entry.multiplier
			),
			TextSize = 17,
			Parent = current.history,
		})
	end
	if #list == 0 then
		ModalPanel.text({
			Name = "Discovery0",
			Size = UDim2.new(1, -12, 0, 30),
			Text = "Aucune découverte pour l'instant : récolte des plantes !",
			TextSize = 17,
			TextColor3 = Theme.Colors.TextMuted,
			Parent = current.history,
		})
	end
end

local function render(state: Types.ClientState)
	local current = ui
	local panel = modal
	if not current or not panel or not panel.isOpen() then
		return
	end
	local query = current.search.Text
	local key = signature(state, query)
	if key == lastSignature then
		return
	end
	lastSignature = key
	local data = partialData(state)
	local progress = Mutadex.progress(data)
	current.progressFill.Size = UDim2.fromScale(progress.discovered / progress.total, 1)
	current.progressValue.Text =
		string.format("%d / %d découvertes (%d %%)", progress.discovered, progress.total, math.floor(progress.percent))
	local rarestNames: { string } = {}
	for _, entry in Mutadex.rarest(data, MutadexConfig.RarestLength) do
		table.insert(rarestNames, entry.name)
	end
	current.stats.Text = string.format(
		"Plantes récoltées : %s · Plus rares : %s",
		Format.number(progress.harvests),
		if #rarestNames > 0 then table.concat(rarestNames, ", ") else "aucune"
	)
	local steps: { string } = {}
	for _, milestone in MutadexConfig.Milestones do
		table.insert(steps, (if Mutadex.isClaimed(data, milestone) then "✓ " else "") .. milestone.percent .. " %")
	end
	local nextMilestone = Mutadex.nextMilestone(data)
	current.milestones.Text = "Paliers : "
		.. table.concat(steps, " · ")
		.. (
			if nextMilestone
				then string.format(
					" — prochain : %d découvertes → %s",
					Mutadex.requirement(nextMilestone),
					rewardLabels(nextMilestone)
				)
				else " — collection complète !"
		)
	local plant = if plantFilter then PlantConfig.get(plantFilter) else nil
	current.plantButton.Text = "Plante : " .. (if plant then plant.name else "toutes")
	current.rarityButton.Text = "Rareté : " .. (if rarityFilter then rarityFilter.name else "toutes")
	current.historyButton.Text = if showHistory then "Cartes" else "Historique"
	current.grid.Visible = not showHistory
	current.history.Visible = showHistory

	local visible = 0
	for _, card in cards do
		local entry = card.entry
		local matches = Mutadex.matches(data, entry, plantFilter, if rarityFilter then rarityFilter.id else nil, query)
		card.frame.Visible = matches
		if matches then
			visible += 1
			local record = Mutadex.entry(data, entry.id)
			card.band.BackgroundColor3 = Color3.fromHex(entry.rarity.color)
			if record then
				card.frame.BackgroundColor3 = Theme.Colors.PanelRow
				card.name.Text = entry.name
				card.name.TextColor3 = Theme.Colors.Text
				card.detail.Text = string.format(
					"×%d · %s\n%s récolte(s)\n%s",
					entry.multiplier,
					entry.rarity.name,
					Format.number(record.count),
					formatDate(record.firstAt)
				)
				card.detail.TextColor3 = Theme.Colors.TextMuted
				card.band.BackgroundTransparency = 0
			else
				card.frame.BackgroundColor3 = Theme.Colors.PanelDark
				card.name.Text = "???"
				card.name.TextColor3 = Theme.Colors.TextLight
				card.detail.Text = entry.rarity.name .. "\nnon découverte"
				card.detail.TextColor3 = Theme.Colors.Grey
				card.band.BackgroundTransparency = 0.55
			end
		end
	end
	current.empty.Visible = not showHistory and visible == 0
	if showHistory then
		renderHistory(current, data)
	end
end

local function rerender()
	local state = StateController.Get()
	if state then
		render(state)
	end
end

-- Pulsation discrète du bouton du menu et badge « Nouveau » (première découverte).
local function notifyDiscovery(id: string)
	local current = ui
	local panel = modal
	if not current or not panel then
		return
	end
	fresh[id] = true
	if panel.isOpen() then
		rerender()
		return
	end
	current.badge.Visible = true
	-- Repart toujours de 1 : des découvertes rapprochées annulent la pulsation en cours, qui sinon reviendrait à
	-- une valeur intermédiaire (bouton resté agrandi, constaté en Studio).
	current.pulse.Scale = 1
	TweenService:Create(
		current.pulse,
		TweenInfo.new(0.18, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 2, true),
		{ Scale = 1.12 }
	):Play()
end

-- À l'ouverture : les cartes découvertes depuis la dernière visite s'illuminent brièvement.
local function highlightFresh()
	for _, card in cards do
		if fresh[card.entry.id] then
			card.stroke.Transparency = 0
			TweenService:Create(card.stroke, TweenInfo.new(2.5, Enum.EasingStyle.Quad), { Transparency = 1 }):Play()
		end
	end
	table.clear(fresh)
	local current = ui
	if current then
		current.badge.Visible = false
	end
end

local function filterButton(parent: Instance, name: string, x: number, width: number): TextButton
	return Builder.button({
		Name = name,
		Position = UDim2.fromOffset(x, 86),
		Size = UDim2.fromOffset(width, 40),
		TextSize = 17,
		BackgroundColor3 = Theme.Colors.Blue,
		Text = "…",
		Parent = parent,
	})
end

local function buildCard(parent: Instance, entry: Mutadex.CatalogEntry, order: number): Card
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Colors.Gold
	stroke.Thickness = 3
	stroke.Transparency = 1
	local frame = Builder.new("Frame", {
		Name = entry.id,
		LayoutOrder = order,
		BackgroundColor3 = Theme.Colors.PanelDark,
		Selectable = true, -- navigation à la manette (le cadre défile jusqu'à la carte sélectionnée)
		Parent = parent,
	}, { Builder.corner(10), stroke }) :: Frame
	local band = Builder.new("Frame", {
		Name = "Rarity",
		Size = UDim2.new(1, 0, 0, 8),
		BackgroundColor3 = Color3.fromHex(entry.rarity.color),
		BorderSizePixel = 0,
		Parent = frame,
	}, { Builder.corner(10) }) :: Frame
	local name = Builder.label({
		Name = "EntryName",
		Position = UDim2.fromOffset(4, 12),
		Size = UDim2.new(1, -8, 0, 36),
		TextSize = 14,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "???",
		Parent = frame,
	})
	local detail = Builder.label({
		Name = "Detail",
		Position = UDim2.fromOffset(4, 50),
		Size = UDim2.new(1, -8, 1, -54),
		TextSize = 12,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		Parent = frame,
	})
	return { entry = entry, frame = frame, band = band, name = name, detail = detail, stroke = stroke }
end

function MutadexController.Init()
	local root = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MutationFarmHUD")
	local created = ModalPanel.new({
		id = "Mutadex",
		title = "Mutadex",
		parent = root,
		size = PANEL_SIZE,
		menu = root:WaitForChild("Menu"),
		menuText = "Mutadex",
		menuOrder = 5,
		menuColor = Theme.Colors.Teal,
		keys = { Enum.KeyCode.M, Enum.KeyCode.ButtonR2 },
		keyboardHint = "M",
		gamepadHint = "R2",
		onOpen = function()
			lastSignature = nil -- redessin complet à chaque ouverture
			rerender()
			highlightFresh()
			local current = ui
			if current then
				ModalPanel.focus(current.plantButton)
			end
		end,
	})
	modal = created

	local pulse = Instance.new("UIScale")
	pulse.Parent = created.menuButton
	local badge = Builder.label({
		Name = "NewBadge",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 4, 0, -8),
		Size = UDim2.fromOffset(64, 20),
		BackgroundColor3 = Theme.Colors.Red,
		BackgroundTransparency = 0,
		Text = "Nouveau",
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		ZIndex = 3,
		Parent = created.menuButton,
	})
	Builder.corner(8).Parent = badge

	local content = Builder.new("Frame", {
		Name = "Content",
		Position = UDim2.fromOffset(20, ModalPanel.HEADER_HEIGHT),
		Size = UDim2.new(1, -40, 1, -(ModalPanel.HEADER_HEIGHT + 16)),
		BackgroundTransparency = 1,
		Parent = created.frame,
	}) :: Frame
	local progressFill, progressValue = ModalPanel.progressBar(content, 0, 28)
	local stats = ModalPanel.text({
		Name = "Stats",
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 0, 22),
		TextSize = 16,
		TextColor3 = Theme.Colors.TextMuted,
		Parent = content,
	})
	local milestones = ModalPanel.text({
		Name = "Milestones",
		Position = UDim2.fromOffset(0, 58),
		Size = UDim2.new(1, 0, 0, 22),
		TextSize = 15,
		Parent = content,
	})
	-- Lignes d'information sur une seule ligne : texte réduit pour tenir (noms longs, petits écrans), jamais de
	-- chevauchement avec la rangée de filtres.
	for _, line in { stats, milestones } do
		line.TextWrapped = false
		line.TextScaled = true
		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MinTextSize = 10
		constraint.MaxTextSize = line.TextSize
		constraint.Parent = line
	end
	local plantButton = filterButton(content, "PlantFilter", 0, 190)
	local rarityButton = filterButton(content, "RarityFilter", 198, 190)
	local search = Builder.new("TextBox", {
		Name = "Search",
		Position = UDim2.fromOffset(396, 86),
		Size = UDim2.fromOffset(190, 40),
		BackgroundColor3 = Theme.Colors.PanelRow,
		Font = Theme.Font,
		PlaceholderText = "Rechercher…",
		PlaceholderColor3 = Theme.Colors.TextMuted,
		Text = "",
		TextColor3 = Theme.Colors.Text,
		TextSize = 17,
		ClearTextOnFocus = false,
		Parent = content,
	}, { Builder.corner(10), Builder.stroke(Theme.Colors.Outline, 2) }) :: TextBox
	local historyButton = filterButton(content, "HistoryToggle", 594, 146) -- nom distinct du cadre « History »
	historyButton.BackgroundColor3 = Theme.Colors.Gold

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y)
	gridLayout.CellPadding = UDim2.fromOffset(6, 6)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	local grid = Builder.new("ScrollingFrame", {
		Name = "Cards",
		Position = UDim2.fromOffset(0, CONTENT_TOP),
		Size = UDim2.new(1, 0, 1, -CONTENT_TOP),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = content,
	}, { gridLayout }) :: ScrollingFrame
	for order, entry in Mutadex.catalog() do
		table.insert(cards, buildCard(grid, entry, order))
	end
	local history = Builder.new("ScrollingFrame", {
		Name = "History",
		Position = UDim2.fromOffset(0, CONTENT_TOP),
		Size = UDim2.new(1, 0, 1, -CONTENT_TOP),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Visible = false,
		Parent = content,
	}, { Builder.list(Enum.FillDirection.Vertical, 4) }) :: ScrollingFrame
	local empty = ModalPanel.text({
		Name = "Empty",
		Position = UDim2.fromOffset(0, CONTENT_TOP + 20),
		Size = UDim2.new(1, 0, 0, 30),
		Text = "Aucune entrée ne correspond à ces filtres.",
		TextSize = 17,
		TextColor3 = Theme.Colors.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		Parent = content,
	})

	ui = {
		progressFill = progressFill,
		progressValue = progressValue,
		stats = stats,
		milestones = milestones,
		plantButton = plantButton,
		rarityButton = rarityButton,
		search = search,
		historyButton = historyButton,
		grid = grid,
		history = history,
		empty = empty,
		badge = badge,
		pulse = pulse,
	}

	plantButton.Activated:Connect(function()
		-- Cycle : toutes → chaque plante dans l'ordre → toutes.
		if plantFilter == nil then
			plantFilter = PlantConfig.List[1].id
		else
			local nextPlant = PlantConfig.nextAfter(plantFilter)
			plantFilter = if nextPlant then nextPlant.id else nil
		end
		rerender()
	end)
	rarityButton.Activated:Connect(function()
		local index = 0
		for position, rarity in rarities do
			if rarityFilter == rarity then
				index = position
			end
		end
		rarityFilter = rarities[index + 1]
		rerender()
	end)
	historyButton.Activated:Connect(function()
		showHistory = not showHistory
		rerender()
	end)
	search:GetPropertyChangedSignal("Text"):Connect(rerender)
end

function MutadexController.Start()
	StateController.Changed:Connect(render)
	Net.event(Net.Events.HarvestResult).OnClientEvent:Connect(function(result: Types.HarvestResult)
		if result.discovered then
			notifyDiscovery(Mutadex.entryId(result.plantId, result.mutation))
		end
	end)
end

return MutadexController
