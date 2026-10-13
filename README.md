# Vivid

Barre de menu macOS qui débloque la pleine luminosité XDR des écrans Liquid Retina XDR (MacBook Pro 14"/16"), en Swift.

Principe : un pixel EDR de 1 pt (invisible) met l'écran en mode étendu, puis la table gamma est montée au-dessus de 1.0. Pas de capture d'écran, pas d'overlay plein écran. macOS restaure la table gamma tout seul quand l'app quitte ou plante.

Usage : luminosité native au max, puis la touche luminosité + continue de 500 à 1000 nits (pas de 50). La touche − redescend. Un HUD affiche les nits. Les touches demandent la permission Accessibilité.

```
./build.sh && open build/Vivid.app
```

## Sécurité

- **⌃⌥⌘V** active / coupe Vivid depuis n'importe où.
- Si la luminosité native baisse (Centre de contrôle, capteur), le boost retombe à 500 nits.
- En dernier recours : `pkill -x Vivid` (la table gamma est restaurée par macOS).
- `Tools/gamma-probe.swift` vérifie que macOS garde une table gamma > 1.0 en mode EDR.
