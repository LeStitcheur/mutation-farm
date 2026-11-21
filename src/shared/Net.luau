--!strict
-- Noms et accès aux RemoteEvents. Le serveur crée le dossier ; le client l'attend.
-- Contrats de charge utile : docs/ARCHITECTURE.md §4.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Remotes"

local Events = {
	-- Client -> Serveur
	HarvestRequest = "HarvestRequest",
	UnlockSeed = "UnlockSeed",
	SelectSeed = "SelectSeed",
	ClientReady = "ClientReady", -- écouteurs client connectés : le serveur renvoie l'état complet
	RebirthRequest = "RebirthRequest", -- révision de progression attendue (idempotence)
	PrestigeRequest = "PrestigeRequest", -- révision de progression attendue (idempotence)
	UpgradePurchase = "UpgradePurchase", -- identifiant d'amélioration + niveau attendu (idempotence)
	PetHatch = "PetHatch", -- œuf + nombre d'éclosions attendu (idempotence) + œuf gratuit (booléen)
	PetEquip = "PetEquip", -- identifiant d'instance
	PetUnequip = "PetUnequip", -- identifiant d'instance
	PetRelease = "PetRelease", -- identifiant d'instance (familier non équipé)
	-- Serveur -> Client
	StateSync = "StateSync",
	HarvestResult = "HarvestResult",
	PetHatched = "PetHatched", -- résultat d'éclosion, envoyé après la sauvegarde
	Notify = "Notify",
	LoadStatus = "LoadStatus",
}
table.freeze(Events)

local EVENT_NAMES: { string } = {}
for _, name in pairs(Events) do
	table.insert(EVENT_NAMES, name)
end

local Net = {
	Events = Events,
}

local folder: Instance? = nil

local function getFolder(): Instance
	if folder then
		return folder
	end
	local resolved: Instance
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if existing then
			resolved = existing
		else
			local created = Instance.new("Folder")
			created.Name = FOLDER_NAME
			for _, name in EVENT_NAMES do
				local remote = Instance.new("RemoteEvent")
				remote.Name = name
				remote.Parent = created
			end
			created.Parent = ReplicatedStorage
			resolved = created
		end
	else
		resolved = ReplicatedStorage:WaitForChild(FOLDER_NAME)
	end
	folder = resolved
	return resolved
end

function Net.event(name: string): RemoteEvent
	local container = getFolder()
	local remote = if RunService:IsServer() then container:FindFirstChild(name) else container:WaitForChild(name)
	assert(remote and remote:IsA("RemoteEvent"), "RemoteEvent inconnu : " .. name)
	return remote
end

return Net
