# MUTATION FARM — Économie

> Source de vérité des valeurs : `src/shared/Config/PlantConfig.luau`, `src/shared/Config/GameConfig.luau`,
> `src/server/Config/MutationOdds.luau`. Les invariants ci-dessous sont **testés automatiquement**
> (`tests/specs/Config.spec.luau`, `Economy.spec.luau`, `MutationRoll.spec.luau`, `Mutations.spec.luau`).

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
- **Valeur de vente** = `valeurBase(plante) × multiplicateur(mutation)` (× multiplicateurs d'améliorations, Phase 3+).
- **Bonus de précision** (Coins instantanés, arrondis à l'inférieur) :
  Parfait (≤ 1,5 s) = 50 % de la valeur de base, Bien (≤ 5 s) = 20 %.

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

## 4. Rebirth et Prestige (Phase 5, formules contractuelles, non branchées au gameplay)

- **Coût de rebirth** n (n = rebirths déjà faits) : `5·10⁷ × 6ⁿ` Coins.
- **Multiplicateur de revenu** après n rebirths : `1,5ⁿ`.
- **Rebirth Tokens** : +1 par rebirth.
- **Prestige** p (p = prestiges déjà faits) : exige `8 + 4p` rebirths.
- **Primal Cores** gagnés : `floor(2 × 1,35^(rebirths − requis))` (≥ 2 au seuil).

## 5. Invariants économiques (tests)

1. Chaque graine débloquée augmente strictement le revenu par case et par seconde.
2. Les prix de déblocage sont strictement croissants.
3. Le temps de déblocage (jeu parfait, graine précédente, 9 cases) est strictement croissant et compris entre 30 s et 6 h.
4. Le bonus de précision ne dépasse jamais 50 % de la valeur de base.
5. Les Coins ne deviennent jamais négatifs : toute dépense passe par `EconomyService.TrySpendCoins`.
6. Les multiplicateurs de mutation sont exactement 2, 4, 8, 20, 50, 150 ; les probabilités sont celles du §3 et
   somment à 1 ; E(1) = 1,5051 ∈ [1,4 ; 1,6] (avant Phase 2 : [1,1 ; 1,3]).
7. La croissance du coût de rebirth (×6) dépasse celle du multiplicateur (×1,5) : chaque rebirth est plus long.
8. Production hors ligne plafonnée à 7 200 s.

## 6. Grands nombres

`BigNum = { m, e }` avec valeur = `m × 10^e`, `m` entier.
- **Exact** pour toute valeur < 10¹⁵ (`e = 0`, arithmétique entière sur doubles, sous 2⁵³).
- Au-delà : 15 chiffres significatifs (erreur relative < 10⁻¹⁴), pas de dépassement avant 10^(2⁵³).
- Sérialisation DataStore directe (`{ m = ..., e = ... }`), affichage `1.23K … 1.23Dc` puis notation scientifique.
- Affichage **tronqué** (jamais arrondi vers le haut) : le joueur ne voit jamais un solde supérieur au réel.
