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
- [ ] Décision d'équilibrage : avec la Tomate, un drone remplace des récoltes « Parfait » d'un joueur attentif
      (−3 %) — option délai de grâce à trancher (Phase 3)
- [ ] Manuel : station à 2 joueurs, 3ᵉ drone, persistance réelle de la flotte, station au toucher et à la manette

## Phase 3 — Croissance de la ferme
- [ ] Améliorations normales (vitesse, valeur, sac) — UpgradeService + UI
- [ ] Extensions latérales `west`/`east`, terrasses (escaliers, déblocage)
- [ ] Événement Floraison dorée
- [ ] Simulateur d'économie Lune + rééquilibrage

## Phase 4 — Automatisation
- [ ] AutomationService : drones collecteurs (simulation agrégée), vente auto (drones récolteurs : Phase 2 jalon B)
- [ ] Production hors ligne plafonnée à 2 h, écran « Pendant ton absence »

## Phase 5 — Rebirth & Prestige
- [ ] RebirthService, PrestigeService (règles `Resets` déjà testées)
- [ ] Rebirth Tokens / Primal Cores, upgrades de rebirth et permanents, UI

## Phase 6 — Monétisation
- [ ] PurchaseService : Game Passes (confort/cosmétique), Developer Products limités
- [ ] ProcessReceipt idempotent (reçus persistés avant `PurchaseGranted`)

## Phase 7 — Polish & lancement
- [ ] Modèles 3D originaux, sons originaux, animations
- [ ] Localisation (LocalizationService), analytics, perf mobile, QA multi-appareils
- [ ] TestEZ en Studio via Wally (`test.project.json`)

## V1.1
- [ ] Familiers (conservés après tous les resets)
