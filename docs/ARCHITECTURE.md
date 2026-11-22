# MUTATION FARM — Architecture

## 1. Principes

1. **Serveur autoritaire** : monnaies, récoltes, mutations, achats, progression et sauvegarde sont décidés par le
   serveur. Le client ne fait qu'**afficher** et **demander**.
2. **Logique pure séparée** : toute règle de jeu calculable sans API Roblox vit dans `src/shared/Util/*`
   (fonctions pures, `--!strict`) et est couverte par des tests exécutés hors Studio (Lune).
3. **Configuration centralisée** : `src/shared/Config/*` (publique) et `src/server/Config/*` (secrète : probabilités).
4. **Services modulaires** à dépendances acycliques, cycle de vie `Init()` puis `Start()`.
5. **Timestamps plutôt que boucles** : la croissance est calculée à partir de `plantedAt + growTime`
   (`workspace:GetServerTimeNow()`), aucune boucle serveur par plante.
6. **Données d'abord** : `Types.luau` + `DataSchema` (version, migrations, réconciliation, validation JSON) sont le
   contrat. Toute évolution du schéma = migration + test.

## 2. Arborescence et mapping Rojo

```
default.project.json
src/
  shared/   -> ReplicatedStorage.Shared
    Types.luau            Contrats de données (PlayerData, TileState, ClientState…)
    Net.luau              Noms et accès aux RemoteEvents
    Config/               GameConfig, PlantConfig, MutationConfig, DroneConfig, ProgressionConfig, UpgradeConfig,
                          MutadexConfig, PetConfig, EventConfig, QuestConfig, ExpansionConfig, AutomationConfig
                          (gelées)
    Util/                 Logique pure : BigNum, Format, Growth, Economy, Inventory, MutationRoll,
                          DataSchema, Resets, FarmLayout, ClientView, Signal, Deep, SessionLock, SlotAllocator,
                          HarvestRules, DroneLogic, ProgressionMath, Upgrades, Mutadex, Pets, WorldEvents, Quests,
                          Hash, Expansions, Selling, Automation,
                          Bonuses (agrégation améliorations × familiers sous les plafonds globaux)
  server/   -> ServerScriptService.Server
    init.server.luau      Bootstrap des services
    Config/MutationOdds   Poids de mutation (jamais répliqués)
    Infra/                DataStoreAdapter, RateLimiter, Notifier, QuestNotifier
    Services/             DataService, EconomyService, PlantService, MutationService, FarmService, HarvestService,
                          DroneService, ProgressionService, RebirthService, PrestigeService,
                          UpgradeService, AutomationService, MutadexService, PetService, EventService, QuestService,
                          DevService (Studio uniquement),
                          SyncService
  client/   -> StarterPlayer.StarterPlayerScripts.Client
    init.client.luau      Bootstrap des contrôleurs
    Controllers/          StateController, HudController, RebirthController, PrestigeController, UpgradeController,
                          MutadexController, PetController, EventController, QuestController, PlantRenderer,
                          HarvestController,
                          DroneRenderer,
                          PetRenderer (familiers de tous les joueurs, rendu local), AutomationController
                          (menu latéral : grille de 2 colonnes, boutons ajoutés par les contrôleurs)
    UI/                   Theme, Builder, PanelHub (un panneau à la fois, chat masqué),
                          ModalPanel (base des panneaux du menu : bouton, touches, échelle, X / B, PanelHub),
                          ConfirmPanel (information + confirmation, sur ModalPanel : Rebirth et Prestige)
    Visuals/              PlantVisuals (modèles procéduraux)
tests/
  run.luau                Runner Lune (simule require(script…) et game:GetService)
  TestEZLite.luau         describe/it/expect compatibles TestEZ
  specs/*.spec.luau       Specs exécutables aussi par TestEZ en Studio
  sim/                    Simulateur économique (EconomySim) et rapport (`lune run tests/run.luau report`),
                          exposés aux specs comme TestService.Sim — jamais synchronisés dans le jeu
```

## 3. Services serveur

Graphe de dépendances (acyclique, ordre de démarrage) :

```
DataService ─┬─> EconomyService ──> PlantService ──> FarmService ──> HarvestService ──> DroneService
             └─> SyncService              MutationService ──┘
```
(`MutationService` ne dépend que de configurations : `MutationOdds`, `MutationConfig`, `MutationRoll`.
`DroneService` dépend de `HarvestService`, `FarmService`, `EconomyService` et `DataService`.
`ProgressionService` dépend de `DataService`, `FarmService` et `DroneService` ; `RebirthService` et
`PrestigeService` dépendent de `ProgressionService` ; `DevService` de `DataService` et `EconomyService` ; rien ne
dépend de ces trois derniers.)

| Service | Responsabilité | API publique principale |
|---|---|---|
| **DataService** | Chargement/sauvegarde, verrou de session, autosave, migrations | `GetData`, `Update`, `IsLoaded`, `SaveNow`, signaux `ProfileLoaded`, `ProfileReleasing`, `Changed` |
| **EconomyService** | Coins, vente du sac (× multiplicateur de revenu rebirth × prestige, calculé dans le mutateur) ; tout gain alimente l'historique et les cycles (`ProgressionMath.recordEarnings`) ; vente au marché et comptoir automatique (Phase 5) par la même règle pure `Selling.sellBag`, chacune dans son mutateur (jamais deux ventes du même objet) | `AddCoins`, `TrySpendCoins`, `SellAll`, `AutoSell` |
| **PlantService** | Graines (déblocage, sélection), durée de pousse effective | `GetSelectedSeed`, `ComputeGrowTime`, `UnlockSeed`, `SelectSeed` |
| **FarmService** | Fermes (attribution, construction), état des cases, replantation ; **extensions** (Phase 5) : chaque parcelle construite ou démontée selon `farm.plots` (`SyncPlots` : chargement, achat, rebirth / prestige), panneaux « À vendre » à invite serveur, achat `Expansions.purchase` dans un mutateur ; personnages posés sur un socle de terrasse qui apparaît | `PlantTile`, `ReplantEmpty`, `SyncPlots`, `BuyPlot`, `GetTilePart`, `OwnsTile`, `GetPlotModel`, `GetPlotOrigin`, signal `PlotReady` |
| **HarvestService** | Récoltes joueur et drone (règles communes `HarvestRules`, qui enregistrent aussi le Mutadex et l'XP des familiers dans le même mutateur), bonus de précision (joueur seulement), notification des mutations ≥ ×8 ; signal `Harvested(player, outcome, source)` après chaque récolte validée | `Harvest`, `HarvestForDrone`, `Harvested` |
| **MutadexService** | Annonces du Mutadex (Phase 4, jalon A) : premières découvertes et paliers accordés ; accorde au chargement les paliers déjà atteints | `OnHarvest` |
| **SyncService** | Réplication de l'état joueur (coalescée, ≤ 10 Hz) | — |
| **MutationService** | Tirage pondéré exclusif d'une mutation par plantation (`Random` serveur, poids `MutationOdds` × chance du joueur `Upgrades.luck`, poids mis en cache par niveau de chance) ; valide la configuration au démarrage | `Roll(luck?)` |
| **DroneService** | Station d'achat (ProximityPrompt serveur, propriétaire seulement), flotte sauvegardée (`machines.drones`), **une** boucle serveur pour tous les drones (intervalle `DroneLogic.interval`, planifié depuis l'échéance précédente), ancres `FarmDrone`  ; drones mis en pause par le joueur (`automation.dronesEnabled`, statut `paused`, Phase 5) | `Buy`, `Refresh` |
| **ProgressionService** | Exécution commune des transitions (§7.1) : verrou par joueur partagé rebirth/prestige, mutateur unique, replantation, flotte recalculée, notification, sauvegarde immédiate ; validation des révisions reçues | `Run`, `IsValidRevision` |
| **RebirthService** | Rebirth (Phase 3, jalon A) : remote, débit, règle `Resets.rebirth` exécutée par `ProgressionService.Run` | `Rebirth` |
| **PrestigeService** | Prestige (Phase 3, jalon B) : remote, débit, règle `Resets.prestige` exécutée par `ProgressionService.Run` | `Prestige` |
| **UpgradeService** | Achats d'améliorations (Phase 3, jalon C ; arbre Coins des améliorations normales, Phase 5, jalon B) : remote validé, débit, refus pendant une transition, `Upgrades.purchase` dans un mutateur, flotte recalculée pour les drones offerts | `Purchase` |
| **PetService** | Familiers (Phase 4, jalon B) : éclosion (aléa serveur, `Pets.hatch` dans un mutateur, **sauvegarde avant confirmation**), équiper / retirer / relâcher, annonces de niveau (signal `HarvestService.Harvested`), attribut `Pets` du joueur pour le rendu | `Hatch`, `Equip`, `Unequip`, `Release`, `OnLevelUps`, `GrantFreeEggs`, `Refresh` |
| **EventService** | Événements du monde (Phase 4, jalon C) : calendrier déterministe (`WorldEvents`, horloge serveur, identique sur tous les serveurs), état publié dans `ReplicatedStorage.WorldEvent` (attributs `EventId`, `StartsAt`, `EndsAt`, répliqués aux arrivées tardives), annonces de début et de fin ; bonus lus à l'instant de l'action (chance à la plantation, valeur à la récolte) | `Current`, `LuckFactor`, `ValueBonus`, `Force`, `ClearForced` (Studio) |
| **QuestService** | Missions (Phase 4, jalon D) : tirage déterministe par joueur et période (au chargement, puis contrôle toutes les 15 s), **sauvegardé** (aucun nouveau tirage en changeant de serveur) ; récupération `QuestClaim` validée et unique (`Quests.claim` dans un mutateur) ; annonces des missions terminées (récoltes via `HarvestService.Harvested` ; ventes, éclosions et rebirths via `Infra/QuestNotifier` dans leurs services) | `Refresh`, `Claim`, `Record` (Studio) |
| **DevService** | Outils de test **Studio uniquement** (`RunService:IsStudio()`) : `ServerStorage.MutationFarmDev` (BindableFunction, inaccessible aux clients) — `grantEarned`, `snapshot` | — |
| **AutomationService** | Automatisation (Phase 5, jalon C) : remote `AutomationRequest` validé (action, valeur, débit, aucune transition), achat du comptoir automatique et réglages (`Automation`, un mutateur), vente immédiate si le seuil est déjà atteint | `BuySeller`, `SetSetting` |
| *PurchaseService* | Phase 6 | |

Convention : chaque module service expose `Init()` (connexions, création d'instances) et `Start()` (boucles,
traitement des joueurs). `DataService.Start` est appelé en **dernier** pour que tous les abonnés soient prêts.

## 4. Réseau (RemoteEvents, dossier `ReplicatedStorage.Remotes`)

| Remote | Sens | Charge utile | Validation serveur |
|---|---|---|---|
| `HarvestRequest` | C→S | `tileId: string` | type, longueur ≤ 32, 8 req/s, propriété de la case, maturité (horloge serveur), distance ≤ 20 studs, capacité du sac |
| `UnlockSeed` | C→S | `plantId: string` | type, 4 req/s, existence, ordre séquentiel, solde |
| `SelectSeed` | C→S | `plantId: string` | type, 4 req/s, graine débloquée |
| `RebirthRequest` | C→S | `revision: number` (révision de progression affichée) | type, fini, entier, 0 ≤ r < 2³¹, 0,5 req/s, verrou par joueur ; révision = révision courante (sinon refus sans effet), seuil de Coins gagnés pendant le cycle |
| `PrestigeRequest` | C→S | `revision: number` (révision de progression affichée) | mêmes contrôles que `RebirthRequest` (verrou **partagé**) ; rebirths depuis le dernier prestige et Coins gagnés depuis le dernier prestige ≥ conditions |
| `UpgradePurchase` | C→S | `upgradeId: string`, `expectedLevel: number` (niveau affiché) | chaîne ≤ 32 du catalogue, entier 0..1 000, 4 req/s, aucune transition en cours ; niveau attendu = niveau courant (sinon refus sans effet), niveau < maximum, solde de la monnaie de l'arbre ≥ coût |
| `ClientReady` | C→S | — | 1 req/s ; si profil chargé : renvoi de `LoadStatus` + `StateSync` (rattrape les événements émis avant la connexion des écouteurs) |
| `PetHatch` | C→S | `eggId: string`, `expectedHatched: number` (éclosions affichées), `useFree: boolean` | chaîne ≤ 32 du catalogue, entier 0..1e9, booléen, 1 éclosion / 3 s, aucune transition en cours, aucune éclosion en sauvegarde ; révision attendue = `pets.hatched` (sinon sans effet), inventaire < 50, œuf gratuit en réserve ou Coins ≥ prix (œuf vendu) |
| `PetEquip` / `PetUnequip` / `PetRelease` | C→S | `instanceId: string` | chaîne 1..32, 5 req/s, aucune transition ; instance existante et active (équiper : < 3 équipés ; relâcher : non équipée) |
| `QuestClaim` | C→S | `missionId: string` | chaîne 1..32, 4 req/s, aucune transition ; mission connue de la période courante, terminée, non récupérée (sinon sans effet) |
| `AutomationRequest` | C→S | `action: string`, `value` (booléen ou nombre selon l'action) | chaîne 1..16 parmi `buy_seller` / `drones` / `autosell` / `threshold`, booléen pour les interrupteurs, nombre fini pour le seuil (50, 75, 100), 4 req/s, aucune transition ; comptoir non possédé et Coins ≥ prix (achat) |
| `StateSync` | S→C | `ClientState` | — |
| `PetHatched` | S→C | `{ eggId, instanceId, petId, saved }` — **après** la tentative de sauvegarde | — |
| `HarvestResult` | S→C | `{ tileId, plantId, mutation, tier, bonus, source, discovered, eventBonus }` (`source` : `"player"` / `"drone"` ; `discovered` : première récolte de la combinaison au Mutadex ; `eventBonus` : part de valeur de la Floraison dorée versée à la récolte) | — |
| `Notify` | S→C | `{ kind, text }` | — |
| `LoadStatus` | S→C | `{ status, message }` | — |

L'événement du monde actif n'utilise aucun remote : `ReplicatedStorage.WorldEvent` porte trois attributs écrits par le serveur
(`EventId`, `StartsAt`, `EndsAt`) ; le client n'en tire que l'affichage (`docs/EVENTS.md`).

Règle 7 (probabilités de mutation côté serveur) : les **poids** et le facteur de la Pluie mutagène restent dans
`Server/Config/MutationOdds` ; les bonus de chance des améliorations, des familiers et de la Rosée chanceuse sont des
multiplicateurs publics (affichés au joueur), appliqués aux poids par le serveur et plafonnés par `Util/Bonuses`.

La vente passe par un `ProximityPrompt` serveur (le moteur valide la distance) avec un délai anti-spam.
L'achat d'extensions de ferme aussi (Phase 5 : panneau « À vendre » de chaque emplacement, appui de 0,5 s,
propriétaire seulement, 2 achats/s, ordre et prix validés par `Expansions.purchase`).
L'achat de drones aussi (station de la parcelle, appui de 0,4 s, propriétaire seulement, 2 achats/s) : aucun remote
d'achat n'existe, le client ne peut fournir ni prix ni quantité.
Aucune `RemoteFunction` serveur→client.

## 5. État des cases et rendu

- Données : `farm.tiles[tileId] = { plantId, plantedAt, growTime, mutation? }` (absent = case vide).
- Le serveur construit la géométrie statique (socle, cases, marché, panneau) et écrit sur chaque case
  (`CollectionService` tag `FarmTile`) les attributs `TileId`, `PlantId`, `PlantedAt`, `GrowTime`, `Mutation`.
- Le client (`PlantRenderer`) construit **localement** les modèles de plantes de toutes les parcelles et anime la
  croissance à 10 Hz via `Model:ScaleTo` à partir des attributs → zéro coût serveur par image.
- Le client (`HarvestController`) crée des `ProximityPrompt` **locaux** sur ses propres cases mûres.
- **Mutations (Phase 2)** : `FarmService.PlantTile` appelle `MutationService.Roll()` → `tile.mutation` (nil = normale),
  sauvegardée avec la case puis exposée par l'attribut `Mutation`. La récolte place `"<plante>|<mutation>"` dans le sac
  à partir de la donnée serveur (jamais de l'attribut) ; la vente applique `valeurBase × multiplicateur`.
  Le client ne fait qu'afficher : style 3D (`PlantVisuals`), invite « Carotte · Brillante ×2 », texte flottant.
  Modifier l'attribut côté client ne change que l'affichage local (vérifié en Studio).
- **Drones (Phase 2)** : `DroneService` lit `machines.drones`, place un point d'attente local par drone
  (`DroneLogic.homePosition`) et, toutes les 0,25 s, fait agir chaque drone dont l'`interval` est écoulé :
  `DroneLogic.selectTargets` (cases mûres depuis au moins `graceDelay` = 5 s, débloquées, à portée, la plus ancienne
  d'abord, non réservées pendant le tick) → `HarvestService.HarvestForDrone`. `HarvestRules.check` puis `apply` s'exécutent dans le même mutateur
  synchrone de `DataService.Update` : un joueur et un drone ne peuvent jamais récolter deux fois la même culture.
  Le serveur n'écrit que des attributs sur des ancres invisibles (`Status`, `TargetTile`, `ActionAt`) ; `DroneRenderer`
  anime localement vol, pales, aller-retour et bulle « Sac plein ! ». Ajouter un type = une entrée de `DroneConfig`.

## 6. Temps, croissance, hors ligne

- Horloge unique : `workspace:GetServerTimeNow()` (secondes Unix, synchronisée client/serveur).
- `growTime` est figé à la plantation (les bonus futurs ne modifient pas les cultures en cours).
- La croissance continue hors ligne (timestamps). La production **automatisée** hors ligne (Phase 4) sera simulée de
  façon agrégée sur `min(now − meta.lastSeen, 7200 s)`.

## 7. Persistance (DataService)

**Clé** : `player_<UserId>` dans le DataStore `MutationFarm_PlayerData_v1`.

**Enregistrement** :
```lua
{ format = 1, data = PlayerData, session = { id = "<GUID serveur>", heartbeat = 1763625600 } | nil, savedAt = 1763625600 }
```

**Algorithme** (règles du verrou : module pur `Shared.Util.SessionLock`, testé en Lune avec une simulation
multi-serveurs ; `DataService` ne fait que les appliquer dans `UpdateAsync`)
1. **Chargement** : `UpdateAsync` ; si `session` appartient à un autre serveur et `heartbeat` < 120 s → verrou actif,
   la transformation retourne `nil` (aucune écriture), nouvelle tentative toutes les 5 s jusqu'à 130 s puis kick.
   Sinon on écrit notre `session` (vol du verrou périmé) et on lit `data`.
2. **Migration** : `DataSchema.load` → migrations `version → VERSION` (schéma **v6** depuis la Phase 5, jalon C), réconciliation
   avec le gabarit (valeurs d'un type incompatible consignées), assainissement : toute valeur retirée, remplacée ou
   corrigée part en quarantaine (`meta.quarantine`), jamais supprimée silencieusement — voir
   `docs/DATA_MIGRATIONS.md`. Une version **future** (serveur obsolète) refuse le
   chargement **sans écrire**.
3. **Autosave** toutes les 45 s (rafraîchit `heartbeat`). Avant chaque écriture : copie profonde + `DataSchema.validate`
   (JSON-safe) ; donnée invalide = pas d'écriture.
4. **Perte de verrou** : si un autre serveur détient la session lors d'une sauvegarde, la transformation annule,
   le profil est marqué perdu (plus aucune écriture) et le joueur est expulsé.
5. **Départ / BindToClose** : sauvegarde finale avec `session = nil` (3 tentatives avec backoff).
   Un rejoin rapide sur le **même** serveur attend la fin de cette sauvegarde (`releasing[UserId]`) avant de recharger :
   le verrou porte notre propre identifiant de session et serait sinon repris sur une donnée antérieure.
6. **Jamais** de jeu sans données chargées : en cas d'échec, kick avec message (aucune sauvegarde d'un gabarit vide).
7. **Studio** : si l'accès API est désactivé, repli automatique sur un store mémoire (avertissement en console).

### 7.1 Transitions de progression (rebirth, prestige — `ProgressionService.Run`)

Règles et listes exactes : `docs/PROGRESSION.md`. Principe :
1. Le client n'envoie que la `revision` de progression qu'il affiche.
2. Validation, reset et récompense s'exécutent dans **un seul** mutateur synchrone (`Resets.rebirth` ou
   `Resets.prestige` dans `DataService.Update`) : aucune récolte, vente ou tâche de drone ne peut s'intercaler ; une
   révision périmée (requête rejouée, doublée, concurrente ou préparée avant l'autre type de transition) est refusée
   sans effet ; `revision + 1` à chaque transition.
3. Verrou par joueur **commun** à toutes les transitions pendant la replantation, la flotte et la sauvegarde : une
   seule transition à la fois ; une erreur après le mutateur est journalisée et libère toujours le verrou.
4. `SaveNow` immédiat ; chaque enregistrement contient l'état avant **ou** après (jamais de récompense sans reset).
   Échec : avertissement, l'autosave réessaie avec le même état cohérent.

## 8. Achats (Phase 6 — conception figée)

`ProcessReceipt` :
1. Joueur absent ou profil non chargé → `NotProcessedYet`.
2. `PurchaseId` déjà dans `data.receipts` → `PurchaseGranted` (idempotence).
3. Appliquer l'effet dans `DataService.Update`, ajouter `PurchaseId` (FIFO borné à 200).
4. `DataService.SaveNow(player)` ; succès → `PurchaseGranted`, échec → `NotProcessedYet` (Roblox réessaiera,
   l'étape 2 empêche le double octroi).
Game Passes : `UserOwnsGamePassAsync` au chargement + `PromptGamePassPurchaseFinished`, jamais stockés comme vérité.

## 9. Grands nombres

`BigNum` (voir `docs/ECONOMY.md` §6) : exact < 10¹⁵, 15 chiffres significatifs au-delà, opérations immuables,
sérialisation directe. Monnaies et valeurs : `BigNum`. Compteurs (niveaux, rebirths) : `number` entiers.

## 10. Sécurité

- Toute entrée client est typée, bornée et limitée en débit (`RateLimiter`, seau à jetons par joueur).
- Le client n'envoie jamais de montant, de prix, de timestamp ni de résultat aléatoire.
- Les probabilités de mutation restent dans `ServerScriptService`.
- Aucun `loadstring`, aucun `HttpService` sortant (`DevService` n'utilise que `JSONEncode`, en Studio).
- Outils de test (`DevService`) : créés seulement si `RunService:IsStudio()`, exposés par une `BindableFunction`
  dans `ServerStorage` (jamais répliquée, inaccessible aux clients) ; aucun effet sur un serveur Roblox.
- Limites acceptées (prototype) : un client automatisé peut viser le palier Parfait (les attributs `PlantedAt`/`GrowTime`
  sont lisibles) — gain borné à +50 % et au débit limité ; l'autosave fait une seule tentative toutes les 45 s
  (une panne DataStore > 120 s peut faire perdre le verrou et expulser le joueur, données intactes au dernier succès).

## 11. Performance (budget)

- Serveur : aucune boucle par plante ; autosave étalée ; réplication d'état coalescée (≤ 10 Hz, uniquement si modifié).
- Client : rendu des plantes local, mise à l'échelle uniquement si variation > 1 %, `CastShadow = false`,
  `CanCollide/CanQuery/CanTouch = false` sur les décors, particules à faible débit, uniquement sur les plantes mûres.
- `StreamingEnabled = false` pour le prototype (petite carte) — à réévaluer en Phase 7.
