return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local SessionLock = require(Shared.Util.SessionLock)
	local DataSchema = require(Shared.Util.DataSchema)
	local Deep = require(Shared.Util.Deep)
	local BigNum = require(Shared.Util.BigNum)
	local GameConfig = require(Shared.Config.GameConfig)

	local TIMEOUT = GameConfig.Data.LockTimeout
	local FORMAT = GameConfig.Data.RecordFormat
	local KEY = "player_1"

	-- Store mémoire à la sémantique UpdateAsync (copies profondes), comme DataStoreAdapter.memory.
	local function newStore()
		local entries = {}
		local store = { writes = 0 }
		function store.update(key, transform)
			local result = transform(Deep.copy(entries[key]))
			if result ~= nil then
				entries[key] = Deep.copy(result)
				store.writes += 1
			end
		end
		function store.peek(key)
			return Deep.copy(entries[key])
		end
		return store
	end

	-- Serveur simulé : mêmes transformations que DataService (acquisition + chargement, écriture, libération).
	local function newServer(store, sessionId)
		local server = {}
		function server.join(now)
			local outcome, raw
			store.update(KEY, function(old)
				local result, record, data = SessionLock.acquire(old, sessionId, now, TIMEOUT, FORMAT)
				outcome, raw = result, data
				return record
			end)
			if outcome ~= "ok" then
				return outcome, nil
			end
			local data = DataSchema.load(raw, now)
			return outcome, data
		end
		function server.save(data, release, now)
			local valid = DataSchema.validate(data)
			assert(valid, "donnée invalide")
			local written = false
			store.update(KEY, function(old)
				local record = SessionLock.write(old, sessionId, Deep.copy(data), release, now, FORMAT)
				written = record ~= nil
				return record
			end)
			return written
		end
		return server
	end

	describe("acquisition", function()
		it("crée l'enregistrement et prend le verrou sur une clé vide", function()
			local outcome, record, data = SessionLock.acquire(nil, "A", 1000, TIMEOUT, FORMAT)
			expect(outcome).to.equal("ok")
			expect(data).to.equal(nil)
			expect(record.format).to.equal(FORMAT)
			expect(record.session.id).to.equal("A")
			expect(record.session.heartbeat).to.equal(1000)
		end)

		it("refuse sans rien écrire tant qu'un autre serveur tient un verrou récent", function()
			local old = { format = FORMAT, savedAt = 900, data = { x = 1 }, session = { id = "B", heartbeat = 1000 } }
			local outcome, record = SessionLock.acquire(old, "A", 1000 + TIMEOUT - 1, TIMEOUT, FORMAT)
			expect(outcome).to.equal("locked")
			expect(record).to.equal(nil)
		end)

		it("reprend un verrou périmé (serveur planté) après le délai", function()
			local old = { format = FORMAT, savedAt = 900, data = { x = 1 }, session = { id = "B", heartbeat = 1000 } }
			local outcome, record, data = SessionLock.acquire(old, "A", 1000 + TIMEOUT, TIMEOUT, FORMAT)
			expect(outcome).to.equal("ok")
			expect(record.session.id).to.equal("A")
			expect(data.x).to.equal(1)
		end)

		it("réacquiert son propre verrou (même serveur) et rafraîchit le heartbeat", function()
			local old = { format = FORMAT, savedAt = 900, data = {}, session = { id = "A", heartbeat = 1000 } }
			local outcome, record = SessionLock.acquire(old, "A", 1005, TIMEOUT, FORMAT)
			expect(outcome).to.equal("ok")
			expect(record.session.heartbeat).to.equal(1005)
		end)

		it("ignore un verrou malformé", function()
			for _, session in { "B", { id = "B" }, { id = "B", heartbeat = "hier" } } do
				local outcome = SessionLock.acquire({ session = session }, "A", 1000, TIMEOUT, FORMAT)
				expect(outcome).to.equal("ok")
			end
		end)
	end)

	describe("écriture et libération", function()
		it("écrit la donnée en gardant le verrou (autosave)", function()
			local old = { format = FORMAT, savedAt = 0, session = { id = "A", heartbeat = 1000 } }
			local record = SessionLock.write(old, "A", { coins = 5 }, false, 1045, FORMAT)
			expect(record.data.coins).to.equal(5)
			expect(record.savedAt).to.equal(1045)
			expect(record.session.id).to.equal("A")
			expect(record.session.heartbeat).to.equal(1045)
		end)

		it("libère le verrou dans la sauvegarde finale", function()
			local old = { format = FORMAT, savedAt = 0, session = { id = "A", heartbeat = 1000 } }
			local record = SessionLock.write(old, "A", { coins = 5 }, true, 1050, FORMAT)
			expect(record.session).to.equal(nil)
			expect(record.data.coins).to.equal(5)
		end)

		it("n'écrase jamais un enregistrement dont le verrou appartient à un autre serveur", function()
			local stolen = { format = FORMAT, savedAt = 0, session = { id = "B", heartbeat = 1000 } }
			expect(SessionLock.write(stolen, "A", {}, false, 1000, FORMAT)).to.equal(nil)
			expect(SessionLock.write({ format = FORMAT }, "A", {}, true, 1000, FORMAT)).to.equal(nil)
			expect(SessionLock.write(nil, "A", {}, true, 1000, FORMAT)).to.equal(nil)
		end)

		it("ne libère que son propre verrou, sans toucher à la donnée", function()
			local mine = { data = { coins = 7 }, session = { id = "A", heartbeat = 1000 } }
			local released = SessionLock.release(mine, "A")
			expect(released.session).to.equal(nil)
			expect(released.data.coins).to.equal(7)
			expect(SessionLock.release({ session = { id = "B", heartbeat = 1000 } }, "A")).to.equal(nil)
			expect(SessionLock.release(nil, "A")).to.equal(nil)
		end)
	end)

	describe("simulation multi-serveurs (store mémoire)", function()
		it("conserve la progression d'un serveur à l'autre après déconnexion", function()
			local store = newStore()
			local a, b = newServer(store, "A"), newServer(store, "B")
			local outcome, data = a.join(1000)
			expect(outcome).to.equal("ok")
			data.currencies.coins = BigNum.fromNumber(1234)
			data.seeds.unlocked.tomato = true
			expect(a.save(data, false, 1045)).to.equal(true) -- autosave
			expect(a.save(data, true, 1060)).to.equal(true) -- départ du joueur

			local outcomeB, dataB = b.join(1061)
			expect(outcomeB).to.equal("ok")
			expect(BigNum.eq(dataB.currencies.coins, BigNum.fromNumber(1234))).to.equal(true)
			expect(dataB.seeds.unlocked.tomato).to.equal(true)
		end)

		it("bloque un second serveur tant que le premier tient le profil, sans modifier le store", function()
			local store = newStore()
			local a, b = newServer(store, "A"), newServer(store, "B")
			a.join(1000)
			local before = store.peek(KEY)
			local writes = store.writes
			local outcome, data = b.join(1010)
			expect(outcome).to.equal("locked")
			expect(data).to.equal(nil)
			expect(store.writes).to.equal(writes)
			expect(Deep.equal(store.peek(KEY), before)).to.equal(true)
		end)

		it("après un plantage, le second serveur reprend le profil et l'ancien ne peut plus écrire", function()
			local store = newStore()
			local a, b = newServer(store, "A"), newServer(store, "B")
			local _, data = a.join(1000)
			data.currencies.coins = BigNum.fromNumber(50)
			a.save(data, false, 1045) -- dernier autosave avant le plantage (pas de libération)

			expect((b.join(1045 + TIMEOUT - 1))).to.equal("locked")
			local outcome, dataB = b.join(1045 + TIMEOUT)
			expect(outcome).to.equal("ok")
			expect(BigNum.eq(dataB.currencies.coins, BigNum.fromNumber(50))).to.equal(true)

			-- Le serveur A revient d'un gel réseau : son écriture tardive est refusée.
			data.currencies.coins = BigNum.fromNumber(999999)
			expect(a.save(data, true, 1045 + TIMEOUT + 1)).to.equal(false)
			local record = store.peek(KEY)
			expect(record.session.id).to.equal("B")
			expect(BigNum.eq(record.data.currencies.coins, BigNum.fromNumber(50))).to.equal(true)
		end)

		it("un rejoin sur le même serveur relit la dernière sauvegarde", function()
			local store = newStore()
			local a = newServer(store, "A")
			local _, data = a.join(1000)
			data.stats.harvests = 42
			a.save(data, true, 1100)
			local outcome, again = a.join(1101)
			expect(outcome).to.equal("ok")
			expect(again.stats.harvests).to.equal(42)
		end)
	end)
end
