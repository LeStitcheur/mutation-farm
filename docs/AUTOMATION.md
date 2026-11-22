# MUTATION FARM — Automatisation et production hors ligne

> Phase 5, jalons C (automatisation avancée) et D (production hors ligne). Configuration :
> `src/shared/Config/AutomationConfig.luau`. Règles pures : `src/shared/Util/Automation.luau`,
> `src/shared/Util/Selling.luau`. Services : `AutomationService`, `EconomyService.AutoSell`, `DroneService`
> (drones récolteurs, Phase 2). Interface : `AutomationController`. Tests : `tests/specs/Automation.spec.luau`.
> Équilibrage : `docs/ECONOMY.md` §14.

## 1. Ce qui existait : drones récolteurs (Phase 2)

Les drones récoltent les cases mûres depuis au moins 5 s (délai de grâce : les bonus Parfait/Bien restent au joueur),
dans **une seule** boucle serveur pour tous les drones, avec les mêmes validations atomiques que le joueur
(`HarvestRules`). Ils n'ont pas été réécrits ; la Phase 5 étend leur portée à toute la ferme (`docs/FARM.md` §4).

## 2. Collecte et transport : pas de drone collecteur

Une récolte place directement l'objet dans le sac : il n'existe ni objet au sol ni silo à vider. Un « drone
collecteur » ferait donc le même travail que le drone récolteur. La seule étape réellement manuelle de la boucle
automatique est le **transport du sac au marché** : c'est le rôle du comptoir automatique (§3). Aucune machine de
collecte n'est ajoutée (distinction fonctionnelle non justifiée).

## 3. Comptoir automatique (vente automatique configurable)

| Élément | Valeur |
|---|---|
| Prix | 5 000 Coins (`AutomationConfig.AutoSeller.Price`) |
| Statut | **machine** du cycle (`machines.autoSeller`) : perdue au rebirth et au prestige, comme les drones |
| Seuil | 50, 75 ou 100 % de la capacité du sac (défaut 100 % : sac plein) |
| Vente | tout le sac, **même règle** que le marché (`Selling.sellBag`) : valeur × multiplicateur de revenu, Coins gagnés |

- Déclenchement : après **chaque** récolte (joueur ou drone) et après chaque achat ou réglage, si le comptoir est
  installé, activé et le seuil atteint (`EconomyService.AutoSell`). Aucune boucle supplémentaire.
- **Sans attribution double** : la vente manuelle et la vente automatique exécutent chacune `Selling.sellBag` dans
  leur propre mutateur ; la seconde trouve le sac vide (testé dans les deux ordres).
- Missions : une vente automatique ne compte **pas** pour les missions « vendre » (elles récompensent le jeu actif) ;
  les récoltes de drones comptent pour les missions « drones » comme avant.
- Notification « Vente automatique : N récolte(s), +X Coins » au plus toutes les 20 s.

## 4. Sacs pleins

- Comptoir installé et activé : un sac plein est vendu puis la récolte (joueur ou drone) reprend aussitôt.
- Sinon (comportement de la Phase 2) : rien n'est perdu, la culture attend ; les drones affichent « Sac plein ! » et
  le joueur reçoit au plus toutes les 30 s « Tes drones attendent : sac plein ! » avec un conseil (installer le
  comptoir, ou le réactiver s'il est coupé) ; le panneau Automatisation signale « PLEIN : tes drones attendent ».

## 5. Réglages (jamais réinitialisés)

| Réglage | Valeurs | Effet |
|---|---|---|
| Drones actifs | oui / non | non : la boucle serveur ne fait plus agir les drones (statut « En pause » affiché au-dessus d'eux) ; à la reprise, aucune action manquée n'est rattrapée |
| Vente automatique | oui / non | coupe le comptoir sans le perdre |
| Seuil de vente | 50 / 75 / 100 % | abaisser le seuil sous le contenu du sac le vend aussitôt |

Remote `AutomationRequest(action, valeur)` : actions `buy_seller`, `drones` (booléen), `autosell` (booléen),
`threshold` (nombre de la liste) ; chaîne ≤ 16 caractères, types stricts, 4 requêtes/s, refus pendant une
transition de progression ; jamais de prix ni de montant envoyé par le client.

## 6. Statistiques de production automatique

- Stockées (`automation.stats`, jamais réinitialisées) : récoltes de drones, ventes du comptoir, Coins rapportés.
- Panneau Automatisation (bouton **Automatisation**, touche **K**, manette croix droite) : comptoir (prix ou état,
  seuil), drones (nombre, débit max., pause), ferme (cases, récoltes/min avec la graine actuelle, facteur limitant :
  drones ou cases), sac, statistiques **depuis toujours** et **depuis la connexion**.
- Débits (`Automation.rates`) : drones = Σ capacité × 60 / intervalle effectif ; ferme = cases × 60 / (pousse
  effective + délai de grâce).

## 7. Données (schéma v6)

`machines.autoSeller` (booléen) et `automation = { dronesEnabled, autoSellEnabled, autoSellThreshold, stats }`,
ajoutés par la réconciliation (migration v5 -> v6 sans transformation, rien de supprimé ; détail :
`docs/DATA_MIGRATIONS.md`). Assainissement : seuil hors liste, compteurs ou montant invalides, booléens d'un autre
type → quarantaine et valeur par défaut.
