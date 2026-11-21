# MUTATION FARM — Familiers (Phase 4, jalon B)

> Configuration : `src/shared/Config/PetConfig.luau`. Règles pures : `src/shared/Util/Pets.luau` (familiers),
> `src/shared/Util/Bonuses.luau` (agrégation de toutes les sources de bonus). Serveur : `PetService`.
> Interface : `PetController` (bouton « Familiers », touche **F**, manette **L3**), rendu : `PetRenderer`.
> Tests : `tests/specs/Pets.spec.luau`.

## 1. Espèces (originales)

| Identifiant | Nom | Rareté | Effet (niveau 1 → niveau 15) | Silhouette |
|---|---|---|---|---|
| `sproutling` | Pousselet | Commun | pousse −4 % → −12 % | boule verte, deux feuilles |
| `solar_bunny` | Lapin solaire | Commun | bonus de précision des récoltes **manuelles** +20 % → +60 % | lapin jaune |
| `crystal_fox` | Renard de cristal | Rare | revenu +5 % → +15 % | renard cyan |
| `drone_beetle` | Scarabée-drone | Rare | intervalle des drones −5 % → −15 % | scarabée à rotor |
| `moon_moth` | Phalène lunaire | Épique | chance de mutation +0,10 → +0,30 | papillon violet (ailes battantes, lueur) |
| `primal_wisp` | Feu follet primal | Légendaire | un peu de tout : revenu +3→8 %, pousse −2→6 %, chance +0,05→0,12, drones −2→6 %, précision +10→25 % | flamme orange (néon, lueur) |

Bonus d'un niveau = interpolation linéaire entre le niveau 1 et le niveau maximum (15).

## 2. Œufs (probabilités affichées en jeu)

| Œuf | Prix | Pousselet | Lapin solaire | Renard de cristal | Scarabée-drone | Phalène lunaire | Feu follet primal |
|---|---|---|---|---|---|---|---|
| Œuf de prairie | 5 000 Coins | 40 % | 40 % | 8 % | 8 % | 4 % | — |
| Œuf cristallin | 75 000 Coins | 10 % | 10 % | 30 % | 30 % | 17 % | 3 % |
| Œuf des missions | **non vendu** (missions, objectifs) | 25 % | 25 % | 18 % | 18 % | 10 % | 4 % |

- Probabilité affichée = poids / somme des poids (`Pets.odds`) : le panneau affiche exactement ce que tire le serveur.
- **Aucun œuf contre des Robux.** Les œufs gratuits (réserve par type, ≤ 99) viennent des récompenses (missions,
  jalon D) ; en Studio : `ServerStorage.MutationFarmDev:Invoke("grantEggs", userId, eggId, n)`.
- Prix : l'Œuf de prairie coûte ≈ 1 min 30 de revenu au stade Tomate, l'Œuf cristallin ≈ 5 min au stade
  Citrouille (`docs/ECONOMY.md` §8, table A) : un vrai choix face au déblocage des graines (les Coins sont remis à
  zéro au rebirth, les familiers jamais).

## 3. Éclosion (serveur autoritaire, idempotente, sauvegardée)

1. Le client envoie `PetHatch(eggId, éclosions affichées, œuf gratuit ?)` — jamais un prix, un aléa ni un résultat.
2. `PetService` valide (type, longueur, catalogue, entier borné, débit 1 éclosion / 3 s, pas de rebirth/prestige en
   cours, pas d'éclosion déjà en sauvegarde), tire l'aléa avec **son** générateur, puis exécute `Pets.hatch` dans
   **un** mutateur : vérifications (œuf, révision, inventaire, paiement) → paiement → tirage → instance `p<n>` →
   compteur d'éclosions + 1. Paiement et familier sont indissociables.
3. **Idempotence** : le nombre d'éclosions attendu doit égaler `pets.hatched` ; un double clic ou un paquet rejoué
   arrive avec une révision périmée (`stale`) et n'ouvre rien.
4. **Sauvegarde avant confirmation** : `DataService.SaveNow` puis `PetHatched` au client (animation : l'œuf tremble,
   puis le familier apparaît). Si l'écriture échoue (stockage indisponible), le familier reste acquis en mémoire et
   sera écrit par la sauvegarde périodique ou de départ (`saved = false`, avertissement serveur).
5. Inventaire plein (50) : refusé **avant** tout paiement.

## 4. Inventaire, emplacements, relâchement

- Identifiant d'instance unique `p<n>` : `pets.nextSerial` ne fait que croître (jamais réutilisé, même après un
  relâchement ou une quarantaine).
- **3 emplacements** : équiper / retirer (`PetEquip` / `PetUnequip`) ; double équipement refusé.
- Tri : équipés, rareté, niveau, espèce, ancienneté ; doublons comptés (« ×2 ») et affichés chacun.
- Relâcher (`PetRelease`, confirmation en deux clics) : uniquement un familier **non équipé** ; c'est le seul moyen
  de libérer une place d'inventaire (choix explicite du joueur).

## 5. XP et niveaux

- XP par récolte **validée** (joueur ou drone) : +1, +1 de plus pour une récolte manuelle « Parfait ». Accordée par
  `HarvestRules.apply` dans le mutateur de récolte, aux seuls familiers **équipés**. Aucun événement réseau par
  récolte : l'XP voyage avec la synchronisation d'état existante ; seuls les passages de niveau sont annoncés.
- Coût du niveau L → L + 1 = `ceil(30 × 1,35^(L − 1))` ; niveau maximum 15 (XP remise à 0 ensuite).

| Niveau | 1→2 | 2→3 | 3→4 | 4→5 | 5→6 | 6→7 | 7→8 | 8→9 | 9→10 | 10→11 | 11→12 | 12→13 | 13→14 | 14→15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| XP | 30 | 41 | 55 | 74 | 100 | 135 | 182 | 246 | 331 | 447 | 604 | 815 | 1 100 | 1 485 |
| Cumul | 30 | 71 | 126 | 200 | 300 | 435 | 617 | 863 | 1 194 | 1 641 | 2 245 | 3 060 | 4 160 | 5 645 |

Ordre de grandeur : 5 645 récoltes pour le niveau maximum, soit quelques heures de jeu actif avec des drones.

## 6. Bonus et plafonds

- Cumul des familiers équipés plafonné **par effet** (`PetConfig.Caps`) : revenu +40 %, pousse −30 %, chance +0,60,
  drones −30 %, précision +150 % (ex. 3 Renards de cristal niveau 15 : 0,45 → 0,40).
- Agrégation (`Util/Bonuses`) avec les améliorations, sous les **plafonds globaux** (`UpgradeConfig.Caps`) :
  pousse ≥ 40 % de la durée de base, intervalle des drones ≥ 50 %, **chance totale ≤ 5** (P(normale) ≥ 46 %,
  testé). Points d'entrée : `Economy.growTime`, `DroneLogic.interval`, `ProgressionMath.incomeMultiplier` (et ses
  aperçus de rebirth/prestige), `FarmService` (tirage de mutation), `HarvestRules` (précision manuelle).
- Les drones n'ont jamais de bonus de précision : le Lapin solaire ne profite qu'aux récoltes manuelles.

## 7. Rendu (`PetRenderer`)

- `PetService` publie les familiers équipés dans l'attribut `Pets` du joueur (« espèce:niveau;… ») ; chaque client
  affiche ceux de **tous** les joueurs, localement (aucune physique ni réplication de pièces).
- Modèles stylisés de 5 à 8 pièces, taille +2 %/niveau ; suivi par interpolation (`1 − e^(−7·dt)`), positions
  autour du joueur (gauche, droite, derrière) ; sautillement en marche, flottement et battement d'ailes pour les
  volants, rotor pour le Scarabée-drone ; retour immédiat après une téléportation (> 40 studs).
- Mobile d'entrée de gamme : pièces ancrées sans collision, requête ni ombre ; déplacement groupé
  (`BulkMoveTo`) à 30 Hz ; familiers à plus de 160 studs de la caméra retirés du rendu ; lumière uniquement pour
  les familiers lumineux du joueur local.

## 8. Persistance (schéma v4)

- `pets = { owned (obsolète, conservé), equipped = { "p3", … }, instances = { p3 = { petId, level, xp, obtainedAt } },
  nextSerial, hatched, freeEggs = { mission = 2 } }` (`docs/DATA_MIGRATIONS.md`).
- **Jamais réinitialisé** : ni rebirth, ni prestige (testé) ; conservé entre serveurs et reconnexions.
- Migration v3 → v4 : chaque exemplaire de l'ancien contrat (`owned` = compteurs) devient une instance de niveau 1 ;
  les espèces équipées sont reportées ; `owned` et l'ancienne liste équipée (`legacyEquipped`) restent stockés.
- Assainissement : instance malformée → quarantaine ; espèce retirée de la configuration → **en sommeil** (gardée,
  ni active ni équipable) ; niveau > 15 → plafonné (valeur d'origine en quarantaine) ; compteur d'instances
  remonté au-dessus du plus grand numéro connu ; liste équipée nettoyée (doublons, instances absentes ou en
  sommeil, au-delà de 3 : liste d'origine en quarantaine, aucun familier perdu).

## 9. Limites

- Les familiers ne sont pas modélisés par le simulateur économique (`tests/sim`) : leurs bonus sont bornés par les
  plafonds ci-dessus et vérifiés par `Pets.spec`.
- Pas de fusion ni d'échange de familiers ; pas de nom personnalisé.
- La sauvegarde à chaque éclosion consomme le budget DataStore (1 écriture / 3 s / joueur au plus) : à surveiller
  avec beaucoup de joueurs ouvrant des œufs en continu.
