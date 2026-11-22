# MUTATION FARM — Ferme et extensions

> Phase 5, jalon A. Géométrie : `src/shared/Util/FarmLayout.luau`. Prix : `src/shared/Config/ExpansionConfig.luau`.
> Règles pures : `src/shared/Util/Expansions.luau`. Service : `FarmService`. Tests : `tests/specs/Expansions.spec.luau`.
> Équilibrage : `docs/ECONOMY.md` §12.

## 1. Parcelles

Chaque joueur reçoit un **emplacement** (8 par serveur, `SlotAllocator`) portant un socle de 104 × 96 studs. Les
parcelles sont définies en coordonnées **locales** dans `FarmLayout.Plots` :

| Parcelle | Cases | Position locale | Accès |
|---|---|---|---|
| `main` | 3 × 3 | centre | parcelle de départ (toujours débloquée) |
| `west` | 3 × 3 | x = −34 | au sol |
| `east` | 3 × 3 | x = +34 | au sol |
| `terrace` | 3 × 3 | z = −34, surélevée de 10 studs | escalier de 10 marches (flanc +X) |

**Escalier** (`FarmLayout.stairs`) : marches pleines de 1 stud de haut, 2 de profondeur et 8 de large, posées sur le
socle le long du flanc +X de la terrasse, de la plus basse à la plus haute (au niveau du sol de la terrasse, contre
son socle). Un personnage les gravit sans sauter (contrôles géométriques testés en Lune ; montée vérifiée en Studio,
`docs/TESTING.md` §2.9).

**Aucune superposition** (testé) : parcelles, escalier et éléments fixes (marché, panneau, station des drones, zone
d'apparition) ont des emprises disjointes, toutes contenues dans le socle ; les socles des 8 emplacements sont
disjoints (130 × 150 studs entre emplacements pour un socle de 104 × 96).

## 2. Achat (serveur autoritaire)

| Extension | Prix | Prérequis |
|---|---|---|
| Champ ouest (`west`) | 300 000 Coins | — |
| Champ est (`east`) | 4 000 000 Coins | Champ ouest |
| Terrasse (`terrace`) | 40 000 000 Coins | Champ est |

- Chaque emplacement achetable non possédé affiche un contour lumineux et un **panneau « À vendre »** (nom, prix ;
  « après : … » tant que l'extension précédente manque) portant une **invite serveur** (`ProximityPrompt`, appui
  0,5 s, 12 studs, réservée au propriétaire, 2 achats/s). Aucun remote : le client ne peut fournir ni prix ni
  parcelle hors de sa ferme ; le moteur valide la distance.
- `FarmService.BuyPlot` exécute `Expansions.purchase` dans **un** mutateur : extension connue, non possédée,
  précédente possédée, solde suffisant, puis débit (`Economy.trySpend`, jamais de solde négatif) et déblocage
  indissociables. Un appui répété ou un paquet rejoué trouve la parcelle possédée (« owned ») : rien n'est débité.
- Après l'achat : la parcelle est construite (`SyncPlots`), ses 9 cases sont plantées (graine sélectionnée, tirage
  de mutation serveur), les panneaux restants sont mis à jour, notification « Champ ouest débloqué ! +9 cases ».
- **Terrasse** : son socle apparaît d'un coup ; tout personnage qui se tenait à cet endroit (l'acheteur devant le
  panneau, un visiteur) est posé dessus au lieu d'être enfermé dans la pierre (défaut trouvé en Studio, corrigé).

## 3. Reconstruction, rebirth et prestige

- `FarmService.SyncPlots` aligne la géométrie sur `farm.plots` : parcelles possédées construites (modèle
  `Area_<id>` : bordures, socle, escalier, cases taguées `FarmTile`), parcelles reprises démontées, panneaux « À
  vendre » sur les emplacements restants. Appelé à la construction de la ferme (chargement), après un achat et
  après chaque rebirth / prestige (`ProgressionService.Run`).
- **Rebirth** : extensions **conservées** (`farm.plots` n'est pas touché), cultures vidées puis replantées en
  Carotte sur toutes les cases, extensions comprises.
- **Prestige** : retour à `main` seule (`Resets.prestige`), extensions démontées **immédiatement** (la limite de la
  Phase 3 — géométrie visible jusqu'à la reconnexion — est levée) ; elles se rachètent dans l'ordre.
- Données : `farm.plots` (`{ [plotId]: boolean }`) existait depuis la v1 ; **aucune migration**. L'assainissement
  met désormais en quarantaine un état de parcelle non booléen (parcelle verrouillée) en plus des parcelles
  inconnues ; `main` est toujours forcée.

## 4. Récolte et drones sur les extensions

- Récolte manuelle : mêmes règles partout (`HarvestRules` : parcelle débloquée, maturité, sac), distance au
  personnage ≤ 20 studs. Les invites locales de récolte suivent les cases taguées (ajoutées / retirées à la volée).
- **Drones** : portée passée de 25 à **55 studs** et point d'attente relevé à 12 studs (au-dessus du sol de la
  terrasse, à 11) : chaque drone couvre toutes les cases de toutes les parcelles quel que soit le nombre de drones
  (testé) ; délai de grâce de 5 s inchangé.
- **Entre joueurs** : le serveur résout toujours une case dans la ferme **du demandeur** (`FarmService.GetTilePart`
  et `OwnsTile` sur sa propre donnée) et vérifie la distance à sa propre case ; un joueur ne peut ni récolter ni
  acheter dans la ferme d'un autre (invite d'achat : « Cette parcelle appartient à une autre ferme. »).

## 5. Limites

- Ordre des extensions imposé (ouest → est → terrasse) : choix de lisibilité.
- Validation à 2 joueurs réels (deux fermes voisines, achats croisés refusés) : protocole manuel
  (`docs/TESTING.md` §2.4), non exécutable par Studio MCP.
