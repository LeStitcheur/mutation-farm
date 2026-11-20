--!strict
-- Sac du joueur : table { [ItemKey] = quantité }. Fonctions pures (mutent la table passée).

local Inventory = {}

function Inventory.count(items: { [string]: number }): number
	local total = 0
	for _, quantity in items do
		total += quantity
	end
	return total
end

function Inventory.isFull(items: { [string]: number }, capacity: number): boolean
	return Inventory.count(items) >= capacity
end

-- Ajoute jusqu'à `amount` objets sans dépasser `capacity`. Retourne la quantité réellement ajoutée.
function Inventory.add(items: { [string]: number }, key: string, amount: number, capacity: number): number
	if amount <= 0 then
		return 0
	end
	local free = math.max(0, capacity - Inventory.count(items))
	local added = math.min(free, math.floor(amount))
	if added > 0 then
		items[key] = (items[key] or 0) + added
	end
	return added
end

function Inventory.clear(items: { [string]: number })
	table.clear(items)
end

return Inventory
