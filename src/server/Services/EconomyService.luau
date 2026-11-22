--!strict
-- EconomyService — Coins et vente du sac. Point de passage unique pour créditer/débiter des Coins.
-- Vente au marché (SellAll) et vente automatique du comptoir (AutoSell, Phase 5) : même règle pure Selling.sellBag.
-- API : AddCoins, TrySpendCoins, SellAll, AutoSell.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local AutomationConfig = require(Shared.Config.AutomationConfig)
local GameConfig = require(Shared.Config.GameConfig)
local Types = require(Shared.Types)
local Automation = require(Shared.Util.Automation)
local BigNum = require(Shared.Util.BigNum)
local Economy = require(Shared.Util.Economy)
local Format = require(Shared.Util.Format)
local Inventory = require(Shared.Util.Inventory)
local ProgressionMath = require(Shared.Util.ProgressionMath)
local Selling = require(Shared.Util.Selling)
local DataService = require(script.Parent.DataService)
local Notifier = require(script.Parent.Parent.Infra.Notifier)
local QuestNotifier = require(script.Parent.Parent.Infra.QuestNotifier)

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
		spent = Economy.trySpend(data, amount)
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
	-- Total calculé DANS le mutateur (sac et multiplicateur lus dans le même état atomique, même face à un rebirth) ;
	-- même règle que le comptoir automatique (Selling.sellBag) : une vente concurrente trouve le sac vide.
	local sale: Selling.SaleOutcome? = nil
	DataService.Update(player, function(d)
		sale = Selling.sellBag(d, Workspace:GetServerTimeNow(), "manual")
	end)
	local result = sale
	if not result then
		return nil
	end
	Notifier.send(
		player,
		"success",
		string.format("%d récolte(s) vendue(s) : +%s Coins", result.count, Format.bigNum(result.total))
	)
	QuestNotifier.completed(player, result.questsCompleted)
	return result.total
end

-- Vente automatique (Phase 5, comptoir) : vend le sac si le comptoir est installé, activé et le seuil atteint.
-- Appelée après chaque récolte (joueur ou drone) et après un changement de réglage. Retourne le montant crédité.
function EconomyService.AutoSell(player: Player): BigNum?
	if not DataService.GetData(player) then
		return nil
	end
	local sale: Selling.SaleOutcome? = nil
	DataService.Update(player, function(d)
		sale = Automation.autoSell(d, Workspace:GetServerTimeNow())
	end)
	local result = sale
	if not result then
		return nil
	end
	Notifier.sendThrottled(
		player,
		"auto_sell",
		AutomationConfig.SaleNoticeInterval,
		"success",
		string.format("Vente automatique : %d récolte(s), +%s Coins", result.count, Format.bigNum(result.total))
	)
	return result.total
end

function EconomyService.Init()
	Players.PlayerRemoving:Connect(function(player: Player)
		lastSell[player] = nil
	end)
end

function EconomyService.Start() end

return EconomyService
