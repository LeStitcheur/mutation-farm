--!strict
-- Adaptateur de stockage clé/valeur : DataStore Roblox réel, ou store mémoire en Studio sans accès API.
-- Seule opération exposée : update (sémantique UpdateAsync ; la transformation retourne nil pour annuler).

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Deep = require(ReplicatedStorage.Shared.Util.Deep)

export type Transform = (old: any) -> any

export type Store = {
	name: string,
	isMemory: boolean,
	update: (key: string, transform: Transform) -> (),
}

local BUDGET_WAIT_MAX = 10

local DataStoreAdapter = {}

-- Store en mémoire : copies profondes en entrée/sortie pour imiter la sérialisation.
function DataStoreAdapter.memory(name: string): Store
	local entries: { [string]: any } = {}
	return {
		name = name,
		isMemory = true,
		update = function(key: string, transform: Transform)
			local result = transform(Deep.copy(entries[key]))
			if result ~= nil then
				entries[key] = Deep.copy(result)
			end
		end,
	}
end

local function waitForBudget()
	local deadline = os.clock() + BUDGET_WAIT_MAX
	while
		DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync) < 1
		and os.clock() < deadline
	do
		task.wait(0.5)
	end
end

local function robloxStore(name: string): Store
	local store = DataStoreService:GetDataStore(name)
	return {
		name = name,
		isMemory = false,
		update = function(key: string, transform: Transform)
			waitForBudget()
			store:UpdateAsync(key, function(old: any): any
				return transform(old)
			end)
		end,
	}
end

-- Ouvre le store. En Studio sans « Enable Studio Access to API Services », bascule en mémoire (avertissement).
function DataStoreAdapter.open(name: string, forceMemoryInStudio: boolean): Store
	if RunService:IsStudio() then
		if forceMemoryInStudio then
			warn("[DataStore] ForceMemoryStoreInStudio actif : données en mémoire, rien n'est persisté.")
			return DataStoreAdapter.memory(name)
		end
		local ok, err = pcall(function()
			DataStoreService:GetDataStore(name):GetAsync("__studio_access_probe")
		end)
		if not ok then
			warn(
				string.format(
					"[DataStore] Accès API indisponible en Studio (%s). Données en MÉMOIRE : rien ne sera sauvegardé. "
						.. "Activez Game Settings > Security > Enable Studio Access to API Services pour tester la persistance.",
					tostring(err)
				)
			)
			return DataStoreAdapter.memory(name)
		end
	end
	return robloxStore(name)
end

return DataStoreAdapter
