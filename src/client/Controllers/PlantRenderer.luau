--!strict
-- PlantRenderer — rendu LOCAL des plantes de toutes les fermes à partir des attributs des cases
-- (PlantId, PlantedAt, GrowTime). Croissance animée à 10 Hz, étincelles sur les plantes mûres.
-- Aucun coût serveur par image.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Growth = require(ReplicatedStorage.Shared.Util.Growth)
local PlantVisuals = require(script.Parent.Parent.Visuals.PlantVisuals)

local TILE_TAG = "FarmTile"
local UPDATE_INTERVAL = 0.1
local MIN_SCALE = 0.2
local SCALE_EPSILON = 0.01

type Record = {
	tile: BasePart,
	plantId: string,
	plantedAt: number,
	growTime: number,
	plant: PlantVisuals.PlantModel?,
	scale: number,
	dirty: boolean,
	connection: RBXScriptConnection?,
}

local records: { [BasePart]: Record } = {}
local container: Folder? = nil

local PlantRenderer = {}

local function getContainer(): Folder
	if container and container.Parent then
		return container
	end
	local folder = Instance.new("Folder")
	folder.Name = "ClientPlants"
	folder.Parent = Workspace
	container = folder
	return folder
end

local function readNumber(instance: Instance, name: string): number
	local value = instance:GetAttribute(name)
	return if type(value) == "number" then value else 0
end

local function readString(instance: Instance, name: string): string
	local value = instance:GetAttribute(name)
	return if type(value) == "string" then value else ""
end

local function destroyPlant(record: Record)
	if record.plant then
		record.plant.model:Destroy()
		record.plant = nil
	end
end

local function tileTop(tile: BasePart): CFrame
	return tile.CFrame * CFrame.new(0, tile.Size.Y / 2, 0)
end

-- Relit les attributs ; reconstruit le modèle si la plante change.
local function refresh(record: Record)
	record.dirty = false
	local plantId = readString(record.tile, "PlantId")
	if plantId ~= record.plantId then
		destroyPlant(record)
		record.plantId = plantId
		if plantId ~= "" then
			local plant = PlantVisuals.build(plantId)
			if plant then
				plant.model.Parent = getContainer()
				record.plant = plant
			end
		end
	end
	record.plantedAt = readNumber(record.tile, "PlantedAt")
	record.growTime = readNumber(record.tile, "GrowTime")
	record.scale = -1 -- force la mise à l'échelle
end

local function updateVisual(record: Record, now: number)
	local plant = record.plant
	if not plant then
		return
	end
	local progress = Growth.progress(record, now)
	local eased = 1 - (1 - progress) ^ 2
	local scale = MIN_SCALE + (1 - MIN_SCALE) * eased
	if math.abs(scale - record.scale) >= SCALE_EPSILON or (progress >= 1 and record.scale ~= scale) then
		PlantVisuals.place(plant, tileTop(record.tile), scale)
		record.scale = scale
	end
	local ripe = progress >= 1
	if plant.sparkle.Enabled ~= ripe then
		plant.sparkle.Enabled = ripe
	end
end

local function addTile(instance: Instance)
	if not instance:IsA("BasePart") or records[instance] then
		return
	end
	local record: Record = {
		tile = instance,
		plantId = "",
		plantedAt = 0,
		growTime = 0,
		plant = nil,
		scale = -1,
		dirty = true,
		connection = nil,
	}
	record.connection = instance.AttributeChanged:Connect(function()
		record.dirty = true
	end)
	records[instance] = record
end

local function removeTile(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local record = records[instance]
	if not record then
		return
	end
	if record.connection then
		record.connection:Disconnect()
	end
	destroyPlant(record)
	records[instance] = nil
end

function PlantRenderer.Init() end

function PlantRenderer.Start()
	for _, tile in CollectionService:GetTagged(TILE_TAG) do
		addTile(tile)
	end
	CollectionService:GetInstanceAddedSignal(TILE_TAG):Connect(addTile)
	CollectionService:GetInstanceRemovedSignal(TILE_TAG):Connect(removeTile)

	local elapsed = 0
	RunService.Heartbeat:Connect(function(deltaTime: number)
		elapsed += deltaTime
		if elapsed < UPDATE_INTERVAL then
			return
		end
		elapsed = 0
		local now = Workspace:GetServerTimeNow()
		for _, record in records do
			if record.dirty then
				refresh(record)
			end
			updateVisual(record, now)
		end
	end)
end

return PlantRenderer
