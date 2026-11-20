--!strict
-- Formatage d'affichage. Les montants sont TRONQUÉS (jamais arrondis vers le haut).

local BigNum = require(script.Parent.BigNum)

type BigNum = BigNum.BigNum

local SUFFIXES = {
	"K",
	"M",
	"B",
	"T",
	"Qa",
	"Qi",
	"Sx",
	"Sp",
	"Oc",
	"No",
	"Dc",
	"UDc",
	"DDc",
	"TDc",
	"QaDc",
	"QiDc",
	"SxDc",
	"SpDc",
	"OcDc",
	"NoDc",
	"Vg",
}

local Format = {}

-- 999 -> "999", 1000 -> "1.00K", 12345 -> "12.3K", 1e66 -> "1.00e66"
function Format.bigNum(value: BigNum): string
	local m, e = value.m, value.e
	if m == 0 then
		return "0"
	end
	local prefix = if m < 0 then "-" else ""
	local digits = string.format("%d", math.abs(m))
	if e == 0 and #digits <= 3 then
		return prefix .. digits
	end
	local exponent = #digits - 1 + e
	local group = exponent // 3
	local lead = exponent - group * 3 + 1
	local significant = string.sub(digits, 1, 3)
	local suffix = SUFFIXES[group]
	if suffix then
		local text = string.sub(significant, 1, lead)
		if lead < 3 then
			text ..= "." .. string.sub(significant, lead + 1, 3)
		end
		return prefix .. text .. suffix
	end
	return prefix .. string.sub(significant, 1, 1) .. "." .. string.sub(significant, 2, 3) .. "e" .. exponent
end

function Format.number(value: number): string
	return Format.bigNum(BigNum.fromNumber(value))
end

-- 6 -> "6 s", 90 -> "1 min 30 s", 3720 -> "1 h 02 min"
function Format.duration(seconds: number): string
	local total = math.max(0, math.floor(seconds + 0.5))
	if total < 60 then
		return string.format("%d s", total)
	end
	if total < 3600 then
		local minutes = total // 60
		local rest = total % 60
		if rest == 0 then
			return string.format("%d min", minutes)
		end
		return string.format("%d min %02d s", minutes, rest)
	end
	local hours = total // 3600
	local minutes = (total % 3600) // 60
	if minutes == 0 then
		return string.format("%d h", hours)
	end
	return string.format("%d h %02d min", hours, minutes)
end

return Format
