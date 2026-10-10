import Foundation
import Observation

@MainActor @Observable
public final class SceneFavorites {
    public private(set) var ids: Set<String>
    @ObservationIgnored private let defaults: UserDefaults?
    private static let key = "holodeck.favoriteSceneIDs"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }
    private init() { defaults = nil; ids = [] }
    public static func inMemory() -> SceneFavorites { SceneFavorites() }
    public func toggle(_ id: String) {
        if !ids.insert(id).inserted { ids.remove(id) }
        defaults?.set(ids.sorted(), forKey: Self.key)
    }
}

nonisolated public enum SceneLibrary {
    public static func collections(_ authored: [CatalogCollection]?, shaders: [ShaderDefinition]) -> [CatalogCollection] {
        if let authored, !authored.isEmpty { return authored }
        return [ShaderDefinition.Category.procedural, .material].compactMap { category in
            let ids = shaders.filter { $0.category == category }.map(\.id)
            return ids.isEmpty ? nil : CatalogCollection(id: category == .procedural ? "procedural" : "materials",
                name: category == .procedural ? "Procedural" : "Materials", description: "Scenes grouped by category.", shaderIDs: ids)
        }
    }
    public static func moods(_ shaders: [ShaderDefinition]) -> [String] {
        Array(Set(shaders.flatMap { $0.discovery?.moods.map(SceneDiscovery.normalized) ?? [] })).sorted()
    }
    public static func motions(_ shaders: [ShaderDefinition]) -> [String] {
        let values = Set(shaders.compactMap { $0.discovery.map { SceneDiscovery.normalized($0.motion) } })
        return ["slow", "steady", "fast"].filter { values.contains($0) } + values.subtracting(["slow", "steady", "fast"]).sorted()
    }
    public static func filter(_ shaders: [ShaderDefinition], query: String, favoritesOnly: Bool,
                              favorites: Set<String>, collection: CatalogCollection? = nil,
                              mood: String? = nil, motion: String? = nil) -> [ShaderDefinition] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let mood = mood.map(SceneDiscovery.normalized)
        let motion = motion.map(SceneDiscovery.normalized)
        let ordered: [ShaderDefinition]
        if let collection {
            let lookup = Dictionary(shaders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            ordered = collection.shaderIDs.compactMap { lookup[$0] }
        } else { ordered = shaders }
        return ordered.filter {
            (!favoritesOnly || favorites.contains($0.id)) &&
            (mood == nil || $0.discovery?.moods.contains(where: { SceneDiscovery.normalized($0) == mood }) == true) &&
            (motion == nil || $0.discovery.map { SceneDiscovery.normalized($0.motion) } == motion) &&
            (query.isEmpty || ([$0.title, $0.description] + ($0.discovery?.tags ?? []) + ($0.discovery?.moods ?? []) + [$0.discovery?.motion ?? ""]).contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
}

/// UI status changes can reuse results; catalog and every filtering input participate in the key.
@MainActor public final class SceneFilterCache {
    private struct Key: Equatable {
        let revision: String
        let query: String
        let favoritesOnly: Bool
        let favorites: Set<String>
        let collectionID: String
        let mood: String?
        let motion: String?
    }
    private var key: Key?
    private var results: [ShaderDefinition] = []
    private(set) var computationCount = 0
    public init() {}

    public func filter(_ catalog: ValidatedCatalog?, query: String = "", favoritesOnly: Bool = false,
                       favorites: Set<String> = [], collectionID: String = "all",
                       mood: String? = nil, motion: String? = nil) -> [ShaderDefinition] {
        guard let catalog else { key = nil; results = []; return [] }
        let next = Key(revision: catalog.publicationRevision, query: query, favoritesOnly: favoritesOnly,
                       favorites: favorites, collectionID: collectionID, mood: mood, motion: motion)
        if next != key {
            results = SceneLibrary.filter(catalog.shaders, query: query, favoritesOnly: favoritesOnly, favorites: favorites,
                                          collection: catalog.collections.first { $0.id == collectionID }, mood: mood, motion: motion)
            key = next
            computationCount += 1
        }
        return results
    }
}
