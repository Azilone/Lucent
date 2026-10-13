# Vivid

Barre de menu macOS qui débloque la pleine luminosité XDR des écrans Liquid Retina XDR (MacBook Pro 14"/16"), en Swift.

Principe : une fenêtre 2×2 px rend un pixel EDR (>1.0) pour mettre l'écran en mode étendu, puis la table gamma est montée au-dessus de 1.0.

```
./build.sh && open build/Vivid.app
```

## Sécurité

- **⌃⌥⌘V** active / coupe le boost depuis n'importe où.
- **Watchdog** : si le thread principal bloque > 1 s ou si une image capturée n'est pas affichée en 0,75 s, le boost est désactivé et l'app se tue (l'overlay disparaît instantanément). La raison est enregistrée : `defaults read design.personalize.vivid lastEmergency`.
- En dernier recours : `pkill -x Vivid`.
- Test du watchdog : `open --env VIVID_TEST_STALL=1 build/Vivid.app` (bloque le thread principal 5 s après le démarrage).
