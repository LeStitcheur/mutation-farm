--!strict
-- PetController — panneau Familiers (UI/ModalPanel) : œufs (prix, réserve gratuite, probabilités affichées, achat),
-- bonus actifs des familiers équipés, inventaire trié (rareté, niveau ; doublons comptés) avec niveau, barre d'XP,
-- bonus, équiper / retirer et relâcher (confirmation). Animation d'éclosion à la réception de PetHatched (le
-- résultat est déjà sauvegardé par le serveur). Touche F, manette L3. Le client n'envoie que des intentions.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local PetConfig = require(Shared.Config.PetConfig)
local BigNum = require(Shared.Util.BigNum)
local Format = require(Shared.Util.Format)
local Pets = require(Shared.Util.Pets)
local Net = require(Shared.Net)
local StateController = require(script.Parent.StateController)
local Builder = require(script.Parent.Parent.UI.Builder)
local ModalPanel = require(script.Parent.Parent.UI.ModalPanel)
local Theme = require(script.Parent.Parent.UI.Theme)

local PANEL_SIZE = Vector2.new(880, 660)
local EGG_COLUMN = 300
local CARD_SIZE = Vector2.new(124, 172)
local PENDING_TIMEOUT = 6 -- secondes sans réponse : les boutons d'œuf redeviennent actifs
local RELEASE_CONFIRM = 3 -- secondes pour confirmer un relâchement

type EggCard = {
	egg: PetConfig.EggDef,
	buy: TextButton,
	free: TextButton,
	price: TextLabel,
}

type PetCard = {
	frame: Frame,
	band: Frame,
	name: TextLabel,
	level: TextLabel,
	xpFill: Frame,
	bonus: TextLabel,
	equip: TextButton,
	release: TextButton,
	stroke: UIStroke,
	id: string?,
	equipped: boolean,
	confirmUntil: number,
}

type Ui = {
	summary: TextLabel,
	inventoryTitle: TextLabel,
	grid: ScrollingFrame,
	empty: TextLabel,
	overlay: Frame,
	egg: Frame,
	reveal: TextLabel,
}

local modal: ModalPanel.Modal? = nil
local ui: Ui? = nil
local eggCards: { EggCard } = {}
local petCards: { PetCard } = {}
local pendingUntil = 0
local lastSignature: string? = nil

local PetController = {}

local function partialData(state: Types.ClientState): any
	local pets: any = state.pets or {}
	return {
		pets = {
			instances = pets.instances or {},
			equipped = pets.equipped or {},
			hatched = pets.hatched or 0,
			freeEggs = pets.freeEggs or {},
		},
		currencies = { coins = state.coins },
	}
end

-- Empreinte de ce que le panneau affiche (évite de redessiner à chaque synchronisation de l'état).
local function signature(state: Types.ClientState): string
	local pets: any = state.pets or {}
	local parts: { string } = { tostring(pets.hatched), Format.bigNum(state.coins) }
	local instances: { [string]: any } = pets.instances or {}
	for id, instance in instances do
		if type(instance) == "table" then
			table.insert(
				parts,
				string.format(
					"%s:%s:%s:%s",
					id,
					tostring(instance.level),
					tostring(instance.xp),
					tostring(instance.petId)
				)
			)
		end
	end
	local equipped: { any } = pets.equipped or {}
	for _, id in equipped do
		table.insert(parts, "e" .. tostring(id))
	end
	local freeEggs: { [string]: any } = pets.freeEggs or {}
	for eggId, count in freeEggs do
		table.insert(parts, "f" .. eggId .. tostring(count))
	end
	table.sort(parts)
	return table.concat(parts, "|")
end

local function oddsText(egg: PetConfig.EggDef): string
	local parts: { string } = {}
	for _, odds in Pets.odds(egg) do
		local def = Pets.get(odds.petId)
		local percent = odds.probability * 100
		local shown = if percent >= 1
			then string.format("%d %%", math.floor(percent + 0.5))
			else string.format("%.1f %%", percent)
		table.insert(parts, (if def then def.name else odds.petId) .. " " .. shown)
	end
	return table.concat(parts, " · ")
end

local function bonusSummary(data: any): string
	local effects = Pets.effects(data)
	local parts: { string } = {}
	if effects.value > 0 then
		table.insert(parts, string.format("+%d %% revenu", math.floor(effects.value * 100 + 0.5)))
	end
	if effects.growth > 0 then
		table.insert(parts, string.format("−%d %% pousse", math.floor(effects.growth * 100 + 0.5)))
	end
	if effects.luck > 0 then
		table.insert(parts, string.format("+%.2f chance", effects.luck))
	end
	if effects.drones > 0 then
		table.insert(parts, string.format("−%d %% drones", math.floor(effects.drones * 100 + 0.5)))
	end
	if effects.manual > 0 then
		table.insert(parts, string.format("+%d %% précision", math.floor(effects.manual * 100 + 0.5)))
	end
	return if #parts > 0 then table.concat(parts, " · ") else "aucun (équipe un familier)"
end

local function setButton(button: TextButton, enabled: boolean, text: string, color: Color3)
	button.Text = text
	button.AutoButtonColor = enabled
	button.Active = enabled
	button.BackgroundColor3 = if enabled then color else Theme.Colors.Grey
end

local function render(state: Types.ClientState)
	local current = ui
	local panel = modal
	if not current or not panel or not panel.isOpen() then
		return
	end
	local pending = os.clock() < pendingUntil
	local key = signature(state) .. (if pending then "|pending" else "")
	if key == lastSignature then
		return
	end
	lastSignature = key
	local data = partialData(state)
	local full = Pets.count(data) >= PetConfig.InventoryCapacity

	current.summary.Text = string.format(
		"Équipés %d/%d · Bonus actifs : %s",
		#Pets.equippedIds(data),
		PetConfig.Slots,
		bonusSummary(data)
	)
	for _, card in eggCards do
		local egg = card.egg
		local price = egg.price
		local freeCount = Pets.freeEggs(data, egg.id)
		card.price.Text = if price
			then string.format("Prix : %s Coins · gratuits : %d", Format.bigNum(BigNum.fromNumber(price)), freeCount)
			else string.format("Gagné avec les missions · en réserve : %d", freeCount)
		if price then
			local affordable = not BigNum.lt(state.coins, BigNum.fromNumber(price))
			setButton(card.buy, affordable and not full and not pending, "Acheter", Theme.Colors.Green)
			card.buy.Visible = true
		else
			card.buy.Visible = false
		end
		setButton(card.free, freeCount > 0 and not full and not pending, "Ouvrir gratuit", Theme.Colors.Gold)
	end

	local owned = Pets.sorted(data)
	local species = Pets.speciesCount(data)
	current.inventoryTitle.Text = string.format(
		"Inventaire %d/%d%s",
		Pets.count(data),
		PetConfig.InventoryCapacity,
		if full then " — plein : relâche un familier" else ""
	)
	current.empty.Visible = #owned == 0
	local slotsFull = #Pets.equippedIds(data) >= PetConfig.Slots
	for index, card in petCards do
		local entry = owned[index]
		card.frame.Visible = entry ~= nil
		card.id = if entry then entry.id else nil
		card.equipped = if entry then entry.equipped else false
		if entry then
			local def, instance = entry.def, entry.instance
			card.band.BackgroundColor3 = Color3.fromHex(def.rarity.color)
			card.name.Text = def.name
			local duplicates = species[def.id] or 1
			card.level.Text = string.format(
				"Nv %d · %s%s",
				instance.level,
				def.rarity.name,
				if duplicates > 1 then string.format(" (×%d)", duplicates) else ""
			)
			local maxed = instance.level >= PetConfig.Level.Max
			local progress = if maxed then 1 else math.clamp(instance.xp / Pets.xpToNext(instance.level), 0, 1)
			card.xpFill.Size = UDim2.fromScale(progress, 1)
			card.xpFill.BackgroundColor3 = if maxed then Theme.Colors.Gold else Theme.Colors.Green
			card.bonus.Text = Pets.describe(def, instance.level)
			card.stroke.Transparency = if entry.equipped then 0 else 1
			if entry.equipped then
				setButton(card.equip, true, "Retirer", Theme.Colors.Blue)
			else
				setButton(card.equip, not slotsFull, "Équiper", Theme.Colors.Green)
			end
			local confirming = os.clock() < card.confirmUntil
			card.release.Visible = not entry.equipped
			card.release.Text = if confirming then "Confirmer ?" else "Relâcher"
			card.release.TextColor3 = if confirming then Theme.Colors.Red else Theme.Colors.TextMuted
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

local function requestHatch(egg: PetConfig.EggDef, useFree: boolean)
	local state = StateController.Get()
	if not state or os.clock() < pendingUntil then
		return
	end
	local data = partialData(state)
	pendingUntil = os.clock() + PENDING_TIMEOUT
	rerender()
	Net.event(Net.Events.PetHatch):FireServer(egg.id, Pets.hatchedCount(data), useFree)
	task.delay(PENDING_TIMEOUT + 0.1, rerender)
end

local function buildEggCard(parent: Instance, egg: PetConfig.EggDef): EggCard
	local frame = Builder.new("Frame", {
		Name = egg.id,
		LayoutOrder = egg.order,
		Size = UDim2.new(1, -10, 0, 170),
		BackgroundColor3 = Theme.Colors.PanelRow,
		Parent = parent,
	}, { Builder.corner(12) })
	Builder.new("Frame", {
		Name = "Band",
		Size = UDim2.new(0, 10, 1, 0),
		BackgroundColor3 = Color3.fromHex(egg.color),
		BorderSizePixel = 0,
		Parent = frame,
	}, { Builder.corner(12) })
	ModalPanel.text({
		Name = "EggName",
		Position = UDim2.fromOffset(20, 8),
		Size = UDim2.new(1, -30, 0, 26),
		Text = egg.name,
		TextSize = 20,
		Parent = frame,
	})
	local price = ModalPanel.text({
		Name = "Price",
		Position = UDim2.fromOffset(20, 36),
		Size = UDim2.new(1, -30, 0, 20),
		TextSize = 14,
		TextColor3 = Theme.Colors.TextMuted,
		Parent = frame,
	})
	ModalPanel.text({
		Name = "Odds",
		Position = UDim2.fromOffset(20, 58),
		Size = UDim2.new(1, -30, 0, 56),
		Text = oddsText(egg),
		TextSize = 13,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = frame,
	})
	local buy = Builder.button({
		Name = "Buy",
		Position = UDim2.fromOffset(20, 120),
		Size = UDim2.fromOffset(124, 40),
		TextSize = 17,
		BackgroundColor3 = Theme.Colors.Green,
		Text = "Acheter",
		Parent = frame,
	})
	local free = Builder.button({
		Name = "Free",
		Position = UDim2.fromOffset(152, 120),
		Size = UDim2.fromOffset(124, 40),
		TextSize = 17,
		BackgroundColor3 = Theme.Colors.Gold,
		Text = "Ouvrir gratuit",
		Parent = frame,
	})
	buy.Activated:Connect(function()
		if buy.Active then
			requestHatch(egg, false)
		end
	end)
	free.Activated:Connect(function()
		if free.Active then
			requestHatch(egg, true)
		end
	end)
	return { egg = egg, buy = buy, free = free, price = price }
end

local function buildPetCard(parent: Instance, index: number): PetCard
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Colors.Green
	stroke.Thickness = 3
	stroke.Transparency = 1
	local frame = Builder.new("Frame", {
		Name = "Pet" .. index,
		LayoutOrder = index,
		BackgroundColor3 = Theme.Colors.PanelRow,
		Visible = false,
		Parent = parent,
	}, { Builder.corner(10), stroke }) :: Frame
	local band = Builder.new("Frame", {
		Name = "Rarity",
		Size = UDim2.new(1, 0, 0, 8),
		BorderSizePixel = 0,
		Parent = frame,
	}, { Builder.corner(10) }) :: Frame
	local name = ModalPanel.text({
		Name = "PetName",
		Position = UDim2.fromOffset(4, 10),
		Size = UDim2.new(1, -8, 0, 32),
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = frame,
	})
	local level = ModalPanel.text({
		Name = "Level",
		Position = UDim2.fromOffset(4, 42),
		Size = UDim2.new(1, -8, 0, 18),
		TextSize = 12,
		TextColor3 = Theme.Colors.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = frame,
	})
	local xpBack = Builder.new("Frame", {
		Name = "Xp",
		Position = UDim2.fromOffset(8, 62),
		Size = UDim2.new(1, -16, 0, 8),
		BackgroundColor3 = Theme.Colors.BarBack,
		Parent = frame,
	}, { Builder.corner(4) })
	local xpFill = Builder.new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Colors.Green,
		Parent = xpBack,
	}, { Builder.corner(4) }) :: Frame
	local bonus = ModalPanel.text({
		Name = "Bonus",
		Position = UDim2.fromOffset(4, 74),
		Size = UDim2.new(1, -8, 0, 36),
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = frame,
	})
	local equip = Builder.button({
		Name = "Equip",
		Position = UDim2.fromOffset(6, 112),
		Size = UDim2.new(1, -12, 0, 30),
		TextSize = 15,
		BackgroundColor3 = Theme.Colors.Green,
		Text = "Équiper",
		Parent = frame,
	})
	local release = Builder.button({
		Name = "Release",
		Position = UDim2.fromOffset(6, 146),
		Size = UDim2.new(1, -12, 0, 22),
		TextSize = 12,
		BackgroundTransparency = 1,
		TextColor3 = Theme.Colors.TextMuted,
		TextStrokeTransparency = 1,
		Text = "Relâcher",
		Parent = frame,
	})
	local card: PetCard = {
		frame = frame,
		band = band,
		name = name,
		level = level,
		xpFill = xpFill,
		bonus = bonus,
		equip = equip,
		release = release,
		stroke = stroke,
		id = nil,
		equipped = false,
		confirmUntil = 0,
	}
	equip.Activated:Connect(function()
		local id = card.id
		if id and equip.Active then
			Net.event(if card.equipped then Net.Events.PetUnequip else Net.Events.PetEquip):FireServer(id)
		end
	end)
	release.Activated:Connect(function()
		local id = card.id
		if not id or card.equipped then
			return
		end
		if os.clock() < card.confirmUntil then
			card.confirmUntil = 0
			Net.event(Net.Events.PetRelease):FireServer(id)
		else
			card.confirmUntil = os.clock() + RELEASE_CONFIRM
			task.delay(RELEASE_CONFIRM + 0.05, rerender)
		end
		rerender()
	end)
	return card
end

-- Animation d'éclosion : l'œuf tremble puis révèle le familier (résultat déjà sauvegardé par le serveur).
local function playHatch(result: Types.HatchResult)
	pendingUntil = 0
	local current = ui
	local panel = modal
	local def = Pets.get(result.petId)
	local egg = Pets.egg(result.eggId)
	if not current or not panel or not def then
		rerender()
		return
	end
	if not panel.isOpen() then
		panel.setOpen(true)
	end
	current.overlay.Visible = true
	current.egg.Visible = true
	current.egg.Rotation = 0
	current.egg.BackgroundColor3 = if egg then Color3.fromHex(egg.color) else Theme.Colors.Panel
	current.reveal.Visible = false
	TweenService:Create(
		current.egg,
		TweenInfo.new(0.09, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 8, true),
		{ Rotation = 14 }
	):Play()
	task.delay(1.0, function()
		current.egg.Visible = false
		current.reveal.Text = string.format("%s\n%s", def.name, def.rarity.name)
		current.reveal.TextColor3 = Color3.fromHex(def.rarity.color)
		current.reveal.TextTransparency = 1
		current.reveal.Visible = true
		TweenService:Create(current.reveal, TweenInfo.new(0.35), { TextTransparency = 0 }):Play()
		task.delay(2.2, function()
			current.overlay.Visible = false
		end)
	end)
	rerender()
end

function PetController.Init()
	local root = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MutationFarmHUD")
	local created = ModalPanel.new({
		id = "Pets",
		title = "Familiers",
		parent = root,
		size = PANEL_SIZE,
		menu = root:WaitForChild("Menu"),
		menuText = "Familiers",
		menuOrder = 6,
		menuColor = Theme.Colors.Pink,
		keys = { Enum.KeyCode.F, Enum.KeyCode.ButtonL3 },
		keyboardHint = "F",
		gamepadHint = "L3",
		onOpen = function()
			rerender()
			local first = eggCards[1]
			if first then
				ModalPanel.focus(first.buy)
			end
		end,
	})
	modal = created

	local content = Builder.new("Frame", {
		Name = "Content",
		Position = UDim2.fromOffset(20, ModalPanel.HEADER_HEIGHT),
		Size = UDim2.new(1, -40, 1, -(ModalPanel.HEADER_HEIGHT + 16)),
		BackgroundTransparency = 1,
		Parent = created.frame,
	}) :: Frame
	local summary = ModalPanel.text({
		Name = "Summary",
		Size = UDim2.new(1, 0, 0, 24),
		TextSize = 17,
		Parent = content,
	})
	summary.TextWrapped = false
	summary.TextScaled = true
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MinTextSize = 10
	constraint.MaxTextSize = 17
	constraint.Parent = summary

	local eggs = Builder.new("ScrollingFrame", {
		Name = "Eggs",
		Position = UDim2.fromOffset(0, 32),
		Size = UDim2.new(0, EGG_COLUMN, 1, -32),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = content,
	}, { Builder.list(Enum.FillDirection.Vertical, 8) })
	local sortedEggs = table.clone(PetConfig.Eggs)
	table.sort(sortedEggs, function(a, b)
		return a.order < b.order
	end)
	for _, egg in sortedEggs do
		table.insert(eggCards, buildEggCard(eggs, egg))
	end

	local inventoryTitle = ModalPanel.text({
		Name = "InventoryTitle",
		Position = UDim2.fromOffset(EGG_COLUMN + 16, 32),
		Size = UDim2.new(1, -(EGG_COLUMN + 16), 0, 24),
		TextSize = 17,
		Parent = content,
	})
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y)
	gridLayout.CellPadding = UDim2.fromOffset(6, 6)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	local grid = Builder.new("ScrollingFrame", {
		Name = "Inventory",
		Position = UDim2.fromOffset(EGG_COLUMN + 16, 60),
		Size = UDim2.new(1, -(EGG_COLUMN + 16), 1, -60),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = content,
	}, { gridLayout }) :: ScrollingFrame
	for index = 1, PetConfig.InventoryCapacity do
		table.insert(petCards, buildPetCard(grid, index))
	end
	local empty = ModalPanel.text({
		Name = "Empty",
		Position = UDim2.fromOffset(EGG_COLUMN + 16, 80),
		Size = UDim2.new(1, -(EGG_COLUMN + 16), 0, 60),
		Text = "Aucun familier pour l'instant : ouvre un œuf !",
		TextSize = 17,
		TextColor3 = Theme.Colors.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = content,
	})

	local overlay = Builder.new("Frame", {
		Name = "Hatch",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.PanelDark,
		BackgroundTransparency = 0.25,
		Visible = false,
		ZIndex = 20,
		Active = true,
		Parent = created.frame,
	}, { Builder.corner(16) }) :: Frame
	local egg = Builder.new("Frame", {
		Name = "Egg",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(120, 150),
		ZIndex = 21,
		Parent = overlay,
	}, { Builder.corner(60), Builder.stroke(Theme.Colors.Outline, 4) }) :: Frame
	local reveal = Builder.label({
		Name = "Reveal",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(600, 140),
		TextSize = 44,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0,
		Visible = false,
		ZIndex = 21,
		Parent = overlay,
	})
	overlay.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			overlay.Visible = false
		end
	end)

	ui = {
		summary = summary,
		inventoryTitle = inventoryTitle,
		grid = grid,
		empty = empty,
		overlay = overlay,
		egg = egg,
		reveal = reveal,
	}
end

function PetController.Start()
	StateController.Changed:Connect(render)
	Net.event(Net.Events.PetHatched).OnClientEvent:Connect(playHatch)
end

return PetController
