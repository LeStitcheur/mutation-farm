--!strict
-- EventService — événements du monde (Phase 4, jalon C), côté serveur uniquement. Le calendrier est une fonction
-- pure de l'horloge serveur (Util/WorldEvents) : tous les serveurs ont le même, sans communiquer. Ce service
-- publie l'événement actif dans ReplicatedStorage.WorldEvent (attributs EventId, StartsAt, EndsAt : répliqués à
-- tous les joueurs, y compris ceux qui arrivent en cours d'événement), annonce le début et la fin, et fournit les
-- bonus LUS À L'INSTANT de l'action (aucun état de bonus stocké, rien ne survit à la fin de la fenêtre) :
--   LuckFactor() — Pluie mutagène : facteur de chance au moment de la plantation (FarmService), plafonné ensuite
--                  par Bonuses.luck (UpgradeConfig.Caps.MaxTotalLuck) ;
--   ValueBonus() — Floraison dorée : part de la valeur versée au moment de la récolte (HarvestService).
-- Le client n'envoie rien : il affiche l'état publié (EventController). Force / ClearForced : outillage Studio.
-- API : Current, LuckFactor, ValueBonus, Force, ClearForced.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local WorldEvents = require(ReplicatedStorage.Shared.Util.WorldEvents)
local MutationOdds = require(script.Parent.Parent.Config.MutationOdds)
local Notifier = require(script.Parent.Parent.Infra.Notifier)

local FOLDER_NAME = "WorldEvent"
local CHECK_INTERVAL = 1

local forced: WorldEvents.Window? = nil
local published: WorldEvents.Window? = nil
local state: Folder? = nil

local EventService = {}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

function EventService.Current(): WorldEvents.Window?
	return WorldEvents.activeAt(serverNow(), forced)
end

function EventService.LuckFactor(): number
	return WorldEvents.luckFactor(EventService.Current(), MutationOdds.Luck.MutagenicRain)
end

function EventService.ValueBonus(): number
	return WorldEvents.valueBonus(EventService.Current())
end

local function same(a: WorldEvents.Window?, b: WorldEvents.Window?): boolean
	if a == nil or b == nil then
		return a == b
	end
	return a.id == b.id and a.startsAt == b.startsAt and a.endsAt == b.endsAt
end

local function broadcast(kind: "info" | "success", text: string)
	for _, player in Players:GetPlayers() do
		Notifier.send(player, kind, text)
	end
end

local function publish(active: WorldEvents.Window?)
	local folder = state
	if not folder then
		return
	end
	folder:SetAttribute("EventId", if active then active.id else "")
	folder:SetAttribute("StartsAt", if active then active.startsAt else 0)
	folder:SetAttribute("EndsAt", if active then active.endsAt else 0)
end

local function refresh()
	local active = EventService.Current()
	if same(active, published) then
		return
	end
	local previous = published
	published = active
	publish(active)
	local ended = if previous then EventConfig.ById[previous.id] else nil
	if ended then
		broadcast("info", ended.announceEnd)
	end
	local started = if active then EventConfig.ById[active.id] else nil
	if started and active then
		broadcast("success", started.announceStart)
		print(string.format("[EventService] %s jusqu'à %d", started.id, active.endsAt))
	end
end

-- Outillage Studio (DevService) : force un événement maintenant (il remplace l'événement planifié en cours).
function EventService.Force(eventId: string, duration: number?): boolean
	local window = WorldEvents.force(eventId, serverNow(), duration)
	if not window then
		return false
	end
	forced = window
	refresh()
	return true
end

-- Outillage Studio : arrête l'événement forcé (sa fenêtre est close maintenant ; l'écart minimal reste respecté).
function EventService.ClearForced()
	local current = forced
	if current then
		forced = { id = current.id, startsAt = current.startsAt, endsAt = serverNow(), forced = true }
		refresh()
	end
end

function EventService.Init()
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	local folder = if existing and existing:IsA("Folder") then existing else Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = ReplicatedStorage
	state = folder
	publish(nil)
end

function EventService.Start()
	task.spawn(function()
		while true do
			-- Une erreur ponctuelle ne doit jamais arrêter la publication des événements pour tout le serveur.
			xpcall(refresh, function(err: any)
				warn("[EventService] Rafraîchissement en échec : " .. tostring(err))
			end)
			task.wait(CHECK_INTERVAL)
		end
	end)
end

return EventService
