--!strict
-- SlotAllocator — attribution des emplacements de parcelles (1..capacité) : un propriétaire par emplacement,
-- un emplacement par propriétaire, plus petit emplacement libre d'abord. Logique pure (testée en Lune).

export type SlotAllocator<T> = {
	capacity: number,
	owners: { [number]: T },
}

local SlotAllocator = {}

function SlotAllocator.new<T>(capacity: number): SlotAllocator<T>
	assert(capacity >= 1 and capacity % 1 == 0, "SlotAllocator : capacité invalide")
	return { capacity = capacity, owners = {} }
end

-- Emplacement actuellement détenu par `owner`, ou nil.
function SlotAllocator.slotOf<T>(allocator: SlotAllocator<T>, owner: T): number?
	for slot = 1, allocator.capacity do
		if allocator.owners[slot] == owner then
			return slot
		end
	end
	return nil
end

-- Attribue le plus petit emplacement libre (ou celui déjà détenu : jamais deux parcelles). nil si complet.
function SlotAllocator.claim<T>(allocator: SlotAllocator<T>, owner: T): number?
	local existing = SlotAllocator.slotOf(allocator, owner)
	if existing then
		return existing
	end
	for slot = 1, allocator.capacity do
		if allocator.owners[slot] == nil then
			allocator.owners[slot] = owner
			return slot
		end
	end
	return nil
end

-- Libère `slot` uniquement s'il appartient encore à `owner` : une libération tardive ne retire jamais
-- l'emplacement d'un autre joueur.
function SlotAllocator.release<T>(allocator: SlotAllocator<T>, slot: number, owner: T): boolean
	if allocator.owners[slot] ~= nil and allocator.owners[slot] == owner then
		allocator.owners[slot] = nil
		return true
	end
	return false
end

return table.freeze(SlotAllocator)
