--!strict
-- Grands nombres sans dépassement : valeur = m × 10^e, m entier, e entier ≥ 0.
-- Forme normalisée :
--   e == 0 : |m| < 1e15 (arithmétique entière EXACTE, sous 2^53)
--   e  > 0 : 1e14 ≤ |m| < 1e15 (15 chiffres significatifs)
-- Les valeurs sont immuables : chaque opération retourne une nouvelle table { m, e } directement sérialisable.
-- Les résultats fractionnaires sont tronqués vers zéro (monnaies entières).

local Types = require(script.Parent.Parent.Types)

export type BigNum = Types.BigNum

local LIMIT = 1e15
local LOWER = 1e14

local BigNum = {}

local function isFinite(x: number): boolean
	return x == x and x ~= math.huge and x ~= -math.huge
end

local function make(m: number, e: number): BigNum
	return { m = m, e = e }
end

-- Tronque en absorbant le bruit flottant (ex. 53.99999999999999 -> 54) sans altérer les entiers exacts.
local function snapFloor(a: number): number
	local nearest = math.floor(a + 0.5)
	if math.abs(a - nearest) <= math.min(a * 1e-12, 1e-6) then
		return nearest
	end
	return math.floor(a)
end

local function normalize(m: number, e: number): BigNum
	if not isFinite(m) then
		error("BigNum : valeur non finie", 3)
	end
	if m == 0 then
		return make(0, 0)
	end
	local sign = if m < 0 then -1 else 1
	local a = math.abs(m)
	if a >= LIMIT then
		-- Décomposition décimale exacte du double (17 chiffres), tronquée à 15 chiffres significatifs.
		local lead, fraction, exponentText = string.match(string.format("%.16e", a), "^(%d)%.(%d+)e([%+%-]%d+)$")
		assert(lead and fraction and exponentText, "BigNum : format flottant inattendu")
		a = tonumber(lead .. string.sub(fraction, 1, 14)) :: number
		e += (tonumber(exponentText) :: number) - 14
	elseif e > 0 and a < LOWER then
		local shift = math.min(e, 14 - math.floor(math.log10(a)))
		if shift > 0 then
			a *= 10 ^ shift
			e -= shift
		end
		while a >= LIMIT do
			a /= 10
			e += 1
		end
	end
	a = snapFloor(a)
	while e > 0 and a > 0 and a < LOWER do
		a *= 10
		e -= 1
	end
	if a >= LIMIT then
		a = math.floor(a / 10)
		e += 1
	end
	if a == 0 then
		return make(0, 0)
	end
	return make(sign * a, e)
end

function BigNum.zero(): BigNum
	return make(0, 0)
end

function BigNum.fromNumber(n: number): BigNum
	return normalize(n, 0)
end

function BigNum.new(m: number, e: number): BigNum
	assert(isFinite(e) and e >= 0 and e % 1 == 0, "BigNum.new : exposant invalide")
	return normalize(m, e)
end

function BigNum.clone(a: BigNum): BigNum
	return make(a.m, a.e)
end

-- Vérifie qu'une valeur (ex. issue du DataStore) est un BigNum normalisé.
function BigNum.isValid(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local m, e = value.m, value.e
	if type(m) ~= "number" or type(e) ~= "number" then
		return false
	end
	if not isFinite(m) or not isFinite(e) or m % 1 ~= 0 or e % 1 ~= 0 or e < 0 then
		return false
	end
	local a = math.abs(m)
	if e == 0 then
		return a < LIMIT
	end
	return a >= LOWER and a < LIMIT
end

-- Retourne une copie valide ou zéro.
function BigNum.sanitize(value: any): BigNum
	if BigNum.isValid(value) then
		return make(value.m, value.e)
	end
	return make(0, 0)
end

function BigNum.isZero(a: BigNum): boolean
	return a.m == 0
end

function BigNum.isNegative(a: BigNum): boolean
	return a.m < 0
end

function BigNum.negate(a: BigNum): BigNum
	if a.m == 0 then
		return make(0, 0)
	end
	return make(-a.m, a.e)
end

function BigNum.add(a: BigNum, b: BigNum): BigNum
	if a.m == 0 then
		return make(b.m, b.e)
	end
	if b.m == 0 then
		return make(a.m, a.e)
	end
	local hi, lo = a, b
	if b.e > a.e then
		hi, lo = b, a
	end
	local diff = hi.e - lo.e
	if diff > 16 then
		return make(hi.m, hi.e)
	end
	return normalize(hi.m + lo.m / 10 ^ diff, hi.e)
end

function BigNum.sub(a: BigNum, b: BigNum): BigNum
	return BigNum.add(a, BigNum.negate(b))
end

function BigNum.mul(a: BigNum, b: BigNum): BigNum
	if a.m == 0 or b.m == 0 then
		return make(0, 0)
	end
	return normalize(a.m * b.m, a.e + b.e)
end

function BigNum.mulNumber(a: BigNum, k: number): BigNum
	assert(isFinite(k), "BigNum.mulNumber : facteur non fini")
	if a.m == 0 or k == 0 then
		return make(0, 0)
	end
	local product = a.m * k
	if isFinite(product) then
		return normalize(product, a.e)
	end
	return BigNum.mul(a, BigNum.fromNumber(k))
end

-- -1 si a < b, 0 si égal, 1 si a > b.
function BigNum.compare(a: BigNum, b: BigNum): number
	local sa = if a.m > 0 then 1 elseif a.m < 0 then -1 else 0
	local sb = if b.m > 0 then 1 elseif b.m < 0 then -1 else 0
	if sa ~= sb then
		return if sa < sb then -1 else 1
	end
	if sa == 0 then
		return 0
	end
	local magnitude: number
	if a.e ~= b.e then
		magnitude = if a.e < b.e then -1 else 1
	else
		local ma, mb = math.abs(a.m), math.abs(b.m)
		if ma == mb then
			return 0
		end
		magnitude = if ma < mb then -1 else 1
	end
	return magnitude * sa
end

function BigNum.eq(a: BigNum, b: BigNum): boolean
	return BigNum.compare(a, b) == 0
end

function BigNum.lt(a: BigNum, b: BigNum): boolean
	return BigNum.compare(a, b) < 0
end

function BigNum.lte(a: BigNum, b: BigNum): boolean
	return BigNum.compare(a, b) <= 0
end

function BigNum.gt(a: BigNum, b: BigNum): boolean
	return BigNum.compare(a, b) > 0
end

function BigNum.gte(a: BigNum, b: BigNum): boolean
	return BigNum.compare(a, b) >= 0
end

function BigNum.max(a: BigNum, b: BigNum): BigNum
	return if BigNum.compare(a, b) >= 0 then make(a.m, a.e) else make(b.m, b.e)
end

function BigNum.min(a: BigNum, b: BigNum): BigNum
	return if BigNum.compare(a, b) <= 0 then make(a.m, a.e) else make(b.m, b.e)
end

-- log10 de la valeur (-inf pour zéro ou négatif).
function BigNum.log10(a: BigNum): number
	if a.m <= 0 then
		return -math.huge
	end
	return math.log10(a.m) + a.e
end

-- Construit 10^L (L fini).
function BigNum.fromLog10(L: number): BigNum
	if L == -math.huge then
		return make(0, 0)
	end
	assert(isFinite(L), "BigNum.fromLog10 : exposant non fini")
	if L < 15 then
		return normalize(10 ^ L, 0)
	end
	local e = math.floor(L) - 14
	return normalize(10 ^ (L - e), e)
end

-- factor × base^exponent, exact tant que le résultat reste < 1e15.
function BigNum.fromExponential(factor: number, base: number, exponent: number): BigNum
	assert(factor > 0 and base > 0, "BigNum.fromExponential : facteur et base doivent être > 0")
	local L = math.log10(factor) + exponent * math.log10(base)
	if L < 15 then
		return normalize(factor * base ^ exponent, 0)
	end
	return BigNum.fromLog10(L)
end

-- Conversion en number (peut valoir math.huge). Réservé à l'affichage et aux ratios.
function BigNum.toNumber(a: BigNum): number
	return a.m * 10 ^ a.e
end

-- a / b en number, borné à [0, math.huge]. Utile pour les barres de progression.
function BigNum.ratio(a: BigNum, b: BigNum): number
	if b.m <= 0 then
		return math.huge
	end
	if a.m <= 0 then
		return 0
	end
	return 10 ^ (BigNum.log10(a) - BigNum.log10(b))
end

return BigNum
