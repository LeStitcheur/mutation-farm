--!strict
-- Projection de PlayerData vers l'état répliqué au client (aucune donnée sensible).

local Types = require(script.Parent.Parent.Types)
local Economy = require(script.Parent.Economy)
local Inventory = require(script.Parent.Inventory)

local ClientView = {}

function ClientView.build(data: Types.PlayerData): Types.ClientState
	return {
		coins = data.currencies.coins,
		essence = data.currencies.essence,
		primalCores = data.currencies.primalCores,
		bagItems = data.bag.items,
		bagCount = Inventory.count(data.bag.items),
		bagCapacity = Economy.bagCapacity(data),
		seedsUnlocked = data.seeds.unlocked,
		selectedSeed = data.seeds.selected,
		rebirths = data.progression.rebirths,
		prestiges = data.progression.prestiges,
		revision = data.progression.revision,
		cycleCoins = data.progression.cycleCoins,
		prestigeCoins = data.progression.prestigeCoins,
		upgrades = { rebirth = data.upgrades.rebirth, permanent = data.upgrades.permanent },
		mutadex = data.mutadex,
		mutadexRewards = data.mutadexRewards,
		pets = {
			instances = data.pets.instances,
			equipped = data.pets.equipped,
			hatched = data.pets.hatched,
			freeEggs = data.pets.freeEggs,
		},
		quests = { daily = data.quests.daily, weekly = data.quests.weekly },
		boosts = data.boosts,
		harvests = data.stats.harvests,
		perfectHarvests = data.stats.perfectHarvests,
	}
end

return ClientView
