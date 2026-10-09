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
    public static func filter(_ shaders: [ShaderDefinition], query: String, favoritesOnly: Bool,
                              favorites: Set<String>) -> [ShaderDefinition] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return shaders.filter {
            (!favoritesOnly || favorites.contains($0.id)) &&
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query))
        }
    }
}
