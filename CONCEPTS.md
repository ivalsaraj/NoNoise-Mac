# Concepts — NoNoise Mac domain vocabulary

Shared language for humans and agents. Use these terms consistently in code, commits,
docs, and reviews.

## Product
- **NoNoise Mac** — the macOS menu-bar app (this project). Identifier `NoNoiseMac`.
- **Passthrough** — AI off: input is routed to output unprocessed (gain only).
- **Preset / Mode** — a named bundle of suppression + polish settings: `Meeting`,
  `Podcast`, `Tutorial`, `Custom`. Source of truth: `VoicePreset`.
- **Virtual cable** — a loopback audio device (e.g. BlackHole 2ch) used as NoNoise Mac's
  output so other apps can select it as their input.

## Signal pipeline
- **Capture → Ring buffer → Render callback → DSP → Voice polish → Output.**
- **Ring buffer** — lock-light FIFO decoupling capture from the render thread
  (`RingBuffer`); spectral feature history uses `SpecHistoryRingBuffer`.
- **Render thread** — the real-time AVAudioEngine callback. Allocation-free; scalar/vDSP
  math only. See `AGENTS.md` → Real-time audio rules.

## Incoming / guest cleanup
- **Incoming / guest cleanup** — the mirror of mic cleaning: capture the call app's
  output from a loopback/aggregate **INPUT** device, clean it with a SECOND DeepFilterNet
  stream (`IncomingCleanupEngine`), and play it to the user's speakers (Phase 1) and/or a
  second virtual sink for recording (Phase 2). Independent of the outgoing mic — its own
  capture session, engine, ring buffer, and DSP state.
- **Loopback source** — a device (BlackHole / Loopback / aggregate) the user points the call
  app's speaker at, so its audio becomes a capturable **INPUT**. macOS has no built-in app
  loopback, so this routing step is required.
- **Monitor output** — the real speakers / headphones the cleaned guest audio is played to.

## DSP / DeepFilterNet
- **DeepFilterNet3 (DFN)** — the noise-suppression neural model (stock), run via CoreML on
  the Neural Engine/GPU (`computeUnits = .all`).
- **STFT / ISTFT** — short-time Fourier transform and its inverse. fft 960, hop 480,
  481 bins.
- **wnorm** — analysis window normalization `1/960`. The model's input/output spectra live
  in this scale; never blend across scales or de-normalize the output.
- **OLA (overlap-add)** — synthesis reconstruction; the Vorbis window gives unity OLA
  (Princen–Bradley).
- **ERB bands** — 32 perceptual frequency bands partitioning the 481 bins; a DFN input
  feature (`feat_erb`).
- **feat_spec** — first 96 unit-normed complex bins; a DFN input feature.
- **Hidden state** — recurrent model state (`h_enc/h_erb/h_df`) carried across hops.

## Suppression controls
- **Suppression Strength** — wet/dry mix `0…1` (`DeepFilterNetDSP.suppressionStrength`).
- **Reduction Limit (attenuation limit, dB)** — caps how far a bin may be reduced so the
  voice keeps natural tone; `>= maxAttenuationDb` means unlimited.
- **minGain / resolveOutputBin** — pure, unit-tested helpers implementing the blend math.

## Voice polish (Tier 2)
- **Voice Polish / VoiceChain** — post-DSP shaping: high-pass → low-shelf → high-shelf →
  compressor → limiter. Off in Meeting; on in Podcast/Tutorial/Custom.
- **Clarity / Broadcast Voice** — an optional, mode-independent enhancement
  (`ClarityLevel`: off/low/medium/high) layered on the voice chain. Couples a
  **presence** lift with a **de-esser** so "crisp" never becomes harsh.
- **Presence** — a wide-Q peaking biquad (~4.5 kHz) that lifts intelligibility.
  Unity gain at DC/Nyquist, so the vocal body/identity is untouched.
- **De-esser** — a subtractive split-band sibilance controller
  (`out = x − frac·sib`). Identity at rest; only acts on loud sibilant transients.
- **Mouth Noise Finishers** — two identity-at-rest DSP stages after the de-esser:
  - **De-plosive** (`DePlosive`): subtractive low-band gate. `out = x − frac·lowSig`
    when the low-band ratio and total energy both exceed thresholds. Identity otherwise.
  - **De-click** (`DeClick`): broadband transient gate. `out = x × gain` where
    `gain < 1` only during brief (< 5 ms) fast/slow envelope ratio spikes. Identity otherwise.
  - Controlled by `MouthNoiseLevel` (off/low/medium/high); persisted under `mv.mouthNoise`.
- **Biquad** — RBJ-cookbook second-order IIR filter (TDF-II).
- **Compressor** — log-domain feed-forward dynamics (threshold/ratio/attack/release/makeup).
- **Limiter** — fast peak limiter + hard clamp; the final overflow guard (ceiling dB).

## Metering & loudness (Tier 2)
- **Telemetry** — lock-free scalars written on the render/DSP threads and consumed by the
  always-on ~25 Hz **control pump** (`AudioModel.runControlPump`, which also runs Smart Level
  + loudness normalization) — the suppression-knob atomic-scalar pattern, reversed; no locks.
  The pump writes a plain `MeterSnapshot`; a **separate, popover-gated** UI timer copies that
  snapshot into the `@Published` fields on `MeterModel` only while a meter view is on screen,
  so `AudioModel` no longer republishes at 25 Hz. The `LoudnessMeter` struct is mutated only on
  the render thread and snapshotted into scalars (`tMomentaryLUFS` / `tIntegratedLUFS`) — it is
  never read cross-thread.
- **AI activity** — a smoothed 0…1 "AI working hard" signal = energy-weighted average
  per-bin suppression (`1 − wetMag/dryMag`) from the DSP blend. A UX hint, not a model
  quality metric; reads 0 when noise cancellation is off.
- **LUFS (`LoudnessMeter`)** — real ITU-R BS.1770 K-weighted loudness (the standard's
  published 48 kHz two-stage filter, not an approximation). Momentary (400 ms) is the
  live needle; integrated is gated (absolute −70 LUFS + relative −10 LU) using a
  fixed-size block ring (no unbounded history, no render-path allocation).
- **Loudness normalization** — optional slew-limited make-up gain toward a target
  (−14 / −16 LUFS), applied pre-limiter in the voice chain; OFF by default. Works even
  with polish/clarity off (the chain activates for `loudnessActive` so the limiter runs).
- **Peak / clip** — v1 tracks **sample-peak** + an output-clip warning (reuses the
  Smart Level output-clip signal), NOT oversampled true-peak; the normalization ceiling
  is the voice-chain limiter (≈ −1 dBFS; −0.5 in Tutorial), not certified dBTP.
- **Output telemetry runs whenever audio flows** (like Smart Level's), so the output
  meter/LUFS are live in passthrough too; AI activity is the only AI-gated readout.
