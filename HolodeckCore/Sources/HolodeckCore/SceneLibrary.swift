import Foundation
import Observation

@MainActor @Observable
public final class SceneFavorites {
    public private(set) var ids: Set<String>
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "holodeck.favoriteSceneIDs"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }
    public func toggle(_ id: String) {
        if !ids.insert(id).inserted { ids.remove(id) }
        defaults.set(ids.sorted(), forKey: Self.key)
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
        Array(Set(shaders.flatMap { $0.discovery?.moods ?? [] })).sorted()
    }
    public static func motions(_ shaders: [ShaderDefinition]) -> [String] {
        let values = Set(shaders.compactMap { $0.discovery?.motion })
        return ["slow", "steady", "fast"].filter { values.contains($0) } + values.subtracting(["slow", "steady", "fast"]).sorted()
    }
    public static func filter(_ shaders: [ShaderDefinition], query: String, favoritesOnly: Bool,
                              favorites: Set<String>, collection: CatalogCollection? = nil,
                              mood: String? = nil, motion: String? = nil) -> [ShaderDefinition] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lookup = Dictionary(uniqueKeysWithValues: shaders.map { ($0.id, $0) })
        let ordered = collection.map { $0.shaderIDs.compactMap { lookup[$0] } } ?? shaders
        return ordered.filter {
            (!favoritesOnly || favorites.contains($0.id)) &&
            (mood == nil || $0.discovery?.moods.contains(mood!) == true) &&
            (motion == nil || $0.discovery?.motion == motion) &&
            (query.isEmpty || ([$0.title, $0.description] + ($0.discovery?.tags ?? []) + ($0.discovery?.moods ?? []) + [$0.discovery?.motion ?? ""]).contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
}
