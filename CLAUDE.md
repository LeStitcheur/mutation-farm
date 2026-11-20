# CLAUDE.md — MUTATION FARM

Jeu Roblox de farming incrémental hybride. Luau `--!strict`, Rojo, serveur autoritaire.
Docs de référence : `docs/GAME_DESIGN.md`, `docs/ARCHITECTURE.md`, `docs/ECONOMY.md`, `docs/ROADMAP.md`, `docs/TESTING.md`.

## Commandes

```powershell
pwsh scripts/setup-tools.ps1      # installe rojo/stylua/selene/lune/luau-lsp dans tools/bin (une fois)
pwsh scripts/check.ps1            # sourcemap + StyLua + Selene + luau-lsp strict + tests Lune + build
pwsh scripts/check.ps1 -Fix       # idem en appliquant le formatage
tools/bin/lune.exe run tests/run.luau                 # tests unitaires seuls
tools/bin/rojo.exe serve                              # synchro live avec Studio (plugin Rojo)
tools/bin/rojo.exe build -o build/MutationFarm.rbxlx  # place autonome
```

`scripts/check.ps1` doit être **vert avant tout commit**.

## Arborescence (Rojo)

- `src/shared` → `ReplicatedStorage.Shared` : `Types`, `Net`, `Config/*` (gelées), `Util/*` (logique **pure**).
- `src/server` → `ServerScriptService.Server` : `Services/*`, `Infra/*`, `Config/*` (secret : probabilités).
- `src/client` → `StarterPlayerScripts.Client` : `Controllers/*`, `UI/*`, `Visuals/*`.
- `tests/specs/*.spec.luau` : specs TestEZ exécutées par Lune (`tests/run.luau`).

## Règles d'architecture (non négociables)

1. **Serveur autoritaire** : le client n'envoie que des intentions (`tileId`, `plantId`), jamais de montant, prix,
   timestamp ni résultat aléatoire. Toute entrée remote : `typeof`, longueur bornée, `RateLimiter`.
2. **Logique pure dans `src/shared/Util`**, sans API Roblox (sauf `game:GetService` pour les requires) → testée en Lune.
   Toute nouvelle règle de jeu calculable = module pur + spec.
3. **Données** : toute modification de `Types.PlayerData` = `DataSchema.VERSION + 1` + entrée `MIGRATIONS` + test.
   Toute mutation passe par `DataService.Update(player, fn)` (fn synchrone). Les Coins passent par `EconomyService`.
4. **Monnaies** en `BigNum` (`{ m, e }`, immuable, exact < 1e15). Jamais de `number` brut pour une monnaie.
5. **Temps** : `workspace:GetServerTimeNow()` ; croissance par timestamps, aucune boucle serveur par plante.
6. **Services** : `Init()` (connexions) puis `Start()` ; dépendances acycliques ; `DataService.Start` en dernier.
7. **Probabilités** de mutation uniquement dans `src/server/Config/MutationOdds.luau`.
8. **Achats** (Phase 6) : `ProcessReceipt` idempotent (voir ARCHITECTURE §8), jamais de vente de Primal Cores.

## Conventions

- Identifiants de code en anglais ; commentaires, docs et textes UI en français.
- Tabs, 120 colonnes (StyLua). `--!strict` en tête de chaque module `src/`.
- Configuration : modifier `Config/*` plutôt que des constantes en dur ; les invariants économiques sont testés
  (`tests/specs/Config.spec.luau`) — un test rouge après un rééquilibrage signale une rupture de courbe.
- Une phase à la fois (`docs/ROADMAP.md`), commit par incrément jouable.

## Limites connues de l'environnement

- Aucun test Studio n'est exécuté automatiquement : services et UI sont validés via `docs/TESTING.md` §2.
  Ne jamais affirmer qu'un comportement Studio a été testé sans outil (Studio MCP, voir `docs/TESTING.md` §3).
- En Studio sans accès API, `DataStoreAdapter` bascule en mémoire (avertissement console) : normal.
