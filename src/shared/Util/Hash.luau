--!strict
-- Hachage 32 bits PUR et stable (Phase 4, jalon D) : mêmes résultats sur tous les serveurs, en Lune et en jeu.
-- Sert aux tirages déterministes des missions d'un joueur pour une période (Util/Quests).

local TWO_32 = 4294967296

local Hash = {}

-- Produit modulo 2^32 sans dépasser la précision des nombres flottants (moitiés de 16 bits).
local function mul32(a: number, b: number): number
	local aHi, aLo = bit32.rshift(a, 16), bit32.band(a, 0xFFFF)
	local bHi, bLo = bit32.rshift(b, 16), bit32.band(b, 0xFFFF)
	local high = (aHi * bLo + aLo * bHi) % 0x10000
	return (high * 0x10000 + aLo * bLo) % TWO_32
end

-- Mélange d'un entier (pris modulo 2^32) en un entier 32 bits.
function Hash.int(value: number): number
	local x = math.floor(value) % TWO_32
	x = bit32.bxor(x, bit32.rshift(x, 16))
	x = mul32(x, 0x7FEB352D)
	x = bit32.bxor(x, bit32.rshift(x, 15))
	x = mul32(x, 0x846CA68B)
	x = bit32.bxor(x, bit32.rshift(x, 16))
	return x
end

-- Combine plusieurs entiers en un hachage (ordre significatif).
function Hash.combine(values: { number }): number
	local h = 0x9E3779B9
	for _, value in values do
		h = Hash.int(bit32.bxor(h, Hash.int(value)) + 0x6A09E667)
	end
	return h
end

-- Aléa stable ∈ [0, 1[ dérivé des entiers donnés.
function Hash.unit(values: { number }): number
	return Hash.combine(values) / TWO_32
end

return table.freeze(Hash)
