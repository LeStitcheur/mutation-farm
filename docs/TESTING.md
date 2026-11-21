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
| Tests unitaires | Lune 0.11 + `tests/TestEZLite.luau` | logique pure : BigNum, économie, croissance, mutations, schéma de données, resets, géométrie, verrou de session (simulation multi-serveurs), attribution des parcelles (isolation) |
| Build | `rojo build` → `build/MutationFarm.rbxlx` | le projet est constructible |

### Tests unitaires
- Specs : `tests/specs/*.spec.luau`, syntaxe **TestEZ** (`describe`/`it`/`expect(...).to.equal`).
- Le runner `tests/run.luau` simule `game:GetService`, `script` et `require(Instance)` à partir de l'arbre Rojo :
  seuls les modules **purs** (`src/shared/**`, `src/server/Config/**`) sont testables hors Studio.
- Ajouter un test : créer `tests/specs/<Nom>.spec.luau` retournant `function() ... end`.
- Les mêmes specs pourront tourner avec le vrai TestEZ en Studio (Phase 7, via Wally + `test.project.json`).

### Ce qui est couvert hors Studio pour la sauvegarde et le multijoueur
- `SessionLock.spec` (13 tests) : acquisition, attente, reprise d'un verrou périmé, refus d'écraser le verrou d'un
  autre serveur, libération ; simulation multi-serveurs sur un store mémoire à sémantique `UpdateAsync` (progression
  conservée d'un serveur à l'autre, second serveur bloqué, serveur « gelé » empêché d'écrire après reprise).
  Contrôle de mutation : retirer la vérification de propriété dans `SessionLock.write` fait échouer 2 tests.
- `SlotAllocator.spec` (7 tests) + `FarmLayout.spec` : un emplacement distinct par joueur, 9ᵉ joueur refusé, jamais deux
  parcelles pour un joueur, libération tardive sans effet sur le nouvel occupant, socles des 8 emplacements disjoints.

### Ce qui est couvert hors Studio pour les mutations (Phase 2, jalon A)
- `Mutations.spec` (13 tests) : six mutations aux noms, multiplicateurs et probabilités exacts du cahier des charges ;
  exclusivité (un seul résultat connu par tirage) ; **distribution statistique** : χ² à 6 ddl < 22,46 (α = 0,001) sur
  3 × 400 000 tirages à graines fixes, chaque mutation observée (Divine comprise), test de sensibilité (Divine ×10
  détectée) ; multiplicateurs appliqués à la vente (Carotte, Tomate, sac mixte = 2 020) ; bonus de précision sur la
  valeur de base ; sauvegarde/restauration de chaque mutation (case + sac), mutation inconnue retirée.
- `MutationRoll.spec` (10 tests) : bornes cumulées, balayage déterministe exact, E(1) = 1,5051, chance ×3.
  Contrôle de mutation : inverser les poids Astrale/Divine fait échouer 3 tests.

### Ce qui est couvert hors Studio pour les drones (Phase 2, jalon B)
- `HarvestRules.spec` (9 tests) : validations communes joueur/drone (case verrouillée ou mal formée, vide, pas mûre,
  sac plein sans perte) ; bonus de précision pour le joueur seulement ; **concurrence** joueur + drone au même instant
  = une récolte ; **duplication** : 100 tentatives alternées sur un cycle = un seul objet vendu ; reprise après vente
  avec la mutation conservée. Contrôle de mutation : ne plus vider la case dans `apply` fait échouer 3 tests.
- `Drones.spec` (13 tests) : configuration valide et gelée (dont `graceDelay ≥ GoodWindow`) ; **délai de grâce**
  (plante ignorée à 4,99 s de maturité, visée à 5 s) ; prix 1 500 / 3 750 / 9 375 ; achat refusé (type inconnu,
  fonds, maximum) ; flotte plafonnée ; points d'attente centrés et espacés ; portée (parcelle principale couverte,
  extensions non) ; station sur le socle et à l'écart ; cibles (mûres, plus ancienne d'abord, capacité, réservées,
  hors portée, parcelle verrouillée) ; sauvegarde/restauration et assainissement de `machines.drones`.
- `DroneEconomy.spec` (7 tests) : simulation 10 min Carotte/Tomate (§ ECONOMY 7) — sac ≤ 40, aucun bonus drone,
  récoltes ≤ production, ventes jamais réduites, drones seuls croissants, rentabilité du premier drone, perte ≤ 1 %
  pour un joueur attentif (délai de grâce). Contrôle de mutation : `graceDelay = 0` fait échouer 3 tests.

### Ce qui n'est PAS couvert automatiquement
Entrées/sorties DataStore réelles, remotes, contrôleurs client et rendu : ils nécessitent Roblox Studio.
→ checklist ci-dessous, déroulée via Studio MCP (§3) ; ce qui exige un humain reste marqué comme tel.

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
| 17 | Ouvrir le panneau Graines (G, Y, bouton) puis le fermer (G, B, X, bouton) | Chat Roblox masqué tant que le panneau est ouvert, puis restauré dans son état précédent |

### 2.1 Dernière validation — 2026-11-20, 2ᵉ passe (Studio MCP, Play solo, accès API désactivé)

Place `build/MutationFarm.rbxlx` (38 scripts identiques à `src/`, `TextChatService`), pilotée par Claude via les
outils `roblox-studio` (`start_stop_play`, `character_navigation`, touches E / G / ButtonY / ButtonB, clics,
`execute_luau` Client et Server, `screen_capture`). Toute la boucle a été rejouée après les correctifs.
Console : aucune erreur serveur ni client, seulement l'avertissement attendu `[DataStore] … Données en MÉMOIRE`.

**Bilan : 13 vérifiées (1-11, 16, 17), 2 partielles (13 simulée, 15), 2 non vérifiables (12, 14) sur 17.**
(La 1ʳᵉ passe annonçait « 11/16 » : erreur de décompte, c'était 12/16.)

| # | Statut | Constat |
|---|---|---|
| 1 | ✅ | HUD « 0 » / « Sac 0/40 », téléportation devant la parcelle, panneau « Ferme de LeStitcheurFou ». Écran de chargement détruit (affichage trop bref pour être capturé) |
| 2 | ✅ | 9 carottes ; carotte replantée mesurée à 0,9 → 2,5 → 3,2 studs (0,3 s → 3 s → 6,2 s), étincelles à maturité |
| 3 | ✅ | `PromptShown` « Récolter / Carotte » sur la case la plus proche (E) |
| 4 | ✅ | « PARFAIT ! +5 », Coins +5, Sac +1, carotte replantée petite |
| 5 | ✅ | Récolte tardive : « +1 Carotte », pas de bonus ; récolte à +3 s : « Bien ! +2 » |
| 6 | ✅ | Invites « Sac plein ! » ×9, barre rouge, notification « Sac plein ! Va vendre au marché. » |
| 7 | ✅ | « 40 récolte(s) vendue(s) : +400 Coins », Sac 0/40 |
| 8 | ✅ | « Ton sac est vide : récolte des plantes mûres ! » (info) |
| 9 | ✅ | G : 7 plantes, Carotte « En culture », Tomate « Débloquer 750 » grise sous 750 (clic sans effet), autres « Verrouillée » |
| 10 | ✅ | 750 Coins gagnés en jouant (aucun crédit de test) ; Coins −750, notification complète sur 2 lignes, Tomate « En culture », Maïs « Débloquer 6.00K » ; case récoltée → tomate (12 s) |
| 11 | ✅ | « Planter » Carotte → Carotte « En culture » |
| 12 | ⛔ non vérifiable | Place non publiée (PlaceId 0) : pas d'accès DataStore. Repli mémoire confirmé (profil remis à zéro après Stop/Play, attendu). Règles du verrou couvertes en Lune (§1) |
| 13 | ◐ simulé | Pas de 2ᵉ client possible (Play solo). Case factice mûre créée côté **serveur** avec un autre `OwnerUserId` : sa plante est rendue chez le joueur, aucune invite de récolte, E sans effet ; `HarvestRequest("main:1")` vise la case `main:1` **du demandeur** (refusée, hors portée) et la case factice reste intacte. Attribution des parcelles couverte en Lune (§1). **Test réel à 2 clients restant** |
| 14 | ⛔ non vérifiable | Émulateur d'appareil non pilotable par le MCP. Mesure à 675×613 : bas du chat (barre de saisie) y≈194, haut du bouton Graines y≈208 (marge 14 px) — sur un écran plus bas, chat ouvert, ils peuvent se chevaucher : **à contrôler dans l'émulateur** |
| 15 | ◐ partiel | ButtonY ouvre / ButtonB ferme le panneau (et restaurent le chat) ; sélection auto du 1er bouton non testable (aucune manette, `LastInputType` = Keyboard) |
| 16 | ✅ | 200 requêtes sur une case mûre → 1 seule récolte ; `nil`, nombre, table, chaîne de 5000 car., `main:99` ignorés sans erreur ; case à 22 studs refusée ; seau de 8 jetons vidé → 6 cases mûres à portée refusées, puis récoltées après 1,2 s de recharge |
| 17 | ✅ | Panneau ouvert (G, ButtonY, bouton Graines) : `CoreGuiType.Chat`, fenêtre et barre de saisie désactivées, **0** élément du chat affiché (26 panneau fermé). Fermé (G, ButtonB, bouton X, bouton Graines) : état restauré. Une fenêtre de chat désactivée avant l'ouverture le reste après la fermeture |

Défauts trouvés puis corrigés (1ʳᵉ et 2ᵉ passes) :
- **Ferme enfouie sous la plaque de base** : Rojo sérialise `Position`, que Roblox ignore au chargement d'un `.rbxlx`
  → Baseplate (1024×4) restée centrée en y=0, recouvrant plateforme, cases et bordures. Corrigé dans
  `default.project.json` (propriété `CFrame` explicite pour Baseplate et SpawnLocation). Règle : toujours `CFrame`.
- **Notifications tronquées** : le texte de déblocage tient sur 2 lignes (36 px) pour 30 px disponibles → « …tes
  cultures à ». Corrigé dans `HudController` (`AutomaticSize.Y` sur le toast et son libellé).
- **Ancien chat** : sans `ChatVersion` dans le projet, la place tournait sous `LegacyChatService` (abandonné par
  Roblox ; les jeux publiés utilisent `TextChatService`). `default.project.json` fixe désormais `TextChatService`.
- **Chat sur le panneau Graines** : le chat (x 8→278, y 12→194) recouvrait le coin haut gauche du panneau
  (x 151→523, y 118→379). `HudController` masque le chat pendant que le panneau est ouvert et restaure l'état exact.

### 2.2 Phase 2, jalon A (mutations) — validation Studio MCP du 2026-11-20 (Play solo, API désactivée)

Deux sessions sur le build de la branche `phase-2/mutations-automation` (39 scripts identiques à `src/`).

| Contrôle | Statut | Constat |
|---|---|---|
| Tirage serveur en jeu | ✅ | 9 tirages initiaux : 3 Brillantes ; puis Cristallisée et Radioactive obtenues naturellement |
| Distribution du module réel (`Random` Roblox) | ✅ | `MutationService.Roll()` × 200 000 dans Studio : χ² = 3,33 (< 22,46) ; Brillante 12,07 %, Géante 4,96 %, Cristallisée 1,52 %, Radioactive 0,40 %, Astrale 0,087 %, Divine 0,009 %. (Un relevé de 41 replantations sans Brillante relevait du hasard) |
| Sac et vente | ✅ | Composition du sac reçue du serveur (`StateSync`) = résultats de récolte ; ventes exactes : +690 (35 normales, 3 Brillantes, 1 Cristallisée, 1 Radioactive) et +230 (17 normales, 3 Brillantes) |
| Invite et texte flottant | ✅ | « Carotte · Brillante ×2 » ; « Cristallisée ×8 / PARFAIT ! +5 » etc. dans la couleur de la mutation, accents corrects |
| Notification ≥ ×8 | ✅ | « Mutation Radioactive ×20 récoltée : Carotte », « Mutation Cristallisée ×8 récoltée : Carotte » |
| Anti-triche | ✅ | Attribut `Mutation` mis à « divine » **côté client** : invite locale « Divine ×150 », mais résultat serveur `carrot|normal` et sac normal |
| Visuels des 6 mutations | ✅ | Aperçu forcé par attribut serveur (sans toucher aux données) : Brillante or mat + aura, Géante ×1,5, Cristallisée verre cyan, Radioactive vert néon + lumière, Astrale violet néon ×1,1 + lumière, Divine or néon ×1,2 + halo + lumière |
| Console | ✅ | Aucune erreur serveur ni client |
| Persistance réelle des mutations | ⛔ non vérifiable | Pas d'accès DataStore (place non publiée) ; couvert en Lune (`Mutations.spec`, `SessionLock.spec`) |

Défauts trouvés puis corrigés pendant le jalon : Brillante blanc bleuté (reflets du ciel) → or mat `#FFD23F` ;
Cristallisée et Astrale délavées par le néon → couleurs 3D saturées propres aux styles ; Divine trop proche de la
Brillante → or néon + halo ; « CRISTALLISéE » (`string.upper` ne gère pas l'UTF-8) → nom affiché tel quel.

### 2.3 Phase 2, jalon B (drones) — validation Studio MCP du 2026-11-20 (Play solo, API désactivée)

Build de la branche `phase-2/mutations-automation` (44 scripts identiques à `src/`, 8 services, console sans erreur).
Coins gagnés en jouant (aucun crédit de test).

| Contrôle | Statut | Constat |
|---|---|---|
| Station d'achat | ✅ | Pavé « DRONES » à l'avant gauche ; invite « Acheter : Drone récolteur / 1.50K Coins · 0/3 », appui 0,4 s |
| Achat sans fonds | ✅ | « Pas assez de Coins pour ce drone. », aucun drone créé |
| Achat n°1 puis n°2 | ✅ | 1 660 → 160 puis 4 670 → 928 (−1 500, −3 750) ; « Drone récolteur acheté ! (1/3) » / « (2/3) » ; invite « 3.75K · 1/3 » puis « 9.37K · 2/3 » ; flotte réorganisée (x = −198 et −192, centrée), 2 modèles client exactement |
| Récolte automatique | ✅ | Joueur à 40 studs : 1 drone = 4 récoltes en 17 s (≈ 4,1 s), 2 drones = 10 récoltes en 20 s sur des cases distinctes ; palier normal, **bonus 0** ; mutations conservées dans le sac |
| Délai de grâce (5 s) | ✅ | Ferme vidée à la main puis laissée au drone : 1ʳᵉ récolte drone à 6,55 s de maturité (attendu ≥ 5 s et < 9,25 s), suivante à 10,6 s ; avec arriéré, âges ≥ 19,7 s ; joueur à côté d'une plante mûre, drone actif : « Parfait » (+5) à 0,42 s |
| Concurrence joueur/drone | ✅ | Rafale de requêtes manuelles sur les cases mûres pendant que le drone travaille : 26 résultats (25 joueur, 1 drone) = +26 au sac ; récoltes = replantations sur chacune des 9 cases (0 écart) |
| Sac plein | ✅ | Statut `bag_full`, bulle « Sac plein ! » au-dessus du drone, aucune récolte, notification « Tes drones attendent : sac plein ! Va vendre au marché. » ; reprise dès la vente (statut `working`) |
| Vente avec récoltes de drone | ✅ | Sac serveur 33 normales + 6 Brillantes + 1 Géante → « +490 Coins » (attendu 490) |
| Anti-triche manuel avec drones actifs | ✅ | 200 requêtes + entrées invalides sur une case mûre → 1 récolte, 1 replantation |
| Non-régression | ✅ | Récolte, vente, déblocage Tomate (« Tomate débloquée ! … »), mutations, drones sur Tomate |
| Station réservée au propriétaire | ⛔ non vérifiable | Exige un 2ᵉ joueur ; vérifié à la lecture du code (`buyer ~= player` → refus) |
| 3ᵉ drone / invite « Complet » | ✅ (2026-11-21) | Coins gagnés en jouant (Tomate + drones). À 8 020 : « Pas assez de Coins pour ce drone. » ; solde exact 11 089 → 1 714 (−9 375) ; « Drone récolteur acheté ! (3/3) » ; invite « Complet / Drone récolteur · 3/3 » ; 3 drones centrés (x = −201, −195, −189), 3 modèles client ; 4ᵉ tentative : « Tu possèdes déjà le maximum de ce drone. », solde inchangé |
| Persistance réelle de la flotte | ⛔ non vérifiable | Pas d'accès DataStore ; couvert en Lune (`Drones.spec`, `SessionLock.spec`) |
| Station au toucher / à la manette | ⛔ non vérifiable | ProximityPrompt standard (tactile et ButtonX natifs) ; à contrôler avec l'émulateur et une vraie manette |

### 2.4 Protocole des validations restantes (intervention humaine requise)

Chaque ligne : préparation **par un humain** dans Studio, puis contrôles (à la main ou par Claude via Studio MCP si les
fenêtres de test sont visibles par le MCP). Ne cocher qu'après exécution réelle.

| Validation | Préparation (humain) | Contrôles et résultat attendu |
|---|---|---|
| **2 joueurs réels** (ligne 13 + station) | *Test › Clients and Servers*, 2 joueurs, Start | Deux parcelles distinctes (`Plot_1`, `Plot_2`) ; chacun voit plantes et drones de l'autre ; aucune invite de récolte sur la parcelle de l'autre ; joueur B à la station de A : « Cette station appartient à une autre ferme. », solde de B inchangé ; les drones de A ne récoltent que chez A (sac de B inchangé) |
| **Reconnexion (même serveur)** | Pendant le test à 2 joueurs : fermer la fenêtre du joueur B puis *Add Player* | B retrouve Coins, sac, graines, drones et cultures (store mémoire du serveur) ; un seul jeu de drones ; aucune duplication de Coins ni d'objets |
| **Sauvegarde réelle** (ligne 12 + drones) | Publier la place (privée) **avec accord**, *Game Settings › Security › Enable Studio Access to API Services*, rouvrir | Plus d'avertissement « MÉMOIRE » ; Stop puis Play : Coins, sac, graines, mutations des cultures et nombre de drones restaurés ; drones recréés une seule fois ; pas de duplication |
| **Mobile** (ligne 14 + station) | *Test › Device* : un téléphone (ex. iPhone), relancer Play | HUD lisible sans chevauchement ; invites de récolte, de vente et de la station utilisables au toucher (appui long 0,4 s sur la station) ; panneau Graines ajusté à l'écran ; chat ouvert vs bouton Graines |
| **Manette** (ligne 15 + station) | Brancher une manette (ou émulateur de manette de Studio) | Y ouvre le panneau avec sélection auto du 1ᵉʳ bouton, croix directionnelle pour naviguer, A pour valider, B pour fermer ; invites (récolte, vente, station) déclenchées par X |

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
- `screen_capture` ne rend pas non plus le chat `TextChatService` (`CoreGui.ExperienceChat`) : le vérifier par
  `StarterGui:GetCoreGuiEnabled(Chat)`, `ChatWindowConfiguration.Enabled` et les éléments visibles de `appLayout`.
- Pas de 2ᵉ client (Play solo seulement) ni de contrôle de l'émulateur d'appareil ou d'une vraie manette.
- `execute_luau` tourne dans une VM séparée : `require` d'un service renvoie une **copie neuve** du module (état vide).
  Lire l'état joueur via le HUD (répliqué par `StateSync`) ou les attributs des cases `FarmTile`.
- Sans plugin Rojo dans Studio, un correctif n'est visible qu'après `scripts/check.ps1` puis réouverture de
  `build/MutationFarm.rbxlx` (fermer l'ancienne place **sans enregistrer**, sinon elle écrase le build).
