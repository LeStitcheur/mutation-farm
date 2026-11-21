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

- **Sac** : capacité = 40 + amélioration « Capacité du sac » (Phase 3) + paliers du Mutadex (+5 à 25 %, +10 à 75 %,
  Phase 4 ; `docs/MUTADEX.md`).
- **Valeur de vente** = `valeurBase(plante) × multiplicateur(mutation) × M(R) × Mp(P) × A` où `M(R)` et `Mp(P)` sont
  les multiplicateurs de rebirth et de prestige (§4) et `A` celui des améliorations de valeur
  (`docs/PROGRESSION.md` §4), appliqués au total du sac et arrondis à l'inférieur.
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
13. Améliorations plafonnées : chance ≤ 2,5 (E ≤ 1,98), pousse ≥ 40 %, intervalle des drones ≥ 50 %, délai de
    grâce inchangé (`Upgrades.spec`).
14. Rythme mesuré par le simulateur (`EconomySim.spec`) : premier rebirth en 8–25 min (actif), 10–30 min (hybride),
    15–45 min (automatisé) ; premier prestige en 1 h 30 – 5 h ; cycle suivant plus court mais ≥ 3 min ; aucune
    amélioration Essence de niveau 1 ne réduit le revenu (≥ −1 %) ; Valeur de vente ≥ +8 %.

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

## 8. Simulateur économique et équilibrage (Phase 3, jalon C)

**Outil** : `tests/sim/EconomySim.luau` rejoue une partie avec les règles pures du jeu (HarvestRules, Economy,
DroneLogic, ProgressionMath, Resets, Upgrades, MutationRoll) ; seules les décisions du joueur sont modélisées.
Déterministe (pas de 0,25 s, mutations tirées après `math.randomseed`). Rapport complet :

```powershell
tools/bin/lune.exe run tests/run.luau report
```

**Profils** : 1. actif sans drone (réaction 1 s → Parfait, 1,2 s entre récoltes) ; 2. hybride (réaction 3 s,
1 drone) ; 3. principalement automatisé (joue jusqu'au 1ᵉʳ drone, 3 drones, vend toutes les 2 min) ; 4. avancé
(actif, 3 drones, rebirth et prestige dès que possible, améliorations les moins chères d'abord) ; 5. après prestige
(profil 4 poursuivi). Tous débloquent la graine suivante dès qu'elle est payable et vont vendre dès que le sac est
plein ou que son contenu paie leur prochain achat. **Chaque valeur est la moyenne de 8 parties** (graines 1 à 8) :
une partie seule est trop sensible aux mutations rares et à l'instant des déblocages.

**Évolutions du modèle (Phase 4)**, rendues nécessaires par le Mutadex (ses places de sac modifiaient le rythme des
ventes et faisaient apparaître des artefacts) — les tables ci-dessous datent de la Phase 3 et seront remesurées en
fin de Phase 4 :
- **Variabilité du joueur** : réaction ×[0,6 ; 1,4] et cadence ×[0,8 ; 1,2] autour du profil (générateur séparé à
  graine fixe). Un joueur « métronome » gagnait ou perdait des bonus Parfait selon la phase des allers-retours.
- **Nombres aléatoires communs** : un flux de tirages de mutation par plante ; la n-ième Citrouille reçoit le même
  tirage dans deux parties comparées. Sans cela, une Divine changeait de plante d'une partie à l'autre (±30 % de
  revenu sur 20 min), masquant l'effet réel des améliorations.
- **Vente par habitude** : un joueur présent va vendre quand son sac atteint la capacité de **base** (ou quand le
  contenu paie son prochain achat) ; les places en plus servent de tampon aux drones et aux absences. Un sac plus
  grand ne peut pas nuire à un vrai joueur (il peut vendre aux mêmes moments) : sans cette règle, le modèle naïf
  « vendre sac plein » le pénalisait à tort (−4 %).

### A. Coins gagnés par minute selon la graine (10 min, 9 cases, sans amélioration)

| Graine | Actif sans drone | Hybride + 1 drone | Drones seuls (3, vente toutes les 2 min) |
|---|---|---|---|
| Carotte | 633 | 708 | 320 |
| Tomate | 3 144 | 2 444 | 1 442 |
| Maïs | 7 276 | 5 819 | 4 761 |
| Citrouille | 16 230 | 13 193 | 11 096 |
| Champi-lune | 34 720 | 30 580 | 27 900 |
| Fleur-étoile | 70 184 | 61 799 | 56 469 |
| Fruit du dragon | 109 912 | 95 738 | 87 188 |

### B. Premier rebirth (100 000 Coins gagnés pendant le cycle), partie neuve

| Profil | Moyenne | Min – max | Coins gagnés / min | Part des drones |
|---|---|---|---|---|
| 1. Actif sans drone | 14,4 min | 10,6 – 16,1 min | 8 423 | 0 % |
| 2. Hybride, 1 drone | 18,0 min | 15,8 – 19,2 min | 6 377 | 2 % |
| 3. Principalement automatisé | 28,4 min | 24,1 – 32,1 min | 3 908 | 98 % |

Le drone de l'hybride ne prend que 2 % des revenus : un joueur qui réagit en moins de 5 s garde ses récoltes et
ses bonus (délai de grâce). L'estimation analytique du jalon A (≈ 14 / 22 min) est confirmée.

### C. Profil 4 (avancé) jusqu'au premier prestige — temps entre rebirths

| Rebirth n° | Atteint à | Durée du cycle | Essence gagnée |
|---|---|---|---|
| 1 | 16,5 min | 16,5 min | 103 |
| 2 | 37,1 min | 20,6 min | 168 |
| 3 | 1 h 03 | 26,4 min | 252 |
| 4 | 1 h 42 | 38,5 min | 312 |
| 5 | 2 h 34 | 52,5 min | 347 |

Premier prestige : **2 h 34** en moyenne (2 h 30 – 2 h 40, 8/8 parties), 10 Primal Cores, 17 niveaux
d'améliorations Essence achetés. L'Essence dépasse parfois le minimum (ex. 312 au lieu de 282) : une vente d'un
gros sac peut porter les Coins du cycle bien au-delà du seuil d'un coup (bonus de dépassement voulu, ≤ ×2).

### D. Profil 5 — après le premier prestige
Premier rebirth en **10,7 min** (contre 16,5 min au tout premier cycle), 5ᵉ rebirth en 1 h 42 : le prestige
accélère sans rendre les cycles instantanés (invariant 12).

### E. Effets cumulés des mutations

| Chance | E(multiplicateur) | Gain |
|---|---|---|
| ×1,0 (base) | 1,505 | — |
| ×1,5 | 1,692 | +12,4 % |
| ×2,0 (Chance de mutation au max.) | 1,849 | +22,8 % |
| ×2,5 (plafond, + Énergie mutagène au max.) | 1,983 | +31,7 % |

### F. Rentabilité des améliorations Essence — revenu sur 30 min après le rebirth n° 1

Mesure par revenu sur une fenêtre fixe (Coins gagnés + valeur du sac) : le temps jusqu'au seuil est quantifié par
les ventes et masquerait les petits effets. Avec et sans amélioration, les parties partagent la même suite de
mutations (tirées dans l'ordre des plantations).

| Amélioration | Niveau | Coût | Actif | Hybride | Automatisé | Hybride / 100 Essence |
|---|---|---|---|---|---|---|
| (aucune) | — | — | 26 449 /min | 17 411 /min | 8 085 /min | — |
| Valeur de vente | 1 | 40 | +17,5 % | +18,7 % | +27,0 % | +46,7 % |
| Valeur de vente | 5 | 579 | +85,1 % | +100,8 % | +135,1 % | +17,4 % |
| Vitesse de croissance | 1 | 50 | +4,3 % | +5,6 % | +0,0 % | +11,2 % |
| Vitesse de croissance | 5 | 791 | +36,8 % | +44,8 % | +18,8 % | +5,7 % |
| Chance de mutation | 1 | 60 | +4,1 % | +3,9 % | +9,2 % | +6,4 % |
| Chance de mutation | 5 | 950 | +14,3 % | +18,0 % | +26,6 % | +1,9 % |
| Efficacité des drones | 1 | 50 | +0,0 % | −0,1 % | +3,6 % | −0,2 % |
| Efficacité des drones | 5 | 725 | +0,0 % | −0,3 % | +10,9 % | −0,0 % |
| Capacité du sac | 1 | 30 | +0,5 % | +0,3 % | +10,5 % | +1,1 % |
| Capacité du sac | 5 | 397 | +4,3 % | +3,2 % | +13,2 % | +0,8 % |

Constats :
- Les gains dépassent l'effet direct (+10 % de valeur → +17 à +27 %) : revenu plus élevé = graines suivantes
  débloquées plus tôt (effet boule de neige), ce qui fait aussi la valeur du simulateur par rapport aux formules.
- **Efficacité des drones** n'aide que les joueurs automatisés : au-delà de la Tomate, la production des 9 cases
  limite les revenus, pas la vitesse des drones. À revoir si les drones gagnent une capacité ou un rôle de vente
  automatique (Phase 4).
- **Capacité du sac** sert surtout aux joueurs absents (drones arrêtés sac plein entre deux passages).
- **Défaut corrigé grâce au simulateur** : `DroneService` replanifiait chaque drone à `now + intervalle` avec une
  boucle de 0,25 s ; un intervalle de 3,8 s devenait 4 s et les premiers niveaux d'Efficacité des drones n'avaient
  **aucun effet** en jeu. Planification désormais depuis l'échéance précédente (période moyenne exacte).
- Premier essai écarté : un joueur simulé qui ne vend que sac plein rendait « Capacité du sac » négative
  (−3 à −10 %) ; c'était un artefact de stratégie (pièces bloquées dans le sac), corrigé par la vente anticipée.

### G. Multiplicateurs permanents — premier rebirth d'un cycle (profil actif)

| Situation | Premier rebirth |
|---|---|
| Partie neuve | 14,4 min |
| Après 1 prestige (×1,58), sans amélioration | 8,9 min |
| Après 1 prestige + Génétique supérieure 2 (+10 %) | 8,4 min |
| Après 1 prestige + Héritage agricole 1 (Tomate gardée) | 8,9 min (aucun effet mesurable) |
| Après 3 prestiges (×3,22) + Génétique 5, Croissance ancestrale 5, Héritage 2 | 4,8 min |

### Décisions et limites
- **Carotte et Tomate inchangées** : aucune mesure ne justifie de les modifier (cahier des charges).
- Pas de rééquilibrage des seuils : le rythme mesuré (14–28 min pour le premier rebirth, ≈ 2 h 30 pour le premier
  prestige) correspond à la cible « 10–60 min / plusieurs heures » de `docs/GAME_DESIGN.md`.
- Pistes : rendre Héritage agricole utile dès le niveau 1 (graine plus chère, ou Coins de départ) ; donner un rôle
  à l'Efficacité des drones pour les joueurs actifs ; simuler les extensions de parcelle (Phase 4).
- Limites du modèle : une seule parcelle (9 cases), joueur sans erreur ni pause, aucune extension, aucun événement ;
  les durées sont des ordres de grandeur, pas des promesses de temps de jeu réel.

## 9. Familiers et plafonds globaux (Phase 4, jalon B ; détail : `docs/PETS.md`)

- **Œufs** : Œuf de prairie 5 000 Coins (≈ 1 min 30 de revenu au stade Tomate), Œuf cristallin 75 000 Coins
  (≈ 5 min au stade Citrouille), Œuf des missions non vendu. Les Coins sont remis à zéro au rebirth, les familiers
  jamais : acheter un œuf retarde le déblocage de la graine suivante, c'est un choix assumé.
- **Bonus** (3 familiers équipés, plafonnés par effet) : revenu ≤ +40 %, pousse ≤ −30 %, chance ≤ +0,60,
  drones ≤ −30 %, précision manuelle ≤ +150 %. Le revenu des familiers multiplie celui des améliorations
  (`Bonuses.valueMultiplier`, dans `ProgressionMath.incomeMultiplier`).
- **Plafonds toutes sources** (`UpgradeConfig.Caps`, appliqués par `Util/Bonuses`) : pousse ≥ 40 % de la durée de
  base, intervalle des drones ≥ 50 %, **chance totale ≤ 5**. Rendements de la chance (espérance du multiplicateur
  de vente d'une culture) : E(1) = 1,505 ; E(2,5) = 1,98 ; E(3,1) ≈ 2,12 (améliorations + 2 Phalènes niveau 15) ;
  E(5) ≈ 2,44 ; P(normale) ≥ 46 % au plafond (testé).
- Non simulé : `tests/sim` ne modélise ni familiers ni événements ; les invariants restent ceux du §5.

## 10. Événements du monde (Phase 4, jalon C ; détail : `docs/EVENTS.md`)

- **Fréquence** : ≈ 1 événement par heure (tranches de 30 min, 50 % tirées) + 2 rendez-vous quotidiens (Floraison à
  12:00 et 20:00 UTC) ; 5 min au minimum entre deux événements, jamais deux à la fois.
- **Pluie mutagène** (5 min) : chance × 3 à la plantation, plafonnée à 5 au total. Pour un joueur sans
  amélioration, l'espérance du multiplicateur de vente d'une culture semée sous la pluie passe de 1,505 à
  ≈ 2,10 (+39 %), et les mutations rares (Astrale, Divine) deviennent ≈ 2,2 fois plus probables ; l'effet n'apparaît
  qu'à la récolte de ces cultures (après la pluie pour les plantes lentes).
- **Floraison dorée** (10 min) : +50 % de la valeur de chaque récolte, versés à la récolte (× multiplicateur de
  revenu). Pour un joueur actif, c'est ≈ +50 % de revenu pendant 10 min ; sur une journée (2 rendez-vous et
  ≈ 9 Floraisons tirées parmi ≈ 23 événements, soit ≈ 1 h 50 de Floraison), le gain moyen est ≈ +4 % pour qui
  joue en continu.
- Non simulé (`tests/sim`) : les ordres de grandeur ci-dessus sont calculés à partir des formules, pas mesurés.
