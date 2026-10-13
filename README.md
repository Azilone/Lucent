# Vivid

Barre de menu macOS qui débloque la pleine luminosité XDR des écrans Liquid Retina XDR (MacBook Pro 14"/16"), en Swift.

Principe : une fenêtre 2×2 px rend un pixel EDR (>1.0) pour mettre l'écran en mode étendu, puis la table gamma est montée au-dessus de 1.0.

```
./build.sh && open build/Vivid.app
```
