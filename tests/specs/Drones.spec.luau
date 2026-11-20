-- Drones : configuration, prix et achat, points d'attente, portée, choix des cibles, sauvegarde.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local DroneConfig = require(Shared.Config.DroneConfig)
	local DroneLogic = require(Shared.Util.DroneLogic)
	local DataSchema = require(Shared.Util.DataSchema)
	local FarmLayout = require(Shared.Util.FarmLayout)
	local BigNum = require(Shared.Util.BigNum)
	local Deep = require(Shared.Util.Deep)

	local GameConfig = require(Shared.Config.GameConfig)

	local harvester = DroneConfig.get("harvester")

	local function richData(coins: number, owned: number?)
		local data = DataSchema.template(0)
		data.currencies.coins = BigNum.fromNumber(coins)
		if owned then
			data.machines.drones.harvester = owned
		end
		return data
	end

	describe("configuration", function()
		it("types valides, identifiants uniques, configuration gelée", function()
			local seen = {}
			for index, def in DroneConfig.List do
				expect(seen[def.id]).to.equal(nil)
				seen[def.id] = true
				expect(def.order).to.equal(index)
				expect(def.price > 0 and def.price % 1 == 0).to.equal(true)
				expect(def.priceGrowth >= 1).to.equal(true)
				expect(def.maxOwned >= 1 and def.maxOwned % 1 == 0).to.equal(true)
				expect(def.interval > 0).to.equal(true)
				expect(def.capacity >= 1 and def.capacity % 1 == 0).to.equal(true)
				expect(def.range > 0).to.equal(true)
				-- délai de grâce ≥ fenêtre « Bien » : un drone ne prive jamais le joueur d'un bonus de précision
				expect(def.graceDelay >= GameConfig.Harvest.GoodWindow).to.equal(true)
				expect(string.match(def.color, "^#%x%x%x%x%x%x$")).to.be.ok()
			end
			expect(function()
				(harvester :: any).price = 1
			end).to.throw()
		end)

		it("prix croissants : 1 500, 3 750, 9 375", function()
			expect(DroneLogic.price(harvester, 0)).to.equal(1500)
			expect(DroneLogic.price(harvester, 1)).to.equal(3750)
			expect(DroneLogic.price(harvester, 2)).to.equal(9375)
		end)
	end)

	describe("achat", function()
		it("refuse un type inconnu, des fonds insuffisants ou le maximum atteint", function()
			expect(select(2, DroneLogic.canBuy(richData(1e9), "inconnu"))).to.equal("unknown")
			expect(select(2, DroneLogic.canBuy(richData(1499), "harvester"))).to.equal("insufficient_funds")
			expect((DroneLogic.canBuy(richData(1500), "harvester"))).to.equal(true)
			expect(select(2, DroneLogic.canBuy(richData(3749, 1), "harvester"))).to.equal("insufficient_funds")
			expect(select(2, DroneLogic.canBuy(richData(1e9, harvester.maxOwned), "harvester"))).to.equal("max_owned")
		end)

		it("la flotte suit les exemplaires possédés, plafonnée au maximum", function()
			expect(#DroneLogic.fleet(richData(0))).to.equal(0)
			expect(#DroneLogic.fleet(richData(0, 2))).to.equal(2)
			expect(#DroneLogic.fleet(richData(0, 99))).to.equal(harvester.maxOwned)
		end)
	end)

	describe("positions et portée", function()
		it("points d'attente centrés, espacés et sur le socle", function()
			local f = FarmLayout.Features
			for total = 1, harvester.maxOwned do
				local sum = 0
				for index = 1, total do
					local home = DroneLogic.homePosition(index, total)
					sum += home.x - f.droneHome.x
					expect(home.y > f.groundTop).to.equal(true)
					expect(math.abs(home.x) <= f.platformSize.x / 2).to.equal(true)
				end
				expect(math.abs(sum) < 1e-9).to.equal(true)
			end
			local a, b = DroneLogic.homePosition(1, 3), DroneLogic.homePosition(2, 3)
			expect(b.x - a.x).to.equal(f.droneSpacing)
		end)

		it("chaque drone couvre toute la parcelle principale, pas les extensions lointaines", function()
			for total = 1, harvester.maxOwned do
				for index = 1, total do
					local home = DroneLogic.homePosition(index, total)
					for _, tileId in FarmLayout.tileIds("main") do
						expect(DroneLogic.inRange(home, tileId, harvester.range)).to.equal(true)
					end
					expect(DroneLogic.inRange(home, "east:6", harvester.range)).to.equal(false)
				end
			end
			expect(DroneLogic.inRange(DroneLogic.homePosition(1, 1), "inconnue", 1000)).to.equal(false)
		end)

		it("la station d'achat est sur le socle, à l'écart du marché, du panneau et de l'apparition", function()
			local f = FarmLayout.Features
			local station = f.droneStation
			expect(math.abs(station.x) + 3.5 <= f.platformSize.x / 2).to.equal(true)
			for _, other in { f.sellStand, f.sign, f.spawn } do
				local distance = math.sqrt((station.x - other.x) ^ 2 + (station.z - other.z) ^ 2)
				expect(distance >= 10).to.equal(true)
			end
		end)
	end)

	describe("choix des cibles", function()
		local function farmWith(tiles)
			local data = DataSchema.template(0)
			for tileId, plantedAt in tiles do
				data.farm.tiles[tileId] = { plantId = "carrot", plantedAt = plantedAt, growTime = 6 }
			end
			return data
		end
		local home = DroneLogic.homePosition(1, 1)

		it("cases mûres seulement, la plus anciennement mûre d'abord, dans la limite de la capacité", function()
			local data = farmWith({ ["main:1"] = 3, ["main:2"] = 1, ["main:3"] = 50 })
			local targets = DroneLogic.selectTargets(data, 20, home, harvester, {})
			expect(#targets).to.equal(harvester.capacity)
			expect(targets[1]).to.equal("main:2")
			local wide = table.clone(harvester) :: any
			wide.capacity = 5
			local all = DroneLogic.selectTargets(data, 20, home, wide, {})
			expect(#all).to.equal(2) -- main:3 n'est pas mûre
			expect(all[2]).to.equal("main:1")
		end)

		it("ignore les cases réservées par un autre drone et celles hors de portée", function()
			local data = farmWith({ ["main:1"] = 0, ["main:2"] = 0 })
			local targets = DroneLogic.selectTargets(data, 20, home, harvester, { ["main:1"] = true })
			expect(targets[1]).to.equal("main:2")
			local short = table.clone(harvester) :: any
			short.range = 1
			expect(#DroneLogic.selectTargets(data, 20, home, short, {})).to.equal(0)
		end)

		it("délai de grâce : une plante n'est visée qu'après graceDelay secondes de maturité", function()
			local data = farmWith({ ["main:1"] = 0 }) -- mûre à t = 6
			local ripeAt = 6
			expect(#DroneLogic.selectTargets(data, ripeAt, home, harvester, {})).to.equal(0)
			expect(#DroneLogic.selectTargets(data, ripeAt + harvester.graceDelay - 0.01, home, harvester, {})).to.equal(
				0
			)
			expect(DroneLogic.selectTargets(data, ripeAt + harvester.graceDelay, home, harvester, {})[1]).to.equal(
				"main:1"
			)
		end)

		it("ignore les cases d'une parcelle verrouillée, même à portée", function()
			local data = farmWith({ ["west:5"] = 0 })
			local westHome = { x = -34, y = 9, z = 0 }
			expect(#DroneLogic.selectTargets(data, 20, westHome, harvester, {})).to.equal(0)
			data.farm.plots.west = true
			expect(DroneLogic.selectTargets(data, 20, westHome, harvester, {})[1]).to.equal("west:5")
		end)
	end)

	describe("sauvegarde et restauration", function()
		it("le nombre de drones survit à l'écriture et au rechargement", function()
			local data = richData(0, 2)
			expect((DataSchema.validate(data))).to.equal(true)
			local loaded = DataSchema.load(Deep.copy(data), 10)
			expect(loaded.machines.drones.harvester).to.equal(2)
			expect(#DroneLogic.fleet(loaded)).to.equal(2)
		end)

		it("retire les types inconnus et les valeurs invalides, plafonne au maximum", function()
			local data = DataSchema.template(0)
			data.machines.drones = { harvester = 99, fantome = 2, ["?"] = -1 }
			local loaded = DataSchema.load(Deep.copy(data), 10)
			expect(loaded.machines.drones.harvester).to.equal(harvester.maxOwned)
			expect(loaded.machines.drones.fantome).to.equal(nil)
			for _, bad in { -1, 1.5, 0, "deux" } do
				local raw = DataSchema.template(0)
				raw.machines.drones = { harvester = bad }
				expect(DataSchema.load(Deep.copy(raw), 10).machines.drones.harvester).to.equal(nil)
			end
		end)
	end)
end
