<p align="center">
  <img src="Assets/icon.png" width="140" alt="Lucent icon">
</p>

<h1 align="center">Lucent</h1>

<p align="center"><b>Your MacBook Pro, up to 1000 nits. Free and open source.</b></p>

<p align="center">
  <a href="https://github.com/Azilone/Lucent/releases/latest"><b>⬇ Download</b></a>
</p>

<p align="center">
  <img src="Assets/social.png" alt="Lucent">
</p>

**TL;DR:** macOS caps XDR displays at 500 nits. Lucent lets your brightness keys go past 100%, up to 1000 nits.

- ☀︎ Brightness keys go past 100%, with a HUD in nits
- 🔋 Optional auto-boost on battery or when plugged in, paused in Low Power Mode
- ⬆️ Updates itself

## Lucent vs Vivid

| | **Lucent** | Vivid |
|---|---|---|
| Price | **Free** | €10+ |
| Open source | ✅ | ❌ |
| Max brightness | 1000 nits | 1000 nits |
| CPU (idle) | **0 %** | not published |
| RAM | **12 MB** | not published |

## Install

1. Download the [latest release](https://github.com/Azilone/Lucent/releases/latest) and move **Lucent.app** to Applications.
2. Open it. Since the app isn't notarized, go to **System Settings › Privacy & Security** and click **Open Anyway**.
3. Allow Lucent in **Privacy & Security › Accessibility**.

Then push brightness to max and keep pressing <kbd>☀︎+</kbd>. <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>V</kbd> turns it off.

**Requires** a MacBook Pro 14"/16" (M1 Pro or later) or a Pro Display XDR, on macOS 13+.

<details>
<summary>How it works · Build from source</summary>

A 1-pt EDR pixel switches the panel into extended range, then the gamma table is scaled above 1.0, capped at 1000 nits. There's no screen recording and no overlay. macOS restores the display if Lucent quits.

```bash
git clone https://github.com/Azilone/Lucent.git && cd Lucent && ./build.sh --install
```

Release a new version (builds, publishes the GitHub release, signs the Sparkle update):

```bash
./release.sh 1.2 "- What changed"
```
</details>

<sub>Vivid prices come from [getvivid.app](https://www.getvivid.app/) (Oct 2026). Lucent is not affiliated with Vivid. · [MIT License](LICENSE)</sub>
