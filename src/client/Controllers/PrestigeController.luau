--!strict
-- PrestigeController — contenu du panneau Prestige (UI/ConfirmPanel) : niveau de prestige, conditions (rebirths ET
-- Coins gagnés depuis le dernier prestige) avec progression, Primal Cores obtenus, multiplicateur de prestige futur,
-- revenus juste après, liste exacte perdu / conservé. Confirmation RENFORCÉE : case « J'ai compris » obligatoire et
-- « Confirmer » inactif pendant 3 s. Touche P, manette R1.
-- Le client n'envoie que la révision affichée : le serveur revalide tout (PrestigeService).

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

-- Doit rester aligné sur Resets.prestige (perdu) et sur ce qu'il ne touche pas (conservé).
local LOST_TEXT = "Coins · graines · drones · cultures et sac · parcelles achetées · rebirths du cycle · "
	.. "Mutation Essence · améliorations normales et de rebirth · Coins gagnés des cycles"
local KEPT_TEXT = "Primal Cores · améliorations permanentes · Mutadex · cosmétiques · familiers · "
	.. "Game Passes et achats Robux · statistiques historiques · prestiges réalisés"
local ACKNOWLEDGMENT =
	"J'ai compris : je repars de zéro (rebirths, Essence, parcelles) ; seul le « Conservé » reste."

type Labels = {
	level: TextLabel,
	conditions: TextLabel,
	rebirthsFill: Frame,
	rebirthsValue: TextLabel,
	coinsFill: Frame,
	coinsValue: TextLabel,
	reward: TextLabel,
	multiplier: TextLabel,
	income: TextLabel,
}

local panel: ConfirmPanel.Panel? = nil
local labels: Labels? = nil
local lastPreview: ProgressionMath.PrestigePreview? = nil
local lastEssence: BigNum.BigNum = BigNum.zero()

local PrestigeController = {}

local function computePreview(state: Types.ClientState): ProgressionMath.PrestigePreview
	local partial = {
		progression = {
			rebirths = state.rebirths,
			prestiges = state.prestiges,
			prestigeCoins = BigNum.sanitize(state.prestigeCoins),
		},
	}
	return ProgressionMath.prestigePreview(partial :: any)
end

local function showConfirm()
	local current = panel
	local preview = lastPreview
	if not current or not preview or not preview.eligible then
		return
	end
	current.showConfirm(string.format(
		"Confirmer le prestige n° %d ?\n\nTu perds : %s (dont %d rebirths et %s Mutation Essence).\n\n"
			.. "Tu gagnes : +%s Primal Cores et un multiplicateur de prestige permanent %s "
			.. "(revenus juste après : %s).",
		preview.prestiges + 1,
		LOST_TEXT, -- casse conservée (« Mutation Essence », « Coins »)
		preview.rebirths,
		Format.bigNum(lastEssence),
		Format.bigNum(preview.cores),
		Format.multiplier(preview.nextPrestigeMultiplier),
		Format.multiplier(preview.nextIncomeMultiplier)
	))
end

local function confirmPrestige()
	local state = StateController.Get()
	if state then
		Net.event(Net.Events.PrestigeRequest):FireServer(state.revision)
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
	lastEssence = BigNum.sanitize(state.essence)
	ui.level.Text = string.format(
		"Prestiges réalisés : %d · Primal Cores : %s",
		preview.prestiges,
		Format.bigNum(BigNum.sanitize(state.primalCores))
	)
	ui.conditions.Text =
		string.format("Conditions du prestige n° %d (les deux sont requises) :", preview.prestiges + 1)
	local rebirthsProgress = math.clamp(preview.rebirths / preview.rebirthsRequired, 0, 1)
	ui.rebirthsFill.Size = UDim2.fromScale(rebirthsProgress, 1)
	ui.rebirthsValue.Text =
		string.format("Rebirths depuis le dernier prestige : %d / %d", preview.rebirths, preview.rebirthsRequired)
	ui.coinsFill.Size = UDim2.fromScale(preview.coinsProgress, 1)
	ui.coinsValue.Text = string.format(
		"Coins gagnés depuis le dernier prestige : %s / %s (%d %%)",
		Format.bigNum(preview.prestigeCoins),
		Format.bigNum(preview.coinsRequired),
		math.floor(preview.coinsProgress * 100)
	)
	ui.reward.Text = if preview.eligible
		then "Récompense : +" .. Format.bigNum(preview.cores) .. " Primal Cores (+25 % par rebirth en plus, max ×2)"
		else "Récompense : des Primal Cores, dès les deux conditions remplies"
	ui.multiplier.Text = string.format(
		"Multiplicateur de prestige (permanent) : %s → %s",
		Format.multiplier(preview.prestigeMultiplier),
		Format.multiplier(preview.nextPrestigeMultiplier)
	)
	ui.income.Text = string.format(
		"Revenus : %s maintenant → %s juste après (les rebirths repartent de 0)",
		Format.multiplier(preview.incomeMultiplier),
		Format.multiplier(preview.nextIncomeMultiplier)
	)
	current.setAction(
		if preview.eligible then "Prestige…" else "Conditions non remplies",
		preview.eligible,
		if preview.eligible then Theme.Colors.Violet else Theme.Colors.Grey
	)
	if current.isConfirming() and not preview.eligible then
		current.showInfo()
	end
end

function PrestigeController.Init()
	local hud = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MutationFarmHUD")
	local created = ConfirmPanel.new({
		id = "Prestige",
		title = "Prestige",
		parent = hud,
		size = Vector2.new(640, 520),
		menu = hud:WaitForChild("Menu"),
		menuText = "Prestige",
		menuOrder = 3,
		menuColor = Theme.Colors.Violet,
		keys = { Enum.KeyCode.P, Enum.KeyCode.ButtonR1 },
		keyboardHint = "P",
		gamepadHint = "R1",
		confirmDelay = 3,
		acknowledgment = ACKNOWLEDGMENT,
		onAction = showConfirm,
		onConfirm = confirmPrestige,
	})
	local info = created.info
	local text = ConfirmPanel.text
	local level = text({ Size = UDim2.new(1, 0, 0, 26), TextSize = 21, Parent = info })
	local conditions = text({
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 0, 22),
		TextSize = 16,
		TextColor3 = Theme.Colors.TextMuted,
		Parent = info,
	})
	local rebirthsFill, rebirthsValue = ConfirmPanel.progressBar(info, 56, 26)
	local coinsFill, coinsValue = ConfirmPanel.progressBar(info, 88, 26)
	local reward = text({ Position = UDim2.fromOffset(0, 122), Size = UDim2.new(1, 0, 0, 24), Parent = info })
	local multiplier = text({ Position = UDim2.fromOffset(0, 148), Size = UDim2.new(1, 0, 0, 24), Parent = info })
	local income = text({
		Position = UDim2.fromOffset(0, 174),
		Size = UDim2.new(1, 0, 0, 22),
		TextSize = 16,
		TextColor3 = Theme.Colors.TextMuted,
		Parent = info,
	})
	text({
		Position = UDim2.fromOffset(0, 204),
		Size = UDim2.new(1, 0, 0, 22),
		Text = "Perdu au prestige",
		TextSize = 18,
		TextColor3 = Theme.Colors.Red,
		Parent = info,
	})
	text({
		Position = UDim2.fromOffset(0, 226),
		Size = UDim2.new(1, 0, 0, 58),
		Text = LOST_TEXT,
		TextSize = 16,
		Parent = info,
	})
	text({
		Position = UDim2.fromOffset(0, 288),
		Size = UDim2.new(1, 0, 0, 22),
		Text = "Conservé",
		TextSize = 18,
		TextColor3 = Theme.Colors.Green,
		Parent = info,
	})
	text({
		Position = UDim2.fromOffset(0, 310),
		Size = UDim2.new(1, 0, 0, 40),
		Text = KEPT_TEXT,
		TextSize = 16,
		Parent = info,
	})

	panel = created
	labels = {
		level = level,
		conditions = conditions,
		rebirthsFill = rebirthsFill,
		rebirthsValue = rebirthsValue,
		coinsFill = coinsFill,
		coinsValue = coinsValue,
		reward = reward,
		multiplier = multiplier,
		income = income,
	}
end

function PrestigeController.Start()
	StateController.Changed:Connect(render)
	local state = StateController.Get()
	if state then
		render(state)
	end
end

return PrestigeController
