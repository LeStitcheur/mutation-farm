return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage.Shared
	local SlotAllocator = require(Shared.Util.SlotAllocator)
	local FarmLayout = require(Shared.Util.FarmLayout)

	-- Joueurs simulés : seule l'identité (référence) compte, comme pour les instances Player.
	local function players(count)
		local list = {}
		for i = 1, count do
			table.insert(list, { name = "P" .. i })
		end
		return list
	end

	describe("attribution", function()
		it("donne un emplacement distinct à chaque joueur, du plus petit au plus grand", function()
			local slots = SlotAllocator.new(FarmLayout.MaxSlots)
			local seen = {}
			for index, player in players(FarmLayout.MaxSlots) do
				local slot = SlotAllocator.claim(slots, player)
				expect(slot).to.equal(index)
				expect(seen[slot]).to.equal(nil)
				seen[slot] = true
			end
		end)

		it("refuse un joueur de plus quand le serveur est complet", function()
			local slots = SlotAllocator.new(FarmLayout.MaxSlots)
			for _, player in players(FarmLayout.MaxSlots) do
				SlotAllocator.claim(slots, player)
			end
			expect(SlotAllocator.claim(slots, { name = "en trop" })).to.equal(nil)
		end)

		it("un joueur n'occupe jamais deux emplacements", function()
			local slots = SlotAllocator.new(4)
			local p = { name = "P" }
			expect(SlotAllocator.claim(slots, p)).to.equal(1)
			expect(SlotAllocator.claim(slots, p)).to.equal(1)
			expect(SlotAllocator.claim(slots, { name = "Q" })).to.equal(2)
		end)

		it("rejette une capacité invalide", function()
			expect(function()
				SlotAllocator.new(0)
			end).to.throw()
			expect(function()
				SlotAllocator.new(2.5)
			end).to.throw()
		end)
	end)

	describe("libération", function()
		it("libère l'emplacement d'un joueur parti, réattribué au suivant", function()
			local slots = SlotAllocator.new(FarmLayout.MaxSlots)
			local list = players(3)
			for _, player in list do
				SlotAllocator.claim(slots, player)
			end
			expect(SlotAllocator.release(slots, 2, list[2])).to.equal(true)
			expect(SlotAllocator.slotOf(slots, list[2])).to.equal(nil)
			expect(SlotAllocator.claim(slots, { name = "nouveau" })).to.equal(2)
		end)

		it("une libération tardive ne retire pas l'emplacement d'un autre joueur", function()
			local slots = SlotAllocator.new(2)
			local old, new = { name = "ancien" }, { name = "nouveau" }
			SlotAllocator.claim(slots, old)
			SlotAllocator.release(slots, 1, old)
			SlotAllocator.claim(slots, new)
			expect(SlotAllocator.release(slots, 1, old)).to.equal(false)
			expect(SlotAllocator.slotOf(slots, new)).to.equal(1)
			expect(SlotAllocator.release(slots, 2, new)).to.equal(false)
		end)
	end)

	describe("isolation des parcelles", function()
		it("8 joueurs simultanés : 8 parcelles à des positions distinctes", function()
			local slots = SlotAllocator.new(FarmLayout.MaxSlots)
			local positions = {}
			for _, player in players(FarmLayout.MaxSlots) do
				local slot = SlotAllocator.claim(slots, player)
				local x, z = FarmLayout.slotTransform(slot)
				local key = string.format("%d,%d", x, z)
				expect(positions[key]).to.equal(nil)
				positions[key] = true
			end
		end)
	end)
end
