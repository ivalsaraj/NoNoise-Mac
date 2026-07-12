# Launch at Startup Adaptive Emphasis

## Goal

Make Launch at Startup discoverable while it still needs user action, without allowing an
infrequently changed preference to consume the same vertical space as the audio controls after it
has been configured.

## Approved design

The Launch at Startup control remains in the General tab near the top, before the audio controls,
but has two visual states:

- **Needs attention:** `.notRegistered`, `.requiresApproval`, `.notFound`, or an error shows the
  existing full-width card. The card includes the title `Launch at Startup`, a visually secondary
  `Recommended` badge, its explanatory subtitle, the toggle, and one deduplicated status/error
  guidance block. `Open Login Items` is shown only for `.requiresApproval`; `.notFound` explains
  that the installed bundled app must be launched and does not show a Login Items recovery button.
- **Enabled:** `.enabled` shows a full-width compact row in the same location. It retains the title,
  the same visually secondary `Recommended` badge, and toggle, but removes the explanatory
  subtitle, extra card padding, and status guidance so it takes minimal vertical space. Its
  accessibility label remains `Launch at Startup, recommended`.

Both states stretch to the settings content width with a leading-aligned frame. The surrounding
General tab stack also stretches to the available width so the control does not shrink to its
content size.

## Interaction and state rules

- The toggle continues to use a custom `Binding<Bool>` backed by `LaunchAtLoginManager` rather than
  binding directly to a writable published property.
- The compact state is selected only when `launchAtLoginManager.state == .enabled` and there is no
  error message.
- Any approval, bundled-app, or registration error keeps the expanded card visible so the user can
  understand and recover from it.
- Existing refresh-on-settings-open behavior remains, and the manager performs a one-shot refresh
  when the Settings panel regains key focus after the user returns from Login Items. The refresh is
  armed only when `Open Login Items` is invoked, observes `NSWindow.didBecomeKeyNotification` for
  that panel once, then disarms. Close/dispose also disarms it. Do not add a polling timer.
- `refresh(clearOperationError:)` has explicit semantics. External/open/focus refreshes pass `true`
  and clear an obsolete operation error after reading the system status. The mutation path passes
  `false` after `register()`/`unregister()` so a failed operation's error remains visible; a
  successful mutation clears the error before refreshing.
- `.notFound` explains that the installed bundled app must be launched and does not request System
  Settings guidance. `LaunchAtLoginState.needsSystemSettings` and its tests must reflect that only
  `.requiresApproval` needs Login Items guidance.
- Guidance has a deterministic single-block resolver: `.requiresApproval` wins and includes the
  Login Items button; `.notFound` shows bundled-app guidance without a button; otherwise a current
  operation error is shown. Never render more than one guidance block.
- Both expanded and compact toggles use the accessibility label `Launch at Startup, recommended`
  with the normal switch role. The visible Recommended badge is hidden from accessibility to avoid
  announcing it twice.
- The startup setting does not move into `AudioModel`, Voice Profiles, or the audio reset list.

## Implementation surface

- Modify `Sources/App/SettingsView.swift`, `Sources/App/LaunchAtLoginManager.swift`,
  `Sources/App/ContentView.swift`, `Sources/Core/LaunchAtLoginState.swift`, and
  `Tests/NoNoiseMacTests/LaunchAtLoginStateTests.swift` for the state, presentation, and one-shot
  focus-refresh contracts.
- Keep the existing Service Management source of truth and app-lifetime ownership unchanged.
- Reuse the existing settings card styling; do not introduce a new dependency or settings section.
- Do not reorder, wrap, or otherwise alter the existing Noise Suppression, Input Volume, Voice
  Profiles, Output Gain, Incoming Cleanup, or Loudness cards. The enabled state is one compact toggle
  row; the expanded state contains one guidance block and does not duplicate error/status actions.

## Verification

- Build the app target with `swift build`.
- Run `swift test --filter LaunchAtLoginStateTests`.
- Run `swift test` for the full suite.
- Confirm the settings stack and both Launch at Startup states use the full available width.
- Confirm the disabled/approval/error state remains prominent and the enabled state is compact.
- Confirm returning from Login Items updates the visible state without reopening Settings.
- Confirm a stale registration error disappears after a successful external refresh.
- Confirm `.notFound` has no misleading Login Items button and the existing audio-card order is
  unchanged.
- Test the presentation matrix for every state with and without an error: compact eligibility,
  guidance precedence, and `.notFound` action suppression.
- Test that the Login Items return refresh fires once after the panel becomes key, not on every
  subsequent focus change.
