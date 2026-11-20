--!strict
-- EconomyService — Coins et vente du sac. Point de passage unique pour créditer/débiter des Coins.
-- API : AddCoins, TrySpendCoins, SellAll.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Types = require(Shared.Types)
local BigNum = require(Shared.Util.BigNum)
local Economy = require(Shared.Util.Economy)
local Format = require(Shared.Util.Format)
local Inventory = require(Shared.Util.Inventory)
local DataService = require(script.Parent.DataService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)

type BigNum = Types.BigNum

local lastSell: { [Player]: number } = {}

local EconomyService = {}

-- Crédite des Coins (montant ≥ 0). Comptabilisé dans stats.coinsEarned.
function EconomyService.AddCoins(player: Player, amount: BigNum): boolean
	if BigNum.isNegative(amount) or not BigNum.isValid(amount) then
		return false
	end
	return DataService.Update(player, function(data)
		data.currencies.coins = BigNum.add(data.currencies.coins, amount)
		data.stats.coinsEarned = BigNum.add(data.stats.coinsEarned, amount)
	end)
end

-- Débite des Coins uniquement si le solde suffit (vérification et débit atomiques). Jamais de solde négatif.
function EconomyService.TrySpendCoins(player: Player, amount: BigNum): boolean
	if BigNum.isNegative(amount) or not BigNum.isValid(amount) then
		return false
	end
	local spent = false
	DataService.Update(player, function(data)
		if BigNum.gte(data.currencies.coins, amount) then
			data.currencies.coins = BigNum.sub(data.currencies.coins, amount)
			spent = true
		end
	end)
	return spent
end

-- Vend tout le contenu du sac. Retourne le montant crédité (nil si rien n'a été vendu).
function EconomyService.SellAll(player: Player): BigNum?
	local now = os.clock()
	local previous = lastSell[player]
	if previous and now - previous < GameConfig.Sell.Cooldown then
		return nil
	end
	lastSell[player] = now

	local data = DataService.GetData(player)
	if not data then
		return nil
	end
	local count = Inventory.count(data.bag.items)
	if count == 0 then
		Notifier.sendThrottled(player, "bag_empty", 2, "info", "Ton sac est vide : récolte des plantes mûres !")
		return nil
	end
	local total = Economy.sellValue(data.bag.items)
	DataService.Update(player, function(d)
		d.currencies.coins = BigNum.add(d.currencies.coins, total)
		d.stats.coinsEarned = BigNum.add(d.stats.coinsEarned, total)
		d.stats.sells += 1
		d.bag.items = {}
	end)
	Notifier.send(player, "success", string.format("%d récolte(s) vendue(s) : +%s Coins", count, Format.bigNum(total)))
	return total
end

function EconomyService.Init()
	Players.PlayerRemoving:Connect(function(player: Player)
		lastSell[player] = nil
	end)
end

function EconomyService.Start() end

return EconomyService
