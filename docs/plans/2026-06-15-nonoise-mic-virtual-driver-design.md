# NoNoise Mic — Virtual Microphone Driver (Tier 3, Spec A) — Design

**Status:** Design / brainstorm output (awaiting implementation-plan stage).
**Revision:** r2 — incorporates spec-review round 1 (feasibility + coherence). Changes vs r1: 48 kHz **stereo** device (was mono); hidden-device filtering on the app's *own* output picker; engine device barred from default selection; single shared host-clock + one internal loopback ring; exact CFPlugIn `Info.plist` keys + install-time verification; A2 reworked around a **launchd helper + FD-passed shared memory + atomic liveness header**; A2 app emits PCM via manual-render (no bound output device); ring/zero-timestamp math factored into host-testable C; pinned app↔driver contract constants; corrected BGM citation; auto-route fallback never targets a physical output.
**Scope:** Spec A only — the **NoNoise Mic** virtual input device + the app wiring that feeds it. Health-check dashboard, dual-pipeline GUI, and AEC are **Spec B** (out of scope here).

---

## Goal

Ship a virtual microphone named **"NoNoise Mic"** that appears directly in Slack / Zoom / Meet / OBS. The user selects it once as their mic; the always-running NoNoise Mac app captures the real microphone, runs DeepFilterNet (the existing pipeline), and feeds the **cleaned** audio into that device.

**The single biggest UX upgrade: no BlackHole *required*, no system-default juggling, no manual output routing.** (BlackHole is retained only as an optional fallback when the driver isn't installed — see auto-route priority.)

### Why this works (Krisp's mechanism, verified)
Krisp does exactly this on macOS (confirmed via Apple's CoreAudio docs, the Apple Developer Forums thread that names Krisp, and the BlackHole / Background Music open-source drivers):
- It installs an **AudioServerPlugIn** — a *userspace* CoreAudio HAL driver (`.driver` bundle in `/Library/Audio/Plug-Ins/HAL`, hosted by `coreaudiod`). **No kernel extension.**
- A **always-running companion app** captures the real mic, runs the noise model, and pushes cleaned audio into the virtual device (Krisp uses XPC for control + a stream/shared path for audio).
- Consumer apps just pick **"Krisp Microphone"** as input. It's "active on the fly" because the companion is always processing in the background.

NoNoise Mac already *is* that companion (capture → DeepFilterNet → output). Spec A adds the missing piece: our own virtual device that the app feeds, replacing the BlackHole dependency.

### Success criteria
1. `./install-driver.sh` → **"NoNoise Mic"** shows in **Audio MIDI Setup** and in Slack/Zoom/Meet/OBS input menus; the script **verifies** the device actually appeared and fails loudly otherwise.
2. With the app running + AI on, speaking into the real mic is heard **cleaned** by a consumer app (QuickTime New Audio Recording / Slack test call).
3. Toggling AI off passes audio through (passthrough); quitting the app stops the feed cleanly (consumer hears silence, not stale/garbage audio).
4. The app **auto-routes its engine output to "NoNoise Mic Engine"** (the hidden output device) on launch — the user never picks an output.
5. `./uninstall-driver.sh` removes the device cleanly after a `coreaudiod` restart.
6. `swift build && swift test` stays green; the driver compiles in CI **and the pure ring/timestamp C is host-unit-tested in CI**; the manual on-device checklist passes.

---

## Decisions locked during brainstorming

| Decision | Choice | Rationale |
|---|---|---|
| Scope/sequencing | **2 specs.** Spec A = driver (this doc); Spec B = health check + dual pipeline + AEC | Driver is a full sub-project; the others are incremental |
| Install & signing | **Ad-hoc signed `.driver` + install script** (`sudo cp` to HAL + `sudo killall coreaudiod`) | Keeps the repo's build-from-source, no-Apple-account ethos |
| Driver technology | **AudioServerPlugIn** (userspace HAL plugin) | DriverKit needs a paid account + Apple-granted entitlement; Apple says use AudioServerPlugIn for virtual-only devices |
| Transport | **Both** loopback (A1) **and** XPC input-only (A2), switchable via the `sourceMode` property; **XPC is the eventual default** | A1 reuses existing output code (low risk); A2 is the cleaner Krisp-exact UX |
| Build sequencing | **Phased:** ship A1 first (proven), then add A2 + the toggle, then flip the default to XPC after on-device validation | De-risks: new users don't hit the hardest code first |
| Code base | **Apple's AudioServerPlugIn sample (SimpleAudio / NullAudio)**, Apple Sample Code License | Permissive (MIT-ish), pure C, zero deps. **BlackHole is GPL-3.0 → reference-reading only, no copied code** |
| Format | **48 kHz, stereo (2ch), Float32** | Mirrors today's known-good BlackHole-2ch engine path; DSP stays mono and the engine mixer upmixes mono→stereo at the output edge exactly as it does now. Avoids the untested mono-output-device path. |
| Names | Device **"NoNoise Mic"**; hidden engine **"NoNoise Mic Engine"**; bundle `com.ivalsaraj.NoNoiseMic`; bundle dir `NoNoiseMic.driver` | Consistent with "NoNoise Mac" / `com.ivalsaraj.NoNoiseMac` |

---

## Architecture

```
 Real mic ─▶ AudioModel capture ─▶ DeepFilterNet ─▶ VoiceChain ─┐
                                                                │
                         ┌──────────────────────────────────────┴──────────────────────────┐
                         │                                                                  │
          A1 (ships first): AVAudioEngine output                A2 (eventual default): app renders PCM
          bound to the HIDDEN engine device                     (manual-render/tap, NO output device
                         │                                       bound) into a shared-memory ring     │
            ┌────────────▼──────────────────────────────────────────────────────────────────▼───────┐
            │  NoNoiseMic.driver  —  AudioServerPlugIn hosted by coreaudiod                            │
            │                                                                                          │
            │   visible INPUT  "NoNoise Mic"  ◀── sourceMode ('srcm'): { loopback | xpc } ──┐          │
            │   hidden  OUTPUT "NoNoise Mic Engine"  (A1 target; idle in xpc mode)          │          │
            │   one shared host-clock anchor + one internal loopback ring                   │          │
            └────────────────────────────────────────────────────────────────────────────────┴───────┘
                         │
              Slack / Zoom / Meet / OBS  select "NoNoise Mic" as their microphone
```

**Two processes, one shared contract:**
- **App (companion, existing process):** owns capture + DeepFilterNet + VoiceChain. Gains: device discovery, A1 output auto-route, an XPC client (A2), and a small "driver installed?" status surface.
- **Driver (new, in `coreaudiod`):** publishes the device(s); serves the visible input stream from whichever source `sourceMode` selects. It does **no** ML/heavy work (it's sandboxed and realtime).

---

## The driver (AudioServerPlugIn)

**Topology** (one plug-in, two audio objects — the "mirror" technique, reimplemented from the Apple sample; *concept* informed by BlackHole's `kDevice_*`/`kDevice2_*` docs, **no copied code**):
- **Device 1 — "NoNoise Mic"**: visible, **input-only** (`HasInput=true`, `HasOutput=false`). What consumer apps read. 48 kHz, **2ch**, Float32.
- **Device 2 — "NoNoise Mic Engine"**: **hidden** (`IsHidden=true`), **output-only**. The A1 target the app's engine writes into; **idle in xpc mode**. Resolved programmatically via `kAudioHardwarePropertyTranslateUIDToDevice` (which ignores `IsHidden`).
- **Both devices share ONE host-clock anchor and ONE internal loopback ring.** `GetZeroTimeStamp` for each derives from the same anchor at the same nominal rate, or the read/write pointers drift → periodic clicks. (Mic↔engine drift on the *capture* side is already absorbed by the 2400-frame latency target + drop at `AudioModel.swift:139-143`; this rule is specifically about the intra-driver device pair.)

**Default-eligibility guard (prevents a system-audio→mic leak):** the hidden engine device MUST report `CanBeDefaultDevice=false` and `CanBeDefaultSystemDevice=false` (output scope), so macOS can never route system audio into the loopback. The visible "NoNoise Mic" input being default-eligible is fine.

**`sourceMode` device property** (4-char selector `'srcm'`, scope global) the app sets:
- `loopback` (A1): the visible input is fed from the **loopback ring** written by the engine device's output.
- `xpc` (A2): the visible input is fed from the **shared-memory ring** established over XPC; the engine device is idle.

**I/O contract:** the driver implements the standard `AudioServerPlugInDriverInterface` (QueryInterface/AddRef/Release/Initialize/… `DoIOOperation`/`EndIOOperation`). In `DoIOOperation` the visible input reads from the **loopback ring** or the **shared-memory ring** per `sourceMode`. Timing uses the Apple sample's zero-timestamp scheme off the shared anchor. Ring read/write is **lock-free, allocation-free, syscall-free** (SPSC) — the same real-time discipline the project enforces on its render thread.

**CFPlugIn `Info.plist` (the dominant silent-failure source):** coreaudiod loads the bundle via CFPlugIn, so the plist MUST carry, exactly:
- `CFBundlePackageType` = `BNDL`, `CFBundleExecutable` = the built binary name.
- `CFPlugInFactories` = { `<factory-UUID>` : `<exported New… C function symbol>` }.
- `CFPlugInTypes` = { `<kAudioServerPlugInTypeUUID string>` : [ `<factory-UUID>` ] }.
Any mismatch → coreaudiod **silently** ignores the bundle (no error; the device just never appears). Hence success-criterion #1's install-time verification.

**Shared app↔driver contract constants** (defined once, in a shared header / documented table — a mismatch fails *silently*):
- Engine device UID string, visible device UID string.
- `sourceMode` selector `'srcm'` (FourCharCode) + its scope/element.
- Bundle id `com.ivalsaraj.NoNoiseMic`, factory UUID.
If the driver is installed but the app cannot resolve the engine UID, the app surfaces a **visible error** (not a silent fallback) — see auto-route.

---

## Phase A1 — loopback + auto-route (ships first)

**Driver:** the topology above, `sourceMode` defaulting to `loopback`.

**App (`AudioModel`) changes:**
- **Device discovery:** on launch, resolve **"NoNoise Mic Engine"** (hidden output) by UID via `kAudioHardwarePropertyTranslateUIDToDevice`.
- **Output auto-route (A1 only):** set that engine device as the `AVAudioEngine` output (`kAudioOutputUnitProperty_CurrentDevice`) — the **same call path** as today's `setupPlaybackEngine()`. Engine device is 2ch, so the existing mono→mixer→`format: nil`→output path upmixes exactly as it does for BlackHole 2ch today.
- **Auto-route priority:** NoNoise Mic Engine → (existing) BlackHole → **do not auto-route to a physical output**; if neither virtual sink exists, leave routing unset and surface "Install the NoNoise Mic driver." (Routing cleaned PCM to physical speakers would contradict the goal, so "first available physical device" is explicitly *not* a fallback.)
- **Output-picker filtering (both findings #1):** `fetchOutputDevices` must drop hidden devices — query `kAudioDevicePropertyIsHidden` per device and/or exclude the engine by its known UID — so "NoNoise Mic Engine" never shows in the app's *own* output list. (It passes the current `size > 0` channel test, so without this it would appear: `AudioModel.swift:268-283`.)
- **Input feedback guard:** filter any NoNoise Mic device out of the *input* picker so the user can't select the virtual mic as the capture source. (Loopback HAL devices generally don't surface via `AVCaptureDevice` discovery, but filter by name defensively.)

**Net:** A1 reuses the existing output-to-device code almost verbatim. The visible result is already Krisp-like: the user sees only **"NoNoise Mic"** (input); the engine output is hidden and non-default-eligible.

---

## Phase A2 — XPC input-only + Settings toggle (then flip default)

**Audio transport reality:** Background Music confirms the *negative* — bulk audio must **not** ride XPC messages (too jittery for realtime); BGM itself carries bulk audio over a **device stream** (i.e. a loopback, like our A1) and uses XPC only for control/sync. So BGM validates "XPC for control only" but is **not** precedent for an app→driver shared-memory ring. The shared-memory ring is *our* chosen carrier and is the highest-risk, least-proven piece → it gets a mandatory pre-coding spike.

**Components:**
- A **launchd-registered helper daemon** (Background Music's `BGMXPCHelper` pattern) brokers app ↔ driver. A coreaudiod-hosted plug-in is **sandboxed**, and a sandboxed plug-in doing `mach-lookup` on a third-party global name is exactly what's restricted — which is why BGM uses a helper rather than a driver-hosted service. Design biases to the helper.
  - **Pre-coding spike (make-or-break):** confirm on target macOS (14/15) whether coreaudiod's sandbox permits `mach-lookup` of the chosen service name; pin helper-vs-direct based on the result *before* committing A2 as default.
- A **shared-memory ring** (POSIX shm) carrying 48 kHz stereo Float32:
  - The **unsandboxed app** does `shm_open`+`ftruncate`+`mmap`, then **passes the file descriptor over XPC** (`xpc_dictionary_set_fd`); the driver `mmap`s the **received FD**. The driver must NOT `shm_open` by name (name lookup is sandbox-gated inside coreaudiod) — FD-passing sidesteps that.
  - **Writer liveness** is an **atomic generation/heartbeat counter in the shm header**, checked inside `DoIOOperation` (RT-safe, no syscalls). Teardown is driven by this field — NOT the async XPC `invalidation` callback (which lags by buffers and isn't RT-ordered). No client / stale generation → driver serves silence.
- **App-side PCM emission in xpc mode:** the app does **not** bind an output device. It switches `AVAudioEngine` to manual-rendering mode (or an output tap) and writes rendered PCM directly into the shared-memory ring. (This is the crisp A1/A2 split: A1 reuses `setupPlaybackEngine()` + an output device; A2 has no bound output device.)

**UI:** Settings gains a `sourceMode` control: *Automatic (XPC)* / *Compatibility (Loopback)*. After on-device validation, the **default flips to XPC**.

**Why phased:** A2's cross-process realtime handoff into the sandboxed plug-in (helper + FD-passed shm + RT liveness) is the highest-risk, least-documented part. Shipping A1 first proves the device + routing end-to-end so A2 is an isolated, well-bounded addition.

---

## App-side surface

**Both phases:**
- `AudioModel`: `driverInstalled: Bool` (published), `sourceMode` (published, persisted under a new `mv.*` key), device discovery, input filtering + output hidden-device filtering.
- UI (minimal in Spec A — full dashboard is Spec B): a status row **"NoNoise Mic: installed ✓ / not installed — Install…"**. "Install…" surfaces the script command / reveals the driver in Finder.

**A1 only:** output-device auto-route (binds the engine device).
**A2 only:** XPC client (helper connection, FD-passed shm, liveness), manual-render PCM emission, the Settings `sourceMode` toggle.

Persistence stays in the legacy `mv.*` `UserDefaults` namespace (per `AGENTS.md` branding rule).

---

## Build, install, packaging

**Repo additions:**
- `Driver/NoNoiseMic/` — C sources based on the Apple sample + `Info.plist` (with the exact CFPlugIn keys above). Retain the Apple Sample Code License notice in-file.
  - Factor the **lock-free SPSC ring** and **zero-timestamp/host-clock math** into a standalone `*.c/*.h` free of CoreAudio types (host-compilable) so they can be unit-tested off-device.
- `build-driver.sh` — compiles the `.driver` bundle with `clang -bundle -framework CoreAudio -framework CoreFoundation` (no `.xcodeproj` required; `xcodebuild` documented as an alternative), then ad-hoc signs **after the bundle is fully assembled** (`codesign --force --sign - NoNoiseMic.driver`) and prints `codesign -dv --verbose=4` so a broken signature is caught at build time.
- `install-driver.sh` — `sudo cp -R NoNoiseMic.driver /Library/Audio/Plug-Ins/HAL/`, `sudo killall coreaudiod`, then **verify**: poll `kAudioHardwarePropertyTranslateUIDToDevice` for the engine UID (or `system_profiler SPAudioDataType`) and **fail loudly** if the device didn't appear. Warns that all audio drops for ~1 s. Idempotent.
- `uninstall-driver.sh` — removes the bundle + restarts `coreaudiod`.
- `bundle.sh` — gains an optional `--with-driver` step that builds + stages the driver next to the app. If it copies anything into the bundle, it does so **before** signing (post-sign copies invalidate the signature → silent non-load). Install stays an explicit, admin-gated user action — never silent.
- **CI** (`.github/workflows/ci.yml`): add (a) a **driver compile** check (clang), and (b) **host unit tests** for the pure ring + timestamp C (wrap-around, full/empty, SPSC ordering, drift accounting). Runtime device behavior still can't be tested in CI (no `coreaudiod`).

**README:** a new "NoNoise Mic (virtual microphone)" section — install/uninstall, "select NoNoise Mic in your app," the `coreaudiod`-restart caveat. The BlackHole instructions stay as the documented fallback.

---

## Signing / entitlements reality
- The `.driver` is **ad-hoc** signed and signed **after full assembly**. Locally built bundles aren't quarantined, so they load from `/Library/Audio/Plug-Ins/HAL` for the build-from-source flow (SIP doesn't protect that path; ad-hoc satisfies the arm64 "must be signed" rule). **Redistribution to other machines would require Developer ID + notarization — explicitly out of scope.**
- README must distinguish two different trust mechanisms: the **app's** Gatekeeper/quarantine right-click-Open (existing caveat) vs **coreaudiod's** signature check on the **driver** — they are not the same thing.
- The app stays **un-sandboxed** (as today — only `device.audio-input` + `allow-jit`), which is what lets the unsandboxed app own the shm FD and broker A2. No new app entitlements for A1; A2's helper/entitlement needs are confirmed by the pre-coding spike.

---

## Testing strategy
- **Swift unit tests** (headless, CI) for the new *pure* app-side logic:
  - UID→device resolution wrapper (mockable seam over `kAudioHardwarePropertyTranslateUIDToDevice`).
  - Auto-route **selection** as a pure function (priority: engine → BlackHole → *no physical fallback*).
  - Input-list filtering (NoNoise Mic excluded) + output hidden-device filtering, as pure functions.
- **Driver — pure C, host-tested in CI** (the riskiest code; a bug here crashes `coreaudiod` system-wide): the lock-free SPSC ring (wrap-around, under/overflow, SPSC ordering) and the zero-timestamp/drift math, compiled and run on the CI runner — matching the repo norm "keep DSP math in pure, testable statics" (`critical-patterns.md`).
- **Driver — manual on-device checklist** for the CoreAudio-coupled parts: install (+ verification) → see in Audio MIDI Setup → record in QuickTime hears cleaned mic → AI-off passthrough → quit = clean silence → uninstall.
- `AudioModel` orchestration remains smoke-tested manually (it starts CoreAudio/AVFoundation — can't run under `swift test`), consistent with the repo's existing approach.

---

## Risks & mitigations
| Risk | Mitigation |
|---|---|
| `killall coreaudiod` drops all audio briefly | Documented in `install-driver.sh`; only on install/uninstall |
| **Silent non-load** (bad CFPlugIn plist / invalidated signature) | Exact plist keys specified; sign after assembly; install script verifies the device appeared and fails loudly |
| Ad-hoc driver won't load on *other* machines | Out of scope (build-from-source only); README states the notarization caveat |
| Engine/device **format mismatch** | Device is 48 kHz **2ch**, mirroring the proven BlackHole-2ch path; engine upmixes mono→stereo at the existing `format: nil` output edge |
| Hidden engine device showing in the app's own picker | `fetchOutputDevices` filters `kAudioDevicePropertyIsHidden` + the known engine UID |
| System audio leaking into the mic | Engine device reports `CanBeDefaultDevice=false` / `CanBeDefaultSystemDevice=false` |
| Intra-driver **drift/clicks** | Both devices share one host-clock anchor + one loopback ring |
| **Feedback loop** if user picks NoNoise Mic as input | Filter virtual devices out of the input picker |
| A2 realtime jitter | Bulk audio rides a **shared-memory ring** (our chosen carrier), not XPC messages |
| A2 sandbox blocks mach-lookup / `shm_open` by name | launchd helper (BGM pattern) + **FD-passed** shm over XPC; pre-coding spike to confirm on target macOS |
| Stale audio after app quits (A2) | **Atomic liveness header** checked in `DoIOOperation` (not XPC invalidation); no/stale client → silence |
| Silent auto-route failure | If driver installed but engine UID won't resolve, surface a **visible** error — no silent fallback |
| GPL contamination | **No BlackHole code copied**; base is Apple's permissively-licensed sample |

---

## Out of scope (→ Spec B)
- Full **guided routing / health-check dashboard** (the Spec A status row is intentionally minimal).
- **Dual pipeline** in the GUI (clean mic + clean incoming meeting audio).
- **Acoustic Echo Cancellation** (`setVoiceProcessingEnabled` / `kAudioUnitSubType_VoiceProcessingIO`).
- Notarized installer / Mac App Store distribution.

---

## References (reading only — license-checked)
- Apple — *Creating an Audio Server Driver Plug-in* (SimpleAudio/NullAudio); `CoreAudio/AudioServerPlugIn.h`. **Apple Sample Code License** → safe base.
- gavv/libASPL — MIT (considered; not chosen — keeps the repo dependency-free).
- ExistentialAudio/BlackHole — **GPL-3.0** → concept/technique reference only, **no copied code**.
- kyleneideck/BackgroundMusic — app↔driver XPC + launchd-helper pattern (`BGMXPCHelper`); confirms "bulk audio off XPC."
- WWDC23 *What's new in voice processing* — relevant to Spec B (AEC).
