--!strict
-- EventController — affichage LOCAL des événements du monde (Phase 4, jalon C) à partir de l'état publié par le
-- serveur (ReplicatedStorage.WorldEvent : EventId, StartsAt, EndsAt), y compris pour un joueur arrivé en cours
-- d'événement : bandeau (nom, effet, compte à rebours à l'horloge serveur), éclairage teinté (ColorCorrection
-- local), particules autour de la caméra (pluie violette ; paillettes dorées). Purement visuel : les bonus sont
-- appliqués par le serveur au moment de l'action, rien n'est envoyé.
-- Mobile d'entrée de gamme : un seul émetteur, débit réduit sur écran tactile, mise à jour à 20 Hz.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local EventConfig = require(Shared.Config.EventConfig)
local Builder = require(script.Parent.Parent.UI.Builder)
local Theme = require(script.Parent.Parent.UI.Theme)

local UPDATE_INTERVAL = 1 / 20
local FADE = TweenInfo.new(2, Enum.EasingStyle.Sine)
local PARTICLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

type Look = { tint: Color3, brightness: number, saturation: number, contrast: number }

local LOOKS: { [string]: Look } = {
	rain = { tint = Color3.fromRGB(214, 196, 255), brightness = -0.03, saturation = 0.15, contrast = 0.05 },
	bloom = { tint = Color3.fromRGB(255, 238, 190), brightness = 0.04, saturation = 0.12, contrast = 0 },
}
local NEUTRAL: Look = { tint = Color3.new(1, 1, 1), brightness = 0, saturation = 0, contrast = 0 }

local state: Instance? = nil
local banner: Frame? = nil
local title: TextLabel? = nil
local summary: TextLabel? = nil
local countdown: TextLabel? = nil
local correction: ColorCorrectionEffect? = nil
local anchor: Part? = nil
local emitter: ParticleEmitter? = nil
local activeId = ""
local activeVisual: string? = nil

local EventController = {}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function formatRemaining(seconds: number): string
	local whole = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", whole // 60, whole % 60)
end

local function applyLook(look: Look)
	local effect = correction
	if effect then
		TweenService:Create(effect, FADE, {
			TintColor = look.tint,
			Brightness = look.brightness,
			Saturation = look.saturation,
			Contrast = look.contrast,
		}):Play()
	end
end

-- Configure l'unique émetteur pour l'effet demandé (nil : arrêt, les particules en vol finissent leur vie).
local function setParticles(visual: string?)
	local particles = emitter
	if not particles then
		return
	end
	local scale = if UserInputService.TouchEnabled then 0.5 else 1
	if visual == "rain" then
		particles.Color = ColorSequence.new(Color3.fromRGB(179, 136, 255), Color3.fromRGB(124, 77, 255))
		particles.LightEmission = 0.6
		particles.Size = NumberSequence.new(0.14)
		particles.Squash = NumberSequence.new(3)
		particles.Speed = NumberRange.new(55, 65)
		particles.Lifetime = NumberRange.new(0.9, 1.1)
		particles.EmissionDirection = Enum.NormalId.Bottom
		particles.Orientation = Enum.ParticleOrientation.VelocityParallel
		particles.SpreadAngle = Vector2.new(3, 3)
		particles.Rate = 220 * scale
		particles.Enabled = true
	elseif visual == "bloom" then
		particles.Color = ColorSequence.new(Color3.fromRGB(255, 213, 79), Color3.fromRGB(255, 179, 0))
		particles.LightEmission = 1
		particles.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.3, 0.35),
			NumberSequenceKeypoint.new(1, 0),
		})
		particles.Squash = NumberSequence.new(0)
		particles.Speed = NumberRange.new(1.5, 3.5)
		particles.Lifetime = NumberRange.new(3, 5)
		particles.EmissionDirection = Enum.NormalId.Top
		particles.Orientation = Enum.ParticleOrientation.FacingCamera
		particles.SpreadAngle = Vector2.new(25, 25)
		particles.Rate = 40 * scale
		particles.Enabled = true
	else
		particles.Enabled = false
	end
end

local function refresh()
	local folder = state
	local frame = banner
	if not folder or not frame then
		return
	end
	local id = folder:GetAttribute("EventId")
	local endsAt = folder:GetAttribute("EndsAt")
	local def = if type(id) == "string" then EventConfig.ById[id] else nil
	local active = def ~= nil and type(endsAt) == "number" and serverNow() < endsAt
	local key = if active and def then def.id .. ":" .. tostring(endsAt) else ""
	if key == activeId then
		return
	end
	activeId = key
	if active and def then
		frame.Visible = true
		frame.BackgroundColor3 = Color3.fromHex(def.color):Lerp(Theme.Colors.PanelDark, 0.55)
		if title then
			title.Text = def.name
		end
		if summary then
			summary.Text = def.summary
		end
		activeVisual = def.visual
		applyLook(LOOKS[def.visual] or NEUTRAL)
		setParticles(def.visual)
	else
		frame.Visible = false
		activeVisual = nil
		applyLook(NEUTRAL)
		setParticles(nil)
	end
end

local function step()
	refresh()
	local folder = state
	local label = countdown
	if folder and label and activeId ~= "" then
		local endsAt = folder:GetAttribute("EndsAt")
		label.Text = if type(endsAt) == "number" then formatRemaining(endsAt - serverNow()) else ""
	end
	local part = anchor
	local camera = Workspace.CurrentCamera
	if part and camera and activeVisual then
		local position = camera.CFrame.Position
		local height = if activeVisual == "rain" then 35 else -6
		part.CFrame = CFrame.new(position.X, position.Y + height, position.Z)
	end
end

local function buildBanner(root: Instance)
	local frame = Builder.new("Frame", {
		Name = "EventBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 74),
		Size = UDim2.fromOffset(520, 54),
		BackgroundColor3 = Theme.Colors.PanelDark,
		BackgroundTransparency = 0.1,
		Visible = false,
		Parent = root,
	}, { Builder.corner(14), Builder.stroke(Theme.Colors.Outline, 3) }) :: Frame
	local scale = Instance.new("UIScale")
	scale.Parent = frame
	local function updateScale()
		local camera = Workspace.CurrentCamera
		if camera then
			scale.Scale = Theme.scaleFor(camera.ViewportSize, UserInputService.TouchEnabled)
		end
	end
	updateScale()
	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end
	title = Builder.label({
		Name = "EventName",
		Position = UDim2.fromOffset(14, 4),
		Size = UDim2.new(1, -110, 0, 26),
		TextSize = 22,
		Parent = frame,
	})
	summary = Builder.label({
		Name = "Summary",
		Position = UDim2.fromOffset(14, 29),
		Size = UDim2.new(1, -110, 0, 20),
		TextSize = 14,
		Parent = frame,
	})
	countdown = Builder.label({
		Name = "Countdown",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(90, 40),
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Theme.Colors.Coin,
		Parent = frame,
	})
	banner = frame
end

function EventController.Init()
	local root = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MutationFarmHUD")
	buildBanner(root)

	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = "MutationFarmEvent"
	effect.Parent = Lighting
	correction = effect

	local part = Instance.new("Part")
	part.Name = "EventParticles"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(80, 1, 80)
	part.Parent = Workspace
	anchor = part
	local particles = Instance.new("ParticleEmitter")
	particles.Texture = PARTICLE_TEXTURE
	particles.Enabled = false
	particles.Parent = part
	emitter = particles
end

function EventController.Start()
	task.spawn(function()
		state = ReplicatedStorage:WaitForChild("WorldEvent")
		local elapsed = 0
		RunService.Heartbeat:Connect(function(dt: number)
			elapsed += dt
			if elapsed >= UPDATE_INTERVAL then
				elapsed = 0
				step()
			end
		end)
	end)
end

return EventController
