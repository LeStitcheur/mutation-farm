--!strict
-- DroneService — drones récolteurs (Phase 2, jalon B).
--   * Station d'achat sur chaque parcelle : un ProximityPrompt serveur par type de DroneConfig, réservé au
--     propriétaire ; paiement en Coins via EconomyService.TrySpendCoins.
--   * Drones possédés sauvegardés dans data.machines.drones (champ existant : aucune migration).
--   * UNE seule boucle serveur (GameConfig.Drones.TickInterval) pour tous les drones : chaque drone agit toutes les
--     `interval` secondes et récolte via HarvestService.HarvestForDrone (mêmes validations que la récolte manuelle,
--     sans bonus de précision ; sac plein = attente, rien n'est perdu).
--   * Rendu : ancres invisibles taguées « FarmDrone » (attributs DroneType, OwnerUserId, Status, TargetTile, ActionAt)
--     animées localement par DroneRenderer.
-- API : Buy.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local DroneConfig = require(Shared.Config.DroneConfig)
local GameConfig = require(Shared.Config.GameConfig)
local Types = require(Shared.Types)
local BigNum = require(Shared.Util.BigNum)
local DroneLogic = require(Shared.Util.DroneLogic)
local Economy = require(Shared.Util.Economy)
local FarmLayout = require(Shared.Util.FarmLayout)
local Format = require(Shared.Util.Format)
local Inventory = require(Shared.Util.Inventory)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local FarmService = require(script.Parent.FarmService)
local HarvestService = require(script.Parent.HarvestService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

type DroneDef = Types.DroneDef
type DroneStatus = "idle" | "working" | "bag_full"

type Drone = {
	def: DroneDef,
	home: FarmLayout.Vec3,
	anchor: BasePart,
	nextAt: number,
	status: DroneStatus,
}

type Runtime = {
	drones: { Drone },
	folder: Folder,
	prompts: { [string]: ProximityPrompt },
}

local DRONE_TAG = "FarmDrone"
local STATION_COLOR = Color3.fromRGB(96, 125, 139)
local FAILURE_MESSAGES: { [string]: string } = {
	insufficient_funds = "Pas assez de Coins pour ce drone.",
	max_owned = "Tu possèdes déjà le maximum de ce drone.",
}

local runtimes: { [Player]: Runtime } = {}
local buyLimiter = RateLimiter.new(GameConfig.Drones.BuyRequestsPerSecond)

local DroneService = {}

local function toWorld(origin: CFrame, point: FarmLayout.Vec3): CFrame
	return origin * CFrame.new(point.x, point.y, point.z)
end

local function makePart(name: string, size: Vector3, cframe: CFrame, material: Enum.Material, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = STATION_COLOR
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function setStatus(drone: Drone, status: DroneStatus)
	if drone.status ~= status then
		drone.status = status
		drone.anchor:SetAttribute("Status", status)
	end
end

-- (Re)crée les ancres des drones possédés : points d'attente répartis, premières actions étalées.
local function layoutDrones(player: Player, runtime: Runtime)
	for _, drone in runtime.drones do
		drone.anchor:Destroy()
	end
	table.clear(runtime.drones)
	local data = DataService.GetData(player)
	local origin = FarmService.GetPlotOrigin(player)
	if not data or not origin then
		return
	end
	local fleet = DroneLogic.fleet(data)
	local now = Workspace:GetServerTimeNow()
	for index, def in fleet do
		local home = DroneLogic.homePosition(index, #fleet)
		local anchor: BasePart = Instance.new("Part")
		anchor.Name = string.format("Drone_%s_%d", def.id, index)
		anchor.Size = Vector3.new(1, 1, 1)
		anchor.Transparency = 1
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.CFrame = toWorld(origin, home)
		anchor:SetAttribute("DroneType", def.id)
		anchor:SetAttribute("OwnerUserId", player.UserId)
		anchor:SetAttribute("Status", "idle")
		anchor:SetAttribute("TargetTile", "")
		anchor:SetAttribute("ActionAt", 0)
		CollectionService:AddTag(anchor, DRONE_TAG)
		anchor.Parent = runtime.folder
		table.insert(runtime.drones, {
			def = def,
			home = home,
			anchor = anchor,
			nextAt = now + def.interval * index / #fleet,
			status = "idle",
		})
	end
end

local function refreshPrompts(player: Player, runtime: Runtime)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	for droneId, prompt in runtime.prompts do
		local def = DroneConfig.get(droneId)
		if def then
			local owned = DroneLogic.owned(data, droneId)
			if owned >= def.maxOwned then
				prompt.ActionText = "Complet"
				prompt.ObjectText = string.format("%s · %d/%d", def.name, owned, def.maxOwned)
			else
				prompt.ActionText = "Acheter : " .. def.name
				prompt.ObjectText =
					string.format("%s Coins · %d/%d", Format.number(DroneLogic.price(def, owned)), owned, def.maxOwned)
			end
		end
	end
end

local function buildStation(player: Player, runtime: Runtime, model: Model, origin: CFrame)
	local base = toWorld(origin, FarmLayout.Features.droneStation)
	local pad =
		makePart("DroneStationPad", Vector3.new(7, 1, 7), base * CFrame.new(0, 0.5, 0), Enum.Material.Metal, model)
	makePart("DroneStationPole", Vector3.new(0.6, 5, 0.6), base * CFrame.new(0, 3.5, 0), Enum.Material.Metal, model)
	local board = makePart(
		"DroneStationBoard",
		Vector3.new(5, 2, 0.4),
		base * CFrame.new(0, 6.5, 0),
		Enum.Material.SmoothPlastic,
		model
	)

	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromOffset(240, 50)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = 150
	gui.LightInfluence = 0
	gui.Adornee = board
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(79, 195, 247)
	label.TextStrokeTransparency = 0.25
	label.Text = "DRONES"
	label.Parent = gui
	gui.Parent = board

	for index, def in DroneConfig.List do
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "Buy_" .. def.id
		prompt.HoldDuration = 0.4 -- évite un achat accidentel
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.UIOffset = Vector2.new(0, (index - 1) * 80)
		prompt.Parent = pad
		prompt.Triggered:Connect(function(buyer: Player)
			if buyer ~= player then
				Notifier.send(buyer, "error", "Cette station appartient à une autre ferme.")
				return
			end
			DroneService.Buy(player, def.id)
		end)
		runtime.prompts[def.id] = prompt
	end
end

-- Achète un exemplaire de `droneId` pour `player` (propriétaire de la parcelle). Retourne le succès et la raison.
function DroneService.Buy(player: Player, droneId: string): (boolean, string?)
	if not buyLimiter:allow(player) then
		return false, "rate_limited"
	end
	local runtime = runtimes[player]
	local data = DataService.GetData(player)
	local def = DroneConfig.get(droneId)
	if not runtime or not data or not def then
		return false, "unknown"
	end
	local allowed, reason = DroneLogic.canBuy(data, droneId)
	if not allowed then
		local message = if reason then FAILURE_MESSAGES[reason] else nil
		if message then
			Notifier.send(player, "error", message)
		end
		return false, reason
	end
	local owned = DroneLogic.owned(data, droneId)
	if not EconomyService.TrySpendCoins(player, BigNum.fromNumber(DroneLogic.price(def, owned))) then
		Notifier.send(player, "error", FAILURE_MESSAGES.insufficient_funds)
		return false, "insufficient_funds"
	end
	DataService.Update(player, function(d)
		d.machines.drones[droneId] = DroneLogic.owned(d, droneId) + 1
	end)
	layoutDrones(player, runtime)
	refreshPrompts(player, runtime)
	Notifier.send(player, "success", string.format("%s acheté ! (%d/%d)", def.name, owned + 1, def.maxOwned))
	return true, nil
end

local function tick()
	local now = Workspace:GetServerTimeNow()
	for player, runtime in runtimes do
		local data = DataService.GetData(player)
		if not data or #runtime.drones == 0 then
			continue
		end
		local reserved: { [string]: boolean } = {}
		for _, drone in runtime.drones do
			if now < drone.nextAt then
				continue
			end
			drone.nextAt = now + drone.def.interval
			local status: DroneStatus = if Inventory.isFull(data.bag.items, Economy.bagCapacity(data))
				then "bag_full"
				else "idle"
			for _, tileId in DroneLogic.selectTargets(data, now, drone.home, drone.def, reserved) do
				reserved[tileId] = true
				local ok, failure = HarvestService.HarvestForDrone(player, tileId, drone.home, drone.def.range)
				if ok then
					status = "working"
					drone.anchor:SetAttribute("TargetTile", tileId)
					drone.anchor:SetAttribute("ActionAt", now)
				elseif failure == "bag_full" then
					status = "bag_full"
					break
				end
			end
			setStatus(drone, status)
		end
	end
end

local function attach(player: Player)
	local model = FarmService.GetPlotModel(player)
	local origin = FarmService.GetPlotOrigin(player)
	if not model or not origin or runtimes[player] then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "Drones"
	folder.Parent = model
	local runtime: Runtime = { drones = {}, folder = folder, prompts = {} }
	runtimes[player] = runtime
	buildStation(player, runtime, model, origin)
	layoutDrones(player, runtime)
	refreshPrompts(player, runtime)
end

-- Les instances (station, ancres) sont détruites avec la parcelle par FarmService.
local function detach(player: Player)
	runtimes[player] = nil
end

function DroneService.Init()
	FarmService.PlotReady:Connect(attach)
	DataService.ProfileReleasing:Connect(detach)
	Players.PlayerRemoving:Connect(detach)
end

function DroneService.Start()
	local elapsed = 0
	RunService.Heartbeat:Connect(function(deltaTime: number)
		elapsed += deltaTime
		if elapsed < GameConfig.Drones.TickInterval then
			return
		end
		elapsed = 0
		tick()
	end)
end

return DroneService
