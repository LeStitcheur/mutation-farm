return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local DataSchema = require(Shared.Util.DataSchema)
	local BigNum = require(Shared.Util.BigNum)
	local GameConfig = require(Shared.Config.GameConfig)
	local Deep = require(Shared.Util.Deep)

	describe("gabarit", function()
		it("est sérialisable en JSON", function()
			local ok, reason = DataSchema.validate(DataSchema.template(1700000000))
			expect(ok).to.equal(true)
			expect(reason).to.equal(nil)
		end)

		it("démarre avec la graine de départ et la parcelle principale", function()
			local data = DataSchema.template(0)
			expect(data.version).to.equal(DataSchema.VERSION)
			expect(data.seeds.unlocked[GameConfig.StarterSeed]).to.equal(true)
			expect(data.seeds.selected).to.equal(GameConfig.StarterSeed)
			expect(data.farm.plots.main).to.equal(true)
			expect(data.farm.plots.west).to.equal(nil)
			expect(BigNum.isZero(data.currencies.coins)).to.equal(true)
		end)

		it("retourne des tables indépendantes à chaque appel", function()
			local a = DataSchema.template(0)
			local b = DataSchema.template(0)
			a.bag.items["carrot|normal"] = 3
			expect(b.bag.items["carrot|normal"]).to.equal(nil)
		end)
	end)

	describe("chargement", function()
		it("crée un nouveau profil pour une donnée absente", function()
			local data, err = DataSchema.load(nil, 42)
			expect(err).to.equal(nil)
			expect(data.meta.createdAt).to.equal(42)
		end)

		it("remplace une donnée non tabulaire et le signale", function()
			local data, err, notes = DataSchema.load("corrompu", 0)
			expect(err).to.equal(nil)
			expect(data).to.be.ok()
			expect(#notes > 0).to.equal(true)
		end)

		it("refuse une version future sans la modifier", function()
			local raw = { version = DataSchema.VERSION + 1, secret = "garder" }
			local data, err = DataSchema.load(raw, 0)
			expect(data).to.equal(nil)
			expect(err).to.equal("future_version")
			expect(raw.secret).to.equal("garder")
		end)

		it("conserve les valeurs existantes et complète les champs manquants", function()
			local raw = {
				version = 1,
				currencies = { coins = { m = 500, e = 0 } },
				seeds = { unlocked = { carrot = true, tomato = true }, selected = "tomato" },
			}
			local data = DataSchema.load(raw, 0)
			expect(data.currencies.coins.m).to.equal(500)
			expect(data.seeds.selected).to.equal("tomato")
			expect(data.bag.items).to.be.a("table")
			expect(BigNum.isZero(data.currencies.essence)).to.equal(true)
			expect(data.stats.harvests).to.equal(0)
		end)

		it("migre une donnée sans version", function()
			local data, err, notes = DataSchema.load({ currencies = { coins = { m = 7, e = 0 } } }, 0)
			expect(err).to.equal(nil)
			expect(data.version).to.equal(DataSchema.VERSION)
			expect(data.currencies.coins.m).to.equal(7)
			local migrated = false
			for _, note in notes do
				if string.find(note, "migration", 1, true) then
					migrated = true
				end
			end
			expect(migrated).to.equal(true)
		end)
	end)

	describe("migrations", function()
		it("applique les étapes dans l'ordre et fixe la version", function()
			local steps = {
				[1] = function(data)
					data.gold = 10
					return data
				end,
				[2] = function(data)
					data.coins = data.gold * 2
					data.gold = nil
					return data
				end,
			}
			local result = DataSchema.migrate({ version = 0 }, 0, 2, steps)
			expect(result.version).to.equal(2)
			expect(result.coins).to.equal(20)
			expect(result.gold).to.equal(nil)
		end)

		it("v1 -> v2 : cycles initialisés depuis les Coins déjà gagnés, rien n'est supprimé", function()
			local v1 = DataSchema.template(0)
			v1.version = 1
			v1.progression = { rebirths = 0, prestiges = 0 }
			v1.stats.coinsEarned = BigNum.fromNumber(42000)
			v1.stats.totalRebirths = nil
			v1.meta.quarantine = nil
			v1.legacyField = { keep = true } -- donnée inconnue : conservée
			local data, err, notes = DataSchema.load(Deep.copy(v1), 100)
			expect(err).to.equal(nil)
			expect(data.version).to.equal(DataSchema.VERSION)
			expect(data.progression.revision).to.equal(0)
			expect(BigNum.eq(data.progression.cycleCoins, BigNum.fromNumber(42000))).to.equal(true)
			expect(BigNum.eq(data.progression.prestigeCoins, BigNum.fromNumber(42000))).to.equal(true)
			expect(data.stats.totalRebirths).to.equal(0)
			expect((data :: any).legacyField.keep).to.equal(true)
			expect(#data.meta.quarantine).to.equal(0)
			expect(string.find(table.concat(notes, " "), "migration v1 -> v" .. DataSchema.VERSION, 1, true)).to.be.ok()
		end)

		it("v1 -> v2 défensive : tables manquantes ou compteurs corrompus", function()
			local data = DataSchema.load({ version = 1, stats = { coinsEarned = "abc" } }, 0)
			expect(BigNum.isZero(data.progression.cycleCoins)).to.equal(true)
			expect(data.progression.revision).to.equal(0)
		end)
	end)

	describe("quarantaine (aucune suppression silencieuse)", function()
		it(
			"une valeur d'un type incompatible remplacée par la réconciliation est conservée en quarantaine",
			function()
				local raw = DataSchema.template(0)
				raw.stats.harvests = "douze" :: any
				raw.cosmetics = 7 :: any
				raw.meta.quarantine = "invalide" :: any
				local data, err, notes = DataSchema.load(raw, 50)
				expect(err).to.equal(nil)
				expect(data.stats.harvests).to.equal(0)
				expect(type(data.cosmetics.owned)).to.equal("table")
				local byPath = {}
				for _, item in data.meta.quarantine do
					byPath[item.path] = item.value
				end
				expect(byPath["stats.harvests"]).to.equal("douze")
				expect(byPath["cosmetics"]).to.equal(7)
				expect(byPath["meta.quarantine"]).to.equal("invalide")
				expect(string.find(table.concat(notes, " "), "type incompatible", 1, true)).to.be.ok()
			end
		)

		it("toute valeur retirée ou corrigée est conservée dans meta.quarantine avec une note", function()
			local data = DataSchema.template(0)
			data.farm.tiles["main:2"] = { plantId = "plante_supprimee", plantedAt = 10, growTime = 6 }
			data.bag.items["carrot|inconnue"] = 2
			data.currencies.rebirthTokens = -3
			data.progression.revision = 1.5
			data.receipts = { "ok", 42 }
			local notes = DataSchema.sanitize(data, 77)
			local byPath = {}
			for _, entry in data.meta.quarantine do
				byPath[entry.path] = entry
				expect(entry.at).to.equal(77)
			end
			expect(byPath["farm.tiles.main:2"].value.plantId).to.equal("plante_supprimee")
			expect(byPath["bag.items.carrot|inconnue"].value).to.equal(2)
			expect(byPath["currencies.rebirthTokens"].value).to.equal(-3)
			expect(byPath["progression.revision"].value).to.equal(1.5)
			expect(byPath["receipts.2"].value).to.equal(42)
			expect(#notes).to.equal(#data.meta.quarantine)
			expect((DataSchema.validate(data))).to.equal(true)
		end)

		it("une valeur non sérialisable est gardée sous forme de texte ; la liste est bornée (FIFO)", function()
			local data = DataSchema.template(0)
			data.currencies.coins = { m = 0 / 0, e = 0 }
			DataSchema.sanitize(data, 1)
			expect(type(data.meta.quarantine[1].value)).to.equal("string")
			for i = 1, GameConfig.Data.MaxQuarantine + 10 do
				data.seeds.unlocked["inconnue" .. i] = true
			end
			DataSchema.sanitize(data, 2)
			expect(#data.meta.quarantine).to.equal(GameConfig.Data.MaxQuarantine)
			expect((DataSchema.validate(data))).to.equal(true)
		end)
	end)

	describe("assainissement", function()
		it("retire les cases, objets et graines invalides", function()
			local data = DataSchema.template(0)
			data.farm.tiles["main:1"] = { plantId = "carrot", plantedAt = 10, growTime = 6 }
			data.farm.tiles["main:2"] = { plantId = "plante_supprimee", plantedAt = 10, growTime = 6 }
			data.farm.tiles["west:1"] = { plantId = "carrot", plantedAt = 10, growTime = 6 }
			data.farm.tiles["main:3"] = { plantId = "carrot", plantedAt = 10, growTime = 0 }
			data.bag.items["carrot|normal"] = 4
			data.bag.items["carrot|inconnue"] = 2
			data.bag.items["tomato|normal"] = 1.5
			data.seeds.unlocked.licorne = true
			data.seeds.selected = "corn"
			data.currencies.coins = { m = 0 / 0, e = 0 }
			data.farm.plots.lune = true

			local notes = DataSchema.sanitize(data)
			expect(#notes > 0).to.equal(true)
			expect(data.farm.tiles["main:1"]).to.be.ok()
			expect(data.farm.tiles["main:2"]).to.equal(nil)
			expect(data.farm.tiles["west:1"]).to.equal(nil)
			expect(data.farm.tiles["main:3"]).to.equal(nil)
			expect(data.bag.items["carrot|normal"]).to.equal(4)
			expect(data.bag.items["carrot|inconnue"]).to.equal(nil)
			expect(data.bag.items["tomato|normal"]).to.equal(nil)
			expect(data.seeds.unlocked.licorne).to.equal(nil)
			expect(data.seeds.selected).to.equal(GameConfig.StarterSeed)
			expect(BigNum.isZero(data.currencies.coins)).to.equal(true)
			expect(data.farm.plots.lune).to.equal(nil)
			expect(data.farm.plots.main).to.equal(true)
		end)

		it("borne la liste des reçus (FIFO)", function()
			local data = DataSchema.template(0)
			for i = 1, GameConfig.Data.MaxReceipts + 25 do
				table.insert(data.receipts, "r" .. i)
			end
			DataSchema.sanitize(data)
			expect(#data.receipts).to.equal(GameConfig.Data.MaxReceipts)
			expect(data.receipts[1]).to.equal("r26")
		end)
	end)

	describe("validation JSON", function()
		it("accepte une donnée imbriquée correcte", function()
			expect((DataSchema.validate({ a = { 1, 2, 3 }, b = { c = "ok", d = true } }))).to.equal(true)
		end)

		it("rejette NaN, infini, tables mixtes, trous et fonctions", function()
			expect((DataSchema.validate({ x = 0 / 0 }))).to.equal(false)
			expect((DataSchema.validate({ x = math.huge }))).to.equal(false)
			-- selene: allow(mixed_table)
			expect((DataSchema.validate({ 1, 2, key = 3 }))).to.equal(false)
			expect((DataSchema.validate({ [1] = "a", [3] = "c" }))).to.equal(false)
			expect((DataSchema.validate({ f = function() end }))).to.equal(false)
			expect((DataSchema.validate({ [true] = 1 }))).to.equal(false)
		end)
	end)
end
