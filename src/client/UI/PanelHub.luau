--!strict
-- PanelHub — coordination des panneaux du HUD : un seul panneau ouvert à la fois, et chat Roblox masqué tant qu'un
-- panneau est ouvert (il chevauche le coin haut gauche), puis remis EXACTEMENT dans son état précédent.
-- CoreGuiType.Chat couvre l'ancien chat et TextChatService ; les configurations de fenêtre et de saisie sont aussi
-- coupées (PC, mobile, console). Changer de panneau ne réaffiche pas le chat entre les deux.

local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local PanelHub = {}

local current: string? = nil
local closers: { [string]: () -> () } = {}
local chatRestore: { coreGui: boolean, window: boolean?, inputBar: boolean? }? = nil

local function setChatSuppressed(suppressed: boolean)
	local window = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
	local inputBar = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
	if suppressed then
		if chatRestore then
			return
		end
		chatRestore = {
			coreGui = StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.Chat),
			window = if window then window.Enabled else nil,
			inputBar = if inputBar then inputBar.Enabled else nil,
		}
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, false)
		if window then
			window.Enabled = false
		end
		if inputBar then
			inputBar.Enabled = false
		end
		return
	end
	local restore = chatRestore
	if not restore then
		return
	end
	chatRestore = nil
	if window and restore.window ~= nil then
		window.Enabled = restore.window
	end
	if inputBar and restore.inputBar ~= nil then
		inputBar.Enabled = restore.inputBar
	end
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, restore.coreGui)
end

-- `close` ferme le panneau `id` (il doit appeler PanelHub.closed(id)).
function PanelHub.register(id: string, close: () -> ())
	closers[id] = close
end

-- Le panneau `id` vient de s'ouvrir : ferme le précédent et masque le chat.
function PanelHub.opened(id: string)
	if current == id then
		return
	end
	local previous = current
	current = id
	if previous then
		local close = closers[previous]
		if close then
			close()
		end
	end
	setChatSuppressed(true)
end

-- Le panneau `id` vient de se fermer : restaure le chat s'il était le panneau ouvert.
function PanelHub.closed(id: string)
	if current ~= id then
		return
	end
	current = nil
	setChatSuppressed(false)
end

function PanelHub.isOpen(id: string): boolean
	return current == id
end

return PanelHub
