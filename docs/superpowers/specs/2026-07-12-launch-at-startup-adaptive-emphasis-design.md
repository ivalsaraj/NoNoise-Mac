# Launch at Startup Adaptive Emphasis

## Goal

Make Launch at Startup discoverable while it still needs user action, without allowing an
infrequently changed preference to consume the same vertical space as the audio controls after it
has been configured.

## Approved design

The Launch at Startup control remains in the General tab near the top, before the audio controls,
but has two visual states:

- **Needs attention:** `.notRegistered`, `.requiresApproval`, `.notFound`, or an error shows the
  existing full-width card. The card includes the title `Launch at Startup (Recommended)`, its
  explanatory subtitle, the toggle, and any status/error guidance and recovery button.
- **Enabled:** `.enabled` shows a full-width compact row in the same location. It retains the title,
  `Recommended` label, and toggle, but removes the explanatory subtitle, extra card padding, and
  status guidance so it takes minimal vertical space.

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
- Existing refresh-on-settings-open behavior remains unchanged.
- The startup setting does not move into `AudioModel`, Voice Profiles, or the audio reset list.

## Implementation surface

- Modify `Sources/App/SettingsView.swift` only unless compilation requires initializer plumbing.
- Keep the existing `LaunchAtLoginManager` API and Service Management behavior unchanged.
- Reuse the existing settings card styling; do not introduce a new dependency or settings section.

## Verification

- Build the app target with `swift build`.
- Run `swift test --filter LaunchAtLoginStateTests`.
- Run `swift test` for the full suite.
- Confirm the settings stack and both Launch at Startup states use the full available width.
- Confirm the disabled/approval/error state remains prominent and the enabled state is compact.
