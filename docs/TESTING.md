# MUTATION FARM — Tests et QA

## 1. Vérification automatique (à lancer avant chaque commit)

```powershell
pwsh scripts/check.ps1        # vérifie (échoue si le formatage est incorrect)
pwsh scripts/check.ps1 -Fix   # applique StyLua puis vérifie le reste
```

| Étape | Outil | Ce qui est garanti |
|---|---|---|
| Sourcemap | `rojo sourcemap` | arbre DataModel connu de luau-lsp |
| Formatage | StyLua 2.6 | style homogène (tabs, 120 colonnes) |
| Lint | Selene 0.32 (std `luau` + `roblox_lite.yml`) | variables inconnues, ombres, tables mixtes… |
| Typage | luau-lsp 1.70 `analyze`, mode `--!strict`, définitions Roblox officielles | erreurs de types, API Roblox mal utilisées |
| Tests unitaires | Lune 0.11 + `tests/TestEZLite.luau` | logique pure : BigNum, économie, croissance, mutations, schéma de données, resets, géométrie |
| Build | `rojo build` → `build/MutationFarm.rbxlx` | le projet est constructible |

### Tests unitaires
- Specs : `tests/specs/*.spec.luau`, syntaxe **TestEZ** (`describe`/`it`/`expect(...).to.equal`).
- Le runner `tests/run.luau` simule `game:GetService`, `script` et `require(Instance)` à partir de l'arbre Rojo :
  seuls les modules **purs** (`src/shared/**`, `src/server/Config/**`) sont testables hors Studio.
- Ajouter un test : créer `tests/specs/<Nom>.spec.luau` retournant `function() ... end`.
- Les mêmes specs pourront tourner avec le vrai TestEZ en Studio (Phase 7, via Wally + `test.project.json`).

### Ce qui n'est PAS couvert automatiquement
Services serveur (DataStore, remotes, parcelles), contrôleurs client et rendu : ils nécessitent Roblox Studio.
→ checklist manuelle ci-dessous, et Studio MCP (§3) pour l'automatiser.

## 2. Checklist manuelle Studio (Phase 1)

Préparation : `rojo serve` + plugin Rojo connecté (ou ouvrir `build/MutationFarm.rbxlx`).
Pour tester la persistance : *Game Settings › Security › Enable Studio Access to API Services* (place publiée requise).
Sinon le serveur affiche `[DataStore] … Données en MÉMOIRE` et rien n'est sauvegardé (comportement attendu).

| # | Scénario | Résultat attendu |
|---|---|---|
| 1 | Play (F5) | Écran « MUTATION FARM / Chargement… » puis disparition ; téléportation devant sa parcelle ; panneau « Ferme de <nom> » ; HUD Coins 0, Sac 0/40 |
| 2 | Observer les 9 cases | 9 carottes poussent (petites → grandes en 6 s), étincelles à maturité |
| 3 | S'approcher d'une carotte mûre | Invite « Récolter / Carotte » (E, tactile, manette X) |
| 4 | Récolter < 1,5 s après maturité | Texte « PARFAIT ! +5 », Coins +5, Sac +1, carotte replantée petite |
| 5 | Récolter tard (> 5 s) | Texte « +1 Carotte », pas de bonus |
| 6 | Remplir le sac (40) | Invite « Sac plein ! », barre rouge, notification « Sac plein ! Va vendre au marché. » |
| 7 | Marché → « Vendre tout » | Notification « 40 récolte(s) vendue(s) : +400 Coins », sac 0/40 |
| 8 | Vendre avec un sac vide | Notification info « Ton sac est vide… » |
| 9 | Bouton **Graines** / touche G / manette Y | Panneau 7 plantes : Carotte « En culture », Tomate « Débloquer 750 » (gris si < 750), autres « Verrouillée » |
| 10 | Débloquer la Tomate avec ≥ 750 Coins | Coins −750, notification, Tomate « En culture » ; les cases deviennent des tomates après récolte |
| 11 | « Planter » Carotte | Carotte redevient « En culture » |
| 12 | Stop puis Play (API activée) | Coins, sac, graines et cultures restaurés ; les cultures ont continué de pousser |
| 13 | 2 joueurs (Test › Clients and Servers, 2 joueurs) | Deux parcelles distinctes ; chacun voit les plantes de l'autre mais ne peut récolter que les siennes |
| 14 | Émulateur mobile (téléphone) | HUD lisible, pas de chevauchement, invites utilisables au toucher |
| 15 | Manette | Panneau navigable (sélection auto sur le 1er bouton), B ferme le panneau |
| 16 | Exploit : exécuter `ReplicatedStorage.Remotes.HarvestRequest:FireServer("main:1")` en boucle depuis la console client | Aucun gain hors cases mûres, débit limité à 8/s, aucune erreur serveur |

## 3. Studio MCP (opération manuelle, recommandée)

Roblox Studio est installé avec son serveur MCP (`%LOCALAPPDATA%\Roblox\mcp.bat` → `StudioMCP.exe`).
Pour permettre à Claude d'inspecter et de tester le jeu dans Studio :
1. Ouvrir Studio et le place, activer le serveur MCP dans les réglages de l'Assistant Studio.
2. Enregistrer le serveur dans Claude Code (configuration persistante, à faire soi-même) :
   ```powershell
   claude mcp add roblox-studio -- "$env:LOCALAPPDATA\Roblox\mcp.bat"
   ```
3. Redémarrer la session Claude Code. Vérifier la documentation Roblox pour les arguments éventuels.
