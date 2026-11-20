--!strict
-- Construction déclarative d'instances UI.

local Theme = require(script.Parent.Theme)

export type Props = { [string]: any }

local Builder = {}

-- Crée une instance, applique les propriétés puis parente les enfants ; `Parent` est appliqué en dernier.
-- `children` est typé { any } : le solveur infère les littéraux hétérogènes ({UICorner, UIStroke}) par leur 1er élément.
function Builder.new(className: string, props: Props?, children: { any }?): Instance
	local instance = Instance.new(className)
	local parent: Instance? = nil
	if props then
		for key, value in props do
			if key == "Parent" then
				parent = value
			else
				(instance :: any)[key] = value
			end
		end
	end
	if children then
		for _, child in children do
			(child :: Instance).Parent = instance
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

-- Les décorateurs (corner, stroke, padding, list) retournent `Instance` : ils ne servent qu'en enfants,
-- et ce type garantit que les littéraux { corner, stroke, label } soient inférés en { Instance }.
function Builder.corner(radius: number): Instance
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	return corner
end

function Builder.stroke(color: Color3, thickness: number): Instance
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	return stroke
end

function Builder.padding(pixels: number): Instance
	local padding = Instance.new("UIPadding")
	local offset = UDim.new(0, pixels)
	padding.PaddingTop = offset
	padding.PaddingBottom = offset
	padding.PaddingLeft = offset
	padding.PaddingRight = offset
	return padding
end

function Builder.list(
	direction: Enum.FillDirection,
	spacing: number,
	horizontal: Enum.HorizontalAlignment?,
	vertical: Enum.VerticalAlignment?
): Instance
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = direction
	layout.Padding = UDim.new(0, spacing)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = horizontal or Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = vertical or Enum.VerticalAlignment.Top
	return layout
end

-- Libellé au style du jeu (texte blanc contouré par défaut).
function Builder.label(props: Props): TextLabel
	local defaults: Props = {
		BackgroundTransparency = 1,
		Font = Theme.Font,
		TextColor3 = Theme.Colors.TextLight,
		TextSize = 20,
		TextStrokeTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	}
	for key, value in props do
		defaults[key] = value
	end
	return Builder.new("TextLabel", defaults) :: TextLabel
end

-- Bouton arrondi contouré, sélectionnable à la manette.
function Builder.button(props: Props): TextButton
	local defaults: Props = {
		AutoButtonColor = true,
		BackgroundColor3 = Theme.Colors.Green,
		Font = Theme.Font,
		TextColor3 = Theme.Colors.TextLight,
		TextSize = 22,
		Selectable = true,
	}
	for key, value in props do
		defaults[key] = value
	end
	return Builder.new(
			"TextButton",
			defaults,
			{ Builder.corner(14), Builder.stroke(Theme.Colors.Outline, 3) }
		) :: TextButton
end

return Builder
