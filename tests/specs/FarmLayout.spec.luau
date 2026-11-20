return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local FarmLayout = require(ReplicatedStorage.Shared.Util.FarmLayout)

	describe("identifiants de cases", function()
		it("la parcelle principale compte 9 cases", function()
			local ids = FarmLayout.tileIds("main")
			expect(#ids).to.equal(9)
			expect(ids[1]).to.equal("main:1")
			expect(ids[9]).to.equal("main:9")
		end)

		it("analyse les identifiants valides et rejette les autres", function()
			local plotId, index = FarmLayout.parseTileId("main:5")
			expect(plotId).to.equal("main")
			expect(index).to.equal(5)
			for _, bad in { "main:0", "main:10", "lune:1", "main:x", "main:1:2", "", "main" } do
				expect((FarmLayout.parseTileId(bad))).to.equal(nil)
			end
		end)

		it("seule la parcelle principale est débloquée par défaut", function()
			local plots = FarmLayout.defaultPlots()
			expect(plots.main).to.equal(true)
			expect(plots.west).to.equal(nil)
			expect(FarmLayout.isTileUnlocked(plots, "main:3")).to.equal(true)
			expect(FarmLayout.isTileUnlocked(plots, "west:3")).to.equal(false)
			expect(FarmLayout.isTileUnlocked(plots, "n'importe quoi")).to.equal(false)
		end)
	end)

	describe("géométrie", function()
		it("centre la grille 3×3 principale", function()
			local center = FarmLayout.tileLocalPosition("main:5")
			expect(center.x).to.equal(0)
			expect(center.z).to.equal(0)
			local corner = FarmLayout.tileLocalPosition("main:1")
			expect(corner.x).to.equal(-FarmLayout.TilePitch)
			expect(corner.z).to.equal(-FarmLayout.TilePitch)
		end)

		it("aucune case ne se chevauche, toutes parcelles confondues", function()
			local all = {}
			for _, plot in FarmLayout.Plots do
				for _, id in FarmLayout.tileIds(plot.id) do
					table.insert(all, FarmLayout.tileLocalPosition(id))
				end
			end
			for i = 1, #all do
				for j = i + 1, #all do
					local a, b = all[i], all[j]
					local separated = math.abs(a.x - b.x) >= FarmLayout.TileSize
						or math.abs(a.z - b.z) >= FarmLayout.TileSize
						or a.y ~= b.y
					expect(separated).to.equal(true)
				end
			end
		end)

		it("toutes les cases et équipements tiennent sur le socle", function()
			local f = FarmLayout.Features
			local halfX = f.platformSize.x / 2
			local minZ = f.platformCenter.z - f.platformSize.z / 2
			local maxZ = f.platformCenter.z + f.platformSize.z / 2
			local half = FarmLayout.TileSize / 2
			for _, plot in FarmLayout.Plots do
				for _, id in FarmLayout.tileIds(plot.id) do
					local p = FarmLayout.tileLocalPosition(id)
					expect(math.abs(p.x) + half <= halfX).to.equal(true)
					expect(p.z - half >= minZ and p.z + half <= maxZ).to.equal(true)
				end
			end
			for _, point in { f.sellStand, f.sign, f.spawn } do
				expect(math.abs(point.x) <= halfX).to.equal(true)
				expect(point.z >= minZ and point.z <= maxZ).to.equal(true)
			end
		end)
	end)

	describe("emplacements de parcelles", function()
		local function worldBounds(slot)
			local f = FarmLayout.Features
			local x, z, yaw = FarmLayout.slotTransform(slot)
			local sign = if yaw == 0 then 1 else -1
			local hx = f.platformSize.x / 2
			local z1 = f.platformCenter.z - f.platformSize.z / 2
			local z2 = f.platformCenter.z + f.platformSize.z / 2
			local za, zb = z + sign * z1, z + sign * z2
			return x - hx, x + hx, math.min(za, zb), math.max(za, zb)
		end

		it("les socles des 8 emplacements ne se chevauchent pas", function()
			for a = 1, FarmLayout.MaxSlots do
				for b = a + 1, FarmLayout.MaxSlots do
					local ax1, ax2, az1, az2 = worldBounds(a)
					local bx1, bx2, bz1, bz2 = worldBounds(b)
					local overlap = ax1 < bx2 and bx1 < ax2 and az1 < bz2 and bz1 < az2
					expect(overlap).to.equal(false)
				end
			end
		end)

		it("l'allée centrale reste libre pour le point d'apparition commun", function()
			for slot = 1, FarmLayout.MaxSlots do
				local _, _, z1, z2 = worldBounds(slot)
				expect(z1 > 10 or z2 < -10).to.equal(true)
			end
		end)

		it("rejette un emplacement invalide", function()
			expect(function()
				FarmLayout.slotTransform(0)
			end).to.throw()
			expect(function()
				FarmLayout.slotTransform(FarmLayout.MaxSlots + 1)
			end).to.throw()
		end)
	end)
end
