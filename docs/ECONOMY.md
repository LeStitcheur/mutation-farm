# MUTATION FARM — Économie

> Source de vérité des valeurs : `src/shared/Config/PlantConfig.luau`, `src/shared/Config/GameConfig.luau`,
> `src/shared/Config/ProgressionConfig.luau`, `src/server/Config/MutationOdds.luau`. Les invariants ci-dessous sont
> **testés automatiquement** (`tests/specs/Config.spec.luau`, `Economy.spec.luau`, `MutationRoll.spec.luau`,
> `Mutations.spec.luau`, `Progression.spec.luau`, `RebirthConcurrency.spec.luau`).

## 1. Plantes (Phase 1, implémenté)

Hypothèse de référence « jeu parfait » : 9 cases, récolte instantanée à maturité, sans bonus.

| # | Plante | Pousse | Valeur | Déblocage | Coins/s/case | Coins/s (9 cases) | Temps pour débloquer la suivante |
|---|---|---|---|---|---|---|---|
| 1 | Carotte | 6 s | 10 | gratuit | 1,67 | 15 | 50 s |
| 2 | Tomate | 12 s | 45 | 750 | 3,75 | 33,8 | 2 min 58 |
| 3 | Maïs | 20 s | 150 | 6 000 | 7,5 | 67,5 | 9 min 53 |
| 4 | Citrouille | 35 s | 550 | 40 000 | 15,7 | 141 | 29 min 28 |
| 5 | Champi-lune | 60 s | 2 000 | 250 000 | 33,3 | 300 | 1 h 23 |
| 6 | Fleur-étoile | 90 s | 6 500 | 1 500 000 | 72,2 | 650 | 4 h 16 |
| 7 | Fruit du dragon | 150 s | 22 500 | 10 000 000 | 150 | 1 350 | — |

Le rendement réel en récolte manuelle est d'environ 50–70 % (déplacements, trajets au marché). Les phases 3–4
(extensions ×3 cases, améliorations, drones) raccourciront fortement les derniers paliers : **rééquilibrage prévu en
Phase 3** avec un simulateur Lune.

## 2. Récolte et vente

- **Sac** : capacité de base 40 objets (améliorations Phase 3).
- **Valeur de vente** = `valeurBase(plante) × multiplicateur(mutation) × M(R) × Mp(P)` où `M(R)` et `Mp(P)` sont
  les multiplicateurs de rebirth et de prestige (§4), appliqués au total du sac et arrondis à l'inférieur
  (améliorations : jalon C).
- **Bonus de précision** du joueur (Coins instantanés, arrondis à l'inférieur) :
  Parfait (≤ 1,5 s) = 50 % de la valeur de base, Bien (≤ 5 s) = 20 %, puis `× M(R) × Mp(P)` (jamais la mutation).
- **Coins gagnés** (ventes + bonus) : alimentent `stats.coinsEarned` et les compteurs de cycle (`docs/PROGRESSION.md`).

## 3. Mutations (Phase 2, implémenté)

Tirage **exclusif** côté serveur à chaque plantation (`MutationService`). Poids sur 1 000 000, chance `L`
appliquée à tous les poids non normaux (`L = 1` en Phase 2) :

| Mutation | × | Poids | P (L = 1) |
|---|---|---|---|
| Normale | ×1 | 810 100 | 81,01 % |
| Brillante | ×2 | 120 000 | 12 % |
| Géante | ×4 | 50 000 | 5 % |
| Cristallisée | ×8 | 15 000 | 1,5 % |
| Radioactive | ×20 | 4 000 | 0,4 % |
| Astrale | ×50 | 800 | 0,08 % |
| Divine | ×150 | 100 | 0,01 % |

Espérance du multiplicateur : `E(L) = (810 100 + 695 000·L) / (810 100 + 189 900·L)`
→ E(1) = **1,5051**, E(3) ≈ 2,098 (Pluie mutagène, non implémentée).

**Changement de contrat (2026-11-20)** : le cahier des charges Phase 2 a relevé les probabilités (avant : 5 % /
1,667 % / 0,5 % / 0,1 % / 0,02 % / 0,004 %, E(1) = 1,170). Le revenu moyen par récolte augmente de **×1,286**
par rapport à l'ancien contrat (×1,505 par rapport à une ferme sans mutation) : les temps de déblocage réels
raccourcissent d'autant (ex. Carotte → Tomate : 50 s → ≈ 33 s en jeu parfait). À revoir au rééquilibrage Phase 3 ;
revenir en arrière = modifier les poids de `src/server/Config/MutationOdds.luau` (tests à ajuster).

Règles :
- La mutation multiplie la **valeur de vente** (`valeurBase × multiplicateur`) ; le bonus de précision reste calculé
  sur la valeur de **base** (invariant 4).
- Une récolte ≥ ×8 (Cristallisée et au-delà) déclenche une notification (`GameConfig.Mutations.NotifyMinMultiplier`).
- Hors périmètre Phase 2 actuel : Mutation Essence, Mutadex, Pluie mutagène, annonce serveur de la Divine.

## 4. Rebirth et Prestige (Phase 3 ; détail : `docs/PROGRESSION.md`)

**Rebirth (jalon A, implémenté)** — `ProgressionConfig.Rebirth` :
- **Seuil** du rebirth n° `n + 1` : `100 000 × 3,2ⁿ` Coins **gagnés pendant le cycle** (le solde ne compte pas).
- **Multiplicateur de revenu** après `R` rebirths : `M(R) = 1 + 0,35 R + 0,015 R²` (×1,365 ; ×1,76 ; ×2,185 ; … ×6 à R = 10).
- **Mutation Essence** : `floor(100 × (1 + n)^0,75 × min(gagné / seuil, 4)^0,5)` (100 au premier seuil, 168 au
  deuxième ; dépasser le seuil rapporte au plus ×2).
- Réinitialise Coins, graines, sac, améliorations normales, drones, cultures et Coins du cycle ; conserve le reste.
- Premier rebirth estimé à ≈ 14 min (jeu parfait) / ≈ 22 min (60 %) — à confirmer par le simulateur du jalon C.

**Prestige (jalon B, implémenté)** — `ProgressionConfig.Prestige` :
- **Conditions** (les deux) : rebirths depuis le dernier prestige ≥ 5 / 8 / 12 / 17 / 23… (`5 + 3p + p(p − 1)/2`) et
  Coins gagnés depuis le dernier prestige ≥ 1e7 / 1e8 / 1e9… (`10⁷ × 10ᵖ`).
- **Multiplicateur de prestige** permanent : `Mp(P) = 1 + 0,5 P + 0,08 P²` (×1,58 ; ×2,32 ; ×3,22…).
- **Primal Cores** : `floor(10 × (1 + p)^0,75 × (1 + 0,25 × min(rebirths en plus, 4)))` (10, 16, 22… au minimum).
- Réinitialise aussi parcelles achetées, rebirths du cycle, Mutation Essence, améliorations de rebirth et Coins du
  cycle de prestige ; conserve Primal Cores, améliorations permanentes, Mutadex, cosmétiques, familiers, droits
  Robux, statistiques.
- Constat mesuré : la condition de Coins est toujours satisfaite quand le minimum de rebirths l'est (15,2 M gagnés
  pour 5 rebirths > 10 M) ; elle reste un garde-fou configurable.

L'ancien contrat Phase 5 (coût `5·10⁷ × 6ⁿ`, multiplicateur `1,5ⁿ`, Rebirth Tokens, prestige à `8 + 4p` rebirths) est
**remplacé** par le cahier des charges Phase 3 ; `currencies.rebirthTokens` reste stocké mais n'est plus utilisé.

## 5. Invariants économiques (tests)

1. Chaque graine débloquée augmente strictement le revenu par case et par seconde.
2. Les prix de déblocage sont strictement croissants.
3. Le temps de déblocage (jeu parfait, graine précédente, 9 cases) est strictement croissant et compris entre 30 s et 6 h.
4. Le bonus de précision ne dépasse jamais 50 % de la valeur de base × `M(R) × Mp(P)` (jamais la mutation).
5. Les Coins ne deviennent jamais négatifs : toute dépense passe par `EconomyService.TrySpendCoins`.
6. Les multiplicateurs de mutation sont exactement 2, 4, 8, 20, 50, 150 ; les probabilités sont celles du §3 et
   somment à 1 ; E(1) = 1,5051 ∈ [1,4 ; 1,6] (avant Phase 2 : [1,1 ; 1,3]).
7. La croissance du seuil de rebirth (×3,2) dépasse celle du multiplicateur (`M(R+1)/M(R)` ≤ ×1,365), testé pour
   R = 0..60 : chaque rebirth est plus long que le précédent à production égale (×2,34 à ×2,9).
8. Production hors ligne plafonnée à 7 200 s.
9. Les drones ne touchent jamais de bonus de précision, ne dépassent jamais la production de la ferme ni la capacité
   du sac, et ne réduisent jamais les **ventes** du joueur (simulation, §7).
10. Le premier drone se rembourse en ≤ 30 min là où il rapporte (Carotte en jeu actif, joueur absent qui vend).
11. Délai de grâce ≥ fenêtre « Bien » ; des drones ne font jamais perdre plus de 1 % à un joueur attentif.
12. Pas de cycle instantané après un prestige : `Mp(p + 1)` < `M(minimum de rebirths) × Mp(p)` (testé pour
    p = 0..30 ; ex. ×1,58 juste après le 1ᵉʳ prestige contre ×3,125 juste avant). Conditions de prestige
    strictement croissantes (testé jusqu'à p = 60).

## 6. Grands nombres

`BigNum = { m, e }` avec valeur = `m × 10^e`, `m` entier.
- **Exact** pour toute valeur < 10¹⁵ (`e = 0`, arithmétique entière sur doubles, sous 2⁵³).
- Au-delà : 15 chiffres significatifs (erreur relative < 10⁻¹⁴), pas de dépassement avant 10^(2⁵³).
- Sérialisation DataStore directe (`{ m = ..., e = ... }`), affichage `1.23K … 1.23Dc` puis notation scientifique.
- Affichage **tronqué** (jamais arrondi vers le haut) : le joueur ne voit jamais un solde supérieur au réel.

## 7. Drones récolteurs (Phase 2, jalon B)

Paramètres par type (`src/shared/Config/DroneConfig.luau`) et globaux (`GameConfig.Drones`) :

| Paramètre | Drone récolteur | Rôle |
|---|---|---|
| `price` / `priceGrowth` | 1 500 / ×2,5 | prix du n-ième exemplaire = `floor(1 500 × 2,5ⁿ)` → 1 500, 3 750, 9 375 |
| `maxOwned` | 3 | exemplaires par joueur |
| `interval` | 4 s | délai entre deux actions d'un drone |
| `capacity` | 1 | plantes récoltées par action |
| `range` | 25 studs | portée horizontale autour de son point d'attente (couvre la parcelle principale, pas les extensions) |
| `graceDelay` | 5 s | délai de grâce : un drone ne vise une plante que 5 s après sa maturité (fenêtres Parfait/Bien laissées au joueur ; invariant `graceDelay ≥ GoodWindow`) |
| `TickInterval` | 0,25 s | cadence de l'unique boucle serveur des drones |
| `BagFullNoticeInterval` | 30 s | « Tes drones attendent : sac plein » au plus une fois par 30 s |

Règles : récolte via les mêmes validations serveur que le joueur (propriété, maturité, portée, sac) ; **aucun bonus de
précision** ; mutation conservée ; sac plein = attente sans perte ; validation et application atomiques (aucun double
gain joueur/drone) ; drones actifs uniquement quand le joueur est en ligne (hors ligne : Phase 4).

### Simulation des revenus (`tests/specs/DroneEconomy.spec.luau`, 10 min, 9 cases, Coins/min)

Joueur « attentif » : récolte la case mûre la plus ancienne avec 1,2 s de déplacement, vend sac plein (aller-retour
8 s) ; valeur de vente = espérance des mutations (×1,5051) ; mêmes modules que le serveur (`HarvestRules`, `DroneLogic`).

Avec le délai de grâce retenu (5 s) :

| Scénario | Carotte | Tomate |
|---|---|---|
| Joueur attentif seul | 650 | 3 123 |
| + 1 drone | 725 (+11,5 %) | 3 155 (+1,0 %) |
| + 3 drones | 738 (+13,6 %) | 3 113 (−0,3 %, décalage de calendrier, ventes identiques) |
| 1 drone seul (joueur absent qui vient vendre) | 181 | 813 |
| 3 drones seuls | 542 | 1 896 |

Choix du délai (même simulation, Coins/min) :

| `graceDelay` | Carotte actif + 1 | Tomate actif + 1 | Tomate actif + 3 | Tomate 3 drones seuls |
|---|---|---|---|---|
| 0 s (sans délai) | 847 (+30 %) | 3 029 (−3,0 %) | 3 171 (+1,5 %) | 2 438 |
| 1,5 s | 847 (+30 %) | 3 109 (−0,4 %) | 3 048 (−2,4 %) | 2 167 |
| 3 s | 790 (+21 %) | 3 111 (−0,4 %) | 3 085 (−1,2 %) | 1 896 |
| **5 s (retenu)** | 725 (+11,5 %) | **3 155 (+1,0 %)** | 3 113 (−0,3 %) | 1 896 |

Lecture :
- **Sans délai**, avec la Tomate (0,75 récolte/s, déjà absorbée par un joueur attentif), le drone prenait des récoltes
  que le joueur aurait faites avec un bonus Parfait (bonus 6 847 → 5 911, −3 %). Avec 5 s, seul délai testé où un
  drone ajouté à un joueur actif reste positif sur la Tomate, le drone ne récolte que les plantes « oubliées ».
- Contrepartie : le drone apporte moins au jeu actif sur Carotte (+11,5 % au lieu de +30 %, premier drone remboursé en
  ≈ 20 min au lieu de ≈ 7,6 min) et 3 drones seuls produisent 22 % de moins sur Tomate (chaque plante attend 5 s).
- Pour un joueur absent qui vient vendre, le premier drone se rembourse en ≈ 8 min (Carotte) / ≈ 2 min (Tomate).
- Sans personne pour vendre, les drones s'arrêtent dès que le sac est plein : la vente automatique relève de la Phase 4.
- Réglage : `graceDelay` est un paramètre par type de drone ; un futur drone « rapide » pourra avoir un délai plus
  court (l'invariant `graceDelay ≥ GoodWindow` serait alors à revoir explicitement).
