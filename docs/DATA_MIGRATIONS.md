# MUTATION FARM — Schéma et migrations des données joueur

> Code : `src/shared/Types.luau` (contrat `PlayerData`), `src/shared/Util/DataSchema.luau` (gabarit, migrations,
> réconciliation, assainissement, validation JSON). Tests : `tests/specs/DataSchema.spec.luau`.
> Stockage et verrou de session : `docs/ARCHITECTURE.md` §7.

## 1. Règles

1. Toute modification de `Types.PlayerData` = `DataSchema.VERSION + 1` + entrée `MIGRATIONS[nouvelle version]` + test.
2. Une migration transforme une donnée de version `v − 1` en version `v`. Elle est **défensive** (tables absentes,
   compteurs corrompus) et **ne supprime jamais** de champ : un champ devenu inutile reste stocké tel quel
   (ex. `currencies.rebirthTokens`, obsolète depuis la v2).
3. **Aucune suppression silencieuse** : toute valeur retirée ou corrigée par l'assainissement part en
   **quarantaine** (`meta.quarantine`) avec une note dans les journaux du serveur.
4. Une donnée de version **future** (serveur obsolète) est refusée **sans écriture** : le joueur est expulsé avec un
   message, la donnée reste intacte pour le serveur à jour.
5. Avant chaque écriture : copie profonde + `DataSchema.validate` (JSON sans perte). Donnée invalide = pas d'écriture.

## 2. Chargement (`DataSchema.load`)

```
donnée brute ──> version future ? ── oui ──> refus (aucune écriture)
                     │ non
                     ▼
              migrations v → VERSION (dans l'ordre)
                     ▼
              réconciliation avec le gabarit (champs manquants ajoutés, valeurs existantes conservées)
                     ▼
              assainissement (corrections → quarantaine + notes)
```

## 3. Versions

| Version | Phase | Contenu |
|---|---|---|
| 0 | — | Donnée sans champ `version` : traitée comme v0, migrée jusqu'à la version courante |
| 1 | Phases 0–2 | Schéma initial : monnaies, ferme, graines, sac, améliorations, machines (drones), progression (`rebirths`, `prestiges`), Mutadex, cosmétiques, familiers, statistiques, reçus, méta |
| 2 | Phase 3, jalon A | Progression : `revision`, `cycleCoins`, `prestigeCoins` ; `stats.totalRebirths` ; `meta.quarantine` |
| 3 | Phase 4, jalon A | Mutadex : `mutadex[clé] = { firstAt, count }` (au lieu d'un horodatage) ; `mutadexRewards` (paliers accordés) |
| 4 | Phase 4, jalon B | Familiers : `pets.instances` (instances uniques), `equipped` = identifiants d'instances, `nextSerial`, `hatched`, `freeEggs` |
| **5** | Phase 4, jalon D | Missions : `quests.daily` / `quests.weekly` (`period`, `missions`), `quests.claimed` ; `boosts` (fin des boosts temporaires) |

### Migration v1 → v2 (`MIGRATIONS[2]`)
- `progression.revision = 0`.
- `progression.cycleCoins` = copie de `stats.coinsEarned` si le joueur n'a fait **aucun** rebirth ni prestige
  (cas de toutes les données v1 : ces systèmes n'existaient pas), sinon 0.
- `progression.prestigeCoins` = copie de `stats.coinsEarned` si aucun prestige, sinon 0.
- `stats.totalRebirths = progression.rebirths`.
- Tables `progression` / `stats` absentes ou invalides : recréées ; compteurs non numériques : traités comme 0 pour
  le calcul (la valeur d'origine reste en place jusqu'à l'assainissement, qui la met en quarantaine).
- `meta.quarantine` est ajouté par la réconciliation (liste vide).

Conséquence : un joueur v1 ayant déjà gagné ≥ 100 000 Coins peut faire son premier rebirth dès son retour.

### Migration v2 → v3 (`MIGRATIONS[3]`, Mutadex)
- Une entrée `mutadex[clé]` au format v2 (un horodatage, jamais écrit par le jeu avant la Phase 4) devient
  `{ firstAt = horodatage, count = 1 }` (la récolte de découverte). Rien n'est supprimé.
- `mutadexRewards` est ajouté vide par la réconciliation ; les paliers déjà atteints sont accordés au chargement
  suivant par `MutadexService` (une seule fois).
- Entrées ou paliers malformés → quarantaine ; entrées et paliers bien formés mais absents de la configuration →
  conservés en sommeil (`docs/MUTADEX.md` §4).

### Migration v3 → v4 (`MIGRATIONS[4]`, familiers)
- L'ancien contrat (`pets.owned` = nombre d'exemplaires par espèce, `pets.equipped` = espèces) n'a jamais été écrit
  par le jeu. S'il existe : chaque exemplaire devient une instance `p<n>` de niveau 1 (`obtainedAt` = création du
  compte), dans l'ordre alphabétique des espèces ; les espèces équipées sont reportées sur ces instances (3 au plus).
- **Rien n'est supprimé** : `pets.owned` reste stocké tel quel (obsolète, comme `currencies.rebirthTokens`) ;
  l'ancienne liste équipée est copiée dans `pets.legacyEquipped`. Un compteur > 1 000 est jugé corrompu et
  n'est pas converti (il reste dans `owned`).
- `nextSerial` = dernier numéro + 1, `hatched = 0`, `freeEggs = {}`. Une table `pets.instances` déjà présente
  n'est jamais écrasée.

### Migration v4 → v5 (`MIGRATIONS[5]`, missions)
- Aucune transformation : `quests` (tableaux de période −1, jamais tirés) et `boosts` (vide) sont ajoutés par la
  réconciliation ; `QuestService` tire les missions de la période au chargement du profil.
- Assainissement : un tableau de missions invalide (période, mission malformée, progression > objectif) part en
  quarantaine tel quel puis est tiré à nouveau ; compteur `claimed` invalide → 0 (quarantaine) ; boost malformé →
  quarantaine ; boost inconnu bien formé → conservé, sans effet.

### Réconciliation : types incompatibles (correctif Phase 4)
Avant la Phase 4, `DataSchema.reconcile` remplaçait **silencieusement** une valeur d'un autre type que le gabarit
(ex. `stats.harvests = "douze"` → 0, `cosmetics = 7` → table vide). Désormais chaque remplacement est consigné
(chemin + valeur d'origine) et mis en **quarantaine** par `DataSchema.load` (raison « type incompatible -> valeur
par défaut »), y compris une liste de quarantaine elle-même invalide. Testé (`DataSchema.spec`).

## 4. Quarantaine (`meta.quarantine`)

Entrée : `{ path, value, reason, at }` (`Types.QuarantineEntry`).
- `value` : valeur d'origine si elle est sérialisable en JSON, sinon sa représentation texte (`tostring`).
- Liste FIFO bornée à `GameConfig.Data.MaxQuarantine` (100) : au-delà, les plus anciennes entrées sortent.
- Couvre : montants `BigNum` invalides ou négatifs (monnaies, `coinsEarned`, `cycleCoins`, `prestigeCoins`),
  parcelles et cases inconnues ou invalides (Phase 5 : état de parcelle non booléen → parcelle verrouillée ; le
  champ `farm.plots` existait déjà, aucune nouvelle version), objets du sac, graines inconnues, sélection non débloquée, drones
  inconnus ou au-delà du maximum, compteurs invalides (`rebirths`, `prestiges`, `revision`, `totalRebirths`,
  `rebirthTokens`), reçus non textuels, liste de quarantaine elle-même invalide, **niveaux d'améliorations**
  (Phase 3, jalon C : identifiant inconnu ou rangé dans le mauvais arbre, niveau non entier, négatif ou nul →
  retiré ; au-delà du maximum → plafonné, valeur d'origine en quarantaine). Le schéma reste en v2 : les champs
  `upgrades.rebirth` / `upgrades.permanent` existaient déjà, seul leur contenu est désormais validé.
  Depuis la Phase 4 (v3) : **Mutadex** (entrées et paliers malformés, collection non tabulaire) et toute valeur d'un
  **type incompatible** remplacée par la réconciliation. Depuis la v4 : **familiers** (instance malformée, niveau
  au-delà du maximum → plafonné, compteur d'éclosions invalide, œufs gratuits invalides ou au-delà de la réserve,
  liste équipée corrigée — liste d'origine conservée). Espèces et paliers retirés de la configuration : conservés
  **en sommeil**, pas en quarantaine (`docs/PETS.md` §8, `docs/MUTADEX.md` §4).
- La troncature FIFO des reçus (au-delà de 200) est signalée par une note (les reçus retirés sont les plus anciens).
- Récupération : lire `meta.quarantine` (Studio : `ServerStorage.MutationFarmDev:Invoke("snapshot", userId)`) puis
  restaurer par une migration dédiée si une donnée doit être rendue au joueur.

## 5. Ajouter une version (checklist)

1. Modifier `Types.PlayerData` (+ `ClientState`/`ClientView` si répliqué).
2. `DataSchema.VERSION + 1`, gabarit mis à jour, `MIGRATIONS[n]` défensive et sans suppression.
3. Assainissement : toute nouvelle valeur corrigible passe par `quarantine(...)`.
4. Tests : migration nominale, migration défensive (tables manquantes, valeurs corrompues), rechargement
   (`load(serialize(data))`), validation JSON.
5. Documenter la version ici (§3) et la phase dans `docs/ROADMAP.md`.

## 6. Limites

Les tests de migration et de sauvegarde sont des **simulations** Lune (store mémoire à sémantique `UpdateAsync`) :
ils ne remplacent pas une validation avec le vrai DataStore (place publiée, accès API activé — `docs/TESTING.md` §2.4).
