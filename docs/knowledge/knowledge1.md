# Knowledge Log

`[GOTCHA]` / `[DECISION]` / `[PATTERN]` entries. Newest on top. See `critical-patterns.md`
for the must-read failure modes.

---

### [GOTCHA] 2026-06-15 — Loopback ring replays stale speech unless reads are window-guarded (privacy)
- **Symptom (caught in Codex code review):** a modulo ring (`nn_ring_read_at` reading `storage[pos & mask]`)
  keeps returning the LAST ~1.3 s of cleaned audio after the writer stops — because the mic-read device
  and the engine-write device are SEPARATE objects with separate `StartIO`/`StopIO`. App quits / toggles
  off → engine stops writing, but Slack still captures "NoNoise Mic" → it hears a loop of your last words.
- **Root cause:** modulo indexing has no notion of "this frame was never written" — old slot contents alias
  back. Two-device topology makes the writer-stops-while-reader-runs case routine, not exotic.
- **Fix/Rule:** the ring tracks a `writeEnd` watermark (publish release after the slot writes, read acquire
  before). `nn_ring_read_at` zeroes any frame `>= writeEnd` (unwritten) or `< writeEnd - capacity`
  (overwritten). Reads outside the valid window are SILENCE. Host tests assert read-before-write,
  writer-stopped, and partial-straddle silence. Same rule for the `sourceMode==1` mic branch (A2 stub):
  `memset` silence, never serve whatever's lying around.
- **Files:** `Driver/NoNoiseMic/nn_ring.{c,h}`, `Driver/tests/test_nn_ring.c`, `Driver/NoNoiseMic/NoNoiseMic.c`.

### [GOTCHA] 2026-06-15 — HAL driver must size-check every `GetPropertyData` write & validate the FULL ASBD
- **Symptom (Codex review):** scalar/CFString property branches wrote `*(UInt32*)outData = …` /
  `*(CFStringRef*)outData = …` with no `inDataSize` check, and the stream format setter accepted a format
  on rate/id/channels/bits alone — ignoring `mFormatFlags`/`mBytesPerFrame`.
- **Root cause:** a short caller buffer corrupts `coreaudiod`'s heap; a partial ASBD check lets a client
  negotiate a NON-interleaved/repacked layout that `DoIOOperation` (packed-interleaved-only) then
  silently corrupts or channel-swaps. Apple's NullAudio guards every branch for exactly this reason.
- **Fix/Rule:** `PUT_SCALAR`/`PUT_CFSTRING` macros return `kAudioHardwareBadPropertySizeError` before any
  write; the format setter compares the FULL canonical `MakeASBD()` (flags + bytes/frame + bytes/packet +
  frames/packet too) and rejects anything else with `kAudioHardwareIllegalOperationError`.
- **Files:** `Driver/NoNoiseMic/NoNoiseMic.c` (`NoNoiseMic_GetPropertyData`, `NoNoiseMic_SetPropertyData`).

### [DECISION] 2026-06-15 — NoNoise Mic driver: two-device loopback topology, one canonical layout
- **Topology:** a VISIBLE input-only device + a HIDDEN output-only "engine" device (NOT one duplex
  device). The app renders cleaned audio to the engine; consumer apps pick the visible mic. Both
  share ONE `nn_ring` + a per-device `nn_clock` anchored to a SINGLE host time captured on the first
  `StartIO`, so the engine write axis and the mic read axis coincide.
- **One canonical layout everywhere:** 48 kHz, 2ch, **interleaved** Float32 (`kAudioFormatFlagIsFloat
  | kAudioFormatFlagIsPacked`). The HAL's `ioMainBuffer` is passed straight into `nn_ring`
  (`channels=2`) — no de/interleave at any layer. `test_stereo_channels_preserved` guards L/R order
  across a wrap.
- **Phasing:** A1 = in-driver loopback (`sourceMode 0`, default, shipped); A2 = XPC + shared memory
  (`sourceMode 1`) gated behind a coreaudiod-reachability spike. Cross-ref the silent-non-load
  GOTCHA below.
- **Why two devices, not duplex:** keeps the visible mic free of any output stream (clean picker
  semantics) and the engine hidden + non-default-eligible. Full contract in `AGENTS.md` → driver section.

### [GOTCHA] 2026-06-15 — AudioServerPlugIn silently fails to load (signature / CFPlugIn keys)
- **Symptom:** `NoNoiseMic.driver` installed to `/Library/Audio/Plug-Ins/HAL` but "NoNoise Mic"
  never appears as a device — and `coreaudiod` logs nothing obvious.
- **Root cause:** `coreaudiod` **silently ignores** a HAL plug-in whose code signature is invalid
  or whose `Info.plist` `CFPlugInFactories` / `CFPlugInTypes` keys are wrong (the type UUID must be
  `443ABAB8-E7B3-491A-B985-BEB9187030DB` and the factory string must match the exported
  `NoNoiseMic_Create` symbol). Editing the bundle **after** `codesign` also invalidates the
  signature → silent non-load.
- **Fix/Rule:** `build-driver.sh` signs **after** full assembly; `install-driver.sh` verifies via
  `system_profiler SPAudioDataType | grep "NoNoise Mic"` and the app re-confirms by translating the
  visible UID (`kAudioHardwarePropertyTranslateUIDToDevice`). Never edit a signed `.driver`; rebuild.
- **Files:** `Driver/NoNoiseMic/NoNoiseMic.c`, `Driver/NoNoiseMic/Info.plist`, `build-driver.sh`,
  `install-driver.sh`.

### [GOTCHA] 2026-06-15 — `allow-jit` entitlement is required for CoreML/Metal
- `Resources/NoNoiseMac.entitlements` carries two keys: `com.apple.security.device.audio-input`
  (mic) and `com.apple.security.cs.allow-jit`. The latter is needed because DeepFilterNet3 runs on
  GPU/ANE and Metal shader compilation JITs under the hardened runtime — removing it can break
  inference at runtime. It was inherited from the original app (kept byte-identical); justification
  now lives in `AGENTS.md` → Entitlements & signing. Do not strip it without on-device verification.

### [DECISION] 2026-06-15 — Docs must match the real CLI contract
- `NoNoiseMacCLI` with no `--in`/`--out` prints an error and exits 1; `--help` exits 0; device names
  are echoed only after a valid launch (`Sources/CLI/main.swift:21-23,30-34,42,51`). README must
  describe this exactly — a marketing page that advertises a non-existent mode erodes first-release
  trust. Caught by the pre-publish Codex code review.

### [DECISION] 2026-06-15 — AI noise cancellation defaults ON
- `AudioModel.isAIEnabled` defaults to `true` so suppression is active on first launch
  (product decision for NoNoise Mac). The Meeting preset remains the default profile.
- Implication: the model is exercised immediately; keep the CoreML init path healthy.

### [DECISION] 2026-06-15 — Rebrand to NoNoise Mac; internal `mv.*` keys kept
- Renamed display/identifier/bundle to NoNoise Mac / `NoNoiseMac` / `com.ivalsaraj.NoNoiseMac`.
- `UserDefaults` keys intentionally **kept** in the legacy `mv.*` namespace — invisible to
  users, renaming would only add migration risk. See `AGENTS.md` → Branding conventions.

### [GOTCHA] CoreML Float16 outputs read back as zeros on ANE/GPU
- See `critical-patterns.md`. Read model outputs via `NSNumber`, not raw Float16 buffers.

### [GOTCHA] Inventing a spectral compression exponent muffles speech
- Stock DeepFilterNet has none; do not add `c=0.5/0.6` or de-normalize the output.

### [PATTERN] Keep DSP math in pure, testable statics
- `minGain(forAttenuationDb:)`, `resolveOutputBin(...)`, and the `VoiceChain` value types
  (`Biquad`/`Compressor`/`Limiter`) are unit-tested without CoreML. New DSP math should
  follow the same shape (30 tests currently cover this).
