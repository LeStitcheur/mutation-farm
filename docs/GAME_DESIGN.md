# MUTATION FARM — Game Design

> Statut : document vivant. Les sections marquées **[Phase N]** ne sont pas encore implémentées.
> Les valeurs chiffrées vivent dans `src/shared/Config/*` et `docs/ECONOMY.md` ; ce document décrit les intentions.

## 1. Pitch

Farming incrémental hybride. Le joueur cultive une ferme personnelle : les plantes poussent seules, il les récolte à la
main (avec un bonus de précision) puis automatise avec des drones. Chaque plantation peut muter
(Brillante → Divine) et multiplier sa valeur. Rebirths et prestiges relancent la progression avec des bonus permanents.

Fantasy colorée et stylisée, sessions courtes, progression lisible, aucun achat obligatoire.

## 2. Boucles de jeu

| Échelle | Boucle | Statut |
|---|---|---|
| 5–30 s | Une plante mûrit → récolte (bonus Parfait/Bien) → replantation automatique | **Phase 1 ✅** |
| 1–3 min | Sac plein → aller au marché → vendre → Coins | **Phase 1 ✅** |
| 5–60 min | Débloquer une graine plus rentable → la sélectionner | **Phase 1 ✅** |
| 10–60 min | Améliorations, extensions de ferme, mutations, Mutadex | Phase 2–3 |
| 1–3 h | Drones : récolte, collecte, vente auto, production hors ligne (≤ 2 h) | Phase 4 |
| 15 min – plusieurs h | Rebirth (reset partiel, implémenté), Prestige (reset profond) | Phase 3 |

## 3. Ferme

- **Parcelle personnelle** attribuée à l'arrivée (8 emplacements par serveur, `MaxPlayers` recommandé : 6).
- **Terrain initial 3×3** (`main`), cases de 8×8 studs.
- **Extensions latérales** `west` / `east` (3×3 chacune) et **terrasses** supérieures `terrace` — positions déjà
  réservées dans `FarmLayout`, déblocage **[Phase 3]**.
- **Plantation automatique** : toute case vide est replantée immédiatement avec la graine sélectionnée (gratuit).
- **Croissance automatique** par timestamps serveur : la croissance continue hors ligne.
- **Marché** (stand de vente) devant chaque parcelle : ProximityPrompt « Vendre tout ».

## 4. Récolte manuelle et précision

Une plante mûre affiche des étincelles ; une invite « Récolter » apparaît à proximité (clavier E, tactile, manette X).

| Palier | Fenêtre après maturité | Bonus instantané |
|---|---|---|
| **Parfait** | ≤ 1,5 s | +50 % de la valeur de base, en Coins immédiats |
| **Bien** | ≤ 5 s | +20 % |
| Normal | au-delà | — |

La récolte entre dans le sac (valeur pleine à la vente). Le bonus récompense l'attention pendant la phase manuelle ;
les drones **[Phase 4]** récolteront sans bonus de précision.

## 5. Plantes (7 initiales)

| Ordre | Id | Nom | Identité visuelle |
|---|---|---|---|
| 1 | `carrot` | Carotte | Racine orange, fanes vertes |
| 2 | `tomato` | Tomate | Tige + 3 tomates rouges |
| 3 | `corn` | Maïs | Grande tige, épi jaune |
| 4 | `pumpkin` | Citrouille | Grosse sphère orange aplatie |
| 5 | `moonshroom` | Champi-lune | Chapeau violet à points lumineux |
| 6 | `starbloom` | Fleur-étoile | Pétales dorés en étoile, cœur lumineux |
| 7 | `dragonfruit` | Fruit du dragon | Cactus et fruits roses |

Déblocage **séquentiel** contre des Coins ; la graine débloquée devient la graine sélectionnée.
Les visuels sont procéduraux (primitives Roblox) et remplaçables par des modèles d'art originaux
(`ReplicatedStorage.Assets.Plants.<id>`, **[Phase 7]**).

## 6. Mutations [Phase 2]

Tirage **pondéré exclusif** à la plantation (un seul résultat), probabilités **côté serveur** uniquement
(`src/server/Config/MutationOdds.luau`), modulées par la chance (événements, améliorations).

| Mutation | Multiplicateur | Probabilité de base | Effet visuel (optimisé) |
|---|---|---|---|
| Brillante | ×2 | 12 % | Or mat, petites étincelles |
| Géante | ×4 | 5 % | Échelle ×1,5 |
| Cristallisée | ×8 | 1,5 % | Matériau Glass cyan |
| Radioactive | ×20 | 0,4 % | Vert néon, lumière, particules lentes |
| Astrale | ×50 | 0,08 % | Violet néon, lumière, particules |
| Divine | ×150 | 0,01 % | Or néon, halo, lumière, particules (annonce serveur : plus tard) |

Récolter une mutation rapporte de la **Mutation Essence** et l'inscrit au **Mutadex** (plante × mutation, persistant).

## 7. Monnaies

| Monnaie | Source | Usage | Reset |
|---|---|---|---|
| **Coins** | Vente, bonus de précision | Graines, améliorations normales, machines | Rebirth + Prestige |
| **Mutation Essence** | Rebirth (Phase 3) ; récoltes mutées (prévu) | Améliorations de rebirth, laboratoire de mutation (jalon C) | Prestige |
| ~~Rebirth Tokens~~ | — | Remplacés par la Mutation Essence (cahier des charges Phase 3) ; champ conservé, inutilisé | — |
| **Primal Cores** | Prestige | Améliorations permanentes | Jamais |

Aucune monnaie de prestige n'est vendue contre des Robux.

## 8. Resets [Phase 3] — règles testées (`tests/specs/Resets.spec.luau`) ; détail exact : `docs/PROGRESSION.md`

| Élément | Rebirth | Prestige |
|---|---|---|
| Coins, sac, graines débloquées, machines, upgrades normaux, cultures en cours | reset | reset |
| Parcelles débloquées (extensions, terrasses) | **conservé** | reset |
| Upgrades de rebirth, Rebirth Tokens, nombre de rebirths | **conservé** | reset |
| Mutation Essence | **conservé** | reset |
| Primal Cores, upgrades permanents, Mutadex, cosmétiques, familiers, stats, reçus | conservé | **conservé** |

Coûts exponentiels : voir `docs/ECONOMY.md`.

## 9. Événements [Phase 2–3]

- **Pluie mutagène** : chance de mutation ×3 pendant 3 min (serveur entier), ciel vert, gouttes lumineuses.
- **Floraison dorée** : croissance ×2 pendant 3 min, pétales dorés.
- Planification serveur toutes les ~30 min, annonce 30 s avant.

## 10. Automatisation [Phase 4]

- **Drone récolteur** : récolte les cases mûres d'une zone (sans bonus de précision).
- **Drone collecteur** : vide le sac vers un silo.
- **Vente automatique** : silo vendu périodiquement.
- Simulation **agrégée** (débit = récoltes/s calculées) plutôt que simulation par drone ; production hors ligne
  plafonnée à **2 heures**.

## 11. Familiers [V1.1]

Bonus passifs (chance, vitesse, capacité), conservés après tous les resets. Champ `pets` déjà présent dans le schéma.

## 12. Interface

HUD responsive PC / mobile / console :
- Haut : Coins, Sac (barre de remplissage, rouge si plein).
- Gauche : bouton **Graines** (touche G / manette Y). Phases suivantes : Améliorations, Rebirth, Prestige, Mutadex.
- Notifications en bas, textes flottants de récolte (« PARFAIT ! +5 »).
- Écran de chargement jusqu'à la réception des données.
- `ScreenInsets = DeviceSafeInsets`, `UIScale` selon la résolution, boutons sélectionnables à la manette.

## 13. Monétisation [Phase 6] — principes

- **Game Passes** confort/cosmétique : Sac ×2, Vente automatique à distance, Pack cosmétique VIP (traînée, chapeau).
- **Developer Products** limités : boosts temporaires (Coins ×2 15 min, Chance ×2 15 min).
- Jamais : vente de Primal Cores, de rebirths, d'avantages exclusifs indispensables.
- `ProcessReceipt` idempotent (voir `docs/ARCHITECTURE.md` §8).
