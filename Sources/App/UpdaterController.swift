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
