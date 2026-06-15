# NoNoise Mic — AudioServerPlugIn driver

`NoNoiseMic.driver` is a userspace CoreAudio HAL plug-in (an **AudioServerPlugIn** that runs
inside `coreaudiod`). It is an **original implementation** written against the public
`<CoreAudio/AudioServerPlugIn.h>` API. Its structure follows Apple's documented
"Creating an Audio Server Driver Plug-in" sample (NullAudio) for API-usage patterns **only** —
no Apple sample source is copied — so it ships under this project's **MIT license**. It is
**NOT** derived from BlackHole (GPL-3.0); BlackHole was reference reading only.

## Topology
- **NoNoise Mic** — visible, input-only device (UID `NoNoiseMic:visible:48k2ch`). Apps (Slack/
  Zoom/Meet/OBS) select this as their microphone.
- **NoNoise Mic Engine** — hidden, output-only device (UID `NoNoiseMic:engine:48k2ch`). The
  NoNoise Mac app renders cleaned audio here; it never appears in user-facing pickers and is
  not default-eligible.

Both devices share ONE loopback ring (`nn_ring`) plus a per-device zero-timestamp clock
(`nn_clock`) anchored to a single host time. Audio is 48 kHz, 2ch, **interleaved** Float32.
The visible device's `sourceMode` (`'srcm'`) property selects loopback (`0`, default) vs the
A2 shared-memory/XPC path (`1`).

The ring serves **silence, never stale speech**: it tracks a `writeEnd` watermark and zeroes any
frame the engine hasn't produced (or that has been overwritten by a wrap). So if the app stops
rendering while an app is still capturing "NoNoise Mic", the call hears silence — not a loop of
your last sentence.

## Pure, host-tested math
The risky index math lives in CoreAudio-free C and is unit-tested without a device:
`Driver/NoNoiseMic/nn_ring.{c,h}`, `nn_clock.{c,h}` → `Driver/tests/run-tests.sh` (covers
wraparound, zero-timestamp jumps, and the read-before-write / writer-stopped silence guarantees).

## Build / install / uninstall
```bash
../build-driver.sh                 # compile + ad-hoc sign NoNoiseMic.driver
sudo ../install-driver.sh          # copy to /Library/Audio/Plug-Ins/HAL, restart coreaudiod, verify
sudo ../uninstall-driver.sh        # remove + restart coreaudiod
```
Installing restarts `coreaudiod`, so **all** audio drops for a moment.
