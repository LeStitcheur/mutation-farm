# MUTATION FARM — Roadmap

Règle : une phase = un incrément **jouable**, testé (`scripts/check.ps1` vert + checklist `docs/TESTING.md`)
et versionné (commit/tag Git). Pas de développement simultané de plusieurs systèmes avancés.

## Phase 0 — Fondations ✅
- [x] Audit outils/dossier, chaîne d'outils épinglée (`rokit.toml`, `scripts/setup-tools.ps1`)
- [x] Projet Rojo, StyLua, Selene, luau-lsp (strict), runner de tests Lune compatible TestEZ
- [x] Docs : GAME_DESIGN, ARCHITECTURE, ECONOMY, ROADMAP, TESTING, CLAUDE.md
- [x] Contrats de données (`Types`, `DataSchema` v1), invariants économiques testés

## Phase 1 — Prototype jouable ✅ (à valider en Studio)
- [x] Parcelle personnelle 3×3, attribution/libération, téléportation
- [x] Sauvegarde : verrou de session, UpdateAsync, autosave, BindToClose, migrations, repli mémoire en Studio
- [x] Croissance par timestamps, replantation automatique
- [x] Récolte manuelle (ProximityPrompt), bonus Parfait/Bien, sac à capacité
- [x] Marché : vente → Coins
- [x] Boutique de graines (7 plantes, déblocage séquentiel, sélection)
- [x] HUD responsive (Coins, sac, graines, notifications, chargement)
- [ ] **Validation manuelle en Studio** (checklist `docs/TESTING.md`) — nécessite Studio

## Phase 2 — Mutations
- [ ] MutationService : tirage pondéré à la plantation (`MutationRoll`, `MutationOdds` serveur)
- [ ] Visuels de mutation optimisés (matériau/couleur/échelle, particules limitées)
- [ ] Mutation Essence à la récolte, Mutadex (données + UI)
- [ ] Événement Pluie mutagène (EventService)

## Phase 3 — Croissance de la ferme
- [ ] Améliorations normales (vitesse, valeur, sac) — UpgradeService + UI
- [ ] Extensions latérales `west`/`east`, terrasses (escaliers, déblocage)
- [ ] Événement Floraison dorée
- [ ] Simulateur d'économie Lune + rééquilibrage

## Phase 4 — Automatisation
- [ ] AutomationService : drones récolteurs/collecteurs (simulation agrégée), vente auto
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
