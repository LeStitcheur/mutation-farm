--!strict
-- RebirthController — contenu du panneau Rebirth (UI/ConfirmPanel) : rebirths réalisés, seuil et progression (Coins
-- GAGNÉS pendant le cycle), récompense, multiplicateur de revenu actuel et futur (rebirth × prestige), liste exacte
-- perdu / conservé, confirmation en deux étapes (« Confirmer » actif après 1,5 s). Touche R, manette L1.
-- Le client n'envoie que la révision affichée : le serveur revalide tout (RebirthService).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local BigNum = require(Shared.Util.BigNum)
local Format = require(Shared.Util.Format)
local ProgressionMath = require(Shared.Util.ProgressionMath)
local Net = require(Shared.Net)
local StateController = require(script.Parent.StateController)
local ConfirmPanel = require(script.Parent.Parent.UI.ConfirmPanel)
local Theme = require(script.Parent.Parent.UI.Theme)

-- Doit rester aligné sur Resets.resetEconomy (perdu) et sur ce qu'il ne touche pas (conservé).
local LOST_TEXT = "Coins · graines débloquées · améliorations normales · drones · cultures plantées et sac"
local KEPT_TEXT =
	"Parcelles · Mutation Essence · améliorations de rebirth · Mutadex · cosmétiques et achats · statistiques"

type Labels = {
	rebirths: TextLabel,
	threshold: TextLabel,
	fill: Frame,
	progress: TextLabel,
	reward: TextLabel,
	multiplier: TextLabel,
}

local panel: ConfirmPanel.Panel? = nil
local labels: Labels? = nil
local lastPreview: ProgressionMath.RebirthPreview? = nil

local RebirthController = {}

local function computePreview(state: Types.ClientState): ProgressionMath.RebirthPreview
	local partial = {
		progression = {
			rebirths = state.rebirths,
			prestiges = state.prestiges,
			cycleCoins = BigNum.sanitize(state.cycleCoins),
		},
	}
	return ProgressionMath.rebirthPreview(partial :: any)
end

local function showConfirm()
	local current = panel
	local preview = lastPreview
	if not current or not preview or not preview.eligible then
		return
	end
	current.showConfirm(string.format(
		"Confirmer le rebirth n° %d ?\n\nTu perds : %s.\n\nTu gagnes : +%s Mutation Essence et des revenus %s.",
		preview.rebirths + 1,
		LOST_TEXT, -- casse conservée (« Coins »)
		Format.bigNum(preview.essence),
		Format.multiplier(preview.nextMultiplier)
	))
end

local function confirmRebirth()
	local state = StateController.Get()
	if state then
		Net.event(Net.Events.RebirthRequest):FireServer(state.revision)
	end
end

local function render(state: Types.ClientState)
	local current = panel
	local ui = labels
	if not current or not ui then
		return
	end
	local preview = computePreview(state)
	lastPreview = preview
	ui.rebirths.Text = string.format("Rebirths réalisés : %d", preview.rebirths)
	ui.threshold.Text = string.format(
		"Rebirth n° %d : gagne %s Coins pendant ce cycle (ventes et bonus ; le solde actuel ne compte pas).",
		preview.rebirths + 1,
		Format.bigNum(preview.threshold)
	)
	ui.fill.Size = UDim2.fromScale(preview.progress, 1)
	ui.progress.Text = string.format(
		"%s / %s (%d %%)",
		Format.bigNum(preview.cycleCoins),
		Format.bigNum(preview.threshold),
		math.floor(preview.progress * 100)
	)
	ui.reward.Text = if preview.eligible
		then "Récompense : +" .. Format.bigNum(preview.essence) .. " Mutation Essence"
		else "Récompense : de la Mutation Essence, dès le seuil atteint"
	ui.multiplier.Text = string.format(
		"Revenus : %s maintenant → %s après ce rebirth",
		Format.multiplier(preview.multiplier),
		Format.multiplier(preview.nextMultiplier)
	)
	current.setAction(
		if preview.eligible then "Rebirth…" else "Seuil non atteint",
		preview.eligible,
		if preview.eligible then Theme.Colors.Gold else Theme.Colors.Grey
	)
	if current.isConfirming() and not preview.eligible then
		current.showInfo()
	end
end

function RebirthController.Init()
	local hud = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MutationFarmHUD")
	local created = ConfirmPanel.new({
		id = "Rebirth",
		title = "Rebirth",
		parent = hud,
		size = Vector2.new(620, 480),
		menu = hud:WaitForChild("Menu"),
		menuText = "Rebirth",
		menuOrder = 2,
		menuColor = Theme.Colors.Gold,
		keys = { Enum.KeyCode.R, Enum.KeyCode.ButtonL1 },
		keyboardHint = "R",
		gamepadHint = "L1",
		confirmDelay = 1.5,
		onAction = showConfirm,
		onConfirm = confirmRebirth,
	})
	local info = created.info
	local text = ConfirmPanel.text
	local rebirths = text({ Size = UDim2.new(1, 0, 0, 26), TextSize = 21, Parent = info })
	local threshold = text({
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, 44),
		TextSize = 16,
		TextColor3 = Theme.Colors.TextMuted,
		Parent = info,
	})
	local fill, progress = ConfirmPanel.progressBar(info, 78, 30)
	local reward = text({ Position = UDim2.fromOffset(0, 116), Size = UDim2.new(1, 0, 0, 26), Parent = info })
	local multiplier = text({ Position = UDim2.fromOffset(0, 144), Size = UDim2.new(1, 0, 0, 26), Parent = info })
	text({
		Position = UDim2.fromOffset(0, 180),
		Size = UDim2.new(1, 0, 0, 22),
		Text = "Perdu au rebirth",
		TextSize = 18,
		TextColor3 = Theme.Colors.Red,
		Parent = info,
	})
	text({
		Position = UDim2.fromOffset(0, 202),
		Size = UDim2.new(1, 0, 0, 40),
		Text = LOST_TEXT,
		TextSize = 16,
		Parent = info,
	})
	text({
		Position = UDim2.fromOffset(0, 246),
		Size = UDim2.new(1, 0, 0, 22),
		Text = "Conservé",
		TextSize = 18,
		TextColor3 = Theme.Colors.Green,
		Parent = info,
	})
	text({
		Position = UDim2.fromOffset(0, 268),
		Size = UDim2.new(1, 0, 0, 40),
		Text = KEPT_TEXT,
		TextSize = 16,
		Parent = info,
	})

	panel = created
	labels = {
		rebirths = rebirths,
		threshold = threshold,
		fill = fill,
		progress = progress,
		reward = reward,
		multiplier = multiplier,
	}
end

function RebirthController.Start()
	StateController.Changed:Connect(render)
	local state = StateController.Get()
	if state then
		render(state)
	end
end

return RebirthController
