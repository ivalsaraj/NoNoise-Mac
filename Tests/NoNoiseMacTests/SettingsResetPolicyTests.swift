import XCTest
@testable import Core

final class SettingsResetPolicyTests: XCTestCase {
    func testResetRemovesAudioSettingsButPreservesProfilesAndHotkeys() throws {
        let suiteName = "SettingsResetPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for key in SettingsResetPolicy.resettableKeys {
            defaults.set("changed", forKey: key)
        }
        defaults.set(Data([1, 2, 3]), forKey: SettingsResetPolicy.profilesKey)
        defaults.set("12:34", forKey: HotkeyActionID.toggleAI.prefKey)

        SettingsResetPolicy.reset(defaults: defaults)

        for key in SettingsResetPolicy.resettableKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should be reset")
        }
        XCTAssertNotNil(defaults.object(forKey: SettingsResetPolicy.profilesKey))
        XCTAssertEqual(defaults.string(forKey: HotkeyActionID.toggleAI.prefKey), "12:34")
    }
}
