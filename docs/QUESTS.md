# MUTATION FARM — Missions quotidiennes et hebdomadaires (Phase 4, jalon D)

> Configuration : `src/shared/Config/QuestConfig.luau`. Règles pures : `src/shared/Util/Quests.luau` (et
> `Util/Hash.luau`). Serveur : `QuestService` (+ `Infra/QuestNotifier`). Interface : `QuestController` (bouton
> « Missions », touche **J**, manette **R3**). Tests : `tests/specs/Quests.spec.luau`.

## 1. Périodes et renouvellement

| Type | Missions | Renouvellement | Identifiant de période |
|---|---|---|---|
| Quotidiennes | 3 (Facile, Moyenne, Difficile) | **00:00 UTC** | jour UTC = `floor(t / 86400)` |
| Hebdomadaires | 2 (Moyenne, Difficile) | **lundi 00:00 UTC** | semaine = `(jour + 3) // 7` (le 1er janvier 1970 était un jeudi) |

- Le serveur tire les missions d'une période **une seule fois** (au chargement du profil, puis au changement de
  période — contrôle toutes les 15 s pour les joueurs connectés) et les **sauvegarde**. Une reconnexion ou un
  changement de serveur relit les missions sauvegardées : rien n'est retiré (testé).
- Tirage **déterministe** : `Hash(userId, période, type, emplacement)` parmi les modèles éligibles, sans doublon de
  modèle dans une période. Un même joueur obtient les mêmes missions pour une même période et un même état.
- Une mission non récupérée à la fin de sa période **expire** (elle disparaît au tirage suivant ; la récupérer après
  la fin est refusé). Une période échue ne progresse plus.

## 2. Catalogue (objectifs chiffrés)

| Modèle | Objectif | Quotidien F / M / D | Hebdo M / D | Éligibilité |
|---|---|---|---|---|
| `harvest` | Récolte N plantes (joueur ou drones) | 40 / 120 / 300 | 800 / 2 000 | — |
| `harvest_manual` | Récolte N plantes à la main | 25 / 80 / 200 | 500 / 1 200 | — |
| `harvest_perfect` | Réussis N récoltes Parfait | 10 / 30 / 75 | 200 / 500 | — |
| `harvest_plant` | Récolte N plantes : *plante* | 20 / 60 / 150 | 400 / 1 000 | plante tirée parmi les graines débloquées |
| `mutation` | Récolte N plantes mutées | 5 / 15 / 40 | 100 / 250 | — |
| `mutation_rare` | Récolte N mutations ×8 ou plus | — / 1 / 3 | 10 / 25 | — |
| `drone_harvest` | Laisse tes drones récolter N plantes | 30 / 100 / 250 | 600 / 1 500 | au moins un drone |
| `sell` | Vends ton sac N fois | 5 / 12 / 25 | 60 / 150 | — |
| `discover` | Découvre N combinaisons du Mutadex | — | 1 / 3 | au moins N combinaisons restantes |
| `hatch` | Ouvre N œufs | — | 2 / 5 | — |
| `rebirth` | Fais N rebirth(s) | — | 1 / 3 | au moins un rebirth déjà fait |

## 3. Récompenses (proportionnelles à la difficulté)

| Période / difficulté | Coins (× revenu du joueur au tirage) | Autres |
|---|---|---|
| Quotidienne facile | 1 500 | — |
| Quotidienne moyenne | 4 000 | boost **Engrais** (10 min : +25 % de la valeur de chaque récolte, versés à la récolte) |
| Quotidienne difficile | 10 000 | 1 Œuf des missions |
| Hebdomadaire moyenne | 40 000 | 2 Œufs des missions + boost **Rosée chanceuse** (15 min : chance × 1,5 à la plantation) |
| Hebdomadaire difficile | 100 000 | 3 Œufs des missions + une **décoration** non possédée (nain mutant, épouvantail de cristal, moulin néon ; sinon 1 œuf de plus) |

- Coins : multipliés par le multiplicateur de revenu (rebirth × prestige × améliorations × familiers) **au moment
  du tirage** ; ils comptent comme Coins gagnés (cycle de rebirth et de prestige).
- Œufs : ajoutés à la réserve d'œufs gratuits (`docs/PETS.md`), plafonnée à 99 ; si la réserve ne peut pas tout
  recevoir, la récupération est **refusée sans rien accorder** (`reserve_full`) : le joueur ouvre des œufs puis
  récupère (aucune récompense perdue, testé).
- Boosts : prolongés à chaque activation, au plus 3 h restantes ; la chance reste plafonnée à 5 au total, le bonus
  de valeur s'ajoute à celui de la Floraison dorée (versé à la récolte).
- Décorations : cosmétiques possédés (`cosmetics.owned`) ; leur placement sur la parcelle viendra en Phase 5.

## 4. Progression (serveur autoritaire)

| Action | Où la progression est enregistrée (même mutateur que l'action) |
|---|---|
| Récolte (joueur ou drone) | `HarvestRules.apply` → `Quests.recordHarvest` (récolte, à la main / drones, Parfait, plante, mutation, mutation rare, découverte) |
| Vente | `EconomyService.SellAll` |
| Éclosion | `PetService.Hatch` |
| Rebirth | `RebirthService` (transition `ProgressionService.Run`) |

- Le client n'envoie **que** l'identifiant de la mission à récupérer (`QuestClaim` : chaîne ≤ 32, 4 req/s, aucune
  transition en cours). `Quests.claim` vérifie, dans **un** mutateur : mission connue, période courante, terminée,
  non récupérée → récompenses → `claimed = true`. Une seconde demande est refusée (`already_claimed`).
- La progression ne dépasse jamais l'objectif ; une sauvegarde trafiquée (progression > objectif, champ invalide)
  met le tableau en quarantaine et un nouveau tirage a lieu.
- Rebirth et prestige ne touchent ni aux missions ni aux boosts (testé).
- Notifications : « Mission terminée : … » (toutes sources) ; « Nouvelles missions disponibles » au changement de
  période ; pastille sur le bouton « Missions » tant qu'une récompense attend.
- Studio : `ServerStorage.MutationFarmDev:Invoke("questRecord", userId, objectif, n)`.

## 5. Interface (`QuestController`)

- Onglets Quotidiennes / Hebdomadaires, temps restant avant le renouvellement (horloge serveur), boosts actifs avec
  leur temps restant ; une ligne par mission : difficulté, objectif, barre de progression, récompenses, bouton
  Récupérer (Récupérée / En cours sinon).
- Clavier (J), tactile (boutons), manette (R3, prioritaire sur le zoom caméra par défaut de Roblox ; sélection directe du
  bouton Récupérer quand une récompense attend ;
  B ferme). Un seul panneau à la fois (`PanelHub`), chat masqué.

## 6. Persistance (schéma v5)

- `quests = { daily = { period, missions }, weekly = { period, missions }, claimed }`,
  `boosts = { [boost] = fin }` (`docs/DATA_MIGRATIONS.md`).
- Migration v4 → v5 : champs ajoutés par la réconciliation (période −1 : tirage au chargement) ; rien d'autre ne
  change.

## 7. Limites

- Pas de relance (reroll) de mission ni de série de jours consécutifs.
- Pas de missions liées aux événements (une Floraison peut ne pas avoir lieu pendant la session du joueur).
- Les décorations ne se posent pas encore (Phase 5).
- Après un rebirth ou un prestige, une mission « Récolte N plantes : *plante* » ou « Laisse tes drones récolter… »
  tirée avant la remise à zéro reste valable mais demande de redébloquer la graine ou de racheter un drone ; elle
  n'est pas tirée à nouveau (choix : pas de relance gratuite par rebirth).
