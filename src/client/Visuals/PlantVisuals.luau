--!strict
-- Modèles de plantes procéduraux (primitives Roblox, aucun asset externe) et mise à l'échelle de croissance.
-- Pour remplacer par un modèle d'art : prévoir ReplicatedStorage.Assets.Plants.<id> (Phase 7).
-- Mutations : teinte, matériau, échelle, lumière et aura de particules LIMITÉES (une PointLight seulement à
-- partir de Radioactive, ≤ 6 particules/s par plante). Couleurs 3D réglées en Studio (le néon et la lueur
-- éclaircissent les teintes claires) : elles diffèrent volontairement des couleurs d'UI de MutationConfig.

type Shape = "Block" | "Ball" | "Cylinder" | "Sphere"

type PartSpec = {
	shape: Shape,
	size: Vector3,
	cframe: CFrame, -- relatif au pied de la plante (sol de la case)
	color: Color3,
	material: Enum.Material?,
}

type PlantSpec = {
	height: number,
	parts: { PartSpec },
}

type ScaledPart = { part: BasePart, size: Vector3, offset: CFrame }

export type PlantModel = {
	model: Model,
	parts: { ScaledPart },
	sparkle: ParticleEmitter,
	scale: number, -- facteur d'échelle de la mutation (Géante : 1,5), appliqué en plus de la croissance
}

type AuraSpec = { rate: number, speed: number, size: number }

type MutationStyle = {
	color: string, -- teinte 3D "#RRGGBB"
	tint: number, -- part de cette teinte mélangée à la couleur d'origine (0..1)
	material: Enum.Material?,
	transparency: number?,
	scale: number,
	glow: number?, -- luminosité d'une PointLight (nil : aucune lumière)
	aura: AuraSpec?,
	halo: string?, -- disque néon au-dessus de la plante ("#RRGGBB")
}

-- Effets par mutation (docs/GAME_DESIGN.md §6).
local MUTATION_STYLES: { [string]: MutationStyle } = {
	shiny = { color = "#FFD23F", tint = 0.7, scale = 1, aura = { rate = 2, speed = 0.6, size = 0.25 } },
	giant = { color = "#FFFFFF", tint = 0, scale = 1.5 },
	crystal = { color = "#00BCD4", tint = 0.8, material = Enum.Material.Glass, transparency = 0.25, scale = 1 },
	radioactive = {
		color = "#64DD17",
		tint = 0.85,
		material = Enum.Material.Neon,
		scale = 1,
		glow = 1.2,
		aura = { rate = 3, speed = 0.4, size = 0.35 },
	},
	astral = {
		color = "#5B2EFF",
		tint = 0.85,
		material = Enum.Material.Neon,
		scale = 1.1,
		glow = 1.5,
		aura = { rate = 4, speed = 0.8, size = 0.3 },
	},
	divine = {
		color = "#FF8F00",
		tint = 0.9,
		material = Enum.Material.Neon,
		scale = 1.2,
		glow = 2.5,
		aura = { rate = 6, speed = 1, size = 0.45 },
		halo = "#FFD54F",
	},
}

local LEAF = Color3.fromRGB(76, 168, 72)
local LEAF_DARK = Color3.fromRGB(52, 130, 56)
local STEM = Color3.fromRGB(88, 150, 62)

local function rotation(degrees: Vector3?): CFrame
	if not degrees then
		return CFrame.identity
	end
	return CFrame.Angles(math.rad(degrees.X), math.rad(degrees.Y), math.rad(degrees.Z))
end

local function part(
	shape: Shape,
	size: Vector3,
	position: Vector3,
	color: Color3,
	degrees: Vector3?,
	material: Enum.Material?
): PartSpec
	return {
		shape = shape,
		size = size,
		cframe = CFrame.new(position) * rotation(degrees),
		color = color,
		material = material,
	}
end

-- Cylindre vertical (l'axe des cylindres Roblox est X : rotation de 90° autour de Z).
local function column(height: number, diameter: number, position: Vector3, color: Color3, degrees: Vector3?): PartSpec
	return {
		shape = "Cylinder",
		size = Vector3.new(height, diameter, diameter),
		cframe = CFrame.new(position) * rotation(degrees) * CFrame.Angles(0, 0, math.rad(90)),
		color = color,
	}
end

local function starPetals(count: number, radius: number, y: number, color: Color3): { PartSpec }
	local petals: { PartSpec } = {}
	for index = 0, count - 1 do
		local angle = index * 360 / count
		local cframe = CFrame.new(0, y, 0) * CFrame.Angles(0, math.rad(angle), 0) * CFrame.new(0, 0, radius)
		table.insert(petals, {
			shape = "Block",
			size = Vector3.new(0.55, 0.14, 1.5),
			cframe = cframe * CFrame.Angles(math.rad(-12), 0, 0),
			color = color,
			material = Enum.Material.Neon,
		})
	end
	return petals
end

local SPECS: { [string]: PlantSpec } = {
	carrot = {
		height = 2.6,
		parts = {
			part("Sphere", Vector3.new(1.5, 1.1, 1.5), Vector3.new(0, 0.35, 0), Color3.fromRGB(242, 140, 40)),
			part("Block", Vector3.new(0.22, 1.9, 0.6), Vector3.new(0, 1.45, 0), LEAF, Vector3.new(0, 0, 14)),
			part("Block", Vector3.new(0.22, 1.9, 0.6), Vector3.new(0, 1.45, 0), LEAF, Vector3.new(0, 120, 14)),
			part("Block", Vector3.new(0.22, 1.9, 0.6), Vector3.new(0, 1.45, 0), LEAF_DARK, Vector3.new(0, 240, 14)),
		},
	},
	tomato = {
		height = 3.6,
		parts = {
			column(3.2, 0.32, Vector3.new(0, 1.6, 0), STEM),
			part("Block", Vector3.new(2.6, 0.12, 0.7), Vector3.new(0, 2.1, 0), LEAF, Vector3.new(0, 30, 8)),
			part("Block", Vector3.new(2.2, 0.12, 0.6), Vector3.new(0, 1.2, 0), LEAF_DARK, Vector3.new(0, 110, -8)),
			part("Ball", Vector3.new(1, 1, 1), Vector3.new(0.75, 1.5, 0.25), Color3.fromRGB(229, 57, 53)),
			part("Ball", Vector3.new(1, 1, 1), Vector3.new(-0.65, 2.35, -0.3), Color3.fromRGB(229, 57, 53)),
			part("Ball", Vector3.new(1, 1, 1), Vector3.new(0.25, 2.95, 0.55), Color3.fromRGB(239, 83, 80)),
		},
	},
	corn = {
		height = 6.3,
		parts = {
			column(5.4, 0.45, Vector3.new(0, 2.7, 0), Color3.fromRGB(124, 179, 66)),
			part("Block", Vector3.new(0.18, 3, 0.8), Vector3.new(0.6, 2, 0), LEAF, Vector3.new(0, 0, -32)),
			part("Block", Vector3.new(0.18, 3, 0.8), Vector3.new(-0.6, 2.6, 0.2), LEAF_DARK, Vector3.new(0, 20, 30)),
			part("Block", Vector3.new(0.8, 3, 0.18), Vector3.new(0, 3.4, -0.6), LEAF, Vector3.new(28, 0, 0)),
			part(
				"Sphere",
				Vector3.new(0.85, 2.2, 0.85),
				Vector3.new(0.55, 3.5, 0),
				Color3.fromRGB(253, 216, 53),
				Vector3.new(0, 0, -14)
			),
			part(
				"Sphere",
				Vector3.new(0.6, 2, 0.95),
				Vector3.new(0.38, 3.3, 0.12),
				Color3.fromRGB(139, 195, 74),
				Vector3.new(0, 0, -14)
			),
			part("Block", Vector3.new(0.12, 1, 0.12), Vector3.new(0, 5.8, 0), Color3.fromRGB(230, 200, 120)),
		},
	},
	pumpkin = {
		height = 3,
		parts = {
			part("Sphere", Vector3.new(3.4, 2.3, 3.4), Vector3.new(0, 1.15, 0), Color3.fromRGB(251, 140, 0)),
			part("Sphere", Vector3.new(3.5, 2.1, 1.9), Vector3.new(0, 1.1, 0), Color3.fromRGB(239, 108, 0)),
			part("Sphere", Vector3.new(1.9, 2.1, 3.5), Vector3.new(0, 1.1, 0), Color3.fromRGB(239, 108, 0)),
			column(0.8, 0.42, Vector3.new(0, 2.55, 0), Color3.fromRGB(121, 85, 72), Vector3.new(0, 0, 10)),
			part("Block", Vector3.new(1.6, 0.12, 1.1), Vector3.new(1, 2.2, 0.4), LEAF, Vector3.new(0, 25, -12)),
		},
	},
	moonshroom = {
		height = 3.6,
		parts = {
			column(2.2, 0.95, Vector3.new(0, 1.1, 0), Color3.fromRGB(237, 231, 246)),
			column(0.25, 2.9, Vector3.new(0, 2.05, 0), Color3.fromRGB(200, 180, 230)),
			part("Sphere", Vector3.new(3.4, 1.7, 3.4), Vector3.new(0, 2.55, 0), Color3.fromRGB(142, 92, 217)),
			part(
				"Ball",
				Vector3.new(0.42, 0.42, 0.42),
				Vector3.new(0.9, 3.24, 0.4),
				Color3.fromRGB(128, 255, 234),
				nil,
				Enum.Material.Neon
			),
			part(
				"Ball",
				Vector3.new(0.42, 0.42, 0.42),
				Vector3.new(-0.7, 3.26, -0.6),
				Color3.fromRGB(128, 255, 234),
				nil,
				Enum.Material.Neon
			),
			part(
				"Ball",
				Vector3.new(0.36, 0.36, 0.36),
				Vector3.new(0, 3.4, 0),
				Color3.fromRGB(128, 255, 234),
				nil,
				Enum.Material.Neon
			),
			part(
				"Ball",
				Vector3.new(0.36, 0.36, 0.36),
				Vector3.new(-1.2, 3.1, 0.5),
				Color3.fromRGB(128, 255, 234),
				nil,
				Enum.Material.Neon
			),
			part(
				"Ball",
				Vector3.new(0.36, 0.36, 0.36),
				Vector3.new(0.4, 3.17, -1.1),
				Color3.fromRGB(128, 255, 234),
				nil,
				Enum.Material.Neon
			),
		},
	},
	starbloom = {
		height = 3.6,
		parts = {
			column(3, 0.28, Vector3.new(0, 1.5, 0), STEM),
			part("Block", Vector3.new(1.6, 0.1, 0.6), Vector3.new(0.6, 1.2, 0), LEAF, Vector3.new(0, 0, 20)),
			part("Block", Vector3.new(1.6, 0.1, 0.6), Vector3.new(-0.6, 1.8, 0), LEAF_DARK, Vector3.new(0, 180, 20)),
			part(
				"Ball",
				Vector3.new(0.8, 0.8, 0.8),
				Vector3.new(0, 3.2, 0),
				Color3.fromRGB(255, 152, 0),
				nil,
				Enum.Material.Neon
			),
		},
	},
	dragonfruit = {
		height = 4.2,
		parts = {
			column(3, 1, Vector3.new(0, 1.5, 0), Color3.fromRGB(46, 125, 50)),
			part("Block", Vector3.new(0.9, 0.5, 0.5), Vector3.new(-0.7, 1.8, 0), Color3.fromRGB(46, 125, 50)),
			column(1.4, 0.55, Vector3.new(-1.05, 2.3, 0), Color3.fromRGB(56, 142, 60)),
			part("Block", Vector3.new(0.9, 0.5, 0.5), Vector3.new(0.7, 1.4, 0), Color3.fromRGB(46, 125, 50)),
			column(1.2, 0.55, Vector3.new(1.05, 1.9, 0), Color3.fromRGB(56, 142, 60)),
			part("Sphere", Vector3.new(1.1, 1.4, 1.1), Vector3.new(0, 3.55, 0), Color3.fromRGB(236, 64, 122)),
			part("Sphere", Vector3.new(1, 1.25, 1), Vector3.new(-1.05, 3.4, 0), Color3.fromRGB(240, 98, 146)),
			part("Sphere", Vector3.new(1, 1.25, 1), Vector3.new(1.05, 2.9, 0), Color3.fromRGB(240, 98, 146)),
		},
	},
}

for _, petal in starPetals(5, 0.8, 3.15, Color3.fromRGB(255, 213, 79)) do
	table.insert(SPECS.starbloom.parts, petal)
end

local function newPart(name: string, spec: PartSpec): BasePart
	local instance = Instance.new("Part")
	instance.Name = name
	instance.Anchored = true
	instance.CanCollide = false
	instance.CanQuery = false
	instance.CanTouch = false
	instance.CastShadow = false
	instance.Massless = true
	instance.TopSurface = Enum.SurfaceType.Smooth
	instance.BottomSurface = Enum.SurfaceType.Smooth
	instance.Color = spec.color
	instance.Material = spec.material or Enum.Material.SmoothPlastic
	if spec.shape == "Ball" then
		instance.Shape = Enum.PartType.Ball
	elseif spec.shape == "Cylinder" then
		instance.Shape = Enum.PartType.Cylinder
	elseif spec.shape == "Sphere" then
		-- Ellipsoïde : le maillage suit la taille de la pièce (mise à l'échelle manuelle, pas Model:ScaleTo).
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = instance
	end
	instance.Size = spec.size
	return instance
end

local function newSparkle(): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Sparkle"
	emitter.Enabled = false
	emitter.Rate = 4
	emitter.Lifetime = NumberRange.new(0.8, 1.2)
	emitter.Speed = NumberRange.new(1, 2)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(0.35, 0)
	emitter.LightEmission = 1
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 240, 150))
	return emitter
end

local function newAura(color: Color3, aura: AuraSpec): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "MutationAura"
	emitter.Rate = aura.rate
	emitter.Lifetime = NumberRange.new(1.2, 1.8)
	emitter.Speed = NumberRange.new(aura.speed * 0.5, aura.speed)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(aura.size, 0)
	emitter.LightEmission = 1
	emitter.Color = ColorSequence.new(color)
	return emitter
end

local function applyStyle(instance: BasePart, style: MutationStyle, color: Color3)
	instance.Color = instance.Color:Lerp(color, style.tint)
	if style.material then
		instance.Material = style.material
	end
	if style.transparency then
		instance.Transparency = style.transparency
	end
end

local PlantVisuals = {}

function PlantVisuals.has(plantId: string): boolean
	return SPECS[plantId] ~= nil
end

-- Construit la plante ; `mutationId` (nil ou "normal" : aucun effet) applique le style de mutation.
function PlantVisuals.build(plantId: string, mutationId: string?): PlantModel?
	local spec = SPECS[plantId]
	if not spec then
		return nil
	end
	local style = if mutationId then MUTATION_STYLES[mutationId] else nil
	local mutationColor = if style then Color3.fromHex(style.color) else Color3.new(1, 1, 1)
	local model = Instance.new("Model")
	model.Name = if style then string.format("Plant_%s_%s", plantId, mutationId :: string) else "Plant_" .. plantId
	local scaled: { ScaledPart } = {}
	for index, partSpec in spec.parts do
		local instance = newPart("Part" .. index, partSpec)
		if style then
			applyStyle(instance, style, mutationColor)
		end
		instance.CFrame = partSpec.cframe
		instance.Parent = model
		table.insert(scaled, { part = instance, size = partSpec.size, offset = partSpec.cframe })
	end

	local anchorSpec: PartSpec = {
		shape = "Block",
		size = Vector3.new(0.2, 0.2, 0.2),
		cframe = CFrame.new(0, spec.height + 0.3, 0),
		color = Color3.new(1, 1, 1),
	}
	local anchor = newPart("SparkleAnchor", anchorSpec)
	anchor.Transparency = 1
	anchor.Parent = model
	table.insert(scaled, { part = anchor, size = anchorSpec.size, offset = anchorSpec.cframe })
	local attachment = Instance.new("Attachment")
	attachment.Parent = anchor
	local sparkle = newSparkle()
	sparkle.Parent = attachment

	if style then
		local glow = style.glow
		if glow then
			local light = Instance.new("PointLight")
			light.Color = mutationColor
			light.Brightness = glow
			light.Range = 10
			light.Shadows = false
			light.Parent = anchor
		end
		local aura = style.aura
		if aura then
			newAura(mutationColor, aura).Parent = attachment
		end
		local halo = style.halo
		if halo then
			local haloSpec = column(0.15, 1.8, Vector3.new(0, spec.height + 0.8, 0), Color3.fromHex(halo))
			haloSpec.material = Enum.Material.Neon
			local haloPart = newPart("Halo", haloSpec)
			haloPart.CFrame = haloSpec.cframe
			haloPart.Parent = model
			table.insert(scaled, { part = haloPart, size = haloSpec.size, offset = haloSpec.cframe })
		end
	end

	return { model = model, parts = scaled, sparkle = sparkle, scale = if style then style.scale else 1 }
end

-- Place la plante au pied `base` avec l'échelle `scale` (taille et position des pièces).
function PlantVisuals.place(plant: PlantModel, base: CFrame, scale: number)
	for _, entry in plant.parts do
		entry.part.Size = entry.size * scale
		entry.part.CFrame = base * CFrame.new(entry.offset.Position * scale) * entry.offset.Rotation
	end
end

return PlantVisuals
