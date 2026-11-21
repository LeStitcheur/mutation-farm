--!strict
-- ProgressionService — exécution commune des transitions de progression (rebirth, prestige ; Phase 3) :
--   1. UN verrou par joueur partagé par toutes les transitions : jamais deux transitions simultanées, quel que soit
--      leur type (un rebirth et un prestige concurrents sont sérialisés, puis départagés par la révision) ;
--   2. validation, reset et récompense dans UN mutateur synchrone de DataService.Update : aucune récolte, vente ou
--      tâche de drone ne peut s'intercaler, et une révision périmée (requête rejouée) ne paie jamais ;
--   3. remise en état du monde : cases vides replantées, flotte de drones recalculée (les anciennes récoltes et
--      cibles échouent : case vide, culture pas mûre ou parcelle verrouillée) ;
--   4. notification (`onApplied`) puis sauvegarde immédiate. En cas d'échec, l'état en mémoire reste cohérent et
--      l'autosave réessaie : chaque enregistrement contient l'état avant OU après (jamais de récompense sans reset).
-- API : Run, IsValidRevision.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local DataService = require(script.Parent.DataService)
local DroneService = require(script.Parent.DroneService)
local FarmService = require(script.Parent.FarmService)

local MAX_REVISION = 2 ^ 31

local busy: { [Player]: boolean } = {}

local ProgressionService = {}

-- Une transition est-elle en cours pour ce joueur ? (les achats d'améliorations attendent sa fin)
function ProgressionService.IsBusy(player: Player): boolean
	return busy[player] == true
end

-- Révision envoyée par le client : entier fini dans [0, 2^31[.
function ProgressionService.IsValidRevision(value: unknown): boolean
	if typeof(value) ~= "number" then
		return false
	end
	local revision = value :: number
	return revision == revision and revision % 1 == 0 and revision >= 0 and revision < MAX_REVISION
end

-- Exécute une transition. `apply` (pure et synchrone) valide puis applique dans le mutateur et retourne
-- (résultat, nil) ou (nil, échec). `onApplied` est appelé après la remise en état du monde, avant la sauvegarde.
-- Échecs possibles : "busy", "not_loaded" ou celui retourné par `apply`.
function ProgressionService.Run<T>(
	player: Player,
	label: string,
	apply: (Types.PlayerData) -> (T?, string?),
	onApplied: (T) -> ()
): (T?, string?)
	if busy[player] then
		return nil, "busy"
	end
	if not DataService.GetData(player) then
		return nil, "not_loaded"
	end
	busy[player] = true
	local outcome: T? = nil
	local failure: string? = nil
	DataService.Update(player, function(data)
		outcome, failure = apply(data)
	end)
	local result = outcome
	if result == nil then
		busy[player] = nil
		return nil, failure
	end
	-- La donnée est déjà cohérente : une erreur ici ne doit ni bloquer le joueur ni annuler la transition.
	local ok, err = pcall(function()
		FarmService.ReplantEmpty(player)
		DroneService.Refresh(player)
		onApplied(result)
		if not DataService.SaveNow(player) then
			warn(
				string.format(
					"[ProgressionService] %s : sauvegarde immédiate échouée pour %s, l'autosave réessaiera.",
					label,
					player.Name
				)
			)
		end
	end)
	busy[player] = nil
	if not ok then
		warn(string.format("[ProgressionService] %s appliqué pour %s, suite en erreur : %s", label, player.Name, err))
	end
	return result, nil
end

function ProgressionService.Init()
	Players.PlayerRemoving:Connect(function(player: Player)
		busy[player] = nil
	end)
end

function ProgressionService.Start() end

return ProgressionService
