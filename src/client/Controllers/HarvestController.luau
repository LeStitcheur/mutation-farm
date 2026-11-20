--!strict
-- HarvestController — invites de récolte LOCALES sur les cases mûres du joueur, requêtes au serveur
-- et textes flottants de résultat (Parfait / Bien). Le serveur reste seul juge de la récolte.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local MutationConfig = require(Shared.Config.MutationConfig)
local PlantConfig = require(Shared.Config.PlantConfig)
local Types = require(Shared.Types)
local BigNum = require(Shared.Util.BigNum)
local Format = require(Shared.Util.Format)
local Growth = require(Shared.Util.Growth)
local Net = require(Shared.Net)
local StateController = require(script.Parent.StateController)

local TILE_TAG = "FarmTile"
local UPDATE_INTERVAL = 0.1
local PENDING_TIMEOUT = 1

type Entry = {
	tile: BasePart,
	prompt: ProximityPrompt,
	plantedAt: number,
	pendingSince: number?,
}

local TIER_STYLE: { [string]: { text: string, color: Color3 } } = {
	perfect = { text = "PARFAIT !", color = Color3.fromRGB(255, 214, 64) },
	good = { text = "Bien !", color = Color3.fromRGB(140, 230, 120) },
	normal = { text = "", color = Color3.new(1, 1, 1) },
}

local localPlayer = Players.LocalPlayer
local entries: { [BasePart]: Entry } = {}
local byTileId: { [string]: BasePart } = {}

local HarvestController = {}

-- Définition de mutation si `value` désigne une mutation réelle (nil pour "normal" ou une valeur inconnue).
local function mutatedDef(value: unknown): Types.MutationDef?
	if type(value) ~= "string" or value == MutationConfig.NORMAL then
		return nil
	end
	return MutationConfig.get(value)
end

local function isOwnTile(tile: BasePart): boolean
	return tile:GetAttribute("OwnerUserId") == localPlayer.UserId
end

local function addTile(instance: Instance)
	if not instance:IsA("BasePart") or entries[instance] or not isOwnTile(instance) then
		return
	end
	local tile = instance
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HarvestPrompt"
	prompt.ActionText = "Récolter"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = GameConfig.Harvest.PromptDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Enabled = false
	prompt.Parent = tile

	local entry: Entry = { tile = tile, prompt = prompt, plantedAt = 0, pendingSince = nil }
	prompt.Triggered:Connect(function()
		local tileId = tile:GetAttribute("TileId")
		if type(tileId) ~= "string" then
			return
		end
		entry.pendingSince = os.clock()
		prompt.Enabled = false
		Net.event(Net.Events.HarvestRequest):FireServer(tileId)
	end)
	entries[tile] = entry
	local tileId = tile:GetAttribute("TileId")
	if type(tileId) == "string" then
		byTileId[tileId] = tile
	end
end

local function removeTile(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local entry = entries[instance]
	if not entry then
		return
	end
	entry.prompt:Destroy()
	entries[instance] = nil
	local tileId = instance:GetAttribute("TileId")
	if type(tileId) == "string" and byTileId[tileId] == instance then
		byTileId[tileId] = nil
	end
end

local function update()
	local now = Workspace:GetServerTimeNow()
	local state = StateController.Get()
	local bagFull = state ~= nil and state.bagCount >= state.bagCapacity
	local actionText = if bagFull then "Sac plein !" else "Récolter"
	for tile, entry in entries do
		local plantId = tile:GetAttribute("PlantId")
		local plantedAt = tile:GetAttribute("PlantedAt")
		local growTime = tile:GetAttribute("GrowTime")
		local prompt = entry.prompt
		if type(plantId) ~= "string" or plantId == "" or type(plantedAt) ~= "number" or type(growTime) ~= "number" then
			prompt.Enabled = false
			continue
		end
		local pendingSince = entry.pendingSince
		if pendingSince and (plantedAt ~= entry.plantedAt or os.clock() - pendingSince > PENDING_TIMEOUT) then
			entry.pendingSince = nil
		end
		entry.plantedAt = plantedAt

		local ripe = Growth.isRipe({ plantedAt = plantedAt, growTime = growTime }, now)
		local enabled = ripe and entry.pendingSince == nil
		if prompt.Enabled ~= enabled then
			prompt.Enabled = enabled
		end
		local plant = PlantConfig.get(plantId)
		local objectText = if plant then plant.name else ""
		local mutation = mutatedDef(tile:GetAttribute("Mutation"))
		if mutation then
			objectText = string.format("%s · %s ×%d", objectText, mutation.name, mutation.multiplier)
		end
		if prompt.ObjectText ~= objectText then
			prompt.ObjectText = objectText
		end
		if prompt.ActionText ~= actionText then
			prompt.ActionText = actionText
		end
	end
end

local function showFloatingText(tile: BasePart, text: string, color: Color3, lines: number)
	local gui = Instance.new("BillboardGui")
	gui.Name = "HarvestFloat"
	gui.Size = UDim2.fromOffset(260, 48 * lines)
	gui.StudsOffset = Vector3.new(0, 4, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Adornee = tile
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.1
	label.Text = text
	label.Parent = gui
	gui.Parent = tile

	local info = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(gui, info, { StudsOffset = Vector3.new(0, 7.5, 0) }):Play()
	TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(1.1, function()
		gui:Destroy()
	end)
end

local function onHarvestResult(result: Types.HarvestResult)
	local tile = byTileId[result.tileId]
	if not tile then
		return
	end
	-- L'attente est levée par le changement de PlantedAt (ou le délai) dans update(), pas ici :
	-- l'événement peut arriver avant l'attribut et réactiverait brièvement l'invite sur l'ancien état.
	local plant = PlantConfig.get(result.plantId)
	local style = TIER_STYLE[result.tier] or TIER_STYLE.normal
	local bonus = BigNum.sanitize(result.bonus)
	local text = if result.tier ~= "normal" and not BigNum.isZero(bonus)
		then string.format("%s +%s", style.text, Format.bigNum(bonus))
		else "+1 " .. (if plant then plant.name else "récolte")
	-- Mutation (décidée par le serveur) : ligne dédiée, dans la couleur de la mutation.
	local mutation = mutatedDef(result.mutation)
	if mutation then
		-- Pas de string.upper : il ne traite pas les lettres accentuées UTF-8 (« CRISTALLISéE »).
		local heading = string.format("%s ×%d", mutation.name, mutation.multiplier)
		showFloatingText(tile, heading .. "\n" .. text, Color3.fromHex(mutation.color), 2)
	else
		showFloatingText(tile, text, style.color, 1)
	end
end

function HarvestController.Init()
	Net.event(Net.Events.HarvestResult).OnClientEvent:Connect(onHarvestResult)
end

function HarvestController.Start()
	for _, tile in CollectionService:GetTagged(TILE_TAG) do
		addTile(tile)
	end
	CollectionService:GetInstanceAddedSignal(TILE_TAG):Connect(addTile)
	CollectionService:GetInstanceRemovedSignal(TILE_TAG):Connect(removeTile)

	local elapsed = 0
	RunService.Heartbeat:Connect(function(deltaTime: number)
		elapsed += deltaTime
		if elapsed >= UPDATE_INTERVAL then
			elapsed = 0
			update()
		end
	end)
end

return HarvestController
