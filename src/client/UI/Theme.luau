--!strict
-- Thème visuel du HUD (fantasy colorée) et calcul d'échelle responsive.

local Theme = {
	Font = Enum.Font.FredokaOne,
	Colors = {
		Panel = Color3.fromRGB(255, 247, 228),
		PanelRow = Color3.fromRGB(246, 233, 205),
		PanelDark = Color3.fromRGB(52, 38, 30),
		Outline = Color3.fromRGB(62, 44, 30),
		Text = Color3.fromRGB(62, 44, 30),
		TextMuted = Color3.fromRGB(128, 104, 84),
		TextLight = Color3.fromRGB(255, 255, 255),
		Coin = Color3.fromRGB(255, 201, 40),
		CoinDark = Color3.fromRGB(196, 132, 18),
		Green = Color3.fromRGB(92, 184, 72),
		Blue = Color3.fromRGB(74, 144, 226),
		Gold = Color3.fromRGB(240, 172, 32),
		Red = Color3.fromRGB(224, 76, 76),
		Grey = Color3.fromRGB(158, 150, 140),
		BarBack = Color3.fromRGB(34, 24, 18),
	},
	DesignSize = Vector2.new(1280, 720),
	MinScale = 0.62,
	TouchMinScale = 0.8, -- cibles tactiles ≥ ~44 px sur téléphone
	MaxScale = 1.25,
	TouchBoost = 1.12,
	FitMargin = Vector2.new(0.94, 0.88), -- part de l'écran utilisable par un panneau « ajusté »
}

-- Échelle du HUD selon la taille d'écran ; plancher plus haut sur tactile.
function Theme.scaleFor(viewport: Vector2, touch: boolean): number
	local factor = math.min(viewport.X / Theme.DesignSize.X, viewport.Y / Theme.DesignSize.Y)
	if touch then
		factor *= Theme.TouchBoost
	end
	local minimum = if touch then Theme.TouchMinScale else Theme.MinScale
	return math.clamp(factor, minimum, Theme.MaxScale)
end

-- Échelle d'un élément de taille `designSize` : jamais plus grande que ce qui tient à l'écran.
function Theme.fitScale(base: number, viewport: Vector2, designSize: Vector2): number
	local fitX = viewport.X * Theme.FitMargin.X / designSize.X
	local fitY = viewport.Y * Theme.FitMargin.Y / designSize.Y
	return math.min(base, fitX, fitY)
end

return Theme
