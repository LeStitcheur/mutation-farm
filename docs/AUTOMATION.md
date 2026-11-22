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

## 8. Production hors ligne (Phase 5, jalon D)

Règle pure `src/shared/Util/Offline.luau`, service `OfflineService`, écran `OfflineController`, tests
`tests/specs/Offline.spec.luau`, mesures `docs/ECONOMY.md` §15.

### 8.1 Calcul (serveur, au chargement)

1. **Fenêtre** : de `max(meta.lastSeen, offline.settledAt)` à maintenant. `meta.lastSeen` est écrit par le serveur à
   chaque sauvegarde (heure serveur) ; le client n'envoie **aucune** heure. Absence prise en compte :
   `min(absence, 7 200 s)` ; une absence de moins de **60 s** ne rapporte rien (changements rapides de serveur).
2. **Où** : `DataService.AddLoadStep` — sur la donnée chargée, migrée et assainie, **avant** qu'elle ne devienne
   vivante (aucun remote, aucun service ne peut encore la lire). Le calcul se fait sur une **copie** qui remplace
   la donnée seulement s'il aboutit ; une pause coopérative toutes les 500 actions de drone évite de bloquer le
   serveur (pire cas mesuré : ≈ 9 000 récoltes, ≈ 360 ms de calcul en Lune).
3. **Quoi** : seulement ce qui était **automatisé à la déconnexion** — les drones possédés et actifs (pas de drones
   = rien ; drones en pause = rien), avec leurs intervalles effectifs (améliorations, familiers), leur portée, leur
   capacité et le **délai de grâce de 5 s** ; le **sac** (capacité : sans comptoir, les drones s'arrêtent sac plein,
   rien n'est perdu) ; le **comptoir** s'il est installé et activé (même seuil, même règle de vente) ; la graine
   sélectionnée pour les replantations.
4. **Comment** (aucune simulation image par image) : les actions des drones sont rejouées l'une après l'autre (prochain
   drone dû), en sautant directement à la prochaine plante éligible quand il n'y a rien à récolter. Chaque récolte
   passe par les règles en ligne (`HarvestRules.check` puis `apply`, `Automation.autoSell`), chaque replantation tire
   sa mutation sur le serveur (`MutationService.Roll`) avec la chance du moment.
5. **Idempotence** : `offline.settledAt` = maintenant. Une reconnexion ne recompte jamais une période déjà réglée ;
   si le serveur s'arrête avant d'avoir écrit le règlement, la donnée stockée n'a pas changé et la même absence est
   recalculée une seule fois au chargement suivant (jamais additionnée).
6. **Cycle** : une absence ne peut pas chevaucher un reset (rebirth et prestige exigent le joueur connecté, la session
   est verrouillée sur un seul serveur, et le calcul se fait avant que le profil ne devienne vivant) : la production
   comptée appartient toujours au cycle sauvegardé à la déconnexion. Garantie **structurelle** ; la règle pure
   accepte en plus une révision attendue (une révision différente ne rapporte rien, testé), contrôle seulement
   défensif au chargement (revue de code).
   Absence de moins de 60 s : rien n'est compté et la période est marquée réglée (choix assumé contre les
   changements rapides de serveur : seul le joueur y perd cette micro-absence).
7. **Bilan** : `offline.report` (absence, durée comptée, récoltes, ventes, Coins, objets ajoutés au sac, découvertes,
   niveaux de familiers, missions, sac plein, raison), totaux `offline.totalSeconds` / `totalCoins`. L'écran
   « Pendant ton absence » l'affiche une fois (OK / B le marque lu, remote `OfflineReportSeen` sans charge utile) ;
   une absence sans drone n'affiche un conseil qu'au-delà de 10 min.

### 8.2 Écarts assumés par rapport à une session active

| Écart | Effet | Raison |
|---|---|---|
| Aucune récolte manuelle, aucun bonus de précision | production = drones seuls | le joueur est absent |
| Événements du monde (Pluie mutagène, Floraison dorée) non rejoués | ni chance × 3 ni part de valeur hors ligne | événements partagés, vécus en jeu (`docs/EVENTS.md`) |
| Boosts de mission actifs pendant l'absence : appliqués à l'instant de chaque récolte | Engrais et Rosée chanceuse comptent jusqu'à leur fin | même règle qu'en ligne |
| Plafond de 2 h, à partir du début de l'absence | les drones « s'arrêtent » après 2 h ; les cultures continuent ensuite de pousser (horodatages) | contrat `GameConfig.Offline.MaxSeconds` |
| Tirages de mutation sur un autre flux aléatoire | écart de quelques % sur les graines lentes (mutations rares) | aléa serveur |
| Dernier lot non vendu | reste dans le sac au retour (affiché « Ajouté à ton sac ») | même règle de seuil qu'en ligne |
| Notifications de mutations rares, d'XP et de missions | regroupées dans le bilan au lieu de toasts | lisibilité au retour |

Mesure (`docs/ECONOMY.md` §15) : sur 2 h, le hors ligne donne les mêmes Coins que la même ferme rejouée en ligne au
pas de 0,25 s, à ±0,5 % près (jusqu'à 5 % avec les graines lentes).

### 8.3 Ce qui n'est pas vérifiable sans place publiée

La vraie chaîne « déconnexion → sauvegarde DataStore → reconnexion sur un autre serveur » demande l'accès API (place
publiée, avec accord) : protocole manuel `docs/TESTING.md` §2.4. En Studio, deux chemins sont vérifiés : le **chemin de
chargement** (attribut Studio `ServerStorage.MutationFarmDevOfflineAway` : absence simulée au chargement) et le
**même calcul** sur un profil en jeu (`DevService` `offlineSimulate` : dernière sauvegarde et cultures reculées).
Ce sont des **simulations** de l'horodatage, pas des reconnexions réelles.
