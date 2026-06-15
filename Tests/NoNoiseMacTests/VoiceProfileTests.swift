import XCTest
@testable import Core

final class VoiceProfileTests: XCTestCase {

    // MARK: - Round-trip encoding

    /// A profile must encode to JSON and decode back without data loss.
    func testProfileRoundTrips() throws {
        let profile = VoiceProfile(
            id: UUID(),
            name: "Solo Narration",
            preset: .podcast,
            suppressionStrength: 0.85,
            attenuationLimitDb: 24.0,
            outputGainValue: 1.2,
            voicePolishEnabled: true,
            clarityLevel: .medium
        )
        let data = try VoiceProfile.encoder.encode(profile)
        let decoded = try VoiceProfile.decoder.decode(VoiceProfile.self, from: data)
        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.name, profile.name)
        XCTAssertEqual(decoded.preset, profile.preset)
        XCTAssertEqual(decoded.suppressionStrength, profile.suppressionStrength, accuracy: 1e-6)
        XCTAssertEqual(decoded.attenuationLimitDb, profile.attenuationLimitDb, accuracy: 1e-6)
        XCTAssertEqual(decoded.outputGainValue, profile.outputGainValue, accuracy: 1e-6)
        XCTAssertEqual(decoded.voicePolishEnabled, profile.voicePolishEnabled)
        XCTAssertEqual(decoded.clarityLevel, profile.clarityLevel)
        XCTAssertEqual(decoded.version, 1)
    }

    // MARK: - Extensibility: unknown fields are tolerated (schema forward-compatibility)

    /// A JSON payload with unknown fields (e.g. from a future plan's additions) must decode
    /// without error — the decoder silently ignores unknown keys.
    func testUnknownFieldsAreIgnored() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "version": 1,
          "name": "Test",
          "preset": "podcast",
          "suppression_strength": 1.0,
          "attenuation_limit_db": 24.0,
          "output_gain_value": 1.0,
          "voice_polish_enabled": true,
          "clarity_level": "off",
          "lufs_target": -16.0,
          "normalization_enabled": true,
          "deplosive_level": 0.5,
          "declick_level": 0.3
        }
        """.data(using: .utf8)!
        let decoded = try VoiceProfile.decoder.decode(VoiceProfile.self, from: json)
        XCTAssertEqual(decoded.name, "Test")
        XCTAssertEqual(decoded.preset, .podcast)
        // Future optional fields should not cause decoding failure.
        // (They are nil since VoiceProfile v1 doesn't declare them yet.)
    }

    // MARK: - Extensibility: missing optional future fields default gracefully

    /// A JSON payload WITHOUT optional fields (i.e. produced by an older version)
    /// must decode cleanly — missing optional fields default to nil.
    func testMissingOptionalFieldsDefaultToNil() throws {
        // This represents a minimal v1 payload with no future extension fields.
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000002",
          "version": 1,
          "name": "Minimal",
          "preset": "meeting",
          "suppression_strength": 1.0,
          "attenuation_limit_db": 100.0,
          "output_gain_value": 1.0,
          "voice_polish_enabled": false,
          "clarity_level": "off"
        }
        """.data(using: .utf8)!
        let decoded = try VoiceProfile.decoder.decode(VoiceProfile.self, from: json)
        XCTAssertEqual(decoded.name, "Minimal")
        XCTAssertEqual(decoded.preset, .meeting)
        // Confirm decoding succeeds cleanly with no future fields present.
        XCTAssertEqual(decoded.version, 1)
    }

    // MARK: - Version field is always present

    func testEncodedPayloadContainsVersionField() throws {
        let profile = VoiceProfile.makeDefault(name: "Test")
        let data = try VoiceProfile.encoder.encode(profile)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["version"], "encoded payload must always include a version field")
    }

    // MARK: - Default factory

    /// makeDefault produces a valid profile from the Meeting preset defaults.
    func testMakeDefaultIsValid() {
        let p = VoiceProfile.makeDefault(name: "New Profile")
        XCTAssertEqual(p.name, "New Profile")
        XCTAssertEqual(p.preset, .meeting)
        XCTAssertEqual(p.suppressionStrength, 1.0, accuracy: 1e-6)
        XCTAssertEqual(p.attenuationLimitDb, VoicePreset.maxAttenuationDb, accuracy: 1e-6)
        XCTAssertEqual(p.outputGainValue, 1.0, accuracy: 1e-6)
        XCTAssertFalse(p.voicePolishEnabled == false && p.clarityLevel == .off, "defaults should be sane")
    }

    // MARK: - Unique IDs

    func testProfileIDsAreUnique() {
        let a = VoiceProfile.makeDefault(name: "A")
        let b = VoiceProfile.makeDefault(name: "B")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - VoiceProfileStore CRUD

    func testSaveAddsProfile() {
        var store = VoiceProfileStore()
        let p = VoiceProfile.makeDefault(name: "Podcast")
        store.save(p)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.name, "Podcast")
    }

    func testSaveUpdatesExistingProfile() {
        var store = VoiceProfileStore()
        var p = VoiceProfile.makeDefault(name: "Original")
        store.save(p)
        p.name = "Updated"
        store.save(p)
        // Same UUID → update in place, not duplicate.
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.name, "Updated")
    }

    func testDeleteRemovesProfile() {
        var store = VoiceProfileStore()
        let p = VoiceProfile.makeDefault(name: "To Delete")
        store.save(p)
        store.delete(id: p.id)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testDeleteNonExistentIDIsNoOp() {
        var store = VoiceProfileStore()
        store.save(VoiceProfile.makeDefault(name: "Keep"))
        store.delete(id: UUID())   // random ID not in store
        XCTAssertEqual(store.profiles.count, 1)
    }

    func testRenameUpdatesName() {
        var store = VoiceProfileStore()
        let p = VoiceProfile.makeDefault(name: "Old Name")
        store.save(p)
        store.rename(id: p.id, to: "New Name")
        XCTAssertEqual(store.profiles.first?.name, "New Name")
    }

    func testRenameNonExistentIDIsNoOp() {
        var store = VoiceProfileStore()
        store.save(VoiceProfile.makeDefault(name: "Safe"))
        store.rename(id: UUID(), to: "Ghost")
        XCTAssertEqual(store.profiles.first?.name, "Safe")
    }

    func testProfileByIDReturnsCorrectProfile() {
        var store = VoiceProfileStore()
        let a = VoiceProfile.makeDefault(name: "A")
        let b = VoiceProfile.makeDefault(name: "B")
        store.save(a)
        store.save(b)
        XCTAssertEqual(store.profile(id: a.id)?.name, "A")
        XCTAssertEqual(store.profile(id: b.id)?.name, "B")
        XCTAssertNil(store.profile(id: UUID()))
    }

    func testOrderIsStableAfterMultipleInserts() {
        var store = VoiceProfileStore()
        let names = ["Zzz", "Aaa", "Mmm"]
        names.forEach { store.save(VoiceProfile.makeDefault(name: $0)) }
        // Insertion order preserved (not sorted).
        XCTAssertEqual(store.profiles.map(\.name), names)
    }

    // MARK: - VoiceProfileStore serialization round-trip

    func testStoreEncodesAndDecodesProfiles() throws {
        var store = VoiceProfileStore()
        store.save(VoiceProfile(
            name: "Interview",
            preset: .podcast,
            suppressionStrength: 0.9,
            attenuationLimitDb: 24.0,
            outputGainValue: 1.1,
            voicePolishEnabled: true,
            clarityLevel: .low
        ))
        let data = try store.encodeToJSON()
        let restored = try VoiceProfileStore.decode(from: data)
        XCTAssertEqual(restored.profiles.count, 1)
        XCTAssertEqual(restored.profiles.first?.name, "Interview")
        XCTAssertEqual(restored.profiles.first?.preset, .podcast)
        XCTAssertEqual(restored.profiles.first?.clarityLevel, .low)
    }

    func testDecodeEmptyArrayReturnsEmptyStore() throws {
        let data = "[]".data(using: .utf8)!
        let store = try VoiceProfileStore.decode(from: data)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testDecodeCorruptJSONReturnsEmptyStore() {
        let bad = "NOT_JSON".data(using: .utf8)!
        let store = VoiceProfileStore.decodeSafe(from: bad)
        XCTAssertTrue(store.profiles.isEmpty, "corrupt JSON must not crash — return empty store")
    }

    /// Profiles with unknown/future fields survive a store decode round-trip.
    func testDecodeToleratesProfilesWithUnknownFields() throws {
        let json = """
        [
          {
            "id": "00000000-0000-0000-0000-000000000099",
            "version": 1,
            "name": "Future",
            "preset": "tutorial",
            "suppression_strength": 0.8,
            "attenuation_limit_db": 40.0,
            "output_gain_value": 1.0,
            "voice_polish_enabled": true,
            "clarity_level": "high",
            "lufs_target": -16.0
          }
        ]
        """.data(using: .utf8)!
        let store = try VoiceProfileStore.decode(from: json)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.name, "Future")
        XCTAssertEqual(store.profiles.first?.preset, .tutorial)
    }

    // MARK: - applyProfile shape contract (pure logic, no AudioModel)

    /// Verify that the VoiceProfile produced by "save current settings" round-trips
    /// through the store and can be reconstructed exactly — this is the invariant
    /// that applyProfile must restore. Tested here without AudioModel.
    func testSavedProfileMatchesInputSettings() throws {
        let preset = VoicePreset.podcast
        let profile = VoiceProfile(
            name: "Consistency Check",
            preset: preset,
            suppressionStrength: 0.75,
            attenuationLimitDb: 30.0,
            outputGainValue: 1.3,
            voicePolishEnabled: false,
            clarityLevel: .high
        )
        var store = VoiceProfileStore()
        store.save(profile)
        let data = try store.encodeToJSON()
        let restored = try VoiceProfileStore.decode(from: data)
        let r = try XCTUnwrap(restored.profile(id: profile.id))
        XCTAssertEqual(r.suppressionStrength, profile.suppressionStrength, accuracy: 1e-6)
        XCTAssertEqual(r.attenuationLimitDb, profile.attenuationLimitDb, accuracy: 1e-6)
        XCTAssertEqual(r.outputGainValue, profile.outputGainValue, accuracy: 1e-6)
        XCTAssertEqual(r.voicePolishEnabled, profile.voicePolishEnabled)
        XCTAssertEqual(r.clarityLevel, profile.clarityLevel)
        XCTAssertEqual(r.preset, profile.preset)
    }

    /// Verify that ordering is preserved across a JSON encode/decode round-trip
    /// (the UI must show profiles in the order they were saved, not sorted).
    func testStorePreservesInsertionOrderAfterRoundTrip() throws {
        var store = VoiceProfileStore()
        let names = ["First", "Second", "Third"]
        names.forEach { store.save(VoiceProfile.makeDefault(name: $0)) }
        let data = try store.encodeToJSON()
        let restored = try VoiceProfileStore.decode(from: data)
        XCTAssertEqual(restored.profiles.map(\.name), names)
    }
}
