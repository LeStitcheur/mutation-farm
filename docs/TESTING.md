# MUTATION FARM — Tests et QA

## 1. Vérification automatique (à lancer avant chaque commit)

```powershell
pwsh scripts/check.ps1        # vérifie (échoue si le formatage est incorrect)
pwsh scripts/check.ps1 -Fix   # applique StyLua puis vérifie le reste
```

La même vérification tourne en **CI** (GitHub Actions, `.github/workflows/check.yml`, runner Windows) sur chaque
pull request et chaque push sur `main` : installation des outils épinglés (`scripts/setup-tools.ps1`, mise en cache)
puis `scripts/check.ps1`. Le rapport du simulateur (`… run tests/run.luau report`) n'y est pas exécuté.

| Étape | Outil | Ce qui est garanti |
|---|---|---|
| Sourcemap | `rojo sourcemap` | arbre DataModel connu de luau-lsp |
| Formatage | StyLua 2.6 | style homogène (tabs, 120 colonnes) |
| Lint | Selene 0.32 (std `luau` + `roblox_lite.yml`) | variables inconnues, ombres, tables mixtes… |
| Typage | luau-lsp 1.70 `analyze`, mode `--!strict`, définitions Roblox officielles | erreurs de types, API Roblox mal utilisées |
| Tests unitaires | Lune 0.11 + `tests/TestEZLite.luau` | logique pure : BigNum, économie, croissance, mutations, drones, schéma de données (migrations, quarantaine), progression et rebirth (seuils, Essence, resets, concurrence), géométrie, verrou de session (simulation multi-serveurs), attribution des parcelles (isolation) |
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

### Ce qui est couvert hors Studio pour le rebirth (Phase 3, jalon A)
Ce sont des **simulations** Lune : elles ne valent pas validation du vrai DataStore (§2.4).
- `Progression.spec` (12 tests) : seuils exacts `100 000 × 3,2ⁿ` pour n = 0..10, croissance stricte et écart relatif
  borné jusqu'à n = 200 (au-delà de 10¹⁵) ; `M(R)` ; invariant 7 (R = 0..60) ; Essence 100 / 168 / plafond ×2, rien
  sous le seuil ; éligibilité sur les Coins **gagnés** du cycle et non sur le solde ; aperçu ; `recordEarnings`.
- `Resets.spec` (7 tests) : reset et récompense (168 Essence, révision + 1) ; **conservation profonde** de tous les
  champs non listés ; refus sous le seuil ou avec une révision périmée **sans aucune modification** ; double requête :
  100 appels avec la même révision = 1 récompense ; donnée sérialisable et rechargeable ; structure du prestige.
- `RebirthConcurrency.spec` (6 tests) : récolte joueur et cible de drone préparées avant le reset puis refusées ;
  sac vidé ; ventes et bonus au nouveau multiplicateur (×1,365 : 136 et 6) ; sauvegardes simulées toujours
  cohérentes (jamais de récompense sans reset) ; requête rejouée après restauration refusée (révision persistée).
- `DataSchema.spec` (17 tests) : migration v1 → v2 nominale et défensive, quarantaine (aucune suppression
  silencieuse), valeur non sérialisable gardée en texte, FIFO borné.
- `Format.spec` : affichage des multiplicateurs (`×1,365`, tronqué au millième).
- Non couvert ici : `RebirthService` (verrou `busy`, débit, `SaveNow`), le panneau client → Studio (§2.5).

### Ce qui est couvert hors Studio pour le prestige (Phase 3, jalon B)
Simulations Lune également (pas de validation du vrai DataStore).
- `Progression.spec` (+8 tests) : conditions exactes du cahier des charges (5 / 1e7, 8 / 1e8, 12 / 1e9) puis 17 / 1e10
  et 23 / 1e11 ; croissance stricte et Coins exponentiels jusqu'à p = 60 (au-delà de 10¹⁵) ; nombres invalides
  refusés ; les deux conditions requises (le solde ne compte jamais) ; `Mp(P)` ; Primal Cores (10, 12, 20, plafond,
  16, 22) ; invariant 12 ; aperçu ; revenu = rebirth × prestige.
- `Prestige.spec` (11 tests) : reset et récompense (12 Primal Cores pour 6 rebirths, révision + 1) ; **conservation
  profonde** de tout le reste (Mutadex, cosmétiques, familiers, reçus Robux, améliorations permanentes, stats,
  quarantaine) ; refus sans aucune modification (révision périmée, rebirths ou Coins insuffisants) ; **100 requêtes =
  1 récompense** ; **révisions croisées** rebirth ↔ prestige ; cycle suivant au premier seuil avec ×1,58 ; récolte
  et cible de drone préparées avant le prestige refusées, parcelle rendue refusée ; vente ×1,58 = 158 et bonus 7 ;
  sauvegardes simulées toujours cohérentes ; requête rejouée après restauration refusée.
  Contrôle de mutation : supprimer `revision + 1` dans `Resets.prestige` fait échouer 4 tests.
- Non couvert ici : `ProgressionService` / `PrestigeService` (verrou partagé, débit, `SaveNow`), le panneau → Studio.

### Ce qui est couvert hors Studio pour les améliorations et l'équilibrage (Phase 3, jalon C)
- `Upgrades.spec` (16 tests) : catalogue (5 + 6 identifiants stables) ; coûts exacts et strictement croissants ;
  achat (bonne monnaie, niveau + 1) ; **refus sans aucune modification** : fonds insuffisants, niveau maximum,
  niveau périmé, identifiant inconnu ; **100 achats avec le même niveau attendu = 1 niveau payé** ; **nombres
  invalides** (NaN, −1, 1,5, texte, infini, au-delà du maximum) ; effets et plafonds (valeur multiplicative, pousse
  ≥ 40 %, chance ≤ 2,5 et E ≤ 1,98, intervalle des drones, délai de grâce de 5 s inchangé, sac, Essence) ; resets
  (Essence conservée au rebirth, perdue au prestige ; permanents et reçus Robux conservés ; graines gardées et drones
  offerts appliqués) ; **données malformées** mises en quarantaine ou plafonnées au chargement.
- `EconomySim.spec` (6 tests, simulateur `tests/sim`) : déterminisme ; premier rebirth borné par profil ; part des
  drones (automatisé > 80 %, hybride attentif < 10 %) ; premier prestige en 1 h 30 – 5 h et cycle suivant plus court
  mais ≥ 3 min ; aucune amélioration Essence ne réduit le revenu ; Efficacité des drones agit dès le niveau 1
  (régression de la planification des drones).
- Rapport chiffré (non exécuté par `check.ps1`, ≈ 30 s) : `tools/bin/lune.exe run tests/run.luau report`
  (`docs/ECONOMY.md` §8).

### Ce qui est couvert hors Studio pour le Mutadex (Phase 4, jalon A)
- `Mutadex.spec` (18 tests) : catalogue (49 entrées, identifiants = clés du sac, raretés, multiplicateurs) ;
  exigences des paliers (5 / 13 / 25 / 37 / 49) ; **première découverte** et **découverte déjà enregistrée**
  (date conservée, compteur) ; combinaison hors catalogue ignorée ; **récolte manuelle et de drone** par
  `HarvestRules.apply` ; **concurrence** joueur + drone sur une culture = 1 comptage ; **paliers** accordés une
  seule fois (20 réévaluations), places de sac (confort uniquement), collection complète ; évaluation dans le
  mutateur de récolte ; historique, plus rares, filtres et recherche sans accents (noms inconnus jamais révélés) ;
  **rebirth et prestige** sans effet sur le Mutadex ; **sauvegarde/rechargement** ; **migration v2 -> v3** ;
  **données malformées** en quarantaine (entrées, paliers, Mutadex non tabulaire) ; **contenu retiré** de la
  configuration : entrées et paliers bien formés conservés en sommeil (ni comptés ni mis en quarantaine) et
  intacts après un nouveau cycle sauvegarde -> chargement.
- `DataSchema.spec` (+1) : une valeur d'un **type incompatible** n'est plus remplacée en silence par la
  réconciliation : elle part en quarantaine (correctif d'un défaut antérieur).
- `EconomySim.spec` : détection du rebirth suivant le prestige corrigée (rebirth effectué, pas éligibilité
  transitoire) ; modèle du joueur affiné (`docs/ECONOMY.md` §8).

### Ce qui est couvert hors Studio pour les familiers (Phase 4, jalon B)
- `Pets.spec` (20 tests) : **probabilités** affichées = poids / somme (somme 1, espèces connues, aucun œuf en Robux,
  Œuf des missions non vendu) ; **tirage** exact sur une grille uniforme de 20 000 aléas ; **achat** en Coins
  (paiement, instance `p1` niveau 1, compteur) ; **fonds insuffisants**, œuf inconnu, œuf non vendu sans effet ;
  **œuf gratuit** (consommé, réserve vide refusée, réserve plafonnée) ; **inventaire plein** refusé avant paiement ;
  **double clic / rejeu** (révision périmée : un seul œuf, un seul paiement) ; **identifiants jamais réutilisés** ;
  **équipement** (3 emplacements, double équipement, relâcher un équipé refusé) ; tri, doublons, espèce en
  sommeil ; **bonus** par niveau, **cumul plafonné**, effet réel sur la pousse, le revenu, la chance, les drones et
  la précision manuelle (drone sans bonus) ; **plafonds globaux** (P(normale) ≥ 46 % à la chance maximale) ;
  **XP** exponentielle et niveau plafonné ; XP des **récoltes manuelles et de drones** aux seuls équipés ;
  **rebirth et prestige** sans effet ; **sauvegarde/rechargement** ; **migration v3 -> v4** ; **données
  malformées** (quarantaine, sommeil, niveau plafonné, compteur et équipement corrigés).
- Concurrence côté serveur : un seul mutateur par éclosion (`Pets.hatch`), drapeau « éclosion en sauvegarde » et
  débit 1 / 3 s dans `PetService` (validés en Studio, `docs/TESTING.md` §2.9).

### Ce qui est couvert hors Studio pour les événements (Phase 4, jalon C)
- `Events.spec` (12 tests) : calendrier **déterministe** (même tranche → même événement, sur tous les serveurs) ;
  **tirage contrôlé** (≈ 50 % des tranches, Pluie 60 % / Floraison 40 % sur 20 000 tranches) ; **rendez-vous fixes**
  (12:00 et 20:00 UTC) ; **un seul événement à la fois** et **écart minimal** de 5 min (10 000 tranches) ;
  **déclenchement** forcé et **expiration** (aucun bonus résiduel, durée forcée plafonnée) ; **arrivée tardive**
  (début, milieu, fin → même fenêtre et même fin) ; forcé prioritaire sur le planifié ; **Pluie** : chance × 3 plafonnée
  (P(normale) ≥ 46 %), mutations au moins doublées ; **Floraison** : +50 % de la valeur versé à la récolte pour le
  **joueur et les drones**, une seule fois, sac inchangé à la vente ; **plusieurs joueurs** ; **rebirth et prestige**
  pendant un événement ; **sauvegarde** inchangée ; **aucun cumul**.

### Ce qui est couvert hors Studio pour les missions (Phase 4, jalon D)
- `Quests.spec` (18 tests) : **périodes UTC** (bascule à 00:00, semaine au lundi 00:00) ; **tirage** (3 quotidiennes
  facile/moyenne/difficile + 2 hebdomadaires, modèles distincts, identifiants uniques, **déterministe**) ;
  **récompenses** proportionnelles à la difficulté et au revenu ; **éligibilité** (drones, plante débloquée, Mutadex
  restant, rebirth déjà fait) ; **progression** des récoltes **manuelles et de drones**, Parfait, **mutations**
  (rares ×8), plante précise, plafonnée à l'objectif ; période échue figée ; **rebirth et prestige** sans effet ;
  **récupération unique** (Coins gagnés, œuf, boost, décoration ; seconde tentative refusée) ; **expiration** puis
  nouveau tirage ; **triche** (identifiant inconnu, mission non terminée, sauvegarde trafiquée en quarantaine) ;
  **concurrence** ; **reconnexion / changement de serveur** sans nouveau tirage ; **boosts** (effet, expiration,
  durée plafonnée) ; **migration v4 -> v5**.

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
| **Rebirth : persistance réelle** (Phase 3) | Comme « Sauvegarde réelle » ; en Studio, créditer le seuil avec `ServerStorage.MutationFarmDev:Invoke("grantEarned", userId, 100000)` (barre de commande serveur) | Rebirth confirmé → Stop immédiat → Play : rebirths = 1, Essence +100, Coins 0, Carotte seule, aucun drone ; jamais d'Essence sans le reset ; Stop pendant la transition : état avant **ou** après, jamais un mélange |
| **Rebirth : mobile** (Phase 3) | *Test › Device* (téléphone), relancer Play | Bouton Rebirth sous Graines, panneau ajusté à l'écran (rien de coupé), « Rebirth… », « Annuler » et « Confirmer » utilisables au toucher ; chat masqué pendant l'ouverture puis restauré |
| **Rebirth : manette** (Phase 3) | Manette branchée | L1 ouvre le panneau (sélection auto de l'action), A sur « Rebirth… » → « Annuler » sélectionné, « Confirmer » inactif 1,5 s, B revient à l'écran d'information puis ferme |
| **Prestige : persistance réelle** (Phase 3) | Comme « Sauvegarde réelle » ; atteindre 5 rebirths (crédits `grantEarned` + rebirths) | Prestige confirmé → Stop immédiat → Play : prestiges = 1, Primal Cores +10 (ou plus), rebirths 0, Essence 0, parcelles par défaut, Mutadex / cosmétiques / reçus intacts ; jamais de Primal Cores sans le reset |
| **Prestige : mobile** (Phase 3) | *Test › Device* (téléphone) | Menu à 3 boutons sans chevauchement avec le chat ; panneau Prestige ajusté à l'écran ; case « J'ai compris », « Annuler » et « Confirmer » utilisables au toucher |
| **Prestige : manette** (Phase 3) | Manette branchée | R1 ouvre le panneau ; « Prestige… » → « Annuler » sélectionné ; croix vers la case « J'ai compris », A coche ; « Confirmer » actif seulement après 3 s **et** case cochée ; B revient puis ferme |
| **Améliorations : mobile** (Phase 3) | *Test › Device* (téléphone) | Menu à 4 boutons sans chevauchement avec le chat ouvert ; panneau ajusté à l'écran, onglets et boutons d'achat utilisables au toucher, textes lisibles |
| **Améliorations : manette** (Phase 3) | Manette branchée | L2 ouvre le panneau, onglet sélectionné ; croix pour passer d'un onglet aux lignes, A achète (niveau + 1, solde mis à jour), B ferme |
| **Améliorations : persistance réelle** (Phase 3) | Comme « Sauvegarde réelle » | Niveaux achetés restaurés après Stop / Play ; améliorations Essence perdues et permanentes conservées après un prestige réel |
| **Mutadex : persistance réelle** (Phase 4) | Comme « Sauvegarde réelle » | Découvertes, compteurs, dates et paliers restaurés après Stop / Play et après un changement de serveur ; ancienne sauvegarde v2 migrée sans perte |
| **Missions : renouvellement réel** (Phase 4) | Session ouverte à travers 00:00 UTC (ou un lundi 00:00 UTC) ; place publiée | Nouvelles missions annoncées sans reconnexion ; les anciennes non récupérées disparaissent ; changement de serveur juste après : mêmes missions, même progression |
| **Événements : multijoueur et mobile** (Phase 4) | Serveur local à 2 joueurs ; appareil mobile | Même événement, même compte à rebours pour les deux ; un joueur qui rejoint pendant l'événement voit le bandeau et les effets ; pluie et paillettes fluides sur mobile ; éclairage restauré à la fin |
| **Familiers : persistance réelle** (Phase 4) | Comme « Sauvegarde réelle » | Éclosion puis arrêt brutal du serveur : le familier est présent au retour (sauvegarde avant confirmation) ; équipement, niveaux et œufs gratuits restaurés après changement de serveur |
| **Familiers : performance mobile** (Phase 4) | Appareil d'entrée de gamme, 3 familiers équipés, plusieurs joueurs | Images par seconde stables, familiers qui suivent sans saccade, aucune erreur ; panneau Familiers lisible (*Test › Device*) ; manette : L3 ouvre, B ferme |
| **Mutadex : mobile et manette** (Phase 4) | *Test › Device* ; manette branchée | Menu en grille lisible sans chevauchement avec le chat ; panneau ajusté, cartes défilables au doigt ; R2 ouvre, croix pour parcourir filtres et cartes (défilement automatique), B ferme |

### 2.5 Phase 3, jalon A (rebirth) — validation Studio MCP du 2026-11-21 (Play solo, API désactivée)

Build de la branche `phase-3/progression` (RebirthService, DevService, RebirthController, PanelHub présents ;
10 services, console sans erreur ni avertissement hors repli mémoire). Seuils crédités par
`MutationFarmDev:Invoke("grantEarned", …)` (Coins **gagnés**, outil Studio) ; drone, graine Tomate, récoltes et vente
réalisés en jeu. État lu par `Invoke("snapshot", …)` côté serveur et par le HUD côté client.

| Contrôle | Statut | Constat |
|---|---|---|
| Profil neuf en schéma v2 | ✅ | `version = 2`, `revision = 0`, `cycleCoins = prestigeCoins = 0`, `totalRebirths = 0`, quarantaine vide |
| Bouton et touche | ✅ | Bouton doré « Rebirth » sous « Graines » (menu 2 × 58 px), indice « R » ; R ouvre, clic sur le bouton ouvre |
| Panneau sous le seuil | ✅ | « Rebirths réalisés : 0 », « Rebirth n° 1 : gagne 100K Coins pendant ce cycle (… le solde actuel ne compte pas) », barre 0 / 100K (0 %), « Revenus : ×1 maintenant → ×1,365 », listes Perdu / Conservé, bouton gris « Seuil non atteint » ; capture : aucun chevauchement, échelle 0,90 à 1155 × 793 |
| Un panneau à la fois, chat | ✅ | G ouvre Graines et ferme Rebirth, chat toujours masqué ; fermeture → `CoreGuiType.Chat` et `ChatWindowConfiguration` réactivés |
| Panneau éligible | ✅ | Après 100 000 gagnés : 100K / 100K (100 %), « Récompense : +100 Mutation Essence », bouton doré « Rebirth… » |
| Confirmation en 2 étapes | ✅ | Récapitulatif « Confirmer le rebirth n° 1 ? Tu perds : … Tu gagnes : +100 Mutation Essence et des revenus ×1,365. » ; clic sur « Confirmer » 0,25 s après l'ouverture **sans effet** (révision 0, Essence 0) ; « Annuler » revient à l'écran d'information ; « Confirmer » rouge et actif après 1,5 s |
| Rebirth n° 1 (reset et récompense) | ✅ | Avant : 97 750 Coins, Tomate débloquée et sélectionnée, 1 drone, sac rempli (joueur + drone), cultures Tomate/Carotte. Après : `rebirths = 1`, `revision = 1`, `totalRebirths = 1`, Essence 100, Coins 0, Carotte seule (sélectionnée), sac vide, aucun drone (0 ancre serveur, 0 modèle client), 9 cases replantées en Carotte, `cycleCoins = 0` |
| Conservation | ✅ | Parcelles (`main`), `coinsEarned = 100 000`, `prestigeCoins = 100 000`, `harvests = 15`, quarantaine vide |
| Client après rebirth | ✅ | Panneau fermé, chat restauré, HUD à 0, panneau : « Rebirths réalisés : 1 », 0 / 320K, « ×1,365 maintenant → ×1,76 » |
| Refus | ✅ | Révision périmée (0) : ignorée sans message ni effet ; bonne révision sous le seuil : « Pas encore assez de Coins gagnés pendant ce cycle pour un rebirth. », rien ne change ; charges invalides (`"1"`, NaN, 1,5, −1, 2⁴⁰) ignorées |
| Multiplicateur à la vente | ✅ | Sac de 5 Carottes + 2 Carottes Brillantes (base 90) vendu **122** = ⌊90 × 1,365⌋ ; comptés dans `cycleCoins`, `prestigeCoins` et `coinsEarned` |
| Requêtes multiples | ✅ | Au seuil 320 000 : 10 `RebirthRequest(1)` envoyées d'un coup → **un seul** rebirth (Essence 100 → 268 = +168, `revision = 2`), une seule notification « Rebirth 2 ! +168 Mutation Essence · revenus ×1,76 » (le limiteur de débit absorbe aussi les doublons) |
| Révision périmée au seuil | ✅ | Seuil 1 024 000 atteint, `RebirthRequest(1)` alors que la révision est 2 (jeton du limiteur rechargé) → refus, rien ne change ; le panneau affiche « +227 Mutation Essence », « ×1,76 → ×2,185 » |
| Touches manette (simulées) | ✅ partiel | `ButtonL1` ouvre le panneau ; `ButtonB` revient de la confirmation à l'information puis ferme (chat restauré). Les entrées simulées restent de type `Keyboard` : sélection automatique et indices « L1 » / « B » non vérifiables → vraie manette (§2.4) |
| Fermeture | ✅ | Bouton X (souris), R et B ferment ; chat restauré |
| Persistance réelle d'un rebirth | ⛔ non vérifiable | Store mémoire (pas d'accès API) ; sauvegardes cohérentes couvertes **en simulation** Lune (`RebirthConcurrency.spec`), protocole §2.4 |
| Mobile | ⛔ non vérifiable | Pas de contrôle de l'émulateur ; même mise à l'échelle que le panneau Graines (`Theme.fitScale`) ; protocole §2.4 |
| Concurrence récolte/drone pendant le reset | ⛔ non reproductible à la main | Fenêtre d'une seule image ; garantie par le mutateur synchrone, couverte en Lune (`RebirthConcurrency.spec`) |

### 2.6 Phase 3, jalon B (prestige) — validation Studio MCP du 2026-11-21 (Play solo, API désactivée)

Build de la branche `phase-3/progression` (ProgressionService, PrestigeService, PrestigeController, ConfirmPanel
présents ; 12 services ; remote `PrestigeRequest` créé ; console sans erreur ni avertissement hors repli mémoire).
Seuils crédités par `grantEarned` (outil Studio) ; chaque rebirth envoyé par `RebirthRequest` avec la révision
attendue ; Tomate, drone, récoltes et ventes réalisés en jeu. Le rebirth (jalon A) a été revalidé au passage, désormais
exécuté par `ProgressionService`.

| Contrôle | Statut | Constat |
|---|---|---|
| Menu à 3 boutons | ✅ | Graines (G), Rebirth (R), Prestige (P, violet) empilés, menu ajusté à son contenu (`AutomaticSize`) |
| Panneau sous les conditions | ✅ | « Prestiges réalisés : 0 · Primal Cores : 0 », conditions du prestige n° 1 : 0 / 5 rebirths, 0 / 10.0M Coins, « ×1 → ×1,58 », « Revenus : ×1 → ×1,58 », listes Perdu / Conservé, bouton gris « Conditions non remplies » |
| Défaut d'affichage corrigé | ✅ | Ligne « Récompense : des Primal Cores (+25 % …) » trop longue (2 lignes, chevauchait la suivante, `TextFits = false`) → textes raccourcis dans `src/`, longueur vérifiée par aperçu à l'exécution (483 et 499 px pour 541 disponibles) ; tous les autres libellés `TextFits = true` |
| 5 rebirths enchaînés | ✅ | Révision 5, Essence 1 111 (= 100 + 168 + 227 + 282 + 334), `prestigeCoins` 15 206 560 (= somme des seuils) |
| Panneau éligible | ✅ | 5 / 5, 15.2M / 10.0M (100 %), « +10 Primal Cores », « Revenus : ×3,125 maintenant → ×1,58 juste après » |
| Confirmation renforcée | ✅ | Récapitulatif chiffré (« dont 5 rebirths et 1.11K Mutation Essence », « +10 Primal Cores », « ×1,58 ») ; « Confirmer » cliqué à 0,25 s **puis à 3,3 s sans la case** : sans effet (révision 5, 0 Primal Core) ; case « ☑ J'ai compris … » (glyphe rendu, fond vert) → « Confirmer » rouge et actif |
| Prestige n° 1 (reset et récompense) | ✅ | Avant : 2 750 Coins, Tomate sélectionnée, 1 drone, 7 objets. Après : `prestiges = 1`, `revision = 6`, Primal Cores 10, Essence 0, Coins 0, Carotte seule, aucun drone (0 ancre, 0 modèle), sac vide, parcelle `main`, 9 cases replantées, `cycleCoins = prestigeCoins = 0` ; notification « Prestige 1 ! +10 Primal Cores · multiplicateur de prestige ×1,58 » ; chat restauré |
| Conservation | ✅ | `coinsEarned = 15 211 560`, `totalRebirths = 5`, `harvests = 18`, améliorations permanentes, quarantaine vide |
| Panneaux après prestige | ✅ | Prestige : « Prestiges réalisés : 1 · Primal Cores : 10 », conditions n° 2 : 0 / 8, 0 / 100M, « ×1,58 → ×2,32 » ; Rebirth : « ×1,58 maintenant → ×2,156 après ce rebirth » (1,365 × 1,58 tronqué) |
| Refus | ✅ | Révision périmée : ignorée sans message ; 0 rebirth : « Pas encore assez de rebirths pour un prestige. » ; charges invalides (`"6"`, NaN, 6,5, −1, 2⁴⁰, table) ignorées |
| Multiplicateur de prestige à la vente | ✅ | 3 Carottes + 3 Carottes Brillantes (base 90) vendues **142** = ⌊90 × 1,58⌋, comptées dans les deux cycles |
| Prestige n° 2 | ✅ | 8 rebirths (Essence 2 399), `prestigeCoins` 1,6 G ≥ 100 M : +16 Primal Cores (total 26), « ×2,32 » |
| Requêtes croisées simultanées | ✅ | Rebirth n° 9 **et** prestige n° 2 tous deux possibles (révision 14) : 5 `PrestigeRequest(14)` + 5 `RebirthRequest(14)` dans la même image → **une seule** transition (prestige, révision 15, aucun rebirth appliqué : `totalRebirths` reste 13), une seule notification |
| Touches manette (simulées) | ✅ partiel | `ButtonR1` ouvre le panneau Prestige (chat masqué), `ButtonB` ferme (chat restauré) ; sélection automatique et indices « R1 » / « B » non vérifiables (entrées simulées de type `Keyboard`) |
| Casse du récapitulatif | ✅ (correctif) | `string.lower` donnait « mutation essence » : supprimé dans les deux panneaux après la passe (texte de même longueur ; non revu à l'écran) |
| Persistance réelle d'un prestige | ⛔ non vérifiable | Store mémoire ; sauvegardes cohérentes couvertes **en simulation** (`Prestige.spec`), protocole §2.4 |
| Mobile, vraie manette | ⛔ non vérifiable | Protocole §2.4 |

### 2.7 Phase 3, jalon C (améliorations) — validation Studio MCP du 2026-11-21 (Play solo, API désactivée)

Build de la branche `phase-3/progression` (UpgradeService, UpgradeController, ModalPanel, planification corrigée des
drones présents ; 13 services ; remote `UpgradePurchase` ; console sans erreur du jeu). Fenêtre de jeu réduite
(675 × 613) pendant toute la passe. Rebirth et prestige faits **par les panneaux refactorés** (ConfirmPanel sur
ModalPanel) ; seuils crédités par `grantEarned`.

| Contrôle | Statut | Constat |
|---|---|---|
| Menu à 4 boutons | ✅ | Graines (G), Rebirth (R), Prestige (P), Améliorations (U, bleu) ; menu ajusté à son contenu |
| Panneau Améliorations | ✅ | U ouvre, chat masqué ; onglets « Mutation Essence » (doré) / « Primal Cores » (violet) ; solde et note de l'arbre ; 5 et 6 lignes « nom · niv. 0/max », effet, coût (40, 50, 60, 50, 30 Essence ; 4, 5, 12, 4, 6, 6 Cores) ; aucun dépassement de texte (`TextFits`) sur les deux onglets |
| Rebirth par le panneau refactoré | ✅ | R → « Rebirth… » → « Confirmer » après 1,5 s → rebirth 1, révision 1, 100 Essence |
| Achats Essence | ✅ | Clic « 40 Essence » (Valeur de vente) puis « 30 Essence » (Capacité du sac) : Essence 100 → 30, niveaux 1/10, coûts suivants 62 et 45, boutons gris quand inabordables ; HUD **« Sac 0/50 »** |
| Refus serveur | ✅ | Fonds insuffisants : « Pas assez de Mutation Essence pour cette amélioration. » / « Pas assez de Primal Cores pour cette amélioration. » ; niveau périmé ignoré ; charges invalides (1,5, −1, NaN, identifiant de 40 caractères, nombre, inconnu, tables) ignorées ; données inchangées |
| Effet Valeur de vente | ✅ | 5 Carottes + 1 Carotte Géante (base 90) vendues **135** = ⌊90 × 1,365 × 1,1⌋ |
| Essence conservée au rebirth | ✅ | Rebirths 2 à 6 : Essence 1 424 (= 30 + 168 + 227 + 282 + 334 + 383), niveaux Essence intacts |
| Prestige par le panneau refactoré | ✅ | Récapitulatif avec la casse corrigée (« Coins », « Mutation Essence »), « +12 Primal Cores » (6 rebirths = 1 de plus que le minimum : 10 × 1,25), case cochée puis « Confirmer » après 3 s → prestige 1 |
| Essence perdue au prestige | ✅ | Essence 0, `upgrades.rebirth` vide, HUD « Sac 0/40 », Primal Cores 12 |
| Achat Primal Cores | ✅ | Automatisation primordiale : 12 → 0 Cores, niv. 1/2, **drone accordé immédiatement** (1 ancre serveur, 1 modèle client), notification « Automatisation primordiale : niveau 1/2 (1 drone(s) offert(s) par cycle) » |
| Drone offert à chaque cycle | ✅ | Rebirth suivant : `machines.drones.harvester = 1` à nouveau, amélioration permanente conservée |
| Touches manette (simulées) | ✅ partiel | `ButtonL2` ouvre / ferme, `ButtonB` ferme (chat restauré) ; sélection automatique non vérifiable (entrées simulées de type `Keyboard`) |
| Libellé au niveau 0 | ✅ (correctif) | « −0 % de durée de pousse → −4 % … » remplacé par « Niveau 1 : −4 % de durée de pousse » après la passe (texte plus court ; non revu à l'écran) |
| Niveau maximum en jeu | ⛔ non exécuté | Exigerait des milliers d'Essence ; refus `max_level` couvert en Lune (`Upgrades.spec`) |
| Persistance réelle, mobile, vraie manette | ⛔ non vérifiable | Protocole §2.4 |

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
- Outils de test serveur (Phase 3, Studio uniquement) : `DevService` crée `ServerStorage.MutationFarmDev`
  (`BindableFunction`), utilisable depuis `execute_luau` côté **Server** malgré l'isolation des VM :
  `Invoke("grantEarned", userId, montant)` crédite des Coins **gagnés** (comptent pour le cycle) ;
  `Invoke("snapshot", userId)` renvoie la donnée serveur en JSON (rebirths, Essence, révision, quarantaine…).
