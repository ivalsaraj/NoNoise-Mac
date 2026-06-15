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
- **🛠️ Works everywhere** — any input (Built-in, USB, XLR via interface) → any app via a virtual cable.
- **🟢 On by default** — launches actively cancelling noise; toggle from the menu bar anytime.
- **💸 Free & open source** — MIT licensed.

## 🧩 Modes

| Mode | Best for | Suppression | Voice Polish |
|---|---|---|---|
| **Meeting** | Calls / max noise removal | Full | Off (raw, uncolored) |
| **Podcast** | Warm, natural voice | Full, natural floor | On (warm) |
| **Tutorial** | Screen recordings | Full + makeup gain | On (bright & loud) |
| **Custom** | Your own balance | Your `Strength` + `Reduction Limit` | On (balanced) |

Your selection (and any fine-tuning) is remembered between launches.

## 📥 Install

No notarized binary is shipped yet — building from source takes ~2 minutes on Apple Silicon.

**Prerequisites:** macOS 13+, Apple Silicon, and the Swift toolchain (Xcode or
[Swift.org](https://www.swift.org/install/macos/)).

```bash
git clone https://github.com/ivalsaraj/NoNoise-Mac.git
cd NoNoise-Mac
./install-app.sh            # optimized arm64 build → /Applications/NoNoiseMac.app
```

`install-app.sh` runs `swift build -c release --arch arm64`, bundles/signs the app, and installs it
to **Applications**. To build the app and stage the virtual mic driver in one pass:

```bash
./install-app.sh --with-driver
```

Then:

1. First launch: **right-click → Open** (it's ad-hoc signed). If macOS blocks it, go to
   **System Settings → Privacy & Security → Open Anyway**.
2. If you used `--with-driver`, install the staged driver with `sudo ./install-driver.sh`.

> Prebuilt releases will land on the [Releases page](https://github.com/ivalsaraj/NoNoise-Mac/releases) — ⭐ the repo to get notified.

Maintainers publish prebuilt assets by pushing a `v*` tag that points to a commit on `main`. The
release workflow uploads zipped `NoNoiseMac.app`, `NoNoiseMacCLI`, `NoNoiseMic.driver`, and checksums.

## 🚀 Usage

### NoNoise Mic (virtual microphone) — recommended

Build and install the bundled **NoNoise Mic** driver once, then any app can pick it directly —
no BlackHole, no system-default juggling.

```bash
./build-driver.sh          # compile + ad-hoc sign NoNoiseMic.driver
sudo ./install-driver.sh   # install to /Library/Audio/Plug-Ins/HAL, restart coreaudiod, verify
```

Installing restarts `coreaudiod`, so **all** audio drops for ~3 s. Then:

1. **Launch** NoNoise Mac — the **waveform icon** appears in your menu bar.
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

1. **Launch** — find the **waveform icon** in your menu bar.
2. **Input** — set **Input Device** to your real microphone (Built-in, USB, etc.).
3. **Output** — set **Output Device** to **BlackHole 2ch** (the virtual cable).
4. **Point your apps at the cable** — in Discord / Zoom / OBS, set the **Microphone** to
   **BlackHole 2ch**.
5. **Pick a mode** and toggle as above — noise cancellation is **ON by default**.

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

## 🔬 How it works

```
Microphone ─▶ Capture (48 kHz) ─▶ Ring buffer ─▶ STFT
                                                   │
                            DeepFilterNet3 (CoreML, Neural Engine)
                                                   │
                                ISTFT ─▶ Voice Polish (EQ · compressor · limiter)
                                                   │
                                             Virtual cable ─▶ your app
```

- **DeepFilterNet3** runs as a streaming UNet on CoreML (`computeUnits = .all`).
- A faithful STFT feature pipeline (ERB bands, complex-spec features) matches the reference
  model exactly — see [`AGENTS.md`](AGENTS.md) and [`CONCEPTS.md`](CONCEPTS.md).
- An optional **Voice Polish** chain (high-pass → shelves → compressor → limiter) adds tone
  and leveling for Podcast/Tutorial modes.

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
