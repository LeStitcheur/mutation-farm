--!strict
-- AutomationService — panneau Automatisation (Phase 5, jalon C ; docs/AUTOMATION.md) : achat du comptoir de vente
-- automatique et réglages (drones actifs, vente automatique, seuil). Le client n'envoie qu'une ACTION et une valeur
-- (`AutomationRequest(action, value)`), jamais de prix ni de montant : le serveur valide (type, longueur, action
-- connue, valeur permise, débit, aucune transition de progression en cours) puis applique la règle pure Automation
-- dans UN mutateur. Après un achat ou un réglage, le sac est vendu si le seuil est déjà atteint ; la boucle de
-- DroneService lit le réglage des drones à chaque passage (aucune boucle supplémentaire).
-- API : BuySeller, SetSetting.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local AutomationConfig = require(Shared.Config.AutomationConfig)
local Automation = require(Shared.Util.Automation)
local Format = require(Shared.Util.Format)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local ProgressionService = require(script.Parent.ProgressionService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)
local RateLimiter = require(script.Parent.Parent.Infra.RateLimiter)

local limiter = RateLimiter.new(AutomationConfig.RequestsPerSecond, AutomationConfig.RequestsPerSecond)

local SETTING_ACTIONS: { [string]: boolean } = { drones = true, autosell = true, threshold = true }

local AutomationService = {}

-- Achat du comptoir automatique (Coins, machine perdue au rebirth).
function AutomationService.BuySeller(player: Player): (boolean, string?)
	if ProgressionService.IsBusy(player) then
		return false, "busy"
	end
	if not DataService.GetData(player) then
		return false, "not_loaded"
	end
	local ok: boolean, failure: Automation.BuyFailure? = false, nil
	DataService.Update(player, function(data)
		ok, failure = Automation.buySeller(data)
	end)
	if not ok then
		if failure == "insufficient_funds" then
			Notifier.send(
				player,
				"error",
				string.format(
					"Pas assez de Coins : le %s coûte %s Coins.",
					string.lower(AutomationConfig.AutoSeller.Name),
					Format.bigNum(Automation.sellerPrice())
				)
			)
		end
		return false, failure
	end
	Notifier.send(
		player,
		"success",
		string.format("%s installé : ton sac sera vendu automatiquement.", AutomationConfig.AutoSeller.Name)
	)
	EconomyService.AutoSell(player)
	return true, nil
end

-- Réglage « drones » / « autosell » (booléen) ou « threshold » (seuil proposé).
function AutomationService.SetSetting(player: Player, setting: string, value: any): (boolean, string?)
	if ProgressionService.IsBusy(player) then
		return false, "busy"
	end
	if not DataService.GetData(player) then
		return false, "not_loaded"
	end
	local ok: boolean, failure: Automation.SettingFailure? = false, nil
	DataService.Update(player, function(data)
		ok, failure = Automation.setSetting(data, setting, value)
	end)
	if ok then
		EconomyService.AutoSell(player) -- seuil abaissé ou vente réactivée : le sac est peut-être déjà au seuil
	end
	return ok, failure
end

function AutomationService.Init()
	Net.event(Net.Events.AutomationRequest).OnServerEvent
		:Connect(function(player: Player, action: unknown, value: unknown)
			if typeof(action) ~= "string" then
				return
			end
			local name = action :: string
			if #name == 0 or #name > AutomationConfig.ActionMaxLength then
				return
			end
			if name ~= "buy_seller" and not SETTING_ACTIONS[name] then
				return
			end
			-- Valeur : booléen pour les interrupteurs, nombre fini pour le seuil (validé ensuite contre la liste).
			local valueType = typeof(value)
			if name == "threshold" then
				if valueType ~= "number" then
					return
				end
				local threshold = value :: number
				if threshold ~= threshold then
					return
				end
			elseif name ~= "buy_seller" and valueType ~= "boolean" then
				return
			end
			if not limiter:allow(player) then
				return
			end
			if name == "buy_seller" then
				AutomationService.BuySeller(player)
			else
				AutomationService.SetSetting(player, name, value)
			end
		end)
end

function AutomationService.Start() end

return AutomationService
