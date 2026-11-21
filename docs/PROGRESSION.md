# MUTATION FARM — Progression (rebirth, prestige, améliorations)

> Phase 3, branche `phase-3/progression`. Jalon A (**Rebirth**) implémenté ; jalon B (Prestige) et jalon C (arbres
> d'améliorations, simulateur à 5 profils) à venir.
> Valeurs : `src/shared/Config/ProgressionConfig.luau`. Règles pures : `src/shared/Util/ProgressionMath.luau`
> (formules) et `src/shared/Util/Resets.luau` (transitions). Service : `src/server/Services/RebirthService.luau`.
> Interface : `src/client/Controllers/RebirthController.luau`.

## 1. Cycles et compteurs

| Champ (`PlayerData`) | Sens | Remis à zéro par |
|---|---|---|
| `progression.rebirths` | rebirths depuis le dernier prestige (`n` des seuils, `R` du multiplicateur) | prestige |
| `progression.cycleCoins` | Coins **gagnés** depuis le dernier rebirth (seuil de rebirth) | rebirth, prestige |
| `progression.prestigeCoins` | Coins gagnés depuis le dernier prestige (seuil de prestige, jalon B) | prestige |
| `progression.revision` | +1 à chaque rebirth/prestige : invalide toute requête ou opération lancée avant | jamais |
| `progression.prestiges` | prestiges réalisés | jamais |
| `stats.totalRebirths` | historique de tous les rebirths | jamais |
| `stats.coinsEarned` | historique de tous les Coins gagnés | jamais |

**Coins gagnés** = ventes au marché + bonus de précision, crédités par `EconomyService` via
`ProgressionMath.recordEarnings` (historique + les deux cycles en une seule mutation). Le **solde** ne compte pas :
dépenser des Coins (graines, drones) ne retarde jamais un rebirth.

## 2. Rebirth (jalon A — implémenté)

### Formules (`ProgressionConfig.Rebirth`)
- **Seuil** du rebirth n° `n + 1` : `threshold(n) = 100 000 × 3,2ⁿ` Coins gagnés pendant le cycle
  (exact, arrondi à l'entier supérieur, pour `n ≤ 10` ; `BigNum` au-delà, écart relatif ≤ 10⁻¹⁰).
- **Multiplicateur de revenu** après `R` rebirths : `M(R) = 1 + 0,35 R + 0,015 R²`, appliqué à la **valeur de vente**
  et au **bonus de précision** du joueur (les drones n'ont jamais de bonus). Affiché tronqué au millième.
- **Mutation Essence** gagnée : `floor(100 × (1 + n)^0,75 × min(cycleCoins / seuil, 4)^0,5)` — 100 pile au premier
  seuil ; dépasser le seuil rapporte plus, au plus ×2 (plafond atteint à 4× le seuil) : attendre n'est jamais
  très rentable, refaire un rebirth l'est davantage.

| Rebirth n° | Seuil (Coins gagnés) | Multiplicateur avant → après | Essence au seuil exact | Durée vs rebirth précédent* |
|---|---|---|---|---|
| 1 | 100 000 | ×1 → ×1,365 | 100 | — |
| 2 | 320 000 | ×1,365 → ×1,76 | 168 | ×2,34 |
| 3 | 1 024 000 | ×1,76 → ×2,185 | 227 | ×2,48 |
| 4 | 3 276 800 | ×2,185 → ×2,64 | 282 | ×2,58 |
| 5 | 10 485 760 | ×2,64 → ×3,125 | 334 | ×2,65 |
| 6 | 33 554 432 | ×3,125 → ×3,64 | 383 | ×2,70 |
| 8 | 343 597 384 | ×4,185 → ×4,76 | 475 | ×2,78 |
| 11 | 11 258 999 069 | ×6 → ×6,665 | 604 | ×2,86 |

\* À production de ferme égale : `3,2 / (M(R) / M(R − 1))`. Toujours > 1 (invariant 7 de `docs/ECONOMY.md`) : chaque
rebirth est plus long que le précédent ; graines, drones et améliorations (jalon C) compensent en partie.

**Durée estimée du premier rebirth** (estimation analytique, à confirmer par le simulateur du jalon C) :
≈ 14 min en jeu parfait, ≈ 22 min à 60 % d'efficacité (récolte manuelle réaliste).

### Ce qui est réinitialisé / conservé (`Resets.rebirth`, conservation vérifiée champ par champ dans `Resets.spec`)

| Réinitialisé | Champ | Nouvelle valeur |
|---|---|---|
| Coins | `currencies.coins` | 0 |
| Graines débloquées et sélection | `seeds.unlocked`, `seeds.selected` | Carotte seule |
| Sac | `bag.items` | vide |
| Améliorations normales | `upgrades.normal` | vide |
| Drones | `machines.drones` | aucun |
| Cultures plantées | `farm.tiles` | vides, puis **replantées** en Carotte par le serveur |
| Progression du cycle | `progression.cycleCoins` | 0 |

**Conservé** (tout champ non listé ci-dessus) : parcelles (`farm.plots`), Mutation Essence (+ gain), Primal Cores,
améliorations de rebirth et permanentes, Mutadex, cosmétiques, familiers, droits d'achat (`receipts`), statistiques,
`prestigeCoins`, `prestiges`, `meta` (dont la quarantaine), `rebirthTokens` (obsolète).

### Déroulé et garanties (serveur autoritaire)
1. Le client envoie `RebirthRequest(revision)` : uniquement la **révision** qu'il affiche (entier 0 ≤ r < 2³¹).
   Ni seuil, ni montant, ni récompense.
2. `RebirthService` : verrou `busy[player]` (une transition à la fois par joueur), débit ≤ 0,5 requête/s.
3. **Un seul** mutateur synchrone `DataService.Update` exécute `Resets.rebirth` : révision attendue = révision
   courante, puis seuil, puis calcul de l'Essence, reset, `rebirths + 1`, `revision + 1`, `totalRebirths + 1`, Essence
   créditée. Rien ne peut s'intercaler (aucun `yield`) : **jamais de récompense sans reset**, et une requête rejouée
   ou doublée trouve une révision périmée → refusée sans effet (100 requêtes identiques = 1 récompense, testé).
4. Après le mutateur : replantation des cases vides (`FarmService.ReplantEmpty`), flotte vidée
   (`DroneService.Refresh`). Une récolte ou une cible de drone choisie **avant** le reset échoue (case vide ou culture
   pas mûre) ; le sac de l'ancien cycle est vidé : rien ne peut être revendu au nouveau multiplicateur (testé).
5. `DataService.SaveNow` immédiat. En cas d'échec : avertissement, l'autosave réessaie. Chaque enregistrement
   contient l'état **avant** ou l'état **après**, jamais un mélange (testé sur des sauvegardes simulées en Lune ; la
   persistance réelle reste à valider, `docs/TESTING.md` §2.4).
6. Notification « Rebirth n ! +E Mutation Essence · revenus ×M » ; `StateSync` met le HUD à jour.

### Interface (`RebirthController`)
- Bouton **Rebirth** (doré) sous **Graines** ; touche **R**, manette **L1** ; un seul panneau ouvert à la fois et
  chat masqué pendant l'ouverture (`UI/PanelHub`).
- Panneau : rebirths réalisés, seuil du prochain rebirth (« le solde actuel ne compte pas »), barre de progression
  `cycleCoins / seuil`, récompense en Essence, multiplicateur actuel → futur, listes **Perdu** / **Conservé**.
- Confirmation en deux étapes : « Rebirth… » (actif seulement au seuil) puis écran récapitulatif avec **Annuler**
  (sélectionné par défaut à la manette) et **Confirmer** (inactif pendant 1,5 s). **B** revient à l'écran précédent
  puis ferme. Mise à l'échelle `Theme.fitScale` (PC, téléphone, console).

## 3. Prestige (jalon B — à concevoir)

Structure déjà testée (`Resets.prestige`) : reset de l'économie du cycle, des parcelles, des rebirths, de l'Essence
et des améliorations de rebirth ; conserve Primal Cores (+ gain), améliorations permanentes, Mutadex, cosmétiques,
familiers, reçus, statistiques. Points à trancher au jalon B :
- seuils de prestige exprimés en Coins (1e7 / 1e8 / 1e9) : presque redondants avec les seuils de rebirth
  (rebirth 6 ≈ 3,4e7, 8 ≈ 3,4e8, 10 ≈ 3,5e9) — préférer une condition en rebirths ou en `prestigeCoins` ;
- le multiplicateur de rebirth retombe à ×1 au prestige (`R = 0`) : le gain de Primal Cores doit compenser.

## 4. Améliorations (jalon C — à venir)

Arbres d'améliorations de rebirth (Mutation Essence) et permanentes (Primal Cores), simulateur économique Lune à
5 profils de joueurs. `ProgressionMath.incomeMultiplier` est le point d'entrée unique des futurs multiplicateurs.
