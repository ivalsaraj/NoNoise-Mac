# NoNoise Mic — Virtual Microphone Driver (Tier 3, Spec A) — Design

**Status:** Design / brainstorm output (awaiting implementation-plan stage).
**Scope:** Spec A only — the **NoNoise Mic** virtual input device + the app wiring that feeds it. Health-check dashboard, dual-pipeline GUI, and AEC are **Spec B** (out of scope here).

---

## Goal

Ship a virtual microphone named **"NoNoise Mic"** that appears directly in Slack / Zoom / Meet / OBS. The user selects it once as their mic; the always-running NoNoise Mac app captures the real microphone, runs DeepFilterNet (the existing pipeline), and feeds the **cleaned** audio into that device.

**The single biggest UX upgrade: no BlackHole, no system-default juggling, no manual output routing.**

### Why this works (Krisp's mechanism, verified)
Krisp does exactly this on macOS (confirmed via Apple's CoreAudio docs, the Apple Developer Forums thread that names Krisp, and the BlackHole / Background Music open-source drivers):
- It installs an **AudioServerPlugIn** — a *userspace* CoreAudio HAL driver (`.driver` bundle in `/Library/Audio/Plug-Ins/HAL`, hosted by `coreaudiod`). **No kernel extension.**
- A **always-running companion app** captures the real mic, runs the noise model, and pushes cleaned audio into the virtual device (Krisp uses XPC for control + a stream/shared path for audio).
- Consumer apps just pick **"Krisp Microphone"** as input. It's "active on the fly" because the companion is always processing in the background.

NoNoise Mac already *is* that companion (capture → DeepFilterNet → output). Spec A adds the missing piece: our own virtual device that the app feeds, replacing the BlackHole dependency.

### Success criteria
1. `./install-driver.sh` → **"NoNoise Mic"** shows in **Audio MIDI Setup** and in Slack/Zoom/Meet/OBS input menus.
2. With the app running + AI on, speaking into the real mic is heard **cleaned** by a consumer app (QuickTime New Audio Recording / Slack test call).
3. Toggling AI off passes audio through (passthrough); quitting the app stops the feed cleanly (consumer hears silence, not garbage).
4. The app **auto-routes** to NoNoise Mic on launch — the user does not manually pick an output.
5. `./uninstall-driver.sh` removes the device cleanly after a `coreaudiod` restart.
6. `swift build && swift test` stays green; the driver compiles in CI; manual on-device checklist passes.

---

## Decisions locked during brainstorming

| Decision | Choice | Rationale |
|---|---|---|
| Scope/sequencing | **2 specs.** Spec A = driver (this doc); Spec B = health check + dual pipeline + AEC | Driver is a full sub-project; the others are incremental |
| Install & signing | **Ad-hoc signed `.driver` + install script** (`sudo cp` to HAL + `sudo killall coreaudiod`) | Keeps the repo's build-from-source, no-Apple-account ethos |
| Driver technology | **AudioServerPlugIn** (userspace HAL plugin) | DriverKit needs a paid account + Apple-granted entitlement; Apple says use AudioServerPlugIn for virtual-only devices |
| Transport | **Both** loopback (A1) **and** XPC input-only (A2), switchable in Settings; **XPC is the eventual default** | A1 reuses existing output code (low risk); A2 is the cleaner Krisp-exact UX |
| Build sequencing | **Phased:** ship A1 first (proven), then add A2 + the toggle, then flip the default to XPC after on-device validation | De-risks: new users don't hit the hardest code first |
| Code base | **Apple's AudioServerPlugIn sample (SimpleAudio / NullAudio)**, Apple Sample Code License | Permissive (MIT-ish), pure C, zero deps. **BlackHole is GPL-3.0 → reference-reading only, no copied code** |
| Format | **48 kHz, mono** | Matches the existing DeepFilterNet pipeline |
| Names | Device **"NoNoise Mic"**; hidden engine **"NoNoise Mic Engine"**; bundle `com.ivalsaraj.NoNoiseMic`; bundle dir `NoNoiseMic.driver` | Consistent with "NoNoise Mac" / `com.ivalsaraj.NoNoiseMac` |

---

## Architecture

```
 Real mic ─▶ AudioModel capture ─▶ DeepFilterNet ─▶ VoiceChain ─┐
                                                                │
                         ┌──────────────────────────────────────┴──────────────────────────┐
                         │                                                                  │
          A1 (ships first): AVAudioEngine output                A2 (eventual default): app writes cleaned
          to the HIDDEN mirror output device                    PCM into a shared-memory ring; XPC handshake
                         │                                       sets it up                  │
            ┌────────────▼──────────────────────────────────────────────────────────────────▼───────────┐
            │  NoNoiseMic.driver  —  AudioServerPlugIn hosted by coreaudiod                                │
            │                                                                                              │
            │   visible INPUT  "NoNoise Mic"  ◀── sourceMode property: { loopback | xpc } ──┐              │
            │   hidden  OUTPUT "NoNoise Mic Engine"  (A1 mirror target)                     │              │
            └───────────────────────────────────────────────────────────────────────────────┴───────────┘
                         │
              Slack / Zoom / Meet / OBS  select "NoNoise Mic" as their microphone
```

**Two processes, one shared contract:**
- **App (companion, existing process):** owns capture + DeepFilterNet + VoiceChain. Gains: device discovery/auto-route, an XPC client (A2), and a small "driver installed?" status surface.
- **Driver (new, in `coreaudiod`):** publishes the device(s); serves the input stream from whichever source `sourceMode` selects. It does **no** ML/heavy work (it's sandboxed and realtime).

---

## The driver (AudioServerPlugIn)

**Topology** (one plug-in, two audio objects — the "mirror" technique, reimplemented from the Apple sample, *concept* informed by BlackHole's `kDevice_*`/`kDevice2_*` docs):
- **Device 1 — "NoNoise Mic"**: visible, **input-only** (`HasInput=true`, `HasOutput=false`). This is what consumer apps read. 48 kHz, mono, Float32.
- **Device 2 — "NoNoise Mic Engine"**: **hidden** (`IsHidden=true`), **output-only**. The A1 target the app writes into. Found programmatically via `kAudioHardwarePropertyTranslateUIDToDevice` (hidden devices don't appear in pickers).

**Sample source selector** — a custom device property (e.g. selector `'srcm'`, scope global) the app sets:
- `loopback` (A1): Device 1's input is fed from the ring written by Device 2's output (classic loopback, but the output side is hidden).
- `xpc` (A2): Device 1's input is fed from the **shared-memory ring** established over XPC. Device 2 is idle.

**I/O contract:** the driver implements the standard `AudioServerPlugInDriverInterface` (QueryInterface/AddRef/Release/Initialize/… `DoIOOperation`/`EndIOOperation`). Timing (host-time anchor, zero-timestamp scheme) is reimplemented from the Apple sample's `GetZeroTimeStamp` pattern. Ring read/write in `DoIOOperation` is **lock-free and realtime-safe** (no allocation, no mutex) — the same discipline the project already enforces on its render thread.

---

## Phase A1 — loopback + auto-route (ships first)

**Driver:** the topology above, `sourceMode` defaulting to `loopback`.

**App (`AudioModel`) changes:**
- On launch, resolve **"NoNoise Mic Engine"** (hidden output) by UID via `kAudioHardwarePropertyTranslateUIDToDevice`; set it as the `AVAudioEngine` output device (`kAudioOutputUnitProperty_CurrentDevice`) — the **same call path** as today's `setupPlaybackEngine()`. This replaces "default to BlackHole."
- Auto-route priority: NoNoise Mic Engine → (existing) BlackHole → first available. So existing BlackHole users are unaffected if the driver isn't installed yet.
- **Feedback-loop guard:** filter any NoNoise Mic device out of the *input* picker so the user can't select the virtual mic as the capture source. (Loopback HAL devices generally don't surface via `AVCaptureDevice` discovery, but we filter by name defensively.)

**Net:** A1 reuses the existing output-to-device code almost verbatim. The visible result is already Krisp-like: the user sees only **"NoNoise Mic"** (input); the output side is hidden.

---

## Phase A2 — XPC input-only + Settings toggle (then flip default)

**Audio transport reality (verified against Background Music):** even BGM carries bulk audio over a device stream and uses XPC only for control/sync. So A2 carries **bulk PCM over a shared-memory ring**, with **XPC used only to hand off the shared memory + lifecycle/sync** — *not* per-buffer XPC messages (those are too jittery for realtime).

**Components:**
- An **XPC mach service** bridging app ↔ driver (reference pattern: Background Music's `BGMXPCHelper`, a tiny launchd-registered helper that both sides reach). Exact registration mechanism (helper vs. direct driver-hosted service) is **verified during the implementation-plan stage** per the third-party-integration protocol.
- A **shared-memory ring** (POSIX shared memory) the app writes cleaned 48 kHz mono Float32 into; the driver reads it in `DoIOOperation` when `sourceMode == xpc`.
- App-side **XPC client**: connects, hands over the ring, starts/stops the feed with capture lifecycle, and tears down on quit (driver falls back to silence — never stale audio).

**UI:** Settings gains a **"NoNoise Mic source"** control: *Automatic (XPC)* / *Compatibility (Loopback)*. After on-device validation, the **default flips to XPC**.

**Why phased:** A2's cross-process realtime handoff into the sandboxed plug-in is the highest-risk, least-documented part. Shipping A1 first proves the device + routing end-to-end so A2 is an isolated, well-bounded addition.

---

## App-side surface (both phases)

- `AudioModel`: `driverInstalled: Bool` (published), `sourceMode` (published, persisted under a new `mv.*` key), device discovery/auto-route, input filtering, XPC client (A2).
- UI (minimal in Spec A — full dashboard is Spec B): a status row **"NoNoise Mic: installed ✓ / not installed — Install…"**. "Install…" surfaces the script command / reveals the driver in Finder. The Settings source toggle lands with A2.
- Persistence stays in the legacy `mv.*` `UserDefaults` namespace (per `AGENTS.md` branding rule).

---

## Build, install, packaging

**Repo additions:**
- `Driver/NoNoiseMic/` — C sources based on the Apple sample + `Info.plist` (declares `kAudioServerPlugInTypeUUID` factory, bundle id, device names). Retain the Apple Sample Code License notice in-file.
- `build-driver.sh` — compiles the `.driver` bundle with `clang` (no `.xcodeproj` required; matches the repo's script-based ethos), then ad-hoc signs: `codesign --force --sign - NoNoiseMic.driver`. (`xcodebuild` documented as an alternative.)
- `install-driver.sh` — `sudo cp -R NoNoiseMic.driver /Library/Audio/Plug-Ins/HAL/` then `sudo killall coreaudiod` (warns that all audio drops for ~1 s). Idempotent (replaces an existing copy).
- `uninstall-driver.sh` — removes the bundle + restarts `coreaudiod`.
- `bundle.sh` — gains an optional `--with-driver` step that builds + stages the driver next to the app (install stays an explicit, admin-gated user action — never silent).
- **CI** (`.github/workflows/ci.yml`): add a **compile check** for the driver (clang build). Runtime can't be tested in CI (no `coreaudiod`).

**README:** a new "NoNoise Mic (virtual microphone)" section — install/uninstall, "select NoNoise Mic in your app," and the `coreaudiod`-restart caveat. The BlackHole instructions stay as the documented fallback.

---

## Signing / entitlements reality
- The `.driver` is **ad-hoc** signed. Locally built bundles aren't quarantined, so they load from `/Library/Audio/Plug-Ins/HAL` for the build-from-source flow. **Redistribution to other machines would require Developer ID + notarization — explicitly out of scope** (matches the README's existing ad-hoc caveat).
- The app stays **un-sandboxed** (as it is today — only `device.audio-input` + `allow-jit`), which is what makes the A2 XPC mach service feasible. No new app entitlements for A1; A2's entitlement needs are confirmed at the implementation-plan stage.

---

## Testing strategy
- **Swift unit tests** (run headless in CI) for the new *pure* app-side logic:
  - UID→device resolution wrapper (mockable seam over `kAudioHardwarePropertyTranslateUIDToDevice`).
  - Auto-route **selection** logic (priority: NoNoise Mic → BlackHole → first) as a pure function over a device list.
  - Input-list **filtering** (NoNoise Mic excluded) as a pure function.
- **Driver:** CI **compile** check + a documented **manual on-device checklist** (install → see in Audio MIDI Setup → record in QuickTime hears cleaned mic → AI-off passthrough → quit = clean silence → uninstall).
- `AudioModel` orchestration remains smoke-tested manually (it starts CoreAudio/AVFoundation — can't run under `swift test`), consistent with the repo's existing approach.

---

## Risks & mitigations
| Risk | Mitigation |
|---|---|
| `killall coreaudiod` drops all audio briefly | Documented in `install-driver.sh` output; only on install/uninstall |
| Ad-hoc driver won't load on *other* machines | Out of scope (build-from-source only); README states the notarization caveat |
| Engine/device **format mismatch** | Lock device to 48 kHz mono; convert in the engine if needed (existing `AVAudioConverter` path) |
| **Feedback loop** if user picks NoNoise Mic as input | Filter virtual devices out of the input picker |
| A2 realtime over XPC jitter | Bulk audio rides a **shared-memory ring**, not XPC messages (BGM-verified) |
| Driver timing bugs (clicks/drift) | Reimplement the Apple sample's host-time / zero-timestamp scheme; validate against QuickTime |
| Stale audio after app quits (A2) | Driver feeds silence when no client is connected; app tears down ring on quit |
| GPL contamination | **No BlackHole code copied**; base is Apple's permissively-licensed sample; BlackHole is reference-only |

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
- kyleneideck/BackgroundMusic — app↔driver XPC pattern reference (`BGMXPCHelper`).
- WWDC23 *What's new in voice processing* — relevant to Spec B (AEC).
