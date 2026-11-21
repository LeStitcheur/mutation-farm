--!strict
-- Bootstrap client : attend la réplication initiale, puis Init() et Start() des contrôleurs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not game:IsLoaded() then
	game.Loaded:Wait()
end
ReplicatedStorage:WaitForChild("Shared")

local Net = require(ReplicatedStorage.Shared.Net)
local Controllers = script.Controllers
local StateController = require(Controllers.StateController)
local HudController = require(Controllers.HudController)
local RebirthController = require(Controllers.RebirthController)
local PrestigeController = require(Controllers.PrestigeController)
local UpgradeController = require(Controllers.UpgradeController)
local MutadexController = require(Controllers.MutadexController)
local PlantRenderer = require(Controllers.PlantRenderer)
local HarvestController = require(Controllers.HarvestController)
local DroneRenderer = require(Controllers.DroneRenderer)

type Controller = {
	Init: () -> (),
	Start: () -> (),
}

local ordered: { Controller } = {
	StateController,
	HudController,
	RebirthController, -- après HudController : se greffe sur MutationFarmHUD.Menu
	PrestigeController,
	UpgradeController,
	MutadexController,
	PlantRenderer,
	HarvestController,
	DroneRenderer,
}

for _, controller in ordered do
	controller.Init()
end
for _, controller in ordered do
	controller.Start()
end

-- Tous les écouteurs sont connectés : demande au serveur l'état complet (rattrape un StateSync émis trop tôt).
Net.event(Net.Events.ClientReady):FireServer()
