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

### 2.1 Dernière validation — 2026-11-20 (Studio MCP, Play solo, accès API désactivé)

Place `build/MutationFarm.rbxlx` (scripts identiques à `src/`), pilotée par Claude via les outils `roblox-studio`
(`start_stop_play`, `character_navigation`, touches E / G / ButtonY / ButtonB, clics, `execute_luau` côté Client,
`screen_capture`). Toute la boucle a été rejouée sur le build corrigé. Console : aucune erreur serveur ni client,
seulement l'avertissement attendu `[DataStore] … Données en MÉMOIRE`.

| # | Statut | Constat |
|---|---|---|
| 1 | ✅ | HUD « 0 » / « Sac 0/40 », téléportation devant la parcelle, panneau « Ferme de LeStitcheurFou ». Écran de chargement détruit (affichage trop bref pour être capturé) |
| 2 | ✅ | 9 carottes ; carotte replantée mesurée à 0,9 → 1,8 → 2,5 → 3,0 → 3,2 studs (0,3 s → 6,2 s), étincelles à maturité |
| 3 | ✅ | `PromptShown` « Récolter / Carotte » sur la case la plus proche (E) |
| 4 | ✅ | « PARFAIT ! +5 », Coins +5, Sac +1, carotte replantée petite |
| 5 | ✅ | Récolte tardive : « +1 Carotte », pas de bonus ; récolte à +3 s : « Bien ! +2 » |
| 6 | ✅ | Invites « Sac plein ! » ×9, barre rouge, notification « Sac plein ! Va vendre au marché. » |
| 7 | ✅ | « 40 récolte(s) vendue(s) : +400 Coins », Sac 0/40 |
| 8 | ✅ | « Ton sac est vide : récolte des plantes mûres ! » (info) |
| 9 | ✅ | Touche G : 7 plantes, Carotte « En culture », Tomate « Débloquer 750 » grise sous 750 (clic sans effet), autres « Verrouillée » |
| 10 | ✅ | 750 Coins gagnés en jouant (aucun crédit de test) ; Coins −750, notification, Tomate « En culture », Maïs « Débloquer 6.00K » ; case récoltée → tomate (12 s) |
| 11 | ✅ | « Planter » Carotte → Carotte « En culture » |
| 12 | ⛔ non vérifiable | Place non publiée (PlaceId 0) : pas d'accès DataStore. Repli mémoire confirmé (profil remis à zéro après Stop/Play, attendu) |
| 13 | ⛔ non vérifiable | Le MCP ne lance qu'un Play solo (pas de « Clients and Servers ») |
| 14 | ⛔ non vérifiable | Émulateur d'appareil non pilotable par le MCP ; HUD lisible dans un viewport 675×613 |
| 15 | ◐ partiel | ButtonY ouvre / ButtonB ferme le panneau ; sélection auto du 1er bouton non testable (aucune manette, `LastInputType` = Keyboard) |
| 16 | ✅ | 200 requêtes sur une case → 1 seule récolte ; `nil`, nombre, table, chaîne de 5000 car., `main:99` : ignorés sans erreur ; case à 22 studs refusée ; 8 jetons puis refus, recharge en 1 s |

Défauts trouvés puis corrigés :
- **Ferme enfouie sous la plaque de base** : Rojo sérialise `Position`, que Roblox ignore au chargement d'un `.rbxlx`
  → Baseplate (1024×4) restée centrée en y=0, recouvrant plateforme, cases et bordures. Corrigé dans
  `default.project.json` (propriété `CFrame` explicite pour Baseplate et SpawnLocation). Règle : toujours `CFrame`.
- **Notifications tronquées** : le texte de déblocage tient sur 2 lignes (36 px) pour 30 px disponibles → « …tes
  cultures à ». Corrigé dans `HudController` (`AutomaticSize.Y` sur le toast et son libellé).

Observation non corrigée : au survol de la souris, la fenêtre de chat Roblox (coin haut gauche) chevauche la moitié
gauche du panneau Graines ouvert.

## 3. Studio MCP (opération manuelle, recommandée)

Roblox Studio est installé avec son serveur MCP (`%LOCALAPPDATA%\Roblox\mcp.bat` → `StudioMCP.exe`).
Pour permettre à Claude d'inspecter et de tester le jeu dans Studio :
1. Ouvrir Studio et le place, activer le serveur MCP dans les réglages de l'Assistant Studio.
2. Enregistrer le serveur dans Claude Code (configuration persistante, à faire soi-même) :
   ```powershell
   claude mcp add roblox-studio -- "$env:LOCALAPPDATA\Roblox\mcp.bat"
   ```
3. Redémarrer la session Claude Code. Vérifier la documentation Roblox pour les arguments éventuels.

Limites constatées des outils (2026-11-20) :
- `screen_capture` ne rend pas les `BillboardGui` `AlwaysOnTop` (invites ProximityPrompt, textes « PARFAIT ! »,
  bulles de chat) : les vérifier par l'état des instances (`PromptShown`, `PlayerGui.ProximityPrompts`).
- `execute_luau` tourne dans une VM séparée : `require` d'un service renvoie une **copie neuve** du module (état vide).
  Lire l'état joueur via le HUD (répliqué par `StateSync`) ou les attributs des cases `FarmTile`.
- Sans plugin Rojo dans Studio, un correctif n'est visible qu'après `scripts/check.ps1` puis réouverture de
  `build/MutationFarm.rbxlx` (fermer l'ancienne place **sans enregistrer**, sinon elle écrase le build).
