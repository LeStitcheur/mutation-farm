# MUTATION FARM — Roadmap

Règle : une phase = un incrément **jouable**, testé (`scripts/check.ps1` vert + checklist `docs/TESTING.md`)
et versionné (commit/tag Git). Pas de développement simultané de plusieurs systèmes avancés.

## Phase 0 — Fondations ✅
- [x] Audit outils/dossier, chaîne d'outils épinglée (`rokit.toml`, `scripts/setup-tools.ps1`)
- [x] Projet Rojo, StyLua, Selene, luau-lsp (strict), runner de tests Lune compatible TestEZ
- [x] Docs : GAME_DESIGN, ARCHITECTURE, ECONOMY, ROADMAP, TESTING, CLAUDE.md
- [x] Contrats de données (`Types`, `DataSchema` v1), invariants économiques testés

## Phase 1 — Prototype jouable ✅ (validé en Studio, sauf multijoueur / mobile / persistance réelle)
- [x] Parcelle personnelle 3×3, attribution/libération, téléportation
- [x] Sauvegarde : verrou de session, UpdateAsync, autosave, BindToClose, migrations, repli mémoire en Studio
- [x] Croissance par timestamps, replantation automatique
- [x] Récolte manuelle (ProximityPrompt), bonus Parfait/Bien, sac à capacité
- [x] Marché : vente → Coins
- [x] Boutique de graines (7 plantes, déblocage séquentiel, sélection)
- [x] HUD responsive (Coins, sac, graines, notifications, chargement)
- [x] **Validation en Studio** via Studio MCP (2026-11-20, 2 passes) : 13/17 lignes de la checklist vérifiées,
      2 partielles (13 simulée, 15), 2 non vérifiables (12, 14) ; 4 défauts corrigés (plaque de base sur la ferme,
      notifications tronquées, ancien chat, chat sur le panneau Graines) — voir `docs/TESTING.md` §2.1
- [x] Tests Lune du verrou de session (simulation multi-serveurs) et de l'attribution des parcelles (122 tests)
- [ ] Validation manuelle restante (intervention humaine) :
  - [ ] Persistance réelle : publier la place (avec accord), activer l'accès API, Stop/Play → progression restaurée (ligne 12)
  - [ ] 2 clients réels (Test › Clients and Servers) : parcelles distinctes, récolte des plantes de l'autre impossible (ligne 13)
  - [ ] Émulateur téléphone : HUD, invites tactiles, chat ouvert vs bouton Graines sur écran bas (ligne 14)
  - [ ] Vraie manette : sélection auto du 1er bouton et navigation dans le panneau (ligne 15)

## Phase 2 — Mutations et automatisation (branche `phase-2/mutations-automation`)

**Jalon A — Mutations ✅ (2026-11-20)**
- [x] MutationService : tirage pondéré exclusif à la plantation, côté serveur (`MutationRoll`, `MutationOdds`),
      probabilités du cahier des charges (12 / 5 / 1,5 / 0,4 / 0,08 / 0,01 %), sauvegardé avec la case
- [x] Multiplicateurs appliqués à la vente ; bonus de précision sur la valeur de base
- [x] Visuels de mutation optimisés (teinte, matériau, échelle, lumière ≥ Radioactive, ≤ 6 particules/s, halo Divine)
- [x] Affichage à la récolte (invite, texte flottant coloré, notification ≥ ×8)
- [x] Tests Lune (distribution χ², exclusivité, multiplicateurs, sauvegarde) + validation Studio MCP (`docs/TESTING.md` §2.2)
- [ ] Hors périmètre du cahier des charges Phase 2, reportés : Mutation Essence, Mutadex, Pluie mutagène, annonce
      serveur de la Divine

**Jalon B — Drones récolteurs ✅ (2026-11-20, avancés depuis la Phase 4)**
- [x] Station d'achat par parcelle (Coins, propriétaire seulement), flotte sauvegardée dans `machines.drones`
- [x] Récolte automatique via les mêmes validations serveur que le joueur, sans bonus de précision, mutation conservée
- [x] Sac plein (attente sans perte, bulle, notification), aucun double gain joueur/drone (validation atomique)
- [x] Animation client (vol, pales, aller-retour), architecture multi-types pilotée par `DroneConfig`
- [x] Simulation manuel vs drones (`docs/ECONOMY.md` §7), tests Lune + validation Studio MCP (`docs/TESTING.md` §2.3)
- [x] Délai de grâce de 5 s (`graceDelay`) : les drones ne visent que les plantes mûres depuis 5 s, les bonus restent
      au joueur (Tomate + 1 drone : −3 % → +1 % ; contrepartie chiffrée dans `docs/ECONOMY.md` §7)
- [x] 3ᵉ drone : coût exact (9 375), plafond (« Complet », 4ᵉ achat refusé), affichage (2026-11-21, Studio MCP)
- [ ] Manuel (protocole `docs/TESTING.md` §2.4) : station à 2 joueurs, reconnexion, persistance réelle de la flotte,
      station au toucher et à la manette

## Phase 3 — Rebirth, prestige et progression exponentielle (branche `phase-3/progression`)

Cahier des charges du 2026-11-21 (remplace l'ancienne Phase 3 « Croissance de la ferme », reportée en Phase 4, et
avance la Phase 5). Détail : `docs/PROGRESSION.md`.

**Jalon A — Rebirth ✅ (2026-11-21 ; validations manuelles restantes ci-dessous)**
- [x] Schéma v2 : compteurs de cycle, révision de progression, `totalRebirths`, migration v1 → v2 défensive,
      quarantaine au lieu de toute suppression (`docs/DATA_MIGRATIONS.md`)
- [x] Formules pures : seuil `100 000 × 3,2ⁿ` sur les Coins gagnés du cycle, `M(R) = 1 + 0,35 R + 0,015 R²`,
      Mutation Essence (`ProgressionMath`, `ProgressionConfig`)
- [x] Transition atomique et idempotente (`Resets.rebirth`, révision), multiplicateur appliqué aux ventes et bonus
- [x] RebirthService (verrou par joueur, débit, replantation, flotte vidée, sauvegarde immédiate) ; DevService (Studio)
- [x] Panneau Rebirth (progression, récompense, multiplicateurs, perdu / conservé, confirmation en 2 étapes ;
      R / L1 / B) ; `PanelHub` (un panneau à la fois, chat masqué)
- [x] Tests Lune : 188 (seuils, multiplicateur, Essence, conservation champ par champ, 100 requêtes = 1 récompense,
      récolte/drone concurrents, sauvegardes simulées cohérentes, migration, quarantaine)
- [x] Validation Studio MCP (`docs/TESTING.md` §2.5) : 15 contrôles ✅ (dont rebirth complet, vente ×1,365 = 122,
      10 requêtes = 1 récompense, révision périmée refusée au seuil), manette simulée partielle
- [ ] Manuel : persistance réelle d'un rebirth, mobile, manette (`docs/TESTING.md` §2.4)

**Jalon B — Prestige ✅ (2026-11-21 ; validations manuelles restantes ci-dessous)**
- [x] Conditions du cahier des charges (5 / 1e7, 8 / 1e8, 12 / 1e9) puis exponentielles et configurables,
      `Mp(P) = 1 + 0,5 P + 0,08 P²`, Primal Cores (`ProgressionMath`, `ProgressionConfig.Prestige`)
- [x] Transition atomique et idempotente `Resets.prestige` (révision ; parcelles, rebirths, Essence, améliorations de
      rebirth et Coins des cycles réinitialisés ; droits Robux, Mutadex, cosmétiques, permanents conservés)
- [x] `ProgressionService` (exécution commune, verrou partagé rebirth/prestige), `PrestigeService` ; `RebirthService`
      ramené sur le même chemin
- [x] Panneau Prestige (conditions, Primal Cores, multiplicateurs, perdu / conservé, confirmation renforcée : case
      « J'ai compris » + 3 s ; P / R1 / B) sur `UI/ConfirmPanel`, commun avec le panneau Rebirth
- [x] Tests Lune : 205 (dont `Prestige.spec`, 11 tests, et 8 tests de formules) ; invariant 12
- [x] Validation Studio MCP (`docs/TESTING.md` §2.6) : 2 prestiges complets, confirmation renforcée, vente ×1,58 = 142,
      10 requêtes croisées rebirth/prestige = 1 transition ; 1 défaut d'affichage corrigé ; manette simulée partielle
- [ ] Manuel : persistance réelle d'un prestige, mobile, manette (`docs/TESTING.md` §2.4)

**Jalon C — Améliorations et équilibrage ✅ (2026-11-21 ; validations manuelles restantes ci-dessous)**
- [x] Arbre Mutation Essence (5) et arbre Primal Cores (6) : identifiants stables, coûts configurables, niveaux
      maximum, formules, plafonds (`UpgradeConfig`, `Upgrades`), effets branchés (revenu, sac, pousse, chance,
      drones, Essence, graines gardées, drones offerts)
- [x] `UpgradeService` (validation serveur, niveau attendu, refus pendant une transition) ; quarantaine des niveaux
      malformés au chargement
- [x] Panneau Améliorations à deux onglets (`UpgradeController` sur `UI/ModalPanel`, base désormais commune avec
      `ConfirmPanel`) ; U / L2 / B ; menu à 4 boutons
- [x] Simulateur économique déterministe à 5 profils (`tests/sim`), rapport (`docs/ECONOMY.md` §8), invariants
      testés ; défaut de planification des drones trouvé et corrigé ; Carotte et Tomate inchangées
- [x] Tests Lune : 227 (dont `Upgrades.spec` 16, `EconomySim.spec` 6)
- [x] Documentation (ARCHITECTURE, ECONOMY §8, TESTING, PROGRESSION §4–5, DATA_MIGRATIONS)
- [x] Validation Studio MCP (`docs/TESTING.md` §2.7) : achats Essence et Primal Cores, effets (sac 50, vente
      ×1,1 = 135, drone offert), refus serveur, Essence conservée au rebirth et perdue au prestige, panneaux
      Rebirth / Prestige refactorés revalidés
- [ ] Manuel : améliorations au toucher et à la manette, persistance réelle (`docs/TESTING.md` §2.4)

## Phase 4 — Collection, familiers, événements et missions (branche `phase-4/content-retention`)

Cahier des charges du 2026-11-21 (« contenu et fidélisation »). Branche empilée sur `phase-3/progression` (PR #1
non fusionnée).

**Jalon A — Mutadex (implémenté, validation Studio en attente)**
- [x] Catalogue dérivé (7 plantes × 7 mutations = 49), raretés, multiplicateurs (`MutadexConfig`, `Mutadex`)
- [x] Découvertes par le serveur dans le mutateur de récolte (joueur et drones), compteurs, première date
- [x] Paliers 10 / 25 / 50 / 75 / 100 % accordés une seule fois (cosmétiques, places de sac), rattrapés au chargement
- [x] Schéma v3 + migration v2 -> v3 ; quarantaine des données malformées ; **correctif** : la réconciliation ne
      remplace plus en silence une valeur d'un type incompatible
- [x] Panneau Mutadex (progression, plus rares, paliers, filtres, recherche, cartes, historique ; M / R2) ; menu du
      HUD en grille de 2 colonnes
- [x] Tests Lune : 246 (dont `Mutadex.spec` 18) ; simulateur affiné (variabilité, nombres aléatoires communs)
- [x] Revue de code : contenu retiré conservé en sommeil (au lieu de la quarantaine bornée), panneau redessiné
      seulement si son contenu change, lignes d'information sur une ligne, annonces de rattrapage différées
- [ ] Validation Studio MCP (`docs/TESTING.md` §2.8) — en attente de la connexion du plugin Rojo
- [ ] Manuel : persistance réelle, mobile, manette (`docs/TESTING.md` §2.4)

**Jalon B — Familiers (implémenté, validation Studio en attente)**
- [x] 6 espèces originales (croissance, valeur, chance, drones, récolte manuelle, général), raretés, bonus par niveau
- [x] Œufs en Coins (prairie, cristallin) et gratuits (missions) ; probabilités affichées ; tirage serveur ; aucun
      œuf en Robux ; éclosion atomique, idempotente et **sauvegardée avant confirmation**
- [x] Inventaire (50, tri, doublons), 3 emplacements, relâchement confirmé ; identifiants d'instance uniques
- [x] XP des récoltes validées (joueur et drones) dans le mutateur de récolte, coût exponentiel, niveau 15
- [x] Bonus cumulés plafonnés par effet + plafonds globaux toutes sources (`Util/Bonuses`)
- [x] Modèles stylisés suivant le propriétaire (interpolation locale, animations, rendu mobile économe)
- [x] Schéma v4 + migration v3 -> v4 ; jamais réinitialisés (rebirth, prestige)
- [x] Tests Lune : 266 (dont `Pets.spec` 20)
- [ ] Validation Studio MCP (`docs/TESTING.md` §2.9) — en attente de la connexion du plugin Rojo
- [ ] Manuel : persistance réelle, performance mobile, manette (`docs/TESTING.md` §2.4)

**Jalon C — Événements dynamiques (implémenté, validation Studio en attente)**
- [x] Pluie mutagène (5 min, chance × 3 à la plantation, plafonnée) et Floraison dorée (10 min, +50 % de la valeur
      versés à la récolte, joueur et drones)
- [x] Calendrier déterministe UTC (tranches de 30 min, tirage contrôlé, rendez-vous 12:00 et 20:00, écart ≥ 5 min,
      un seul à la fois) : identique sur tous les serveurs sans MessagingService ; arrivées tardives servies
- [x] Annonces, bandeau avec compte à rebours, éclairage et particules (rendu local économe)
- [x] Bonus lus à l'instant de l'action : rien ne persiste après la fin, aucune donnée joueur
- [x] Tests Lune : 278 (dont `Events.spec` 12)
- [ ] Validation Studio MCP (`docs/TESTING.md` §2.10) — en attente de la connexion du plugin Rojo
- [ ] Manuel : multijoueur et mobile (`docs/TESTING.md` §2.4)

**Jalon D — Missions** : à venir.

## Phase 5 — Croissance de la ferme et automatisation (ex-Phase 4, replanifiée)
- [ ] Améliorations normales (vitesse, valeur, sac) — UpgradeService + UI
- [ ] Extensions latérales `west`/`east`, terrasses (escaliers, déblocage) ; reconstruction de la parcelle au prestige
- [ ] AutomationService : drones collecteurs (simulation agrégée), vente auto (drones récolteurs : Phase 2 jalon B)
- [ ] Production hors ligne plafonnée à 2 h, écran « Pendant ton absence »
- Rebirth & Prestige : avancés en Phase 3. Floraison dorée : Phase 4, jalon C.

## Phase 6 — Monétisation
- [ ] PurchaseService : Game Passes (confort/cosmétique), Developer Products limités
- [ ] ProcessReceipt idempotent (reçus persistés avant `PurchaseGranted`)

## Phase 7 — Polish & lancement
- [ ] Modèles 3D originaux, sons originaux, animations
- [ ] Localisation (LocalizationService), analytics, perf mobile, QA multi-appareils
- [ ] TestEZ en Studio via Wally (`test.project.json`)

## V1.1
- [ ] Familiers (conservés après tous les resets)
