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
