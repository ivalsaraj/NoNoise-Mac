<div align="center">

  <img src="Resources/NoNoiseMacLogo.png" alt="NoNoise Mac" width="150" height="150" />

  # NoNoise Mac

  ### Real-time, on-device AI noise cancellation for macOS

  Silence keyboards, fans, traffic, and room echo on **any** mic, in **every** app —
  processed entirely on your Apple Silicon Neural Engine. No cloud. No subscription. No lag.

  [![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/swift/)
  [![Platform](https://img.shields.io/badge/macOS-Apple%20Silicon-black.svg?style=flat-square&logo=apple)](https://www.apple.com/mac/)
  [![On-device](https://img.shields.io/badge/Privacy-100%25%20On--Device-2ea44f?style=flat-square&logo=shield)](#-privacy)
  [![License](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)
  [![CI](https://github.com/ivalsaraj/NoNoise-Mac/actions/workflows/ci.yml/badge.svg)](https://github.com/ivalsaraj/NoNoise-Mac/actions/workflows/ci.yml)

  <a href="#-install"><b>Install</b></a> ·
  <a href="#-why-nonoise-mac"><b>Why</b></a> ·
  <a href="#-usage"><b>Usage</b></a> ·
  <a href="#-how-it-works"><b>How it works</b></a> ·
  <a href="#-contributing--ai-native"><b>Contribute</b></a>

</div>

<br />

> [!IMPORTANT]
> **Requires a Mac with Apple Silicon (M1 / M2 / M3 / M4 or newer).** NoNoise Mac runs the
> model on the Apple Neural Engine + Metal. It does **not** support Intel Macs.

---

## 🎥 Demo

https://github.com/user-attachments/assets/a6cc5011-7551-4e68-9326-1426c2367936

> Real noise in, studio voice out — in real time, 100% on-device.

---

## 🎯 What is NoNoise Mac?

NoNoise Mac is a lightweight **menu-bar app** that cleans your microphone in real time using
**DeepFilterNet3**, a state-of-the-art deep-learning speech-enhancement model, compiled to
**CoreML**. It strips background noise and de-reverberates "roomy" audio, then routes the
clean signal through a virtual audio cable so **Zoom, Meet, Discord, OBS, Slack, QuickTime —
anything** — hears studio-quality voice.

Everything happens **on your device**. Your audio never leaves your Mac.

## ✨ Why NoNoise Mac

- **🚫 Kills real-world noise** — fans, AC, keyboards, traffic, café chatter, crying kids.
- **🎙️ Studio clarity** — de-reverb removes echo so you sound close-mic'd and present.
- **⚡ Real-time feel** — a tight Metal/Accelerate pipeline keeps latency negligible for live calls.
- **🔒 100% private** — fully on-device on the Neural Engine; nothing is uploaded, ever.
- **🎛️ One-click modes** — Meeting, Podcast, Tutorial, or Custom, with strength + tone control.
- **↩️ Safe reset** — restore audio/device settings to defaults from Settings without deleting saved Voice Profiles or custom Hotkeys.
- **🎙️ Broadcast Voice** — a one-tap clarity lift (Off / Low / Medium / High) that adds studio presence and tames sibilance, so you sound clearer and more present while still sounding like *you*.
- **🎧 Clean Incoming / Guest** — de-noise the *other* side too. Route a noisy guest or caller through a loopback device and NoNoise Mac cleans **what you hear** in real time with the same on-device AI — no cloud, no subscription.
- **🫦 Mouth Noise** — an optional de-plosive (P-pop / B-thump suppressor) and de-click (lip-smack / mouth-click suppressor) stage (Off / Low / Medium / High). Both are identity at rest — only the artifact is removed, never the voice.
- **⌨️ Global Hotkeys + Stream Deck** — system-wide hotkeys (user-configurable) for every
  control action (toggle AI, A/B bypass, cycle preset, cycle Broadcast Voice, nudge gain), plus
  a `nonoisemac://` URL scheme for Stream Deck "Open" actions or shell scripting.
- **📊 Live HUD & loudness** — see your input/output levels, a clip warning, an "AI working hard" signal, and added latency at a glance; an ITU-R BS.1770 LUFS meter with optional one-tap loudness normalization (−14 / −16 LUFS) keeps you consistent across calls and recordings.
- **🛠️ Works everywhere** — any input (Built-in, USB, XLR via interface) → any app via a virtual cable.
- **🟢 On by default** — launches actively cancelling noise; toggle from the menu bar anytime.
- **💸 Free & open source** — MIT licensed.

## 🧩 Modes

| Mode | Best for | Suppression | Voice Polish |
|---|---|---|---|
| **Meeting** | Calls / max noise removal | Full | Off (raw, uncolored) |
| **Podcast** | Warm, natural voice | Full, natural floor | On (warm) |
| **Tutorial** | Screen recordings | Full | On (clear/present) |
| **Custom** | Your own balance | Your `Strength` + `Reduction Limit` | On (balanced) |

Your selection (and any fine-tuning) is remembered between launches.

Tutorial is tuned to sound clean and present for screen recordings; it does **not** add
output gain by default. If your mic is quiet, raise **Output Gain** manually.

### 🎙️ Broadcast Voice

An optional clarity enhancement layered on top of any mode. It pairs a gentle, wide presence lift with an automatic de-esser, so added "air" never becomes harsh sibilance. **Off** by default; **Low / Medium / High** increase the effect. It is designed to be transparent — a peaking bell with unity gain at the low end and a de-esser that only acts on real "ess" sounds — so it preserves the identity of your voice.

### 🫦 Mouth Noise

Two targeted artifact suppressors that live after the de-esser in the chain:

- **De-plosive**: detects P-pop / B-thump transients by watching the ratio of low-band energy (< 120 Hz) to total energy. Only subtractively ducks the low band when both the energy level and the low-heavy ratio exceed their thresholds — so normal voiced stops (B, D, G) pass through untouched.
- **De-click**: tracks a fast envelope vs. a slow background RMS. When the fast/slow ratio spikes beyond `clickRatio` (6×), a brief (4 ms) gain reduction is applied. Normal speech never sustains this ratio.

Both stages are **Off by default** and are **identity at rest** — verified by XCTest. They are orthogonal to Broadcast Voice and the noise preset.

### ⌨️ Global Hotkeys + Stream Deck

**Global hotkeys** (default combos use ⌃⌥ to avoid system-shortcut collisions):

| Action | Default |
|---|---|
| Toggle Noise Cancellation | ⌃⌥N |
| A/B Bypass (hold for raw) | ⌃⌥B |
| A/B Bypass (toggle) | ⌃⌥⇧B |
| Preset → Next | ⌃⌥] |
| Preset → Previous | ⌃⌥[ |
| Broadcast Voice → Next | ⌃⌥C |
| Gain + | ⌃⌥= |
| Gain − | ⌃⌥- |

Rebind any hotkey in **Settings → Hotkeys**. If a combo is already in use by another app,
NoNoise Mac shows a conflict warning and leaves that slot unregistered.

**Stream Deck (no SDK required):** Use the Stream Deck "Open" action (or "Website" in Open
mode) with one of these URLs:

```
nonoisemac://toggle
nonoisemac://bypass
nonoisemac://preset/next
nonoisemac://preset/prev
nonoisemac://clarity/next
nonoisemac://gain/up
nonoisemac://gain/down
```

Or from a terminal / shell script: `open nonoisemac://toggle` (or `NoNoiseMacCLI --action toggle`).

**A/B Bypass:** Hold ⌃⌥B to momentarily hear the raw mic (useful for comparing before/after
during a recording). Release to restore AI. ⌃⌥⇧B toggles bypass on/off persistently.

## 📥 Install

### Easiest — download the installer (no Xcode, no Terminal)

Best for most people. One download, one double-click, done.

1. Grab **`NoNoiseMac.pkg`** from the [Releases page](https://github.com/ivalsaraj/NoNoise-Mac/releases).
2. Double-click it. It isn't notarized yet, so macOS first calls it an *"unidentified developer"* —
   open **System Settings → Privacy & Security**, click **Open Anyway**, then run the installer.
   (One-time approval.)
3. The installer puts **NoNoise Mac** in **Applications** *and* installs the **NoNoise Mic** virtual
   microphone in one step. All audio drops for ~3 s while the audio system restarts — that's expected.

Now skip to [Usage](#-usage) and point your apps at **NoNoise Mic**. No `git`, no build tools — those
aren't preinstalled on macOS, and you don't need them for this path.

> Prefer the pieces separately? The same release also ships `NoNoiseMac.app.zip` (unzip → drag to
> **Applications**) and `NoNoiseMic.driver.zip`. The `.pkg` just installs both for you.

### Build from source (developers)

**Prerequisites:** macOS 13+, Apple Silicon, and the Swift toolchain (Xcode or
[Swift.org](https://www.swift.org/install/macos/)). Note: `git` and the Swift toolchain are **not**
preinstalled on macOS — this path is for contributors; everyone else should use the installer above.

```bash
git clone https://github.com/ivalsaraj/NoNoise-Mac.git
cd NoNoise-Mac
./install-app.sh --with-driver   # arm64 release build → /Applications, stages the driver
sudo ./install-driver.sh         # install the NoNoise Mic driver (restarts coreaudiod)
```

`install-app.sh` runs `swift build -c release --arch arm64`, bundles/signs the app, and installs it
to **Applications**; `--with-driver` also builds the virtual mic so `install-driver.sh` can install it.
First app launch: **right-click → Open** (ad-hoc signed); if macOS blocks it, **System Settings →
Privacy & Security → Open Anyway**. Build the `.pkg` yourself with `./build-pkg.sh`.

> Each tagged release (cut with `./release.sh`) publishes the Apple Silicon build — app, CLI, driver,
> and the one-click `.pkg` — to the [Releases page](https://github.com/ivalsaraj/NoNoise-Mac/releases). ⭐ the repo to get notified.

### Publishing a versioned release

To publish a new version (e.g., `1.2.0`), run:

```bash
./release.sh 1.2.0
```

This script:
1. Updates the version in `Resources/Info.plist`
2. Commits the version bump
3. Creates a `v1.2.0` git tag
4. Pushes to GitHub, which triggers the release workflow

The workflow then builds optimized arm64 binaries and publishes assets (app, CLI, driver, checksums) to the [Releases page](https://github.com/ivalsaraj/NoNoise-Mac/releases).

**Version format:** Use semantic versioning (`major.minor.patch`, e.g., `1.2.0`, `1.2.1`, `2.0.0`).

## 🚀 Usage

### NoNoise Mic (virtual microphone) — recommended

The bundled **NoNoise Mic** driver lets any app pick the cleaned audio directly — no BlackHole, no
system-default juggling. **Installed the `.pkg`? The driver is already set up — skip to step 1.**

Building from source instead? Install the driver once:

```bash
./build-driver.sh          # compile + ad-hoc sign NoNoiseMic.driver
sudo ./install-driver.sh   # install to /Library/Audio/Plug-Ins/HAL, restart coreaudiod, verify
```

Installing restarts `coreaudiod`, so **all** audio drops for ~3 s. Then:

1. **Launch** NoNoise Mac — the **NoNoise logo** appears in your menu bar.
2. **Input** — set **Input Device** to your real microphone (Built-in, USB, etc.). Output is
   **automatic**: the app routes cleaned audio to the hidden "NoNoise Mic Engine" and the popover
   shows **Output: Automatic → NoNoise Mic** (the Output **picker** only appears for the BlackHole
   fallback below).
3. **Point your apps at the mic** — in Slack / Zoom / Meet / Discord / OBS, set the
   **Microphone** to **NoNoise Mic**.
4. **Pick a mode** — Meeting / Podcast / Tutorial, or fine-tune **Suppression Strength** and
   **Reduction Limit** in Settings (this switches the mode to **Custom**).
5. Noise cancellation is **ON by default**. Toggle it anytime from the menu bar. Remove the
   driver later with `sudo ./uninstall-driver.sh`.

> **Gatekeeper and driver-load are different checks.** The *app* is ad-hoc signed (right-click →
> Open on first launch). The *driver* is loaded by `coreaudiod`, which **silently ignores** a
> plug-in with an invalid signature — `install-driver.sh` verifies the device actually appeared.

### Fallback: BlackHole virtual cable

If you can't install the driver (e.g. a managed Mac), NoNoise Mac also works with a
**[BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole)** virtual cable:

1. **Launch** — find the **NoNoise logo** in your menu bar.
2. **Input** — set **Input Device** to your real microphone (Built-in, USB, etc.).
3. **Output** — set **Output Device** to **BlackHole 2ch** (the virtual cable).
4. **Point your apps at the cable** — in Discord / Zoom / OBS, set the **Microphone** to
   **BlackHole 2ch**.
5. **Pick a mode** and toggle as above — noise cancellation is **ON by default**.

### 🎧 Clean Incoming / Guest (hear them clean)

NoNoise Mac can also clean the **other** side of a call — a guest on a noisy laptop mic, or a
caller with a fan running — so **you** hear them de-noised in real time.

macOS has no built-in per-app audio loopback, so you route the call app's **output** into a
loopback device first, then NoNoise Mac captures and cleans it:

1. Install **[BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole)** (or Loopback).
2. In your call app (Zoom / Meet / Discord), set the **speaker / output** to **BlackHole 2ch**.
3. In NoNoise Mac **Settings → Clean Incoming / Guest**, enable it, pick **BlackHole** as
   *Incoming from* and your real **speakers / headphones** as *Hear on*.

NoNoise Mac re-plays the **cleaned** guest audio to your chosen output, so you still hear the
call — just de-noised. It runs a **second** on-device AI stream and is **off by default** (that
stream only runs while enabled). For raw monitoring alongside the cleaned feed, point the call app
at a macOS **Multi-Output Device** that includes both the loopback and your speakers.

## Updating

NoNoise Mac updates itself with [Sparkle](https://sparkle-project.org). It checks for new
**stable** releases on launch and daily; when one is available you'll get a native
"A new version is available" prompt, or use **Check for Updates…** in the popover.

**First install only:** the updater ships starting with the first Sparkle-enabled release.
If you're on an older build, download that first release manually (right-click → Open, since the
app is ad-hoc signed). After that, updates are automatic.

## 💻 Advanced: dual pipelines (CLI)

Want to clean your **outgoing mic** *and* clean **incoming** audio from your headphones at the
same time? Use the bundled `NoNoiseMacCLI`. Device names match those shown in the menu-bar app's
**Input/Output** pickers (and macOS **System Settings → Sound**); the CLI also echoes the
input/output devices it detects on launch.

```bash
# Show usage and available flags
./NoNoiseMacCLI --help

# Terminal 1 — clean your microphone into the virtual cable
./NoNoiseMacCLI --in "Built-in Microphone" --out "BlackHole 2ch" --gain 1.0

# Terminal 2 — clean a captured meeting stream into your speakers
./NoNoiseMacCLI --in "Loopback Audio" --out "MacBook Pro Speakers" --gain 1.5
```

### Offline audio file cleanup

Clean an audio file locally:

```bash
./NoNoiseMacCLI --denoise noisy.wav --output clean.wav --preset podcast --overwrite
```

This v1 file mode writes a cleaned audio file. Video containers such as MP4 are planned separately so the CLI can preserve the original video track correctly.

## 🔬 How it works

```
Microphone ─▶ Capture (48 kHz) ─▶ Ring buffer ─▶ STFT
                                                   │
                            DeepFilterNet3 (CoreML, Neural Engine)
                                                   │
                                ISTFT ─▶ Voice shaping (polish · Broadcast Voice · Mouth Noise)
                                                   │
                                             Virtual cable ─▶ your app
```

- **DeepFilterNet3** runs as a streaming UNet on CoreML (`computeUnits = .all`).
- A faithful STFT feature pipeline (ERB bands, complex-spec features) matches the reference
  model exactly — see [`AGENTS.md`](AGENTS.md) and [`CONCEPTS.md`](CONCEPTS.md).
- An optional **Voice Polish** chain (high-pass → shelves → compressor → limiter) adds tone
  and leveling for Podcast/Tutorial modes.
- Optional **Broadcast Voice** (presence → de-esser) and **Mouth Noise** (de-plosive → de-click)
  finisher stages layer on any mode — each Off by default and identity-at-rest.

## 🔒 Privacy

NoNoise Mac is **100% on-device**. Audio is captured, processed by the local CoreML model,
and routed out — it is never sent off your Mac. There is no telemetry and no account.

## 🧰 Tech stack

- **App:** Swift 5.9, SwiftUI (menu-bar `MenuBarExtra`)
- **Audio:** AVFoundation, CoreAudio, AudioToolbox, Accelerate (vDSP)
- **AI:** CoreML + Metal, model `computeUnits = .all`
- **Model:** [DeepFilterNet3](https://github.com/Rikorose/DeepFilterNet) (streaming UNet)
- **Packaging:** Swift Package Manager + `bundle.sh` / `install-app.sh`

## 🤖 Contributing & AI-native

This repo is built to be worked on by **humans and AI agents** alike:

- [`AGENTS.md`](AGENTS.md) — architecture, build/test, and the non-negotiable DSP / real-time invariants.
- [`docs/agents/README.md`](docs/agents/README.md) — the **agent store**: a catalog of agents to invoke for DSP review, CoreML I/O auditing, releases, and more.
- [`docs/knowledge/`](docs/knowledge/INDEX.md) — compounding knowledge base (gotchas, decisions, timeline).
- [`CONCEPTS.md`](CONCEPTS.md) — domain glossary · [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to contribute.

PRs welcome. Keep the default audio path behavior-preserving and the render thread allocation-free.

## 🙏 Credits & acknowledgements

- **Original project — [MetalVoice](https://github.com/Ghostkwebb/MetalVoice) by [Ghostkwebb](https://github.com/Ghostkwebb).** NoNoise Mac is a rebrand + AI-native restructuring of MetalVoice, used under the MIT License. Huge thanks for the original implementation and the CoreML DeepFilterNet integration.
- **[DeepFilterNet](https://github.com/Rikorose/DeepFilterNet)** by [Hendrik Schröter (Rikorose)](https://github.com/Rikorose) — the speech-enhancement model at the core of this app.
- **[BlackHole](https://github.com/ExistentialAudio/BlackHole)** by Existential Audio — the recommended virtual audio cable.
- **SF Symbols** by Apple — UI iconography.

## 📄 License

[MIT](LICENSE) © Ghostkwebb (original MetalVoice) · ivalsaraj (NoNoise Mac)

---

<div align="center">
  <sub>Built for macOS, on-device, with ❤️ — NoNoise Mac</sub>
</div>
