# MUTATION FARM — Événements du monde (Phase 4, jalon C)

> Configuration : `src/shared/Config/EventConfig.luau` (définitions, calendrier) et
> `src/server/Config/MutationOdds.luau` (`Luck.MutagenicRain`, donnée de probabilité serveur). Règles pures :
> `src/shared/Util/WorldEvents.luau`. Serveur : `EventService`. Client : `EventController`.
> Tests : `tests/specs/Events.spec.luau`.

## 1. Événements

| Événement | Durée | Effet | Quand l'effet s'applique | Visuel |
|---|---|---|---|---|
| **Pluie mutagène** | 5 min | Chance de mutation × 3 (`MutationOdds.Luck.MutagenicRain`), plafonnée à la chance totale 5 | **À la plantation** : le tirage de mutation a lieu quand une culture est semée (replantation après récolte) ; une culture semée pendant la pluie garde sa mutation | pluie violette autour de la caméra, éclairage teinté de violet |
| **Floraison dorée** | 10 min | +50 % de la valeur de chaque plante récoltée | **À la récolte** (joueur et drones) : la part est versée immédiatement en Coins (comptée comme gagnée) ; l'objet du sac garde sa valeur normale à la vente | paillettes dorées, éclairage chaud |

**Choix « à la récolte » pour la Floraison** : le sac ne garde pas la date de récolte de chaque objet ; appliquer le
bonus à la vente inciterait à garder son sac plein jusqu'à l'événement (et paierait des récoltes antérieures).
À la récolte, seul le travail fait pendant l'événement est récompensé, une fois, sans aucune donnée nouvelle.

## 2. Calendrier (déterministe, identique sur tous les serveurs)

- Le temps UTC est découpé en **tranches de 30 min** ; chaque tranche contient **au plus un** événement.
- **Rendez-vous fixes** : tranches de 12:00 et 20:00 UTC → Floraison dorée.
- **Tirage contrôlé** pour les autres tranches : hachage 32 bits stable (tranche + graine) → 50 % de tranches avec
  un événement (≈ 1 par heure), Pluie 60 % / Floraison 40 %, début aléatoire dans la tranche.
- **Écart minimal** : un événement commence au moins 2 min 30 après le début de sa tranche et finit au moins
  2 min 30 avant sa fin → **5 min** au minimum entre deux événements ; jamais deux à la fois (testé sur 10 000
  tranches).
- Le calendrier est une fonction pure de l'horloge serveur (`Workspace:GetServerTimeNow`) : tous les serveurs ont le
  même sans **aucun** MessagingService, et un événement « interserveur » futur (annonce globale) pourra s'y greffer.

## 3. Serveur autoritaire

- `EventService` publie l'événement actif dans `ReplicatedStorage.WorldEvent` (attributs `EventId`, `StartsAt`,
  `EndsAt`, rafraîchis chaque seconde) : tous les joueurs reçoivent le même état, y compris ceux qui arrivent en
  cours d'événement (réplication des attributs).
- Annonces de début et de fin à tous les joueurs (notifications) ; bandeau avec compte à rebours côté client.
- Les bonus sont **lus à l'instant de l'action** (`LuckFactor` à la plantation, `ValueBonus` à la récolte) : aucun
  état de bonus stocké, rien ne survit à la fin de la fenêtre, aucune donnée joueur modifiée ni sauvegardée.
- Le client n'envoie rien : changer l'horloge du client ne change ni l'état ni les bonus (horloge serveur).
- Aucun cumul : un seul événement actif ; le facteur de chance multiplie une fois (améliorations + familiers) puis
  est plafonné (`UpgradeConfig.Caps.MaxTotalLuck` = 5, P(normale) ≥ 46 %) ; la Floraison n'ajoute aucune chance.
- Studio : `ServerStorage.MutationFarmDev:Invoke("startEvent", userId, "mutagenic_rain" | "golden_bloom",
  durée?)` force un événement (prioritaire, durée ≤ 1 h ; l'événement planifié qui le chevauche ± 5 min est annulé) ;
  `Invoke("stopEvent", userId)` l'arrête.

## 4. Client (`EventController`)

- Bandeau sous la barre du haut : nom, effet, compte à rebours (horloge serveur), couleur de l'événement.
- `ColorCorrectionEffect` local (fondu de 2 s), un seul `ParticleEmitter` attaché à une pièce invisible qui suit la
  caméra (pluie : 220 particules/s, 110 sur écran tactile ; paillettes : 40/s, 20 sur tactile), mise à jour à 20 Hz.
- Texte flottant de récolte : « Floraison +X » quand une part de valeur a été versée.

## 5. Limites

- Pas d'événement « interserveur » annoncé à tous les serveurs (le calendrier commun le permet sans
  MessagingService ; à concevoir avec la Phase 5 ou 6).
- La pluie ne change pas les cultures déjà semées (choix : la mutation est tirée à la plantation).
- Particules et éclairage non validés sur un vrai appareil mobile (`docs/TESTING.md` §2.4).
