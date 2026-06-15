# Timeline

Chronological log of notable changes. Newest on top.

### 2026-06-15 — Apple Silicon install script
- Added `install-app.sh`, a one-command local installer that runs `swift build -c release --arch arm64`,
  bundles/signs `NoNoiseMac.app`, installs it to `/Applications`, verifies the copied app signature,
  and optionally stages `NoNoiseMic.driver` via `--with-driver`.
- Documented the release-build rule in `AGENTS.md`: local installs MUST use the optimized arm64
  release path because NoNoise Mac is Apple-Silicon-only.

### 2026-06-15 — Tier 3 / Spec A Phase A1: NoNoise Mic virtual microphone driver
- Shipped a userspace CoreAudio **AudioServerPlugIn** (`Driver/NoNoiseMic/`) publishing a visible
  input-only **NoNoise Mic** + a hidden output-only **NoNoise Mic Engine** (48 kHz, 2ch,
  interleaved Float32). Apps select "NoNoise Mic" directly — no BlackHole, no default juggling.
- **Transport:** Phase A1 in-driver **loopback** (`sourceMode = 0`); A2 (XPC + shared memory,
  `sourceMode = 1`) is gated behind a coreaudiod-reachability spike (plan Task 12).
- **Risky math is CoreAudio-free + host-tested:** `nn_ring` (sample-time wraparound, interleaved
  L/R) and `nn_clock` (O(1) monotonic zero-timestamp) → `Driver/tests/run-tests.sh`, also wired
  into CI alongside a driver compile+sign check.
- **App wiring:** `AudioModel.fetchOutputDevices` auto-routes the engine output by **real UID**
  (`VirtualMicRouting.preferredOutputUID`: engine → BlackHole → else unset), detects install via
  `kAudioHardwarePropertyTranslateUIDToDevice`, and filters hidden/virtual devices from its
  pickers; `ContentView` shows a "NoNoise Mic ready / not installed" row; Settings guide + README
  rewritten to the new routing model (BlackHole demoted to fallback).
- **Contract/decisions** live in `AGENTS.md` → "NoNoise Mic virtual driver"; the silent-non-load
  trap is in `knowledge1.md`. Original MIT implementation — not Apple sample source, not derived
  from BlackHole (GPL-3.0).
- **Plan + review:** `docs/plans/2026-06-15-nonoise-mic-virtual-driver-plan.md` (Codex plan review
  APPROVED, 3 rounds). On-device install/verify (sudo + coreaudiod restart) is the user's manual gate.

### 2026-06-15 — NoNoise Mac v1.0.0 (initial public release)
- Rebranded the project from **MetalVoice** (by Ghostkwebb,
  https://github.com/Ghostkwebb/MetalVoice, MIT) to **NoNoise Mac**: identifiers, bundle id
  `com.ivalsaraj.NoNoiseMac`, assets, CLI (`NoNoiseMacCLI`), and all UI strings.
- Made the repo **AI-native**: this knowledge base, `CONCEPTS.md`, the agent catalog
  (`docs/agents/README.md`), an expanded `AGENTS.md` (overview + ICP + architecture +
  branding conventions), and CI.
- **UI overhaul**: polished menu-bar popover (hero status card, live meter, sectioned
  cards) and Settings (branded header, consistent cards).
- **AI noise cancellation ON by default.**
- DSP/model/audio behavior unchanged. `swift build` + 30 tests green; `swift build -c release`
  + `./bundle.sh` produce a signed `NoNoiseMac.app` + `NoNoiseMacCLI`.
- **Pre-publish Codex code review** (gpt-5.5, 2 rounds → APPROVED): fixed the README CLI section
  to match real `NoNoiseMacCLI` behavior (documented `--help`; removed a non-existent no-arg
  "list devices" mode), and documented the two signing entitlements in `AGENTS.md`.

### Pre-rebrand (inherited from MetalVoice history)
- Voice Polish chain (Biquad/Compressor/Limiter + per-preset profiles + master toggle).
- Preset modes (Meeting/Podcast/Tutorial/Custom) + suppression-strength & reduction-limit knobs.
- DSP correctness fixes: read CoreML outputs via `NSNumber`; match DeepFilterNet feature
  pipeline (no invented compression); stride-aware spectrum reads.
