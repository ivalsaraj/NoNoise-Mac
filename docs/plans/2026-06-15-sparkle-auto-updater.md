# Sparkle Auto-Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give NoNoise Mac an in-app auto-updater so that when a new `vX.Y.Z` release is published, running copies detect it, show a native "update available" window, and download + install it.

**Architecture:** Integrate the [Sparkle 2](https://sparkle-project.org) framework via SwiftPM. The app polls a fixed `appcast.xml` (the `SUFeedURL`), compares the newest `sparkle:version` against the installed `CFBundleVersion`, downloads the GitHub-Release-hosted `.app.zip`, verifies an EdDSA signature, replaces the bundle in place, and relaunches. Versioning is owned by the existing **`release.sh`** (it bumps `Info.plist` and tags); CI signs the archive, regenerates the appcast, and publishes it to a fixed `appcast` GitHub release tag.

**Tech Stack:** Swift / SwiftUI (SwiftPM executable), Sparkle 2.6.x, GitHub Actions, EdDSA (ed25519) signing, GitHub Releases hosting, bash.

**GitHub Issue:** #14 — https://github.com/ivalsaraj/NoNoise-Mac/issues/14

**Design status:** Codex-approved (2 rounds, gpt-5.5), then reconciled with the project's existing `release.sh` flow. Locked decisions: ad-hoc signing (no notarization), stable `vMAJOR.MINOR.PATCH` channel only, native Sparkle UI + scheduled checks.

---

## Working directory

All paths are relative to the **`NoNoise-Mac/` git repository root** (the directory containing `Package.swift`). Run every command from there.

## How versioning works here (read before touching versions)

Releases are cut with **`./release.sh <version> --notes-file …`** (per AGENTS.md — never tag manually). `release.sh` already:
1. bumps `CFBundleShortVersionString` + `CFBundleVersion` in `Resources/Info.plist`,
2. commits the bump,
3. creates an annotated tag `v<version>` carrying the release notes,
4. pushes `main` + the tag, triggering `release.yml`.

So **the version is committed into `Info.plist` before CI runs** — CI must NOT re-stamp it. This plan fixes `release.sh`'s build-number formula (Task 8) and makes CI trust + assert the committed value (Task 10).

## Critical design constraints (do not violate)

1. **`CFBundleVersion` MUST be a monotonic integer** that strictly increases with semver. Sparkle compares it against the installed bundle version. The existing `release.sh` formula (`MAJOR.MINOR` digits concatenated) is **broken for updates**: it ignores PATCH (`1.2.0` and `1.2.5` both → `12`) and isn't monotonic across minors (`2.0.0`→`20` < `1.10.0`→`110`). Replace it with `MAJOR*1000000 + MINOR*1000 + PATCH` (`v1.2.3 → 1002003`). Every value is ≥ 1000000, dwarfing the old concatenated values and the current `CFBundleVersion=2`, so the switch can't strand anyone.
2. **Sign inside-out, never `--deep`** once `Sparkle.framework` is embedded (Sparkle requirement; `--deep` breaks nested XPC/helper signing). The outer app stays **ad-hoc, no Hardened Runtime**; nested Sparkle code gets `-o runtime`.
3. **Updater feed = stable `^v[0-9]+\.[0-9]+\.[0-9]+$` tags only.** The rolling `main-<sha>` build is excluded from the appcast.
4. **`SUFeedURL` is the single source of truth** and must equal the published appcast URL exactly: `https://github.com/ivalsaraj/NoNoise-Mac/releases/download/appcast/appcast.xml`.
5. **One version source of truth: `release.sh`.** CI does not stamp; it asserts the committed `Info.plist` matches the tag.

## File structure

| File | Responsibility | Action |
|------|----------------|--------|
| `scripts/version-from-tag.sh` | Canonical tag→(short, monotonic build) mapping + validation | Create |
| `scripts/version-from-tag.test.sh` | Shell unit tests for the mapping | Create |
| `Package.swift` | Add Sparkle SPM dependency to the `NoNoiseMac` target | Modify |
| `Resources/Info.plist` | Sparkle keys (`SUFeedURL`, `SUPublicEDKey`, auto-check) | Modify |
| `Sources/App/UpdaterController.swift` | Owns `SPUStandardUpdaterController`, publishes `canCheckForUpdates` | Create |
| `Sources/App/NoNoiseMacApp.swift` | Create updater singleton in `init()`, fire launch check | Modify |
| `Sources/App/ContentView.swift` | "Check for Updates…" footer row | Modify |
| `release.sh` | Use the monotonic mapping for `CFBundleVersion` | Modify |
| `bundle.sh` | Framework embedding + inside-out signing (NO stamping) | Modify |
| `.github/workflows/release.yml` | Sign + generate/verify/publish appcast (NO stamping) | Modify |
| `README.md`, `AGENTS.md`, `docs/knowledge/*` | Docs (updating, signing, key escrow, knowledge/timeline) | Modify |

---

## Task 1: Version-from-tag helper (TDD)

**Files:**
- Create: `scripts/version-from-tag.sh`
- Test: `scripts/version-from-tag.test.sh`

This is the **single source** of the tag→version mapping, consumed by both `release.sh` (Task 8) and CI assertions (Task 10).

- [ ] **Step 1: Write the failing test**

Create `scripts/version-from-tag.test.sh`:

```bash
#!/bin/bash
# Unit tests for version-from-tag.sh (shell test harness, mirrors Driver/tests/run-tests.sh style).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/version-from-tag.sh"
fail=0

assert_ok() { # tag expected_short expected_build
  local out short build
  if ! out=$("$SUT" "$1" 2>/dev/null); then
    echo "FAIL $1: expected success, got non-zero exit"; fail=1; return
  fi
  eval "$out"
  if [ "${short:-}" != "$2" ] || [ "${build:-}" != "$3" ]; then
    echo "FAIL $1: got SHORT=${short:-} BUILD=${build:-}, want $2 / $3"; fail=1
  else
    echo "ok   $1 -> $2 / $3"
  fi
}

assert_reject() { # tag
  if "$SUT" "$1" >/dev/null 2>&1; then
    echo "FAIL $1: expected rejection (non-zero exit)"; fail=1
  else
    echo "ok   $1 rejected"
  fi
}

assert_ok v1.0.0 1.0.0 1000000
assert_ok v1.2.0 1.2.0 1002000
assert_ok v1.2.3 1.2.3 1002003
assert_ok v1.2.5 1.2.5 1002005
assert_ok v2.0.0 2.0.0 2000000
assert_ok v1.10.0 1.10.0 1010000
assert_ok v1.999.999 1.999.999 1999999
assert_reject v1.2
assert_reject v1.2.3-beta.1
assert_reject 1.2.3
assert_reject vfoo
assert_reject v1.2.3.4
assert_reject v1.1000.0
assert_reject ""

if [ "$fail" -ne 0 ]; then echo "TESTS FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
```

Make it executable: `chmod +x scripts/version-from-tag.test.sh`

(`v1.2.0`→`1002000` and `v1.2.5`→`1002005` are the cases the old `release.sh` formula got wrong — both → `12`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/version-from-tag.test.sh`
Expected: FAIL — `version-from-tag.sh` does not exist yet; prints `TESTS FAILED`, exit 1.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/version-from-tag.sh`:

```bash
#!/bin/bash
# Canonical mapping from a stable release tag (vMAJOR.MINOR.PATCH) to Sparkle version fields.
# Used by release.sh (to stamp Info.plist) and by release.yml (to assert the committed value).
#
# On success prints two eval-able lines and exits 0:
#   short=<MAJOR.MINOR.PATCH>     # CFBundleShortVersionString (human/display)
#   build=<monotonic integer>     # CFBundleVersion (Sparkle comparison key)
#
# On a non-stable tag (two-part, prerelease, malformed, or minor/patch >= 1000) it prints a
# diagnostic to stderr and exits 1. CFBundleVersion MUST be monotonic because Sparkle's
# SUStandardVersionComparator compares it against the installed bundle version.
set -euo pipefail

tag="${1:-}"

if [[ ! "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "version-from-tag: '$tag' is not a stable vMAJOR.MINOR.PATCH tag" >&2
    exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

# Packing requires minor/patch < 1000 so the integer ordering matches semver ordering.
if (( minor >= 1000 || patch >= 1000 )); then
    echo "version-from-tag: minor/patch must each be < 1000 for monotonic packing ('$tag')" >&2
    exit 1
fi

short="${major}.${minor}.${patch}"
build=$(( major * 1000000 + minor * 1000 + patch ))

echo "short=${short}"
echo "build=${build}"
```

Make it executable: `chmod +x scripts/version-from-tag.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/version-from-tag.test.sh`
Expected: every line `ok …`, final `ALL TESTS PASSED`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/version-from-tag.sh scripts/version-from-tag.test.sh
git commit -m "feat(updater): add tested tag->version mapping for monotonic build numbers"
```

---

## Task 2: Add Sparkle SwiftPM dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the package dependency**

In `Package.swift`, replace the empty top-level dependencies array:

```swift
    dependencies: [],
```

with:

```swift
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
```

- [ ] **Step 2: Add Sparkle to the `NoNoiseMac` target**

In the `.executableTarget(name: "NoNoiseMac", …)` block, change:

```swift
            dependencies: ["Core"],
```

to:

```swift
            dependencies: [
                "Core",
                .product(name: "Sparkle", package: "Sparkle")
            ],
```

Leave the `Core`, `NoNoiseMacCLI`, and test targets unchanged — Sparkle is App-only.

- [ ] **Step 3: Resolve and build**

Run: `swift build -c release --arch arm64`
Expected: Sparkle is fetched and the package builds. Confirm the framework exists:

```bash
find .build -type d -name 'Sparkle.framework' | head
```
Expected: at least one path (Task 9 discovers it the same way).

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build(updater): add Sparkle 2 SwiftPM dependency to the app target"
```

(If `Package.resolved` is git-ignored, `git add Package.swift` alone is fine.)

---

## Task 3: Generate EdDSA keys (one-time, maintainer's Mac)

**Files:** none committed. Produces a public key string (Task 4) and a private key (GitHub Actions secret). **The private key is a secret — never commit it or print it into shared logs.**

- [ ] **Step 1: Locate Sparkle's key tool**

Run: `GENKEYS="$(find .build -type f -name generate_keys | head -1)"; echo "$GENKEYS"`
Expected: a path like `.build/artifacts/sparkle/Sparkle/bin/generate_keys`. If empty, run `swift build -c release --arch arm64` first.

- [ ] **Step 2: Generate the key pair**

Run: `"$GENKEYS"`
Expected: stores a private key in your login Keychain and prints the **base64 public key** (`SUPublicEDKey`). Copy it — it goes into `Info.plist` in Task 4.

- [ ] **Step 3: Export the private key for CI**

```bash
"$GENKEYS" -x /tmp/sparkle_private_key.pem
gh secret set SPARKLE_PRIVATE_KEY < /tmp/sparkle_private_key.pem
```
Expected: `✓ Set secret SPARKLE_PRIVATE_KEY for ivalsaraj/NoNoise-Mac`.

- [ ] **Step 4: Escrow + clean up**

Back up `/tmp/sparkle_private_key.pem` to a secure secret store (a lost private key cannot be rotated into installed builds — every user would have to reinstall manually). Then:
```bash
rm -f /tmp/sparkle_private_key.pem
```
No commit in this task.

---

## Task 4: Add Sparkle keys to Info.plist

**Files:**
- Modify: `Resources/Info.plist`

- [ ] **Step 1: Insert the Sparkle keys**

In `Resources/Info.plist`, immediately before the closing `</dict>` (after the `CFBundleURLTypes` array), add — replacing the public key with the value from Task 3 Step 2:

```xml
	<key>SUFeedURL</key>
	<string>https://github.com/ivalsaraj/NoNoise-Mac/releases/download/appcast/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>PASTE_PUBLIC_KEY_FROM_TASK_3</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUScheduledCheckInterval</key>
	<integer>86400</integer>
```

`SUFeedURL`/`SUPublicEDKey` are public by design (not secrets). `86400` = daily scheduled checks. Note: `release.sh` only `plutil -replace`s the two version keys, so these Sparkle keys are untouched by future releases.

- [ ] **Step 2: Validate the plist**

Run: `plutil -lint Resources/Info.plist`
Expected: `Resources/Info.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add Resources/Info.plist
git commit -m "feat(updater): add Sparkle feed URL, public EdDSA key, and auto-check settings"
```

---

## Task 5: UpdaterController

**Files:**
- Create: `Sources/App/UpdaterController.swift`

- [ ] **Step 1: Write the controller**

Create `Sources/App/UpdaterController.swift`:

```swift
import Foundation
import Combine
import Sparkle

/// Owns Sparkle's updater for the menu-bar app. Created ONCE in `NoNoiseMacApp.init()`
/// (the same launch-time singleton pattern as AudioModel / ActionDispatcher / HotkeyManager)
/// so automatic update checks are live from launch — not deferred until the popover first opens.
///
/// The feed URL and public EdDSA key are read from Info.plist (`SUFeedURL` / `SUPublicEDKey`);
/// `startingUpdater: true` boots the updater and its scheduled checks immediately.
@MainActor
final class UpdaterController: ObservableObject {
    let controller: SPUStandardUpdaterController

    /// Mirrors `SPUUpdater.canCheckForUpdates` so the "Check for Updates…" item can disable
    /// itself while a check or install is already in flight (Sparkle's documented SwiftUI pattern).
    @Published private(set) var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// The underlying updater (used by the AppDelegate to fire a launch-time background check).
    var updater: SPUUpdater { controller.updater }

    /// User-initiated check from the popover. Presents Sparkle's native UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build --arch arm64`
Expected: builds with no errors (compiles against Sparkle; not yet wired in).

- [ ] **Step 3: Commit**

```bash
git add Sources/App/UpdaterController.swift
git commit -m "feat(updater): add UpdaterController wrapping SPUStandardUpdaterController"
```

---

## Task 6: Wire the updater into the app

**Files:**
- Modify: `Sources/App/NoNoiseMacApp.swift`

- [ ] **Step 1: Import Sparkle**

At the top of `Sources/App/NoNoiseMacApp.swift`, add `import Sparkle`:

```swift
import SwiftUI
import Core
import Sparkle
```

- [ ] **Step 2: Add the updater state property**

After `@StateObject private var hotkeyManager: HotkeyManager`, add:

```swift
    @StateObject private var updaterController: UpdaterController
```

- [ ] **Step 3: Create it in `init()` and hand it to the AppDelegate**

Inside `init()`, after `appDelegate.dispatcher = dispatcher`, add:

```swift
        // Create the Sparkle updater at launch (same "singletons in init()" rule as above) so
        // scheduled/automatic checks are live before the popover is ever opened. Hand the updater
        // to the AppDelegate so it can fire one prompt background check in didFinishLaunching.
        let updater = UpdaterController()
        _updaterController = StateObject(wrappedValue: updater)
        appDelegate.updater = updater.updater
```

- [ ] **Step 4: Pass it to ContentView**

In `body`, change:

```swift
            ContentView(audioModel: audioModel, dispatcher: dispatcher, hotkeyManager: hotkeyManager)
```

to:

```swift
            ContentView(audioModel: audioModel, dispatcher: dispatcher, hotkeyManager: hotkeyManager, updaterController: updaterController)
```

- [ ] **Step 5: Give the AppDelegate the updater + a launch check**

In `AppDelegate`, add next to `var dispatcher: ActionDispatcher?`:

```swift
    /// Wired by NoNoiseMacApp.init() at launch so the launch-time update check can run.
    var updater: SPUUpdater?
```

Then change `applicationDidFinishLaunching` from:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
```

to:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Scheduled checks run on SUScheduledCheckInterval; this one extra background check at
        // launch surfaces a waiting update promptly. It shows UI only when an update is found
        // (no nag when up to date), and is guarded so it respects the user's automatic-check pref.
        if updater?.automaticallyChecksForUpdates == true {
            updater?.checkForUpdatesInBackground()
        }
    }
```

- [ ] **Step 6: Build**

Run: `swift build --arch arm64`
Expected: a "missing argument 'updaterController'" error from ContentView is expected until Task 7 Step 1–2; do Task 7 Steps 1–2 then re-run and expect a clean build.

- [ ] **Step 7: Commit**

```bash
git add Sources/App/NoNoiseMacApp.swift
git commit -m "feat(updater): create updater at launch and run a guarded launch check"
```

---

## Task 7: "Check for Updates…" UI

**Files:**
- Modify: `Sources/App/ContentView.swift`

- [ ] **Step 1: Add the updaterController property**

In `ContentView`, after `@ObservedObject var hotkeyManager: HotkeyManager`, add:

```swift
    @ObservedObject var updaterController: UpdaterController
```

- [ ] **Step 2: Add the footer row**

In the `footer` computed property, insert after the "Report" `Link` block (after its `.controlSize(.small)`, before `Spacer()`):

```swift
            Button {
                updaterController.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
            .disabled(!updaterController.canCheckForUpdates)
```

- [ ] **Step 3: Update any other ContentView call sites**

Run: `rg -n 'ContentView\(' Sources`
Expected: only `NoNoiseMacApp.swift` (already updated). If a `#Preview` exists, add `updaterController: UpdaterController()`.

- [ ] **Step 4: Build the whole app**

Run: `swift build -c release --arch arm64`
Expected: clean build of all targets.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/ContentView.swift
git commit -m "feat(updater): add Check for Updates row to the menu-bar popover"
```

---

## Task 8: Fix release.sh build-number formula

**Files:**
- Modify: `release.sh`

The current formula collapses patch releases and isn't monotonic. Replace it with the canonical mapping from Task 1.

- [ ] **Step 1: Replace the BUILD_NUMBER computation**

In `release.sh`, find:

```bash
echo "📝 Updating version in $PLIST_FILE"
BUILD_NUMBER=$(echo "$VERSION" | cut -d. -f1-2 | tr '.' '')
```

Replace those two lines with:

```bash
echo "📝 Updating version in $PLIST_FILE"
# CFBundleVersion must be a MONOTONIC integer for Sparkle (see scripts/version-from-tag.sh).
# The old "MAJOR.MINOR digits" formula ignored PATCH and wasn't monotonic across minors.
if VERS=$(./scripts/version-from-tag.sh "$TAG"); then
  eval "$VERS"   # sets short (== $VERSION) and build
  BUILD_NUMBER="$build"
else
  echo "❌ Error: version-from-tag.sh rejected $TAG"
  exit 1
fi
```

(`$TAG` is `v$VERSION`, already set earlier in `release.sh`. `release.sh`'s own semver check already guarantees the 3-part form, so `version-from-tag.sh` will accept it.)

- [ ] **Step 2: Verify the formula in isolation**

Run:
```bash
TAG=v1.2.3; eval "$(./scripts/version-from-tag.sh "$TAG")"; echo "short=$short build=$build"
```
Expected: `short=1.2.3 build=1002003` (the value `release.sh` will now write to `CFBundleVersion`).

- [ ] **Step 3: Dry-run guard check (do NOT push)**

`release.sh` pushes on success, so do not run it end-to-end here. Confirm the edited block is syntactically valid:
```bash
bash -n release.sh && echo "release.sh syntax OK"
```
Expected: `release.sh syntax OK`. (Full exercise happens in Task 12.)

- [ ] **Step 4: Commit**

```bash
git add release.sh
git commit -m "fix(release): use monotonic CFBundleVersion mapping for Sparkle compatibility"
```

---

## Task 9: bundle.sh — framework embedding + inside-out signing

**Files:**
- Modify: `bundle.sh`

bundle.sh does NOT stamp the version (release.sh already committed it into Info.plist). It only embeds Sparkle and signs.

- [ ] **Step 1: Replace the single signing line**

In `bundle.sh`, find:

```bash
# Sign with Entitlements (Crucial for Microphone Access)
codesign --force --deep --sign - --entitlements "Resources/NoNoiseMac.entitlements" "$APP_BUNDLE"
```

Replace it with:

```bash
# --- Embed Sparkle.framework. Use ditto (NOT cp -r) to preserve the Versions/Current symlink
#     and executable bits; cp -r would corrupt the framework and Sparkle would fail to load. ---
SPARKLE_FRAMEWORK="$(find .build -type d -name 'Sparkle.framework' -path '*artifacts*' 2>/dev/null | head -1)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    SPARKLE_FRAMEWORK="$(find .build -type d -name 'Sparkle.framework' 2>/dev/null | head -1)"
fi
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "ERROR: Sparkle.framework not found under .build — run 'swift build -c release --arch arm64' first." >&2
    exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# Make the executable find the embedded framework via @rpath (idempotent).
if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

# --- Sign inside-out (deepest nested code first), ad-hoc. NEVER use --deep with Sparkle. ---
# Nested Sparkle code gets Hardened Runtime (-o runtime) per Sparkle's signing docs; the OUTER app
# stays ad-hoc with NO hardened runtime (preserves current behavior + the allow-jit entitlement).
SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
SPARKLE_VER="$SPARKLE_FW/Versions/Current"

for xpc in "$SPARKLE_VER"/XPCServices/*.xpc; do
    [ -e "$xpc" ] || continue
    case "$xpc" in
        *Downloader.xpc) codesign --force --sign - --options runtime --preserve-metadata=entitlements "$xpc" ;;
        *)               codesign --force --sign - --options runtime "$xpc" ;;
    esac
done
[ -e "$SPARKLE_VER/Autoupdate" ] && codesign --force --sign - --options runtime "$SPARKLE_VER/Autoupdate"
[ -e "$SPARKLE_VER/Updater.app" ] && codesign --force --sign - --options runtime "$SPARKLE_VER/Updater.app"
codesign --force --sign - --options runtime "$SPARKLE_FW"

# Finally the app itself: ad-hoc, with entitlements, NO hardened runtime.
codesign --force --sign - --entitlements "Resources/NoNoiseMac.entitlements" "$APP_BUNDLE"

# Verify the assembled, signed bundle (Sparkle nested code + app seal).
codesign --verify --deep --strict "$APP_BUNDLE"
```

> Note: the nested layout (`XPCServices/`, `Autoupdate`, `Updater.app`) is what Sparkle 2.6.x ships; the loops/guards tolerate absent items (unsandboxed apps may not use the XPC services). If a future Sparkle version changes the layout, cross-check against the `Code Signing.md` bundled in the Sparkle artifacts and adjust.

- [ ] **Step 2: Build + bundle locally to verify signing succeeds**

```bash
swift build -c release --arch arm64
./bundle.sh
ls NoNoiseMac.app/Contents/Frameworks/Sparkle.framework/Versions/Current
otool -L NoNoiseMac.app/Contents/MacOS/NoNoiseMac | grep -i sparkle
```
Expected: `codesign --verify --deep --strict` returns silently (exit 0); framework contents listed; the binary references `@rpath/Sparkle.framework/.../Sparkle`.

- [ ] **Step 3: Smoke-test the app launches with Sparkle linked**

Run: `open NoNoiseMac.app`
Expected: the menu-bar icon appears (no dyld crash). Popover footer shows "Check for Updates…"; clicking it shows Sparkle's check UI (it may report up-to-date or fail to reach the feed until the first release publishes the appcast — both fine here).

- [ ] **Step 4: Commit**

```bash
git add bundle.sh
git commit -m "build(updater): embed and inside-out sign Sparkle.framework in the app bundle"
```

---

## Task 10: release.yml — sign, generate/verify/publish appcast

**Files:**
- Modify: `.github/workflows/release.yml`

**Prerequisite:** the `SPARKLE_PRIVATE_KEY` secret from Task 3. CI does NOT stamp the version — it trusts the committed `Info.plist` and asserts it matches the tag.

- [ ] **Step 1: Run the version-helper test in CI**

After the `- name: Show Swift version` step, add:

```yaml
      - name: Test updater version helper
        run: ./scripts/version-from-tag.test.sh
```

- [ ] **Step 2: Decide whether this is an updater release**

After the existing `- name: Resolve release target` step (id `release_target`), add:

```yaml
      - name: Resolve updater eligibility
        id: updater
        run: |
          TAG="${{ steps.release_target.outputs.tag }}"
          IS_STABLE="${{ steps.release_target.outputs.is_stable }}"
          if [ "$IS_STABLE" = "true" ]; then
            echo "is_updater_release=false" >> "$GITHUB_OUTPUT"
            echo "Rolling main build — excluded from the updater appcast."
            exit 0
          fi
          if VERS=$(./scripts/version-from-tag.sh "$TAG"); then
            eval "$VERS"   # expected short / build, derived from the tag
            echo "is_updater_release=true" >> "$GITHUB_OUTPUT"
            echo "expected_short=$short" >> "$GITHUB_OUTPUT"
            echo "expected_build=$build" >> "$GITHUB_OUTPUT"
            echo "Updater release: expected $short (build $build)"
          else
            echo "is_updater_release=false" >> "$GITHUB_OUTPUT"
            echo "Tag $TAG is not a stable vX.Y.Z release — excluded from the updater appcast."
          fi
```

(Leave the existing `Bundle app, CLI, and driver` step unchanged — no env, no stamping.)

- [ ] **Step 3: Add the appcast step after the release is published**

After the existing `- name: Publish GitHub Release` step (so the versioned `.app.zip` asset already exists), add:

```yaml
      - name: Generate, verify & publish Sparkle appcast
        if: steps.updater.outputs.is_updater_release == 'true'
        env:
          GH_TOKEN: ${{ github.token }}
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
          EXPECTED_SHORT: ${{ steps.updater.outputs.expected_short }}
          EXPECTED_BUILD: ${{ steps.updater.outputs.expected_build }}
        run: |
          set -euo pipefail
          TAG="${{ steps.release_target.outputs.tag }}"
          TARGET_SHA="${{ steps.release_target.outputs.target_sha }}"
          ZIP="release-assets/NoNoiseMac-${TAG}.app.zip"
          FEED_URL="https://github.com/ivalsaraj/NoNoise-Mac/releases/download/appcast/appcast.xml"

          # Sparkle CLI tools come from the SwiftPM build artifacts.
          GEN="$(find .build -type f -name generate_appcast | head -1)"
          [ -n "$GEN" ] || { echo "generate_appcast not found in .build"; exit 1; }

          # Private EdDSA key (secret) -> temp file for --ed-key-file.
          KEYFILE="$(mktemp)"; trap 'rm -f "$KEYFILE"' EXIT
          printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEYFILE"

          # generate_appcast reads the (release.sh-stamped) Info.plist inside the zip for the version
          # fields and signs the archive; --download-url-prefix sets the enclosure to this release's asset.
          mkdir -p sparkle-feed
          cp "$ZIP" sparkle-feed/
          "$GEN" --ed-key-file "$KEYFILE" \
                 --download-url-prefix "https://github.com/ivalsaraj/NoNoise-Mac/releases/download/${TAG}/" \
                 sparkle-feed/
          APPCAST="sparkle-feed/appcast.xml"
          [ -f "$APPCAST" ] || { echo "appcast.xml was not generated"; exit 1; }

          # --- Assertions: tag <-> committed plist <-> appcast <-> asset must all agree. ---
          rm -rf /tmp/zipcheck && unzip -o -q "$ZIP" -d /tmp/zipcheck
          PLIST="/tmp/zipcheck/NoNoiseMac.app/Contents/Info.plist"
          ZBUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
          ZSHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
          ZFEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PLIST")
          ACVER=$(xmllint --xpath 'string(//*[local-name()="version"])' "$APPCAST")
          ACSHORT=$(xmllint --xpath 'string(//*[local-name()="shortVersionString"])' "$APPCAST")
          ACURL=$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@url)' "$APPCAST")
          # committed plist must match what release.sh should have stamped for this tag
          [ "$ZBUILD" = "$EXPECTED_BUILD" ] || { echo "committed CFBundleVersion $ZBUILD != expected $EXPECTED_BUILD (was release.sh used?)"; exit 1; }
          [ "$ZSHORT" = "$EXPECTED_SHORT" ] || { echo "committed short $ZSHORT != expected $EXPECTED_SHORT"; exit 1; }
          # appcast must match the committed plist
          [ "$ACVER" = "$ZBUILD" ]   || { echo "appcast sparkle:version $ACVER != plist $ZBUILD"; exit 1; }
          [ "$ACSHORT" = "$ZSHORT" ] || { echo "appcast shortVersionString $ACSHORT != plist $ZSHORT"; exit 1; }
          # feed URL + enclosure must be exact
          [ "$ZFEED" = "$FEED_URL" ] || { echo "shipped SUFeedURL $ZFEED != $FEED_URL"; exit 1; }
          case "$ACURL" in
            *"NoNoiseMac-${TAG}.app.zip") echo "enclosure URL ok: $ACURL" ;;
            *) echo "appcast enclosure URL '$ACURL' must end with NoNoiseMac-${TAG}.app.zip"; exit 1 ;;
          esac

          # --- Publish appcast.xml to the fixed `appcast` release tag (auto-create first time). ---
          if gh release view appcast >/dev/null 2>&1; then
            gh release upload appcast "$APPCAST" --clobber
          else
            gh release create appcast "$APPCAST" \
              --title "Sparkle update feed" \
              --notes "Auto-update appcast for NoNoise Mac. Managed by CI — do not delete." \
              --target "$TARGET_SHA"
          fi
          echo "Published appcast for $ZSHORT (build $ZBUILD)."
```

- [ ] **Step 4: Lint the workflow YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"`
Expected: `YAML OK`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci(updater): sign archive and publish verified Sparkle appcast for vX.Y.Z releases"
```

---

## Task 11: Documentation

**Files:**
- Modify: `README.md`, `AGENTS.md`, `docs/knowledge/INDEX.md` + the ACTIVE `docs/knowledge/knowledge*.md` and `docs/knowledge/timeline*.md`

- [ ] **Step 1: README "Updating" section**

Add to `README.md`:

```markdown
## Updating

NoNoise Mac updates itself with [Sparkle](https://sparkle-project.org). It checks for new
**stable** releases on launch and daily; when one is available you'll get a native
"A new version is available" prompt, or use **Check for Updates…** in the popover.

**First install only:** the updater ships starting with the first Sparkle-enabled release.
If you're on an older build, download that first release manually (right-click → Open, since the
app is ad-hoc signed). After that, updates are automatic.
```

- [ ] **Step 2: AGENTS.md auto-update section**

Add a new section to `AGENTS.md` (after "## Entitlements & signing"):

```markdown
## Auto-update (Sparkle)
- The app embeds **Sparkle 2** (SwiftPM, app target only). The updater is created at launch in
  `NoNoiseMacApp.init()` (`UpdaterController`), same singleton rule as the other launch objects.
- **`CFBundleVersion` is a MONOTONIC INTEGER** (`MAJOR*1000000+MINOR*1000+PATCH`), NOT semver —
  Sparkle compares it against the installed bundle version. `scripts/version-from-tag.sh` is the
  single source of that mapping (tested by `scripts/version-from-tag.test.sh`); **`release.sh` calls
  it** to stamp `Info.plist`. Keep minor/patch < 1000. Do NOT reintroduce the old
  `MAJOR.MINOR`-digits formula — it ignored PATCH and wasn't monotonic.
- **Versioning is owned by `release.sh`** (it bumps + commits + tags). CI does NOT re-stamp; it
  trusts the committed `Info.plist` and asserts plist↔tag↔appcast↔asset all agree.
- **`bundle.sh` signs inside-out (never `--deep`):** nested Sparkle code gets `-o runtime`, the outer
  app stays ad-hoc with no Hardened Runtime. `release.yml` signs the zip, runs `generate_appcast`,
  asserts, and publishes `appcast.xml` to the fixed `appcast` release tag.
- **`SUFeedURL`** (Info.plist) must equal `…/releases/download/appcast/appcast.xml`. Public EdDSA key
  is in Info.plist (`SUPublicEDKey`); the **private key is the `SPARKLE_PRIVATE_KEY` GitHub secret**,
  escrowed separately — losing it forces every user to reinstall, so never regenerate it casually.
```

- [ ] **Step 3: Knowledge + timeline entries**

Append a `[DECISION]` entry to the ACTIVE `docs/knowledge/knowledge*.md` (highest-numbered; update its top-of-file summary and `docs/knowledge/INDEX.md`):

```markdown
## 2026-06-15 — [DECISION] Sparkle auto-updater + monotonic CFBundleVersion (@ivalsaraj)

**Problem**: No update mechanism; wanted Voquill-style "update available" for a native Swift menu-bar app.
**Root Cause**: Voquill is Tauri (plugin-updater) — not portable; the native macOS equivalent is Sparkle. Also: release.sh's CFBundleVersion formula (MAJOR.MINOR digits) ignored PATCH and wasn't monotonic, which breaks Sparkle's version comparison.
**Fix**: Sparkle 2 via SwiftPM; EdDSA-signed appcast on a fixed `appcast` GitHub release tag; ad-hoc app + Library-Validation-off EdDSA trust path; inside-out signing (no `--deep`). release.sh now stamps a MONOTONIC CFBundleVersion via scripts/version-from-tag.sh; CI asserts plist↔tag↔appcast↔asset. See docs/plans/2026-06-15-sparkle-auto-updater.md.
**Rule**: Sparkle's CFBundleVersion must be a monotonic integer that exceeds every previously shipped value; never reuse a dotted semver or the MAJOR.MINOR-digits formula for it.
**Files**: Package.swift, Resources/Info.plist, Sources/App/UpdaterController.swift, NoNoiseMacApp.swift, ContentView.swift, release.sh, bundle.sh, .github/workflows/release.yml, scripts/version-from-tag.sh
```

Append a timeline entry to the ACTIVE `docs/knowledge/timeline*.md` summarizing the change set + rationale.

- [ ] **Step 4: Commit**

```bash
git add README.md AGENTS.md docs/knowledge
git commit -m "docs(updater): document Sparkle auto-update, monotonic versioning, signing, key escrow"
```

---

## Task 12: End-to-end verification (manual, real run)

Validates the actual update path — not a mock. Requires Task 3's keys + the `SPARKLE_PRIVATE_KEY` secret.

- [ ] **Step 1: Cut the first updater-enabled release with release.sh**

Write notes to a file, then (from a clean `main`):
```bash
printf '## What'\''s New\n\n- Added automatic in-app updates.\n' > /tmp/notes.md
./release.sh 1.3.0 --notes-file /tmp/notes.md
```
Expected: release.sh bumps Info.plist (`CFBundleShortVersionString=1.3.0`, `CFBundleVersion=1003000`), commits, tags `v1.3.0`, pushes. In the Actions log: "Test updater version helper" passed, "Updater release: expected 1.3.0 (build 1003000)", all assertions passed, "Published appcast…". Confirm the feed:
```bash
curl -sL https://github.com/ivalsaraj/NoNoise-Mac/releases/download/appcast/appcast.xml | head
```
Expected: appcast with `<sparkle:version>1003000</sparkle:version>` and the `v1.3.0` enclosure URL.

- [ ] **Step 2: Install v1.3.0 manually**

Download `NoNoiseMac-v1.3.0.app.zip`, unzip into `/Applications`, right-click → Open. Confirm it runs and the popover shows "Check for Updates…".

- [ ] **Step 3: Cut a second release and confirm auto-update**

```bash
printf '## Bug Fixes\n\n- Verified the auto-update path end to end.\n' > /tmp/notes2.md
./release.sh 1.3.1 --notes-file /tmp/notes2.md
```
After CI finishes, in the running v1.3.0 click **Check for Updates…** (or wait for the launch/scheduled check).
Expected: Sparkle shows "A new version is available (1.3.1)", downloads, EdDSA-verifies, installs in place, relaunches as 1.3.1. Verify:
```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/NoNoiseMac.app/Contents/Info.plist
```
Expected: `1.3.1`.

- [ ] **Step 4: Accessory-app dialog check**

Confirm the Sparkle window appears front-most over the menu-bar (`LSUIElement`) app for both a manual check and a scheduled/background-found update. If not, note it for a follow-up (`userDriverDelegate` / activation tweak) — do not block the release.

- [ ] **Step 5: No commit** — verification only. Record the result in the PR / issue.

---

## Self-review notes (author checklist — already applied)

- **Spec coverage:** detection (Tasks 5–6), UI (Task 7), download+install (Sparkle, Tasks 2/4/9), versioning (Tasks 1/8), hosting + signing (Tasks 9/10). All design sections map to a task.
- **release.sh reconciliation:** versioning stays single-source in `release.sh` (Task 8); CI asserts, never re-stamps (Task 10). No guard-pair divergence.
- **CRITICAL fix present:** monotonic `CFBundleVersion` in Tasks 1/8, asserted in Task 10.
- **Type/contract consistency:** `UpdaterController` API (`controller`/`updater`/`canCheckForUpdates`/`checkForUpdates()`) consistent across Tasks 5/6/7. `version-from-tag.sh` output keys (`short`/`build`) consistent across Tasks 1/8/10. `SUFeedURL` identical in Tasks 4/10. `NoNoiseMac-<TAG>.app.zip` matches `release.yml`'s existing asset name.
- **No placeholders** except the intentional `PASTE_PUBLIC_KEY_FROM_TASK_3` (runtime value from Task 3) and the maintainer-supplied secret.
```
