--!nonstrict
-- Sous-ensemble compatible TestEZ (describe / it / expect / beforeEach / afterEach) pour exécuter
-- les specs hors Studio avec Lune. Les mêmes fichiers *.spec.luau tournent avec le vrai TestEZ en Studio.

local TestEZLite = {}

local function describeValue(value)
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) == "table" then
		if value.m ~= nil and value.e ~= nil then
			return string.format("BigNum{m=%s, e=%s}", tostring(value.m), tostring(value.e))
		end
		return tostring(value)
	end
	return tostring(value)
end

function TestEZLite.expect(value)
	local function build(negated)
		local api = {}
		local function check(pass, message)
			if negated then
				pass = not pass
			end
			if not pass then
				error((if negated then "Attendu (négation) : " else "Attendu : ") .. message, 4)
			end
		end
		api.equal = function(expected)
			check(value == expected, describeValue(value) .. " == " .. describeValue(expected))
		end
		api.near = function(expected, limit)
			limit = limit or 1e-7
			check(
				type(value) == "number" and math.abs(value - expected) <= limit,
				describeValue(value) .. " ≈ " .. describeValue(expected) .. " (±" .. tostring(limit) .. ")"
			)
		end
		api.ok = function()
			check(value ~= nil and value ~= false, describeValue(value) .. " est truthy")
		end
		api.a = function(typeName)
			check(typeof(value) == typeName, describeValue(value) .. " est de type " .. typeName)
		end
		api.an = api.a
		api.throw = function(substring)
			local ok, err = pcall(value)
			local pass = not ok and (substring == nil or string.find(tostring(err), substring, 1, true) ~= nil)
			check(pass, "la fonction lève une erreur" .. (if substring then " contenant " .. substring else ""))
		end
		return api
	end
	local positive = build(false)
	local negative = build(true)
	for _, word in { "to", "be", "been", "have", "was", "at" } do
		positive[word] = positive
		negative[word] = negative
	end
	positive.never = negative
	negative.never = positive
	return positive
end

-- Construit l'environnement d'une spec et l'arbre de tests qu'elle déclare.
function TestEZLite.newSuite(name)
	local root = { name = name, kind = "describe", children = {}, before = {}, after = {}, parent = nil }
	local current = root
	local env = {}
	env.describe = function(label, fn)
		local node = { name = label, kind = "describe", children = {}, before = {}, after = {}, parent = current }
		table.insert(current.children, node)
		local previous = current
		current = node
		fn()
		current = previous
	end
	env.it = function(label, fn)
		table.insert(current.children, { name = label, kind = "it", fn = fn, parent = current })
	end
	env.beforeEach = function(fn)
		table.insert(current.before, fn)
	end
	env.afterEach = function(fn)
		table.insert(current.after, fn)
	end
	env.expect = TestEZLite.expect
	env.FOCUS = function() end
	env.SKIP = function() end
	return env, root
end

local function chain(node, field)
	local list = {}
	local cursor = node
	while cursor do
		table.insert(list, 1, cursor)
		cursor = cursor.parent
	end
	local result = {}
	for _, ancestor in list do
		for _, fn in ancestor[field] or {} do
			table.insert(result, fn)
		end
	end
	return result
end

-- Exécute l'arbre ; retourne (réussis, échecs, liste des échecs).
function TestEZLite.run(root)
	local passed, failed = 0, 0
	local failures = {}
	local function visit(node, path)
		for _, child in node.children do
			local childPath = if path == "" then child.name else path .. " › " .. child.name
			if child.kind == "describe" then
				visit(child, childPath)
			else
				local ok, err = pcall(function()
					for _, fn in chain(node, "before") do
						fn()
					end
					child.fn()
					for _, fn in chain(node, "after") do
						fn()
					end
				end)
				if ok then
					passed += 1
				else
					failed += 1
					table.insert(failures, { path = childPath, message = tostring(err) })
				end
			end
		end
	end
	visit(root, "")
	return passed, failed, failures
end

return TestEZLite
