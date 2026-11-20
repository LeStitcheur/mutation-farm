--!strict
-- Bootstrap serveur : crée les RemoteEvents, appelle Init() de chaque service (connexions),
-- puis Start() dans l'ordre. DataService démarre en DERNIER : il lance le chargement des joueurs
-- une fois tous les abonnés connectés.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local Services = script.Services
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local PlantService = require(Services.PlantService)
local MutationService = require(Services.MutationService)
local FarmService = require(Services.FarmService)
local HarvestService = require(Services.HarvestService)
local DroneService = require(Services.DroneService)
local SyncService = require(Services.SyncService)

type Service = {
	Init: () -> (),
	Start: () -> (),
}

-- Crée le dossier Remotes et tous les RemoteEvents avant toute connexion.
Net.event(Net.Events.StateSync)

local ordered: { { name: string, service: Service } } = {
	{ name = "EconomyService", service = EconomyService },
	{ name = "PlantService", service = PlantService },
	{ name = "MutationService", service = MutationService },
	{ name = "FarmService", service = FarmService },
	{ name = "HarvestService", service = HarvestService },
	{ name = "DroneService", service = DroneService },
	{ name = "SyncService", service = SyncService },
	{ name = "DataService", service = DataService },
}

for _, entry in ordered do
	entry.service.Init()
end
for _, entry in ordered do
	entry.service.Start()
end

print(string.format("[MutationFarm] Serveur prêt (%d services).", #ordered))
