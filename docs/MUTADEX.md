# MUTATION FARM — Mutadex (Phase 4, jalon A)

> Configuration : `src/shared/Config/MutadexConfig.luau`. Règles pures : `src/shared/Util/Mutadex.luau`.
> Enregistrement : `HarvestRules.apply` (mutateur de récolte). Annonces : `MutadexService`. Interface :
> `MutadexController` (bouton « Mutadex », touche **M**, manette **R2**). Tests : `tests/specs/Mutadex.spec.luau`.

## 1. Catalogue

Le catalogue est **dérivé** : toutes les plantes (`PlantConfig`) × toutes les mutations (`MutationConfig`), soit
**7 × 7 = 49 combinaisons** aujourd'hui. Ajouter une plante ou une mutation l'ajoute au Mutadex sans autre code.

| Champ | Source |
|---|---|
| Identifiant stable | clé d'objet `plante|mutation` (ex. `carrot|shiny`) — la même que le sac et les sauvegardes |
| Nom affiché | « Carotte » (normale) ou « Carotte · Brillante » |
| Plante, mutation | `plantId`, `mutationId` |
| Rareté | celle de la mutation : Commune, Peu commune, Rare, Épique, Légendaire, Mythique, Divine (`MutadexConfig.RarityByMutation`) |
| Multiplicateur | multiplicateur de vente de la mutation (×1 à ×150) |
| Découverte / inconnue | entrée présente dans `data.mutadex` |
| Première découverte | `firstAt` (horodatage serveur Unix) |
| Récoltes | `count` |

Les combinaisons inconnues s'affichent en cartes verrouillées « ??? » (bandeau de rareté pâle) ; leur nom n'est
jamais révélé, même par la recherche.

## 2. Découverte (serveur autoritaire)

1. `HarvestService` valide la récolte (propriété, maturité à l'horloge serveur, distance ou portée du drone, sac).
2. Dans **le même** mutateur synchrone, `HarvestRules.apply` lit la mutation **réelle** de la culture (donnée
   serveur, jamais l'attribut client) puis appelle `Mutadex.record` : `count + 1`, et `firstAt` si première fois.
3. Si c'est une première découverte, `Mutadex.claimMilestones` évalue les paliers dans ce même mutateur.
4. `MutadexService` annonce la découverte (« Mutadex : nouvelle découverte — Tomate · Géante (Rare) ! ») et les
   paliers ; le client reçoit `discovered = true` dans `HarvestResult` (badge et pulsation du bouton).

Récoltes manuelles **et** de drones alimentent le Mutadex. Une culture ne peut être récoltée qu'une fois (règle de
récolte existante) : elle n'est comptée qu'une fois. Une combinaison n'est « découverte » qu'une fois.

## 3. Paliers et récompenses (`MutadexConfig.Milestones`)

Exigence = `ceil(49 × pourcentage / 100)` découvertes.

| Palier | Découvertes | Récompense |
|---|---|---|
| 10 % | 5 | Titre « Botaniste curieux » (cosmétique) |
| 25 % | 13 | +5 places de sac (confort, permanent) |
| 50 % | 25 | Titre « Généticien » + Cadre doré (cosmétiques) |
| 75 % | 37 | +10 places de sac (confort, permanent) |
| 100 % | 49 | Titre « Maître du Mutadex » + Aura de collection (cosmétiques) |

- Accordés **une seule fois** : `mutadexRewards[palier] = horodatage`. Les cosmétiques vont dans
  `cosmetics.owned` (l'équipement des titres et auras viendra avec le système de cosmétiques).
- Aucune récompense n'est un multiplicateur de revenu. Les places de sac sont dérivées des paliers accordés
  (`Mutadex.bagBonus`, ajouté à `Economy.bagCapacity`).
- Au chargement d'un profil, `MutadexService` accorde les paliers déjà atteints mais pas encore accordés (cas d'une
  configuration modifiée) — toujours une seule fois.
- 100 % exige les 7 Divines (0,01 % par plantation, ×2,5 au plus avec les améliorations de chance) : objectif de
  très long terme, assumé.

## 4. Persistance (schéma v3)

- `mutadex[clé] = { firstAt, count }` et `mutadexRewards[palier] = horodatage` (`docs/DATA_MIGRATIONS.md`).
- **Jamais réinitialisé** : ni rebirth, ni prestige (testé), conservé entre serveurs et reconnexions (sauvegarde).
- Migration v2 → v3 : l'ancien format (un horodatage) est converti `{ firstAt = ancien, count = 1 }` ; rien n'est
  supprimé.
- Assainissement : `firstAt` non fini ou négatif, `count` non entier ou négatif, palier non horodaté →
  **quarantaine** (`meta.quarantine`), jamais de suppression silencieuse.
- Contenu retiré de la configuration (plante, mutation ou palier) : les entrées **bien formées** restent en place,
  **en sommeil** (non comptées, non affichées, signalées dans les journaux du chargement) et redeviennent actives si
  le contenu revient ; un palier déjà accordé ne l'est donc jamais deux fois. La quarantaine, bornée à 100 entrées
  (FIFO), ne sert pas de stockage à des découvertes valides.

## 5. Interface

- Barre de progression (découvertes / 49 et %), plantes récoltées, trois découvertes les plus rares, paliers
  (✓ accordés) et prochaine récompense.
- Filtres par plante et par rareté (boutons à cycle), recherche par nom (insensible aux accents et à la casse),
  bouton « Historique » (8 dernières premières découvertes avec date locale).
- Cartes : nom, multiplicateur, rareté, nombre de récoltes, date de découverte ; cartes inconnues « ??? ».
- Animations discrètes : pulsation du bouton du menu et badge « Nouveau » à chaque découverte ; à l'ouverture, les
  cartes découvertes depuis la dernière visite s'illuminent brièvement.
- Clavier (M), tactile (bouton, défilement), manette (R2, cartes sélectionnables, défilement automatique) ; chat
  Roblox masqué pendant l'ouverture et un seul panneau à la fois (`PanelHub` via `ModalPanel`).
- Le panneau ne se met à jour que lorsqu'il est ouvert (aucun coût pendant le jeu).

## 6. Limites

- Pas encore d'équipement des titres ni d'affichage des cosmétiques gagnés (système de cosmétiques à venir).
- Pas d'annonce serveur pour les découvertes très rares (Divine) : prévu avec les événements interserveurs.
