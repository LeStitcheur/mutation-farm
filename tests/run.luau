--!nonstrict
-- Runner de tests Lune : `lune run tests/run.luau` depuis la racine du dépôt.
-- Simule l'arbre Rojo (ReplicatedStorage.Shared, ServerScriptService.Server), `script`, `require(Instance)`
-- et `game:GetService`, puis exécute tests/specs/*.spec.luau avec TestEZLite.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local TestEZLite = require("./TestEZLite")

-- Arbre d'instances virtuelles --------------------------------------------------------------

local methods = {}
local nodeMeta = {}

local function newNode(name, className, parent, path)
	local node = setmetatable(
		{ __name = name, __class = className, __parent = parent, __path = path, __children = {} },
		nodeMeta
	)
	return node
end

nodeMeta.__index = function(self, key)
	if key == "Name" then
		return rawget(self, "__name")
	elseif key == "ClassName" then
		return rawget(self, "__class")
	elseif key == "Parent" then
		return rawget(self, "__parent")
	end
	local child = rawget(self, "__children")[key]
	if child then
		return child
	end
	local method = methods[key]
	if method then
		return method
	end
	error(string.format("%s n'est pas un membre valide de %s", tostring(key), rawget(self, "__name")), 2)
end
nodeMeta.__tostring = function(self)
	return rawget(self, "__name")
end

function methods.FindFirstChild(self, name)
	return rawget(self, "__children")[name]
end
function methods.WaitForChild(self, name)
	local child = rawget(self, "__children")[name]
	if not child then
		error("WaitForChild : enfant introuvable " .. tostring(name))
	end
	return child
end
function methods.GetChildren(self)
	local list = {}
	for _, child in rawget(self, "__children") do
		table.insert(list, child)
	end
	return list
end
function methods.IsA(self, className)
	return rawget(self, "__class") == className
end
function methods.GetFullName(self)
	local parts = {}
	local cursor = self
	while cursor do
		table.insert(parts, 1, rawget(cursor, "__name"))
		cursor = rawget(cursor, "__parent")
	end
	return table.concat(parts, ".")
end

local function stripSuffix(fileName)
	return (string.gsub(fileName, "%.luau?$", ""))
end

local function buildDir(dirPath, name, parent)
	local initPath = nil
	for _, candidate in { "init.luau", "init.lua" } do
		if fs.isFile(dirPath .. "/" .. candidate) then
			initPath = dirPath .. "/" .. candidate
		end
	end
	local isScript = fs.isFile(dirPath .. "/init.server.luau") or fs.isFile(dirPath .. "/init.client.luau")
	local className = if initPath then "ModuleScript" elseif isScript then "Script" else "Folder"
	local node = newNode(name, className, parent, initPath)
	local children = rawget(node, "__children")
	for _, entry in fs.readDir(dirPath) do
		local full = dirPath .. "/" .. entry
		if fs.isDir(full) then
			children[entry] = buildDir(full, entry, node)
		elseif string.match(entry, "%.luau?$") and not string.match(entry, "^init%.") then
			local base = stripSuffix(entry)
			if string.match(base, "%.server$") or string.match(base, "%.client$") then
				base = string.gsub(base, "%.%a+$", "")
				children[base] = newNode(base, "Script", node, nil)
			else
				children[base] = newNode(base, "ModuleScript", node, full)
			end
		end
	end
	return node
end

local services = {
	ReplicatedStorage = newNode("ReplicatedStorage", "ReplicatedStorage", nil, nil),
	ServerScriptService = newNode("ServerScriptService", "ServerScriptService", nil, nil),
	-- Outils de test hors jeu (jamais synchronisés par Rojo) : tests/sim -> TestService.Sim.
	TestService = newNode("TestService", "TestService", nil, nil),
}
rawget(services.ReplicatedStorage, "__children").Shared = buildDir("src/shared", "Shared", services.ReplicatedStorage)
rawget(services.ServerScriptService, "__children").Server =
	buildDir("src/server", "Server", services.ServerScriptService)
rawget(services.TestService, "__children").Sim = buildDir("tests/sim", "Sim", services.TestService)

local game = setmetatable({}, {
	__index = {
		GetService = function(_, serviceName)
			local service = services[serviceName]
			if not service then
				error("Service non simulé dans les tests : " .. tostring(serviceName) .. " (module non pur ?)")
			end
			return service
		end,
	},
})

-- require(Instance) virtuel --------------------------------------------------------------------

local cache = {}
local loading = {}
local vrequire

local function baseEnv()
	return {
		game = game,
		require = vrequire,
		warn = function(...)
			print("[warn]", ...)
		end,
	}
end

vrequire = function(target)
	if type(target) ~= "table" or getmetatable(target) ~= nodeMeta then
		error("require : seules les instances virtuelles sont supportées dans ce runner")
	end
	local path = rawget(target, "__path")
	if not path then
		error("require : " .. methods.GetFullName(target) .. " n'est pas un ModuleScript")
	end
	if cache[path] ~= nil then
		return cache[path]
	end
	if loading[path] then
		error("require circulaire : " .. path)
	end
	loading[path] = true
	local env = baseEnv()
	env.script = target
	local chunk = luau.load(fs.readFile(path), { debugName = path, environment = env })
	local result = chunk()
	loading[path] = nil
	cache[path] = result
	return result
end

-- Rapport du simulateur économique : `lune run tests/run.luau report` ---------------------------

-- `report phase5` : mesures d'équilibrage de la Phase 5 (extensions, améliorations normales, automatisation, hors
-- ligne) ; `report` seul : rapport des phases 3–4.
if process.args[1] == "report" then
	local sims = rawget(rawget(services.TestService, "__children").Sim, "__children")
	local report = vrequire(if process.args[2] == "phase5" then sims.Phase5Report else sims.Report)
	report()
	process.exit(0)
end

-- Exécution des specs --------------------------------------------------------------------------

local SPEC_DIR = "tests/specs"
local specFiles = {}
for _, entry in fs.readDir(SPEC_DIR) do
	if string.match(entry, "%.spec%.luau$") then
		table.insert(specFiles, entry)
	end
end
table.sort(specFiles)

local totalPassed, totalFailed = 0, 0
for _, fileName in specFiles do
	local path = SPEC_DIR .. "/" .. fileName
	local env, root = TestEZLite.newSuite(fileName)
	for key, value in baseEnv() do
		env[key] = value
	end
	local ok, err = pcall(function()
		local chunk = luau.load(fs.readFile(path), { debugName = path, environment = env })
		local specFn = chunk()
		assert(type(specFn) == "function", "une spec doit retourner une fonction")
		specFn()
	end)
	if not ok then
		totalFailed += 1
		print(string.format("✗ %s : erreur de chargement\n    %s", fileName, tostring(err)))
	else
		local passed, failed, failures = TestEZLite.run(root)
		totalPassed += passed
		totalFailed += failed
		print(
			string.format(
				"%s %s : %d réussi(s), %d échec(s)",
				if failed == 0 then "✓" else "✗",
				fileName,
				passed,
				failed
			)
		)
		for _, failure in failures do
			print(string.format("    ✗ %s\n      %s", failure.path, failure.message))
		end
	end
end

print(string.format("\nTotal : %d réussi(s), %d échec(s)", totalPassed, totalFailed))
process.exit(if totalFailed > 0 then 1 else 0)
