# MUTATION FARM — Progression (rebirth, prestige, améliorations)

> Phase 3, branche `phase-3/progression`. Jalons A (**Rebirth**), B (**Prestige**) et C (**Améliorations**, simulateur
> économique à 5 profils) implémentés.
> Valeurs : `src/shared/Config/ProgressionConfig.luau`. Règles pures : `src/shared/Util/ProgressionMath.luau`
> (formules) et `src/shared/Util/Resets.luau` (transitions). Services : `ProgressionService` (exécution commune des
> transitions), `RebirthService`, `PrestigeService`. Interface : `RebirthController`, `PrestigeController` sur le
> panneau commun `src/client/UI/ConfirmPanel.luau`.

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
- **Multiplicateur de rebirth** après `R` rebirths : `M(R) = 1 + 0,35 R + 0,015 R²`. Le **revenu** applique
  `M(R) × Mp(P)` (`Mp` : multiplicateur de prestige, §3) à la **valeur de vente** et au **bonus de précision** du
  joueur (les drones n'ont jamais de bonus). Affiché tronqué au millième. Le tableau ci-dessous est pour `P = 0`.
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
2. `RebirthService` : débit ≤ 0,5 requête/s ; `ProgressionService.Run` : verrou par joueur **partagé avec le
   prestige** (jamais deux transitions simultanées, quel que soit leur type).
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

### Interface (`RebirthController` sur `UI/ConfirmPanel`)
- Bouton **Rebirth** (doré) sous **Graines** ; touche **R**, manette **L1** ; un seul panneau ouvert à la fois et
  chat masqué pendant l'ouverture (`UI/PanelHub`).
- Revenus affichés : multiplicateur total (rebirth × prestige), actuel → après ce rebirth.
- Panneau : rebirths réalisés, seuil du prochain rebirth (« le solde actuel ne compte pas »), barre de progression
  `cycleCoins / seuil`, récompense en Essence, multiplicateur actuel → futur, listes **Perdu** / **Conservé**.
- Confirmation en deux étapes : « Rebirth… » (actif seulement au seuil) puis écran récapitulatif avec **Annuler**
  (sélectionné par défaut à la manette) et **Confirmer** (inactif pendant 1,5 s). **B** revient à l'écran précédent
  puis ferme. Mise à l'échelle `Theme.fitScale` (PC, téléphone, console).

## 3. Prestige (jalon B — implémenté)

### Formules (`ProgressionConfig.Prestige`)
- **Conditions** du prestige n° `p + 1` (`p` = prestiges déjà faits), **toutes deux** requises :
  - rebirths depuis le dernier prestige ≥ `5 + 3p + p(p − 1)/2` → 5, 8, 12 (cahier des charges), puis 17, 23, 30… ;
  - Coins **gagnés** depuis le dernier prestige (`prestigeCoins`) ≥ `10⁷ × 10ᵖ` → 1e7, 1e8, 1e9 (cahier des
    charges), puis 1e10… (exact jusqu'à `p = 7`, `BigNum` au-delà ; croissance testée jusqu'à `p = 60`).
- **Multiplicateur de prestige** (permanent, `P` = prestiges réalisés) : `Mp(P) = 1 + 0,5 P + 0,08 P²`.
  Revenu total = `M(R) × Mp(P)`.
- **Primal Cores** : `floor(10 × (1 + p)^0,75 × (1 + 0,25 × min(e, 4)))`, `e` = rebirths faits au-delà du minimum
  (au plus ×2) — formule choisie au jalon B (le cahier des charges ne la fixe pas), configurable.

| Prestige n° | Rebirths | Coins gagnés | Coins réellement gagnés pour atteindre ces rebirths* | Primal Cores (minimum) | Mp avant → après | Revenu juste avant → juste après |
|---|---|---|---|---|---|---|
| 1 | 5 | 10 M | ≈ 15,2 M | 10 | ×1 → ×1,58 | ×3,125 → ×1,58 |
| 2 | 8 | 100 M | ≈ 500 M | 16 | ×1,58 → ×2,32 | ×7,52 → ×2,32 |
| 3 | 12 | 1 G | ≈ 52,4 G | 22 | ×2,32 → ×3,22 | ×17,08 → ×3,22 |
| 4 | 17 | 10 G | ≈ 1,76e13 | 28 | ×3,22 → ×4,28 | ×36,3 → ×4,28 |

\* Somme des seuils de rebirth du cycle. **Constat mesuré** : avec les valeurs actuelles, atteindre le minimum de
rebirths implique déjà la condition de Coins (15,2 M > 10 M, etc.). La condition de Coins reste appliquée et
configurable (garde-fou si les seuils de rebirth sont rééquilibrés au jalon C), mais elle ne bloque jamais seule.
**Invariant 12** (testé pour `p = 0..30`) : juste après un prestige, le revenu (`Mp(p + 1)`, rebirths à 0) est
inférieur au revenu juste avant (au minimum de rebirths) — un prestige ne rend jamais les premiers cycles
instantanés ; les Primal Cores (améliorations permanentes, jalon C) compensent sur la durée.

### Ce qui est réinitialisé / conservé (`Resets.prestige`, conservation vérifiée champ par champ dans `Prestige.spec`)

| Réinitialisé | Champ | Nouvelle valeur |
|---|---|---|
| Tout ce que réinitialise un rebirth (§2) | Coins, graines, sac, améliorations normales, drones, cultures, `cycleCoins` | comme au rebirth |
| Parcelles achetées | `farm.plots` | parcelles par défaut (`main`) |
| Rebirths du cycle | `progression.rebirths` | 0 |
| Mutation Essence | `currencies.essence` | 0 |
| Améliorations de rebirth | `upgrades.rebirth` | vide |
| Statistiques économiques du cycle | `progression.prestigeCoins` | 0 |

**Conservé** (tout champ non listé) : Primal Cores (+ gain), améliorations permanentes (`upgrades.permanent`),
Mutadex, cosmétiques, familiers, **droits Robux** (`receipts` ; les Game Passes sont vérifiés auprès de Roblox, jamais
stockés comme vérité), statistiques historiques (`stats`, dont `coinsEarned` et `totalRebirths`), `prestiges`
(+1), `meta` (dont la quarantaine), `rebirthTokens` (obsolète).

Extensions de ferme (Phase 5, jalon A, `docs/FARM.md`) : achetées en Coins, **conservées au rebirth**, reprises au
prestige. Leur géométrie est démontée **immédiatement** après le prestige (`FarmService.SyncPlots`, appelé par
`ProgressionService.Run`) et leurs panneaux « À vendre » réapparaissent ; la limite de la Phase 3 (géométrie
visible jusqu'à la reconnexion) est levée.

### Déroulé et garanties
Identiques au rebirth (§2) : `PrestigeRequest(revision)` validé (entier, débit ≤ 0,5/s), `ProgressionService.Run`
(verrou partagé, **un** mutateur `Resets.prestige`, replantation, flotte vidée, notification, `SaveNow`). Une requête
répétée, rejouée ou préparée avant un rebirth trouve une révision périmée : jamais plusieurs récompenses (testé :
100 requêtes = 1 récompense ; rebirth et prestige croisés ; requête rejouée après restauration).

### Interface (`PrestigeController` sur `UI/ConfirmPanel`)
- Bouton **Prestige** (violet) sous **Rebirth** ; touche **P**, manette **R1**.
- Panneau : prestiges réalisés et Primal Cores, conditions avec deux barres (rebirths, Coins gagnés depuis le
  dernier prestige), récompense, multiplicateur de prestige actuel → futur, revenus juste après, listes **Perdu** /
  **Conservé**.
- **Confirmation renforcée** : récapitulatif chiffré (rebirths et Essence perdus, Primal Cores gagnés), case
  « J'ai compris » **obligatoire** et « Confirmer » inactif pendant **3 s** ; « Annuler » sélectionné par défaut.

## 4. Améliorations (jalon C — implémenté)

Catalogue `src/shared/Config/UpgradeConfig.luau` (identifiants **stables** : clés de sauvegarde), règles pures
`src/shared/Util/Upgrades.luau`, service `UpgradeService`, panneau `UpgradeController` (onglets Mutation Essence /
Primal Cores ; bouton « Améliorations », touche **U**, manette **L2**). Coût du niveau L → L + 1 :
`⌈costBase × costGrowth^L⌉`.

### Arbre Coins (améliorations normales, Phase 5, jalon B) — `upgrades.normal` : perdu au rebirth et au prestige

Payées en **Coins**, dans le même panneau (onglet « Coins », sélectionné par défaut), par la même règle
`Upgrades.purchase` et le même remote `UpgradePurchase` que les deux autres arbres ; leurs effets se cumulent avec
eux sous les mêmes plafonds globaux. Équilibrage : `docs/ECONOMY.md` §13.

| Identifiant | Nom | Effet par niveau | Max | Coût L → L + 1 | Coût total |
|---|---|---|---|---|---|
| `coins_growth` | Arrosage rapide (vitesse de croissance) | −3 % de durée de pousse | 10 | ⌈4 000 × 2^L⌉ | 4 092 000 |
| `coins_value` | Récoltes de qualité (valeur des récoltes) | +5 % de revenu (ventes et bonus) | 10 | ⌈2 500 × 1,9^L⌉ | 1 700 300 |
| `coins_bag` | Grand sac (capacité du sac) | +10 places | 5 | ⌈1 500 × 2,2^L⌉ | 63 171 |

Dépenser des Coins ne retarde jamais le rebirth (seuil sur les Coins **gagnés**). L'aperçu du rebirth n'annonce pas
la valeur de ces améliorations (perdues) : `nextMultiplier` les exclut. `upgrades.normal` existait depuis la v1 sans
catalogue (jamais écrit par le jeu) : **aucune migration** ; son contenu est désormais validé comme les autres arbres
(identifiant inconnu ou d'un autre arbre, niveau invalide → quarantaine ; au-delà du maximum → plafonné).

### Arbre Mutation Essence — `upgrades.rebirth` : conservé au rebirth, perdu au prestige

| Identifiant | Nom | Effet par niveau | Max | Coût L → L + 1 | Coût total |
|---|---|---|---|---|---|
| `essence_value` | Valeur de vente | +10 % de revenu (ventes et bonus) | 10 | ⌈40 × 1,55^L⌉ (40, 62, 97…) | 5 751 |
| `essence_growth` | Vitesse de croissance | −4 % de durée de pousse | 10 | ⌈50 × 1,6^L⌉ | 9 082 |
| `essence_luck` | Chance de mutation | +0,1 de chance (poids non normaux) | 10 | ⌈60 × 1,6^L⌉ | 10 899 |
| `essence_drones` | Efficacité des drones | −5 % d'intervalle des drones | 8 | ⌈50 × 1,55^L⌉ | 2 942 |
| `essence_bag` | Capacité du sac | +10 places | 10 | ⌈30 × 1,5^L⌉ | 3 403 |

### Arbre Primal Cores — `upgrades.permanent` : jamais réinitialisé

| Identifiant | Nom | Effet par niveau | Max | Coût L → L + 1 | Coût total |
|---|---|---|---|---|---|
| `superior_genetics` | Génétique supérieure | +5 % de revenu | 10 | ⌈4 × 1,45^L⌉ | 361 |
| `ancestral_growth` | Croissance ancestrale | −3 % de durée de pousse | 10 | ⌈5 × 1,5^L⌉ | 571 |
| `primal_automation` | Automatisation primordiale | +1 drone récolteur offert à chaque cycle | 2 | 12, 30 | 42 |
| `collector_instinct` | Instinct du collectionneur | +10 % de Mutation Essence par rebirth | 10 | ⌈4 × 1,45^L⌉ | 361 |
| `farming_legacy` | Héritage agricole | +1 graine gardée (Tomate, Maïs, Citrouille) | 3 | 6, 14, 30 | 50 |
| `mutagenic_energy` | Énergie mutagène | +0,1 de chance | 5 | ⌈6 × 1,6^L⌉ | 97 |

Tout maximiser coûte ≈ 32 000 Essence (un cycle de prestige à 5 rebirths en rapporte ≈ 1 100) et ≈ 1 480 Primal
Cores (10, 16, 22… par prestige) : les arbres se remplissent sur de nombreux cycles.

### Cumul et plafonds (`UpgradeConfig.Caps`, testés)
- Revenu = `M(R) × Mp(P) × (1 + 0,1 a) × (1 + 0,05 b)` (a, b : niveaux de Valeur de vente et de Génétique).
- Pousse × `(1 − 0,04 a)(1 − 0,03 b)`, jamais sous **40 %** de la durée de base (au maximum : 42 %).
- Chance `1 + 0,1 (a + b)` ≤ **2,5** → espérance du multiplicateur de mutation ≤ 1,98 (contre 1,505).
- Intervalle des drones ≥ **50 %** ; le **délai de grâce de 5 s n'est jamais modifié**.
- Effets « de début de cycle » (graines gardées, drones offerts) : appliqués à chaque rebirth et prestige
  (`Resets`), et immédiatement au cycle en cours à l'achat ; les drones achetés ne sont jamais retirés.

### Achat (serveur autoritaire)
`UpgradePurchase(id, niveauAttendu)` : chaîne ≤ 32 caractères du catalogue, entier 0 ≤ niveau ≤ 1 000, 4 requêtes/s,
refusé pendant une transition de progression (`ProgressionService.IsBusy`). **Un** mutateur `Upgrades.purchase` :
fonds insuffisants, niveau maximum, niveau périmé (double clic, paquet rejoué) ou identifiant inconnu → refus sans
aucune modification ; sinon dépense et niveau + 1 indissociables. Données : niveaux assainis au chargement
(identifiant inconnu, mauvais arbre ou niveau invalide → quarantaine ; au-delà du maximum → plafonné et signalé).

## 5. Équilibrage mesuré (simulateur, détail : `docs/ECONOMY.md` §8)

- Premier rebirth : ≈ 14 min (joueur actif), ≈ 18 min (hybride, 1 drone), ≈ 28 min (principalement automatisé).
- Joueur avancé (rebirths dès que possible, améliorations) : cycles de 16 → 21 → 26 → 38 → 52 min, premier
  prestige ≈ **2 h 34** (5 rebirths, 10 Primal Cores) ; premier rebirth après prestige ≈ 11 min.
- Améliorations les plus rentables : Valeur de vente, puis Vitesse de croissance et Chance de mutation ;
  Capacité du sac et Efficacité des drones ne servent qu'aux joueurs automatisés ; Héritage agricole n'a pas d'effet
  mesurable au niveau 1 (la Tomate coûte 750 Coins).
- Valeurs de la Carotte et de la Tomate **inchangées** (aucune mesure ne le justifiait).
