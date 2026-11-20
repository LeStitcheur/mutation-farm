--!strict
-- Copie et gel profonds (fonctions pures, sans API Roblox).

local Deep = {}

function Deep.copy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value :: any do
		result[Deep.copy(key)] = Deep.copy(child)
	end
	return (result :: any) :: T
end

function Deep.freeze<T>(value: T): T
	if type(value) == "table" and not table.isfrozen(value :: any) then
		for _, child in value :: any do
			Deep.freeze(child)
		end
		table.freeze(value :: any)
	end
	return value
end

function Deep.equal(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not Deep.equal(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

return Deep
