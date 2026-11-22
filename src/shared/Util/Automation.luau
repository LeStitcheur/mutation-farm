--!strict
-- Règles PURES de l'automatisation avancée (Phase 5, jalon C ; testées en Lune ; docs/AUTOMATION.md) :
--   • comptoir de vente automatique : achat (Coins, machine perdue au rebirth), seuil de vente, vente du sac par la
--     même règle que le marché (Selling.sellBag) ;
--   • réglages du joueur (drones actifs, vente automatique, seuil), validés ici ;
--   • débits de production (statistiques affichées : récoltes/min des drones et de la ferme).
-- Le serveur exécute chaque opération dans UN mutateur de DataService.Update.

local Types = require(script.Parent.Parent.Types)
local AutomationConfig = require(script.Parent.Parent.Config.AutomationConfig)
local DroneConfig = require(script.Parent.Parent.Config.DroneConfig)
local BigNum = require(script.Parent.BigNum)
local DroneLogic = require(script.Parent.DroneLogic)
local Economy = require(script.Parent.Economy)
local Expansions = require(script.Parent.Expansions)
local Inventory = require(script.Parent.Inventory)
local Selling = require(script.Parent.Selling)

type PlayerData = Types.PlayerData
type BigNum = Types.BigNum

export type BuyFailure = "owned" | "insufficient_funds"
export type Setting = "drones" | "autosell" | "threshold"
export type SettingFailure = "unknown_setting" | "invalid_value"

export type Rates = {
	tiles: number, -- cases cultivables
	dronesPerMinute: number, -- récoltes/min que les drones actifs peuvent assurer
	farmPerMinute: number, -- récoltes/min que les cases produisent (graine actuelle, délai de grâce compris)
}

local SETTINGS: { [string]: Setting } = { drones = "drones", autosell = "autosell", threshold = "threshold" }

local Automation = {}

function Automation.sellerPrice(): BigNum
	return BigNum.fromNumber(AutomationConfig.AutoSeller.Price)
end

function Automation.hasSeller(data: PlayerData): boolean
	return data.machines.autoSeller == true
end

function Automation.canBuySeller(data: PlayerData): (boolean, BuyFailure?)
	if Automation.hasSeller(data) then
		return false, "owned"
	end
	if BigNum.lt(data.currencies.coins, Automation.sellerPrice()) then
		return false, "insufficient_funds"
	end
	return true, nil
end

-- Achat du comptoir : débit (jamais de solde négatif) et installation indissociables ; la vente automatique est
-- activée dans la foulée (le joueur peut la couper ensuite). Un achat rejoué trouve le comptoir déjà installé.
function Automation.buySeller(data: PlayerData): (boolean, BuyFailure?)
	local allowed: boolean, failure: BuyFailure? = Automation.canBuySeller(data)
	if not allowed then
		return false, failure
	end
	if not Economy.trySpend(data, Automation.sellerPrice()) then
		return false, "insufficient_funds"
	end
	data.machines.autoSeller = true
	data.automation.autoSellEnabled = true
	return true, nil
end

function Automation.dronesEnabled(data: PlayerData): boolean
	return data.automation.dronesEnabled ~= false
end

-- Vente automatique effective : comptoir installé ET réglage activé.
function Automation.autoSellActive(data: PlayerData): boolean
	return Automation.hasSeller(data) and data.automation.autoSellEnabled == true
end

function Automation.isValidThreshold(value: any): boolean
	return type(value) == "number" and table.find(AutomationConfig.Thresholds, value) ~= nil
end

-- Seuil en pourcentage de la capacité du sac (défaut si la valeur stockée est invalide).
function Automation.threshold(data: PlayerData): number
	local value = data.automation.autoSellThreshold
	return if Automation.isValidThreshold(value) then value else AutomationConfig.DefaultThreshold
end

-- Nombre d'objets qui déclenche la vente (au moins 1, jamais au-delà de la capacité).
function Automation.thresholdCount(data: PlayerData): number
	local capacity = Economy.bagCapacity(data)
	return math.clamp(math.ceil(capacity * Automation.threshold(data) / 100 - 1e-9), 1, math.max(1, capacity))
end

function Automation.shouldAutoSell(data: PlayerData): boolean
	return Automation.autoSellActive(data) and Inventory.count(data.bag.items) >= Automation.thresholdCount(data)
end

-- Vente automatique si le seuil est atteint (sinon nil, rien n'est modifié). Même règle que le marché.
function Automation.autoSell(data: PlayerData, now: number): Selling.SaleOutcome?
	if not Automation.shouldAutoSell(data) then
		return nil
	end
	return Selling.sellBag(data, now, "auto")
end

-- Modifie un réglage (« drones » / « autosell » : booléen ; « threshold » : un des seuils proposés).
function Automation.setSetting(data: PlayerData, setting: string, value: any): (boolean, SettingFailure?)
	local known = SETTINGS[setting]
	if not known then
		return false, "unknown_setting"
	end
	if known == "threshold" then
		if not Automation.isValidThreshold(value) then
			return false, "invalid_value"
		end
		data.automation.autoSellThreshold = value
		return true, nil
	end
	if type(value) ~= "boolean" then
		return false, "invalid_value"
	end
	if known == "drones" then
		data.automation.dronesEnabled = value
	else
		data.automation.autoSellEnabled = value
	end
	return true, nil
end

-- Débits (statistiques du panneau Automatisation) : capacité des drones actifs et production des cases avec la
-- graine actuelle (pousse effective + délai de grâce des drones). Le plus petit des deux limite la production
-- automatique.
function Automation.rates(data: PlayerData): Rates
	local tiles = Expansions.tileCount(data)
	local dronesPerMinute = 0
	local grace = 0
	local fleet = DroneLogic.fleet(data)
	for _, def in fleet do
		grace = math.max(grace, def.graceDelay)
		if Automation.dronesEnabled(data) then
			dronesPerMinute += def.capacity * 60 / DroneLogic.interval(def, data)
		end
	end
	if #fleet == 0 then
		local harvester = DroneConfig.get("harvester")
		grace = if harvester then harvester.graceDelay else 0
	end
	local cycle = Economy.growTime(data, data.seeds.selected) + grace
	return {
		tiles = tiles,
		dronesPerMinute = dronesPerMinute,
		farmPerMinute = if cycle > 0 then tiles * 60 / cycle else 0,
	}
end

return table.freeze(Automation)
