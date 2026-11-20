# MUTATION FARM — Économie

> Source de vérité des valeurs : `src/shared/Config/PlantConfig.luau`, `src/shared/Config/GameConfig.luau`,
> `src/server/Config/MutationOdds.luau`. Les invariants ci-dessous sont **testés automatiquement**
> (`tests/specs/Config.spec.luau`, `Economy.spec.luau`, `MutationRoll.spec.luau`).

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

## 3. Mutations (Phase 2, contrat défini et testé)

Poids sur 1 000 000 (tirage exclusif), chance `L` appliquée à tous les poids non normaux :

| Mutation | × | Poids | P (L = 1) |
|---|---|---|---|
| Normale | ×1 | 927 093 | 92,709 % |
| Brillante | ×2 | 50 000 | 5 % |
| Géante | ×4 | 16 667 | 1,667 % |
| Cristallisée | ×8 | 5 000 | 0,5 % |
| Radioactive | ×20 | 1 000 | 0,1 % |
| Astrale | ×50 | 200 | 0,02 % |
| Divine | ×150 | 40 | 0,004 % |

Espérance du multiplicateur : `E(L) = (927 093 + 242 668·L) / (927 093 + 72 907·L)`
→ E(1) ≈ **1,170**, E(3) ≈ **1,444** (Pluie mutagène).

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
6. Les multiplicateurs de mutation sont exactement 2, 4, 8, 20, 50, 150 ; les probabilités somment à 1 ; E(1) ∈ [1,1 ; 1,3].
7. La croissance du coût de rebirth (×6) dépasse celle du multiplicateur (×1,5) : chaque rebirth est plus long.
8. Production hors ligne plafonnée à 7 200 s.

## 6. Grands nombres

`BigNum = { m, e }` avec valeur = `m × 10^e`, `m` entier.
- **Exact** pour toute valeur < 10¹⁵ (`e = 0`, arithmétique entière sur doubles, sous 2⁵³).
- Au-delà : 15 chiffres significatifs (erreur relative < 10⁻¹⁴), pas de dépassement avant 10^(2⁵³).
- Sérialisation DataStore directe (`{ m = ..., e = ... }`), affichage `1.23K … 1.23Dc` puis notation scientifique.
- Affichage **tronqué** (jamais arrondi vers le haut) : le joueur ne voit jamais un solde supérieur au réel.
