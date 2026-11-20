# MUTATION FARM

Farming incrémental hybride pour Roblox : cultive, récolte avec précision, découvre des mutations rares,
automatise, rebirth et prestige. Prototype **Phase 1** : ferme 3×3 sauvegardée, croissance automatique,
récolte manuelle avec bonus Parfait/Bien, sac, marché, boutique de 7 graines, HUD responsive.

## Démarrage rapide (Windows / PowerShell)

1. Outils (une fois) : `pwsh scripts/setup-tools.ps1` (ou `rokit install` si Rokit est installé).
2. Vérifier : `pwsh scripts/check.ps1`.
3. Jouer dans Studio, au choix :
   - **Live** : installer le plugin Rojo dans Studio, `tools/bin/rojo.exe serve`, puis *Connect* dans le plugin
     depuis un place vide (Baseplate) ;
   - **Fichier** : ouvrir `build/MutationFarm.rbxlx` (généré par `scripts/check.ps1`).
4. Persistance en Studio : publier le place puis activer *Game Settings › Security › Enable Studio Access to API
   Services* ; sinon les données restent en mémoire (avertissement en console).

Réglage recommandé de l'expérience : `MaxPlayers = 6` (8 parcelles par serveur).

## Documentation

- [Game design](docs/GAME_DESIGN.md) · [Architecture](docs/ARCHITECTURE.md) · [Économie](docs/ECONOMY.md)
- [Roadmap](docs/ROADMAP.md) · [Tests & QA](docs/TESTING.md) · [Consignes agents](CLAUDE.md)
