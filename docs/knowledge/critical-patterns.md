# Critical Patterns — read before touching audio code

These are **shipped-and-broke** failure modes. Each cost real debugging time. Treat them as
hard rules; the full rationale is in `AGENTS.md`.

## [PATTERN] CoreML output arrays MUST be read via `NSNumber`, never raw Float16 pointers
- **Where:** `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift` (the model-call boundary).
- **Symptom:** App produces **no audio** when AI is enabled (silent output).
- **Root cause:** The model runs `computeUnits = .all` (ANE/GPU). Reading its Float16
  output `MLMultiArray`s with `withUnsafeBufferPointer(ofType: Float16.self)` reads back
  **zeros** (the buffer isn't CPU-materialized).
- **Rule:** Read model **outputs** via the `NSNumber` subscript
  (`enhanced[[...] as [NSNumber]].floatValue`). Buffer pointers are only safe for **input**
  arrays we allocate and fill ourselves.

## [PATTERN] No spectral compression exponent; do not de-normalize the output
- **Where:** DFN feature pipeline + ISTFT in `DeepFilterNetDSP`.
- **Symptom:** Muffled, dull voice; attenuated highs.
- **Root cause:** A prior reimplementation invented a compression exponent (`c=0.5/0.6`) and
  de-normalized the enhanced spectrum. Stock DeepFilterNet does neither.
- **Rule:** Feed `spec` raw (`wnorm·FFT(window·x)`, `wnorm=1/960`); ISTFT the enhanced spec
  directly in the same scale. No compression, no output de-normalization.

## [PATTERN] The render thread is allocation-free
- **Where:** `processHop` / render callback (`DeepFilterNetDSP`, `AudioModel`, `VoiceChain`).
- **Symptom:** Audio glitches / dropouts under load.
- **Root cause:** Heap allocation (incl. Swift Array COW on first mutation through a local
  binding) on the real-time thread.
- **Rule:** Pre-allocate all scratch + input `MLMultiArray`s in `init()` and mutate the
  stored properties **directly**. Feature history uses `SpecHistoryRingBuffer`, never
  `Array.removeFirst`. Coefficient recompute (`VoiceChain.configure`) happens on main only.

## [PATTERN] Suppression knobs are lock-free scalars (arm64)
- **Where:** `DeepFilterNetDSP.suppressionStrength` / `attenuationLimitDb` / `outputGain`.
- **Rule:** Plain `var Float`, written from main, read on the render thread. 32-bit aligned
  scalar load/store is atomic on arm64 — **do not add locks**. Keep blend math in the pure
  static helpers (`minGain`, `resolveOutputBin`) so it stays unit-testable without CoreML.

## [PATTERN] Never bind the MenuBarExtra label / whole popover to a high-frequency `@Published` stream
- **Source:** `docs/knowledge/knowledge1.md`, 2026-06-15.
- **Where:** `AudioModel` meter fields, the `MenuBarExtra` label (`NoNoiseMacApp.swift`), `ContentView`,
  `MeterModel.swift`, `NoNoiseLogoMark.swift`.
- **Symptom:** Slow menu-bar popover open + laggy AI toggle — no crash, no log, just sluggishness
  (easy to misattribute to the toggle handler).
- ❌ **WRONG:** Put ~25 Hz live-meter fields as `@Published` on `AudioModel`, which the `MenuBarExtra`
  label and the whole `ContentView` observe. Every tick fires `objectWillChange`, re-evaluating the
  Scene (re-rendering the status `NSImage` via `lockFocus` even while CLOSED) and re-diffing the
  popover → main-thread saturation.
- ✅ **CORRECT:** Keep high-frequency fields on a dedicated `MeterModel: ObservableObject` observed
  ONLY by leaf meter subviews. Drive it from an always-on, NON-publishing main-thread control pump
  (the single `t*` owner; runs Smart Level + loudness) plus a popover-gated, snapshot-read-only UI
  publish timer. Never `lockFocus`/disk-read inside a SwiftUI `body`; cache static images as `static let`.
- **Why:** `objectWillChange` on an app-wide model fans out to EVERY observer, including the
  always-mounted Scene/label; at 25 Hz that starves the run loop and the failure is silent (perf, not correctness).

## [PATTERN] Transient suppressors gate on a TIME-LOCAL change, never a steady band-ratio
- **Source:** `docs/knowledge/knowledge1.md`, 2026-06-15 ([CORRECTION]).
- **Where:** `Sources/Core/AudioProcessing/Dynamics.swift` (`DePlosive`, `DeClick`).
- **Symptom:** Mouth Noise on → voiced speech muffled on the highs + faint distortion (subtle, easy
  to misread as the AI denoiser).
- ❌ **WRONG:** Flag a plosive when `lowEnv/totalEnv ≥ guard` (a steady low/total ratio). Voiced
  vowels are low-dominant too, so this fires on ~all speech and ducks the low-mids continuously; the
  subtractive `x − frac·(x − hp(x))` then re-injects a phase-shifted high-passed copy → intermodulation.
- ✅ **CORRECT:** Gate on a TIME-LOCAL transient — a surge (`fastLow/slowLow`) for the de-plosive and
  an instant-attack peak vs slow background for the de-click — AND a spectral signature (low-band
  concentration). Steady voicing has surge ≈ 1, so it never gates. Duck a CLEAN low-pass band, not `x − hp(x)`.
- **Why:** Voiced speech and these artifacts share frequency bands; only their TIME behavior differs.
  A steady-state band test cannot separate them and silently degrades every voiced frame.
