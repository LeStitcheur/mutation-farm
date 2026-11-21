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
    Config/               GameConfig, PlantConfig, MutationConfig, DroneConfig, ProgressionConfig (gelées)
    Util/                 Logique pure : BigNum, Format, Growth, Economy, Inventory, MutationRoll,
                          DataSchema, Resets, FarmLayout, ClientView, Signal, Deep, SessionLock, SlotAllocator,
                          HarvestRules, DroneLogic, ProgressionMath
  server/   -> ServerScriptService.Server
    init.server.luau      Bootstrap des services
    Config/MutationOdds   Poids de mutation (jamais répliqués)
    Infra/                DataStoreAdapter, RateLimiter, Notifier
    Services/             DataService, EconomyService, PlantService, MutationService, FarmService, HarvestService,
                          DroneService, RebirthService, DevService (Studio uniquement), SyncService
  client/   -> StarterPlayer.StarterPlayerScripts.Client
    init.client.luau      Bootstrap des contrôleurs
    Controllers/          StateController, HudController, RebirthController, PlantRenderer, HarvestController,
                          DroneRenderer
    UI/                   Theme, Builder, PanelHub (un panneau à la fois, chat masqué)
    Visuals/              PlantVisuals (modèles procéduraux)
tests/
  run.luau                Runner Lune (simule require(script…) et game:GetService)
  TestEZLite.luau         describe/it/expect compatibles TestEZ
  specs/*.spec.luau       Specs exécutables aussi par TestEZ en Studio
```

## 3. Services serveur

Graphe de dépendances (acyclique, ordre de démarrage) :

```
DataService ─┬─> EconomyService ──> PlantService ──> FarmService ──> HarvestService ──> DroneService
             └─> SyncService              MutationService ──┘
```
(`MutationService` ne dépend que de configurations : `MutationOdds`, `MutationConfig`, `MutationRoll`.
`DroneService` dépend de `HarvestService`, `FarmService`, `EconomyService` et `DataService`.
`RebirthService` dépend de `DataService`, `FarmService` et `DroneService` ; `DevService` de `DataService` et
`EconomyService` ; rien ne dépend d'eux.)

| Service | Responsabilité | API publique principale |
|---|---|---|
| **DataService** | Chargement/sauvegarde, verrou de session, autosave, migrations | `GetData`, `Update`, `IsLoaded`, `SaveNow`, signaux `ProfileLoaded`, `ProfileReleasing`, `Changed` |
| **EconomyService** | Coins, vente du sac (× multiplicateur de rebirth, calculé dans le mutateur) ; tout gain alimente l'historique et les cycles (`ProgressionMath.recordEarnings`) | `AddCoins`, `TrySpendCoins`, `SellAll` |
| **PlantService** | Graines (déblocage, sélection), durée de pousse effective | `GetSelectedSeed`, `ComputeGrowTime`, `UnlockSeed`, `SelectSeed` |
| **FarmService** | Parcelles (attribution, construction), état des cases, replantation | `PlantTile`, `ReplantEmpty`, `GetTilePart`, `OwnsTile`, `GetPlotModel`, `GetPlotOrigin`, signal `PlotReady` |
| **HarvestService** | Récoltes joueur et drone (règles communes `HarvestRules`), bonus de précision (joueur seulement), notification des mutations ≥ ×8 | `Harvest`, `HarvestForDrone` |
| **SyncService** | Réplication de l'état joueur (coalescée, ≤ 10 Hz) | — |
| **MutationService** | Tirage pondéré exclusif d'une mutation par plantation (`Random` serveur, poids `MutationOdds`) ; valide la configuration au démarrage | `Roll` |
| **DroneService** | Station d'achat (ProximityPrompt serveur, propriétaire seulement), flotte sauvegardée (`machines.drones`), **une** boucle serveur pour tous les drones, ancres `FarmDrone` | `Buy`, `Refresh` |
| **RebirthService** | Rebirth (Phase 3, jalon A) : verrou par joueur, débit, transition atomique `Resets.rebirth` (§7.1), replantation, flotte vidée, sauvegarde immédiate | `Rebirth` |
| **DevService** | Outils de test **Studio uniquement** (`RunService:IsStudio()`) : `ServerStorage.MutationFarmDev` (BindableFunction, inaccessible aux clients) — `grantEarned`, `snapshot` | — |
| *AutomationService* | Phase 4 (drones collecteurs, vente auto, hors ligne) | |
| *PrestigeService* | Phase 3, jalon B | |
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
| `ClientReady` | C→S | — | 1 req/s ; si profil chargé : renvoi de `LoadStatus` + `StateSync` (rattrape les événements émis avant la connexion des écouteurs) |
| `StateSync` | S→C | `ClientState` | — |
| `HarvestResult` | S→C | `{ tileId, plantId, mutation, tier, bonus, source }` (`source` : `"player"` / `"drone"`) | — |
| `Notify` | S→C | `{ kind, text }` | — |
| `LoadStatus` | S→C | `{ status, message }` | — |

La vente passe par un `ProximityPrompt` serveur (le moteur valide la distance) avec un délai anti-spam.
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
2. **Migration** : `DataSchema.load` → migrations `version → VERSION` (schéma **v2** depuis la Phase 3), réconciliation
   avec le gabarit, assainissement : toute valeur retirée ou corrigée part en quarantaine (`meta.quarantine`), jamais
   supprimée silencieusement — voir `docs/DATA_MIGRATIONS.md`. Une version **future** (serveur obsolète) refuse le
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

### 7.1 Transitions de progression (rebirth ; prestige au jalon B)

Règles et listes exactes : `docs/PROGRESSION.md`. Principe :
1. Le client n'envoie que la `revision` de progression qu'il affiche.
2. Validation, reset et récompense s'exécutent dans **un seul** mutateur synchrone (`Resets.rebirth` dans
   `DataService.Update`) : aucune récolte, vente ou tâche de drone ne peut s'intercaler ; une révision périmée
   (requête rejouée, doublée ou concurrente) est refusée sans effet ; `revision + 1` à chaque transition.
3. Verrou `busy[player]` pendant la transition (replantation, flotte, sauvegarde) : une seule transition à la fois.
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
