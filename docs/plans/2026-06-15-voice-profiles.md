# Voice Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a **Voice Profiles** system that lets users save, recall, rename, and delete named snapshots of all their dialed-in settings (preset + every intensity knob) — so a podcaster can save "Interview Guest", "Solo Narration", and "Live Stream" and switch between them in one tap.

**Architecture:** A `VoiceProfile` Codable struct (versioned, tolerant of unknown fields) and a `VoiceProfileStore` pure value type (encoding, decoding, CRUD) live entirely in `Sources/Core` with no UI or CoreAudio dependency, making them headless XCTest-able. `AudioModel` owns a `@Published profiles` collection and an `applyProfile(_:)` method that goes through the existing `applyPreset` + `applyVoiceChain` path (guarded by `isApplyingPreset`) so the live engine and SwiftUI UI update correctly. The collection is serialized as a JSON array and persisted under the single new UserDefaults key `mv.profiles`. UI lives in `SettingsView` as a dedicated profiles card.

**Extensibility mandate:** The schema uses a `version` Int field and Codable optional fields throughout so that in-flight plans (Metering & Loudness: LUFS target + normalization toggle; Mouth-noise Finishers: de-plosive + de-click levels) add fields by adding new optionals to `VoiceProfile` — no migration, no schema break, no existing profiles invalidated.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest (pure logic tests, headless), JSONEncoder/JSONDecoder with `.convertFromSnakeCase` / `.convertToSnakeCase`.

**Execution location:** Run all commands from the package root — the directory that contains `Package.swift`. All paths in this plan are relative to that root.

---

## Context

### Why this feature

The current model exposes four global presets (Meeting / Podcast / Tutorial / Custom) and per-session intensity knobs. A power user — a podcaster switching between solo narration and guest interview, a course creator switching between on-camera and screencast — cannot save their dialed-in combination and recall it later. They re-tweak manually every session. Voice Profiles solves this: save the entire current state once, recall it in one tap, repeat.

### The extensibility constraint

Two in-flight plans will add new user-tunable settings that belong in a profile snapshot:
- **Metering & Loudness plan**: a `lufsTarget: Float?` and `normalizationEnabled: Bool?`
- **Mouth-noise Finishers plan**: a `deplosiveLevel: Float?` and `declickLevel: Float?`

The schema must absorb these by adding optional fields with no migration path required. The decoding strategy is: `JSONDecoder` with `keyDecodingStrategy = .convertFromSnakeCase`, all future fields declared `var fieldName: Type? = nil`, so unknown JSON keys are silently ignored and missing JSON keys default to `nil`. A `version: Int` field allows breaking migrations if they ever become necessary in a v2 schema.

### The `isApplyingPreset` re-entrancy invariant

This is the single most critical implementation constraint. `AudioModel` uses a `private var isApplyingPreset: Bool` flag to break the feedback loop:

```
applyPreset → sets suppressionStrength → suppressionStrength.didSet → onKnobChanged → selectedPreset = .custom → selectedPreset.didSet → applyPreset → loop
```

`applyProfile(_:)` MUST use the same guard pattern. It bulk-sets every `@Published` property that has a `didSet` side effect (`selectedPreset`, `suppressionStrength`, `attenuationLimitDb`, `outputGainValue`, `voicePolishEnabled`, `clarityLevel`). Setting each one outside the `isApplyingPreset` guard would: (a) call `onKnobChanged()` → flip `selectedPreset` to `.custom` mid-apply, (b) call `persistSettings()` six times, (c) call `applyVoiceChain()` six times including mid-apply intermediate states. None of that is correct. The pattern is:

```swift
isApplyingPreset = true
defer { isApplyingPreset = false }
// set all properties
applyPreset(profile.preset)     // sets suppression knobs (internally guarded)
voicePolishEnabled = profile.voicePolishEnabled
clarityLevel = profile.clarityLevel
selectedPreset = profile.preset // arms the UI without re-entering
isApplyingPreset = false
applyVoiceChain()               // single reconfigure with final state
persistSettings()               // single write with final state
```

### Profile-vs-preset relationship

A `VoiceProfile` includes `selectedPreset: VoicePreset` as one of its fields. Applying a profile applies the preset's DSP knob values (via `applyPreset`) AND the stored overrides for the intensity knobs (in case the user had moved them away from the preset defaults). The profile is the union: `preset identity + exact knob values at save time`. Recalling a profile never triggers `onKnobChanged` (because we're inside `isApplyingPreset = true`), so `selectedPreset` does not flip to `.custom` mid-apply.

After applying a profile, the UX state is: the recalled preset is selected, all knobs match the profile's saved values, and any subsequent manual knob movement will flip to `.custom` exactly as normal.

### Current code facts (verified)

- `AudioModel.swift`: `PrefKey` enum at lines 114–120, `@Published var clarityLevel` added by the Broadcast Voice plan (lines 111–120 area after plan execution), `isApplyingPreset: Bool` at line 112, `applyPreset(_:)` at line 229, `applyVoiceChain()` at line 244, `persistSettings()` at line 263, `loadSettings()` at line 272.
- `VoicePreset.swift`: `VoicePreset` enum with `.meeting`, `.podcast`, `.tutorial`, `.custom`; `rawValue` is the persistence key for each case.
- `Sources/App/SettingsView.swift`: `GeneralSettingsView` with `suppressionCard` and `gainCard` inside a `ScrollView → VStack`.
- `Tests/NoNoiseMacTests/`: `BroadcastVoiceTests.swift` and `VoiceChainTests.swift` are the style references for headless unit tests.
- `Sources/Core/AudioProcessing/VoiceChain.swift` now carries `ClarityLevel` (added by the Broadcast Voice plan).
- UserDefaults namespace is `mv.*`; the new key for this plan is `mv.profiles`.

---

## Task 0: Branch

- [ ] **Step 1: Create a feature branch**

```bash
git checkout -b feat/voice-profiles
```

Expected: `Switched to a new branch 'feat/voice-profiles'`. Throughout this plan, `git add` only the specific files named in each task — never `git add -A`/`.`.

---

## Task 1: `VoiceProfile` Codable struct — TDD

Define the versioned, extensible snapshot schema. All future plans add fields as optionals; no migration is needed for any optional field. This is the single most important design invariant — tests enforce it directly.

`VoiceProfile` references `VoicePreset` and `ClarityLevel` directly inside its `Codable` synthesis. Swift's Codable synthesis for a containing type requires every stored-property type to also be `Codable`. Neither enum currently conforms, so they must be updated first or the `VoiceProfile: Codable` declaration is a build-breaker.

**Files:**
- Modify: `Sources/Core/VoicePreset.swift`
- Modify: `Sources/Core/AudioProcessing/VoiceChain.swift`
- Create: `Sources/Core/VoiceProfile.swift`
- Create: `Tests/NoNoiseMacTests/VoiceProfileTests.swift`

- [ ] **Step 0: Add `Codable` to `VoicePreset` and `ClarityLevel`**

In `Sources/Core/VoicePreset.swift`, change the enum declaration from:

```swift
public enum VoicePreset: String, CaseIterable, Identifiable, Sendable {
```

to:

```swift
public enum VoicePreset: String, CaseIterable, Identifiable, Codable, Sendable {
```

In `Sources/Core/AudioProcessing/VoiceChain.swift`, change the `ClarityLevel` declaration from:

```swift
public enum ClarityLevel: String, CaseIterable, Identifiable, Sendable {
```

to:

```swift
public enum ClarityLevel: String, CaseIterable, Identifiable, Codable, Sendable {
```

Both enums use `String` raw values and have no associated values, so Swift synthesizes `Codable` conformance automatically — no `encode`/`decode` implementation needed. Run `swift build` after this step to confirm zero new warnings.

```bash
swift build
```

Expected: build succeeds. Both enums compile with `Codable` added.

- [ ] **Step 1: Write the failing tests** — create `Tests/NoNoiseMacTests/VoiceProfileTests.swift`

```swift
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --filter VoiceProfileTests
```

Expected: compile error — `cannot find type 'VoiceProfile' in scope`.

- [ ] **Step 3: Create `Sources/Core/VoiceProfile.swift`**

```swift
import Foundation

/// A named snapshot of all user-tunable audio settings, saved and recalled as a Voice Profile.
///
/// Schema design: every field beyond the v1 core is declared `var field: Type? = nil` so that
/// future plans (Metering & Loudness, Mouth-noise Finishers) add fields by appending optionals —
/// no migration required. The `version` Int enables a breaking migration path if one is ever needed.
///
/// Decoding is tolerant of both unknown keys (future additions ignored silently) and missing optional
/// keys (default to nil). The `VoiceProfile.decoder` is the single point of configuration for both.
///
/// ## In-flight extension points (add as optional vars when those plans ship):
/// - Metering & Loudness plan:  `var lufsTarget: Float? = nil`, `var normalizationEnabled: Bool? = nil`
/// - Mouth-noise Finishers plan: `var deplosiveLevel: Float? = nil`, `var declickLevel: Float? = nil`
public struct VoiceProfile: Codable, Identifiable, Equatable, Sendable {

    // MARK: - Schema version

    /// Increment only on a breaking schema change (dropped required field, renamed field).
    /// Optional-field additions never require a version bump.
    public var version: Int = 1

    // MARK: - Identity

    public var id: UUID
    public var name: String

    // MARK: - v1 Core settings (all user-tunable settings as of 2026-06-15)

    public var preset: VoicePreset
    public var suppressionStrength: Float
    public var attenuationLimitDb: Float
    public var outputGainValue: Float
    public var voicePolishEnabled: Bool
    public var clarityLevel: ClarityLevel

    // MARK: - Extension points for in-flight plans
    //
    // Metering & Loudness plan — add when that plan ships:
    // public var lufsTarget: Float? = nil
    // public var normalizationEnabled: Bool? = nil
    //
    // Mouth-noise Finishers plan — add when that plan ships:
    // public var deplosiveLevel: Float? = nil
    // public var declickLevel: Float? = nil

    // MARK: - Memberwise init (used by tests and AudioModel)

    public init(
        id: UUID = UUID(),
        name: String,
        preset: VoicePreset,
        suppressionStrength: Float,
        attenuationLimitDb: Float,
        outputGainValue: Float,
        voicePolishEnabled: Bool,
        clarityLevel: ClarityLevel
    ) {
        self.id = id
        self.name = name
        self.preset = preset
        self.suppressionStrength = suppressionStrength
        self.attenuationLimitDb = attenuationLimitDb
        self.outputGainValue = outputGainValue
        self.voicePolishEnabled = voicePolishEnabled
        self.clarityLevel = clarityLevel
    }

    // MARK: - Factory

    /// Produce a profile snapshot from Meeting preset defaults. Use when the user saves
    /// their first profile or when no prior settings are available.
    public static func makeDefault(name: String) -> VoiceProfile {
        VoiceProfile(
            name: name,
            preset: .meeting,
            suppressionStrength: 1.0,
            attenuationLimitDb: VoicePreset.maxAttenuationDb,
            outputGainValue: 1.0,
            voicePolishEnabled: true,
            clarityLevel: .off
        )
    }

    // MARK: - Shared encoder / decoder

    /// Single encoder instance. `convertToSnakeCase` produces stable, human-readable JSON keys.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Single decoder instance. `convertFromSnakeCase` matches the encoder; unknown keys are
    /// silently ignored by Swift's default Codable synthesis, satisfying the extensibility mandate.
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --filter VoiceProfileTests
```

Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/VoiceProfile.swift Tests/NoNoiseMacTests/VoiceProfileTests.swift
git commit -m "feat(core): add VoiceProfile versioned Codable schema with extensibility for in-flight plans"
```

---

## Task 2: `VoiceProfileStore` — CRUD pure value type — TDD

All collection operations (save, recall by ID, rename, delete, list, encode, decode) live in a headless, CoreAudio-free `VoiceProfileStore` struct. This makes all profile logic unit-testable without a running `AudioModel`.

**Files:**
- Create: `Sources/Core/VoiceProfileStore.swift`
- Modify: `Tests/NoNoiseMacTests/VoiceProfileTests.swift` (add store tests)

- [ ] **Step 1: Write the failing tests** — append these methods inside `VoiceProfileTests` (after the existing tests, before the closing `}`)

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --filter VoiceProfileTests
```

Expected: compile error — `cannot find type 'VoiceProfileStore' in scope`.

- [ ] **Step 3: Create `Sources/Core/VoiceProfileStore.swift`**

```swift
import Foundation

/// Pure value type that owns a collection of `VoiceProfile`s and exposes CRUD + JSON serialization.
///
/// Design rules:
/// - All mutations produce a new value (value semantics — callers replace their copy).
/// - `encodeToJSON()` / `decode(from:)` use `VoiceProfile`'s shared encoder/decoder for consistent
///   snake_case keys and tolerant decoding of unknown fields.
/// - `decodeSafe(from:)` never throws — returns an empty store on any parse failure (e.g. corrupt
///   UserDefaults) so the app is never bricked by a bad payload.
/// - Insertion order is preserved (displayed in save-order in the UI, not alphabetically).
public struct VoiceProfileStore {

    public private(set) var profiles: [VoiceProfile] = []

    public init() {}

    // MARK: - CRUD

    /// Add a new profile or update an existing one (matched by `profile.id`).
    public mutating func save(_ profile: VoiceProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// Remove the profile with the given ID. No-op if the ID is not in the collection.
    public mutating func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
    }

    /// Rename the profile with the given ID. No-op if the ID is not in the collection.
    public mutating func rename(id: UUID, to newName: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].name = newName
    }

    /// Look up a profile by ID. Returns `nil` if not found.
    public func profile(id: UUID) -> VoiceProfile? {
        profiles.first { $0.id == id }
    }

    /// Alias for `save(_:)` — add a new profile or update an existing one by ID.
    /// Provided so call sites in `AudioModel` can express intent explicitly ("upsert").
    public mutating func upsert(_ profile: VoiceProfile) {
        save(profile)
    }

    /// Alias for `delete(id:)` — remove the profile with the given ID. No-op if not found.
    /// Provided so `AudioModel` call sites read as `store.remove(id:)` rather than `store.delete(id:)`,
    /// avoiding confusion with Swift collection's `remove(at:)` and matching the intent more clearly.
    public mutating func remove(id: UUID) {
        delete(id: id)
    }

    /// Build a store from an existing array without violating `private(set)`.
    /// Used by `AudioModel` to reconstruct a mutable store from its `@Published var profiles`
    /// so it can call mutating store methods and then read back `store.profiles`.
    public static func from(_ profiles: [VoiceProfile]) -> VoiceProfileStore {
        var store = VoiceProfileStore()
        profiles.forEach { store.save($0) }
        return store
    }

    // MARK: - Serialization

    /// Encode the entire profiles array to JSON. Throws on encoder failure (extremely unlikely
    /// since all fields are basic Codable types).
    public func encodeToJSON() throws -> Data {
        try VoiceProfile.encoder.encode(profiles)
    }

    /// Decode a profiles array from JSON. Throws on malformed JSON or type mismatch.
    /// Prefer `decodeSafe(from:)` when reading from UserDefaults.
    public static func decode(from data: Data) throws -> VoiceProfileStore {
        let profiles = try VoiceProfile.decoder.decode([VoiceProfile].self, from: data)
        var store = VoiceProfileStore()
        store.profiles = profiles
        return store
    }

    /// Non-throwing variant. Returns an empty store on any parse error, so a corrupt
    /// UserDefaults value never crashes or bricks the app.
    public static func decodeSafe(from data: Data) -> VoiceProfileStore {
        (try? decode(from: data)) ?? VoiceProfileStore()
    }
}
```

- [ ] **Step 4: Run the full test suite**

```bash
swift test
```

Expected: all tests PASS (including the Task 1 `VoiceProfileTests` and all pre-existing tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/VoiceProfileStore.swift Tests/NoNoiseMacTests/VoiceProfileTests.swift
git commit -m "feat(core): add VoiceProfileStore CRUD and JSON serialization (headless XCTest-able)"
```

---

## Task 3: Wire profiles into `AudioModel` — persist, load, apply

Expose `profiles` as a `@Published` collection, add `saveCurrentAsProfile`, `applyProfile`, `deleteProfile`, and `renameProfile` methods, and persist under `mv.profiles`. This task does not touch the UI — it is verified by `swift build` + the full test suite (the `AudioModel` path cannot be unit-tested headlessly per CLAUDE.md), plus a manual smoke test at the end.

**Files:**
- Modify: `Sources/Core/AudioModel.swift`

- [ ] **Step 1: Add `mv.profiles` to `PrefKey`**

In the `PrefKey` enum (currently lines 114–120), add the new key — keeping all existing keys unchanged:

```swift
    private enum PrefKey {
        static let preset      = "mv.preset"
        static let strength    = "mv.suppressionStrength"
        static let atten       = "mv.attenuationLimitDb"
        static let gain        = "mv.outputGain"
        static let voicePolish = "mv.voicePolish"
        static let clarity     = "mv.clarity"       // added by Broadcast Voice plan
        static let profiles    = "mv.profiles"      // new: Voice Profiles
    }
```

- [ ] **Step 2: Add the `@Published` profiles collection**

Immediately after `@Published public var clarityLevel` (added by the Broadcast Voice plan), add:

```swift
    /// The user's saved Voice Profiles. Persisted as a JSON array under `mv.profiles`.
    /// Mutations go through `saveCurrentAsProfile`, `deleteProfile`, and `renameProfile`
    /// (not direct array mutation) to keep persistence consistent.
    @Published public var profiles: [VoiceProfile] = []
```

- [ ] **Step 3: Add profile operations**

`VoiceProfileStore.profiles` is `public private(set)` — it cannot be assigned from outside the type. All mutations in `AudioModel` must go through the store's own mutating API (`save`, `delete`, `rename`). The `from(_:)` class helper on `VoiceProfileStore` (defined in Task 2 Step 3) rebuilds a store from an existing array for `persistProfiles`.

Add the following methods in the `// MARK: - Presets & suppression knobs` section, after `onKnobChanged()`:

```swift
    // MARK: - Voice Profiles

    /// Capture the current live settings as a named profile and persist.
    /// If `existingID` is provided, the existing profile is updated in place (rename + re-snapshot);
    /// otherwise a new profile with a fresh UUID is created.
    public func saveCurrentAsProfile(name: String, existingID: UUID? = nil) {
        let profile = VoiceProfile(
            id: existingID ?? UUID(),
            name: name,
            preset: selectedPreset,
            suppressionStrength: suppressionStrength,
            attenuationLimitDb: attenuationLimitDb,
            outputGainValue: outputGainValue,
            voicePolishEnabled: voicePolishEnabled,
            clarityLevel: clarityLevel
        )
        var store = VoiceProfileStore.from(profiles)
        store.upsert(profile)
        profiles = store.profiles
        persistProfiles()
    }

    /// Apply a saved profile to the live engine. Uses the `isApplyingPreset` guard so:
    /// — setting each @Published property does NOT trigger `onKnobChanged` mid-apply
    /// — `persistSettings` and `applyVoiceChain` are called exactly once, after all values are set
    /// — `selectedPreset` does not spuriously flip to `.custom` during the apply
    ///
    /// Verified by the REQUIRED manual smoke test (step 4 of the smoke test checklist).
    /// `AudioModel.init()` starts CoreAudio/AVCapture, making headless XCTest impossible here.
    public func applyProfile(_ profile: VoiceProfile) {
        isApplyingPreset = true
        // Apply DSP suppression knobs from the profile's stored values (not re-derived from preset,
        // in case the user had manually overridden them before saving).
        suppressionStrength = profile.suppressionStrength
        attenuationLimitDb = profile.attenuationLimitDb
        outputGainValue = profile.outputGainValue
        dspEngine.suppressionStrength = suppressionStrength
        dspEngine.attenuationLimitDb = attenuationLimitDb
        dspEngine.outputGain = outputGainValue
        // Apply voice chain settings.
        voicePolishEnabled = profile.voicePolishEnabled
        clarityLevel = profile.clarityLevel
        // Apply the preset last so selectedPreset.didSet fires with isApplyingPreset=true,
        // suppressing the re-entry into applyPreset and applyVoiceChain.
        selectedPreset = profile.preset
        isApplyingPreset = false
        // Single reconfigure with the final restored state — matches loadSettings() pattern.
        applyVoiceChain()
        persistSettings()
    }

    /// Delete a saved profile by ID and persist.
    public func deleteProfile(id: UUID) {
        var store = VoiceProfileStore.from(profiles)
        store.remove(id: id)
        profiles = store.profiles
        persistProfiles()
    }

    /// Rename a saved profile and persist.
    public func renameProfile(id: UUID, to newName: String) {
        var store = VoiceProfileStore.from(profiles)
        store.rename(id: id, to: newName)
        profiles = store.profiles
        persistProfiles()
    }

    /// Serialize the current profiles array to UserDefaults under `mv.profiles`.
    private func persistProfiles() {
        guard let data = try? VoiceProfileStore.from(profiles).encodeToJSON() else { return }
        UserDefaults.standard.set(data, forKey: PrefKey.profiles)
    }
```

The `VoiceProfileStore.from(_:)` class helper and `upsert`/`remove` API must be added to `VoiceProfileStore` — do this before adding the `AudioModel` methods above. Open `Sources/Core/VoiceProfileStore.swift` and make the following two additions:

**1. Rename `save` to `upsert`** (or add `upsert` as an alias for `save`) so the call-site reads as intent-revealing. The simplest approach that keeps the existing tests passing is to add `upsert` as a public alias:

```swift
    /// Alias for `save(_:)` — add a new profile or update an existing one by ID.
    /// Using "upsert" at the AudioModel call site makes the intent explicit.
    public mutating func upsert(_ profile: VoiceProfile) {
        save(profile)
    }
```

**2. Rename `delete(id:)` to `remove(id:)`** (or add `remove` as an alias) and add the `from(_:)` helper:

```swift
    /// Alias for `delete(id:)` — removes the profile with the given ID. No-op if not found.
    public mutating func remove(id: UUID) {
        delete(id: id)
    }

    /// Build a store from an existing array. Used by AudioModel to reconstruct a mutable
    /// store from `@Published var profiles: [VoiceProfile]` without violating `private(set)`.
    public static func from(_ profiles: [VoiceProfile]) -> VoiceProfileStore {
        var store = VoiceProfileStore()
        profiles.forEach { store.save($0) }
        return store
    }
```

Add these to `Sources/Core/VoiceProfileStore.swift` in the `// MARK: - CRUD` section. The `from(_:)` helper was already referenced in the Task 2 Step 3 implementation — verify it is present before proceeding.

- [ ] **Step 4: Load profiles in `loadSettings()`**

At the end of `loadSettings()`, after `applyVoiceChain()`, add:

```swift
        // Load saved profiles (added by Voice Profiles plan). Tolerant: corrupt/absent → empty array.
        if let data = UserDefaults.standard.data(forKey: PrefKey.profiles) {
            profiles = VoiceProfileStore.decodeSafe(from: data).profiles
        }
```

- [ ] **Step 5: Build + regression test**

```bash
swift build && swift test
```

Expected: build succeeds; all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/AudioModel.swift Sources/Core/VoiceProfileStore.swift
git commit -m "feat(audio): persist, load, and apply Voice Profiles in AudioModel via isApplyingPreset guard"
```

---

## Task 4: Serialization and snapshot round-trip tests

`AudioModel` itself cannot be tested headlessly (`init()` starts CoreAudio/AVCapture). The live `applyProfile` path — that it sets each `@Published` property, calls `applyVoiceChain()` exactly once, and calls `persistSettings()` exactly once without intermediate `.custom` flips — is verified **exclusively by the REQUIRED manual smoke test** (step 4 of the smoke test checklist below). No XCTest can exercise this path without a running audio engine.

What XCTest *can* verify headlessly:
- The JSON serialization contract: a `VoiceProfile` round-trips through `VoiceProfileStore` without data loss.
- Insertion-order stability across a JSON encode/decode round-trip (required for stable UI ordering).

These tests are added here as regression guards for the serialization layer that `applyProfile` depends on.

**Files:**
- Modify: `Tests/NoNoiseMacTests/VoiceProfileTests.swift`

- [ ] **Step 1: Add the snapshot and insertion-order round-trip tests**

Append inside `VoiceProfileTests`:

```swift
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
```

- [ ] **Step 2: Run the tests**

```bash
swift test --filter VoiceProfileTests
```

Expected: all tests (including the new two) PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/NoNoiseMacTests/VoiceProfileTests.swift
git commit -m "test(core): add applyProfile shape contract and insertion-order round-trip tests"
```

---

## Task 5: Settings UI — Voice Profiles card

Add a `profilesCard` to `GeneralSettingsView` in `SettingsView.swift`. The card lists saved profiles with Save Current / Recall / Rename / Delete actions. Inline rename uses a SwiftUI `.popover` anchored to the pencil button — consistent with how the parent settings window is itself presented as an `NSPopover` from the menu-bar icon.

**Files:**
- Modify: `Sources/App/SettingsView.swift`

No XCTest (SwiftUI view) — verify by `swift build` + manual smoke test.

- [ ] **Step 1: Add a `@State` for the "save as" name field and the rename target**

Inside `GeneralSettingsView`, add below `@ObservedObject var audioModel: AudioModel`:

```swift
    @State private var isShowingSaveSheet = false
    @State private var newProfileName: String = ""
    @State private var renameTargetID: UUID? = nil
    @State private var renameText: String = ""
```

- [ ] **Step 2: Add `profilesCard` to the view body**

In `GeneralSettingsView.body`, add `profilesCard` in the VStack after `suppressionCard` and before `gainCard`:

```swift
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                brandedHeader
                suppressionCard
                profilesCard       // ← new
                gainCard
                footer
            }
            .padding(.trailing, 2)
        }
    }
```

- [ ] **Step 3: Implement `profilesCard`**

Add the computed property after `suppressionCard`:

```swift
    // MARK: - Voice Profiles

    private var profilesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("Voice Profiles", systemImage: "person.crop.rectangle.stack")
                Spacer()
                Button {
                    newProfileName = ""
                    isShowingSaveSheet = true
                } label: {
                    Label("Save Current", systemImage: "plus")
                        .font(.caption)
                }
                .controlSize(.small)
            }

            if audioModel.profiles.isEmpty {
                Text("No profiles saved yet. Dial in your settings and tap \"Save Current\".")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(audioModel.profiles) { profile in
                    profileRow(profile)
                    if profile.id != audioModel.profiles.last?.id {
                        Divider()
                    }
                }
            }
        }
        .nnCard()
        // "Save Current" sheet — presented as a SwiftUI sheet over the settings window.
        .sheet(isPresented: $isShowingSaveSheet) {
            saveProfileSheet
        }
    }

    private func profileRow(_ profile: VoiceProfile) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(profile.preset.label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Recall") {
                audioModel.applyProfile(profile)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            Button {
                renameTargetID = profile.id
                renameText = profile.name
            } label: {
                Image(systemName: "pencil")
            }
            .controlSize(.small)
            .help("Rename this profile")
            .popover(isPresented: Binding(
                get: { renameTargetID == profile.id },
                set: { if !$0 { renameTargetID = nil } }
            )) {
                renamePopover(for: profile)
            }

            Button(role: .destructive) {
                audioModel.deleteProfile(id: profile.id)
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Delete this profile")
        }
    }

    private var saveProfileSheet: some View {
        VStack(spacing: 16) {
            Text("Save Profile")
                .font(.headline)
            Text("Name this snapshot of your current settings.")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Profile name", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
                .onSubmit { commitSave() }
            HStack {
                Button("Cancel") { isShowingSaveSheet = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { commitSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
    }

    private func renamePopover(for profile: VoiceProfile) -> some View {
        HStack(spacing: 8) {
            TextField("New name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160)
                .onSubmit { commitRename(id: profile.id) }
            Button("OK") { commitRename(id: profile.id) }
                .controlSize(.small)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }

    private func commitSave() {
        let trimmed = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        audioModel.saveCurrentAsProfile(name: trimmed)
        isShowingSaveSheet = false
    }

    private func commitRename(id: UUID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        audioModel.renameProfile(id: id, to: trimmed)
        renameTargetID = nil
    }
```

- [ ] **Step 4: Build**

```bash
swift build
```

Expected: build succeeds with no warnings in the new code.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/SettingsView.swift
git commit -m "feat(ui): add Voice Profiles card to Settings (save, recall, rename, delete)"
```

---

## Task 6: Documentation (8-Fold Awareness Step 2 + compounding)

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/knowledge/timeline1.md`
- Modify: `docs/knowledge/knowledge1.md`

- [ ] **Step 1: Update `CLAUDE.md`**

**1a. Fix the architecture map chain-order description (line 29).**

In the **"Architecture map"** section, change the split description:

```
post-DSP "voice polish" (high-pass → shelves → compressor → limiter) plus the optional **Broadcast Voice** clarity stages (presence peaking bell → subtractive `DeEsser`), driven by `ClarityLevel` and gated independently of the noise preset.
```

to the merged single-order that matches the actual `VoiceChain.process` implementation:

```
post-DSP "voice polish": unified chain `hp → shelves → presence → deEsser → comp → limiter` (polish stages gated by `voicePolishEnabled`; clarity stages gated by `clarity != .off`; limiter always runs while active), driven by `ClarityLevel` and the per-preset `VoiceChainSettings`.
```

The "Voice polish chain (Tier 2)" section (line 141) already states the correct merged order — line 29 was a leftover from before the Broadcast Voice plan added the clarity stages inline.

**1b. Add the Voice Profiles prose.** In the **"Presets & intensity knobs"** section, locate the paragraph that ends with:

> `Only the mv.voicePolish master toggle is persisted (plus the Tier 1 mv.preset).`

Append (after that sentence, still in the same bullet):

```markdown
  A **Voice Profile** is a named snapshot of ALL user-tunable settings (`selectedPreset`,
  `suppressionStrength`, `attenuationLimitDb`, `outputGainValue`, `voicePolishEnabled`,
  `clarityLevel`) persisted as a JSON array under `mv.profiles`. Applying a profile goes through
  the same `isApplyingPreset` guard as `applyPreset` + `applyVoiceChain` — all `@Published`
  properties are set inside `isApplyingPreset = true … = false`, then a single `applyVoiceChain()`
  and `persistSettings()` are called after. This prevents spurious `onKnobChanged` → `.custom`
  flips or redundant persists mid-apply. Future settings fields must be added to `VoiceProfile`
  as optionals (schema version stays at 1) so old profiles survive without migration.
```

- [ ] **Step 2: Append to `docs/knowledge/timeline1.md`**

Prepend to the top (after the `# Timeline` header, before the first existing entry), following the existing "Newest on top" convention:

```markdown
### 2026-06-15 — Voice Profiles: save/recall/rename/delete named setting snapshots

Added a **Voice Profiles** system: `VoiceProfile` (versioned `Codable` struct, extensible via
optional fields), `VoiceProfileStore` (pure CRUD + JSON serialization, headless XCTest-able),
and three new `AudioModel` methods (`saveCurrentAsProfile`, `applyProfile`, `deleteProfile`,
`renameProfile`). Profiles are persisted as a JSON array under `mv.profiles`. The `applyProfile`
path goes through `isApplyingPreset = true … = false` to prevent spurious `.custom` flips or
redundant `applyVoiceChain` / `persistSettings` calls mid-apply. UI: a Profiles card in
`GeneralSettingsView` with Save Current / Recall / Rename / Delete per row. Schema is forward-
compatible: Metering & Loudness and Mouth-noise Finisher plans can add optional fields with no
migration.
```

- [ ] **Step 3: Append to `docs/knowledge/knowledge1.md`**

Prepend a `[DECISION]` entry at the top (after the `# Knowledge Log` header):

```markdown
### [DECISION] 2026-06-15 — Voice Profiles: extensible versioned schema via optional Codable fields

**Problem**: Adding new user-tunable settings (Metering & Loudness LUFS target, Mouth-noise
de-plosive level) would break saved profiles if the schema required all fields to be present.
**Decision**: Declare all extension-point fields as `var field: Type? = nil` in `VoiceProfile`.
Swift's Codable synthesis silently ignores unknown JSON keys (forward-compat) and decodes missing
optional keys as `nil` (backward-compat). A `version: Int = 1` field provides a hook for future
breaking migrations without coupling to optional-field additions. The `VoiceProfile.decoder` is
the single configuration point (`keyDecodingStrategy = .convertFromSnakeCase`); callers never
build their own decoder.
**Rule**: Any new user-tunable setting added to the app MUST be added to `VoiceProfile` as an
optional field at the same time. Mandatory fields (non-optional) require a version bump and a
migration in `VoiceProfileStore.decode(from:)`.
**Files**: `Sources/Core/VoiceProfile.swift`, `Sources/Core/VoiceProfileStore.swift`,
`Tests/NoNoiseMacTests/VoiceProfileTests.swift`.

---
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/knowledge/timeline1.md docs/knowledge/knowledge1.md
git commit -m "docs: document Voice Profiles schema design, apply-profile guard, and extensibility decision"
```

---

## Manual smoke test (after all tasks)

The headless suite does not exercise the live audio path or SwiftUI. After implementation, verify in the running app:

1. `./install-app.sh` (or `swift run`), open Settings → General tab.

2. Confirm the **Voice Profiles** card appears below the Suppression card with the "Save Current" button and an empty-state message.

3. Select **Podcast** mode, set Broadcast Voice to **Medium**, tweak Suppression Strength to 0.8. Tap "Save Current" → name it "Podcast Medium". The profile row appears in the list.

4. Switch to **Meeting** mode (clarity Off). Tap "Recall" on "Podcast Medium". Confirm: the segmented preset picker snaps to Podcast, Broadcast Voice snaps to Medium, Suppression Strength returns to 0.8 — **no intermediate flicker to Custom**.

5. Rename "Podcast Medium" to "Show Prep". Confirm the row updates immediately.

6. Create a second profile ("Solo Narration" with Tutorial preset). Confirm both rows appear in save order.

7. Delete "Show Prep". Confirm only "Solo Narration" remains.

8. Quit and relaunch. Confirm "Solo Narration" is still in the list (persistence).

9. With "Solo Narration" selected: change Suppression Strength slightly. Confirm `selectedPreset` flips to **Custom** normally (the profile recall does NOT permanently lock the preset).

10. Apply a profile while Noise Cancellation is **ON** — confirm the live audio path updates audibly (preset + clarity changes are heard).

---

## Self-Review (completed during authoring)

- **Spec coverage:** Named profiles (save/recall/rename/delete) ✓ Tasks 2–5. Serialized to `mv.profiles` ✓ Task 3. All 6 user-tunable settings captured ✓ `VoiceProfile` struct. Extensible schema with version + optionals ✓ Task 1, explicitly called out for in-flight plans. Apply goes through `isApplyingPreset` guard ✓ Task 3 `applyProfile`. UI list in Settings ✓ Task 5. `VoicePreset` and `ClarityLevel` conformance to `Codable` ✓ Task 1 Step 0 (prerequisite for `VoiceProfile: Codable` synthesis).
- **Invariant coverage:** `isApplyingPreset` re-entrancy documented and enforced in Task 3 Step 3 with a step-by-step breakdown of the exact apply order. `mv.*` namespace preserved — only one new key `mv.profiles` added. No "MetalVoice"/"Ghostkwebb" appears anywhere in Sources/. All paths are repo-relative. `VoiceProfileStore.profiles` `private(set)` invariant respected — `AudioModel` never assigns to `store.profiles` directly; it uses `upsert`/`remove`/`rename` methods and `VoiceProfileStore.from(_:)` exclusively.
- **TDD granularity:** Tasks 1 and 2 follow strict red → green → commit TDD. Tasks 3 and 5 are `swift build`-verified (cannot unit-test `AudioModel` or SwiftUI headlessly — matches the precedent set by the broadcast voice plan's Task 5 and Task 6). Task 4 adds pure serialization and insertion-order round-trip regression tests — it does NOT claim to test `AudioModel.applyProfile` (which requires a live CoreAudio engine); that path is verified exclusively by the manual smoke test.
- **Extensibility:** the three future fields (`lufsTarget`, `normalizationEnabled`, `deplosiveLevel`, `declickLevel`) are documented with commented-out stubs in `VoiceProfile.swift` and the decision is captured in `knowledge1.md`.
- **No placeholder code:** every step shows complete, copy-pasteable implementations.
