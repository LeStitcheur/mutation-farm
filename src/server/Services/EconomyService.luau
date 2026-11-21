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
local ProgressionMath = require(Shared.Util.ProgressionMath)
local DataService = require(script.Parent.DataService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)

type BigNum = Types.BigNum

local lastSell: { [Player]: number } = {}

local EconomyService = {}

-- Crédite des Coins GAGNÉS en jeu (montant ≥ 0) : comptés dans l'historique et les cycles de rebirth/prestige.
-- (Les futurs crédits non gagnés — achats Robux, remboursements — ne devront pas passer par ici.)
function EconomyService.AddCoins(player: Player, amount: BigNum): boolean
	if BigNum.isNegative(amount) or not BigNum.isValid(amount) then
		return false
	end
	return DataService.Update(player, function(data)
		data.currencies.coins = BigNum.add(data.currencies.coins, amount)
		ProgressionMath.recordEarnings(data, amount)
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
	-- Total calculé DANS le mutateur (sac et multiplicateur lus dans le même état atomique, même face à un rebirth).
	local total = BigNum.zero()
	DataService.Update(player, function(d)
		total = Economy.sellValue(d.bag.items, ProgressionMath.incomeMultiplier(d))
		d.currencies.coins = BigNum.add(d.currencies.coins, total)
		ProgressionMath.recordEarnings(d, total)
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
