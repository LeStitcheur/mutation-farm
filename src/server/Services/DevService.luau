--!strict
-- DevService — outillage de TEST réservé à Roblox Studio (RunService:IsStudio()). Jamais créé sur un serveur Roblox.
-- Expose ServerStorage.MutationFarmDev (BindableFunction : invisible et inaccessible aux clients) pour les tests via
-- Studio MCP, qui s'exécutent dans une autre VM et ne peuvent pas lire l'état des services :
--   Invoke("grantEarned", userId, amount) : crédite des Coins GAGNÉS (comptent pour le cycle) via EconomyService.AddCoins
--   Invoke("snapshot", userId)            : copie JSON de la donnée serveur du joueur (inspection)
--   Invoke("setTileMutation", userId, tileId, mutationId) : fixe la mutation d'une culture existante (tests du
--                                           Mutadex par le vrai chemin de récolte)
--   Invoke("grantEggs", userId, eggId, amount) : ajoute des œufs gratuits (tests des familiers, comme une
--                                           récompense de mission)
--   Invoke("startEvent", userId, eventId, duration?) : force un événement du monde maintenant (tests du jalon C)
--   Invoke("stopEvent", userId)           : arrête l'événement forcé
--   Invoke("questRecord", userId, objective, amount) : fait progresser un objectif de mission (tests du jalon D)
-- API : aucune.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local MutationConfig = require(ReplicatedStorage.Shared.Config.MutationConfig)
local BigNum = require(ReplicatedStorage.Shared.Util.BigNum)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local EventService = require(script.Parent.EventService)
local PetService = require(script.Parent.PetService)
local QuestService = require(script.Parent.QuestService)

local MAX_GRANT = 1e15

local DevService = {}

local function invoke(command: unknown, userId: unknown, amount: unknown, extra: unknown): any
	if type(command) ~= "string" or type(userId) ~= "number" then
		return nil
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return nil
	end
	if command == "grantEarned" then
		if type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount > MAX_GRANT then
			return false
		end
		return EconomyService.AddCoins(player, BigNum.fromNumber(math.floor(amount)))
	elseif command == "snapshot" then
		local data = DataService.GetData(player)
		return if data then HttpService:JSONEncode(data) else nil
	elseif command == "setTileMutation" then
		if type(amount) ~= "string" or type(extra) ~= "string" or not MutationConfig.get(extra) then
			return false
		end
		local tileId, mutationId = amount, extra
		local applied = false
		DataService.Update(player, function(data)
			local tile = data.farm.tiles[tileId]
			if tile then
				tile.mutation = if mutationId == MutationConfig.NORMAL then nil else mutationId
				applied = true
			end
		end)
		return applied
	elseif command == "grantEggs" then
		if type(amount) ~= "string" or type(extra) ~= "number" or extra ~= extra or extra < 1 then
			return false
		end
		return PetService.GrantFreeEggs(player, amount, extra)
	elseif command == "startEvent" then
		if type(amount) ~= "string" then
			return false
		end
		local duration = if type(extra) == "number" and extra == extra then extra else nil
		return EventService.Force(amount, duration)
	elseif command == "stopEvent" then
		EventService.ClearForced()
		return true
	elseif command == "questRecord" then
		if type(amount) ~= "string" or type(extra) ~= "number" or extra ~= extra or extra < 1 then
			return false
		end
		return QuestService.Record(player, amount, math.floor(extra))
	end
	return nil
end

function DevService.Init()
	if not RunService:IsStudio() then
		return
	end
	local bridge = Instance.new("BindableFunction")
	bridge.Name = "MutationFarmDev"
	bridge.OnInvoke = invoke
	bridge.Parent = ServerStorage
	warn("[DevService] Outils de test Studio actifs (ServerStorage.MutationFarmDev) — jamais en jeu publié.")
end

function DevService.Start() end

return DevService
