import XCTest
@testable import HolodeckCore

@MainActor
final class LibraryAndQualityTests: XCTestCase {
    func testSearchAndFavoritesComposeAndPreserveOrder() {
        let scenes = TestCatalog.shaders
        XCTAssertEqual(SceneLibrary.filter(scenes, query: "LIGHT", favoritesOnly: false, favorites: []).map(\.id),
                       scenes.filter { $0.title.localizedCaseInsensitiveContains("light") || $0.description.localizedCaseInsensitiveContains("light") }.map(\.id))
        XCTAssertEqual(SceneLibrary.filter(scenes, query: "  ", favoritesOnly: true, favorites: ["aurora", "chrome"]).map(\.id), ["aurora", "chrome"])
        XCTAssertEqual(SceneLibrary.filter(scenes, query: "reflecting", favoritesOnly: true, favorites: ["chrome"]).map(\.id), ["chrome"])
        XCTAssertTrue(SceneLibrary.filter(scenes, query: "reflecting", favoritesOnly: true, favorites: ["aurora"]).isEmpty)
    }
    func testFavoritesPersistIncludingUnavailableIDs() throws {
        let suite = "HolodeckFavoritesTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = SceneFavorites(defaults: defaults)
        favorites.toggle("future-scene")
        favorites.toggle("plasma")
        favorites.toggle("plasma")
        XCTAssertEqual(SceneFavorites(defaults: defaults).ids, ["future-scene"])
        XCTAssertTrue(SceneLibrary.filter(TestCatalog.shaders, query: "", favoritesOnly: true, favorites: favorites.ids).isEmpty)
        var returning = TestCatalog.initialShader
        returning = ShaderDefinition(id: "future-scene", title: returning.title, category: returning.category,
                                     description: returning.description, colors: returning.colors, source: returning.source)
        XCTAssertEqual(SceneLibrary.filter([returning], query: "", favoritesOnly: true, favorites: favorites.ids).count, 1)
    }
    func testAdaptiveWarmupHysteresisAndBounds() {
        var quality = AdaptiveQuality()
        quality.reset(at: 0)
        XCTAssertNil(quality.record(duration: 0.1, at: 1))
        XCTAssertEqual(quality.scale, 1)
        XCTAssertNil(quality.record(duration: 0.03, at: 2))
        XCTAssertNil(quality.record(duration: 0.03, at: 3))
        XCTAssertEqual(quality.record(duration: 0.03, at: 4), 0.85)
        for time in 5...20 { _ = quality.record(duration: 0.03, at: Double(time)) }
        XCTAssertEqual(quality.scale, 0.5)
        quality.reset(at: 20)
        _ = quality.record(duration: 0.01, at: 22)
        for time in 23...26 { XCTAssertNil(quality.record(duration: 0.01, at: Double(time))) }
        XCTAssertEqual(quality.record(duration: 0.01, at: 27), 0.7)
        for time in 28...50 { _ = quality.record(duration: 0.01, at: Double(time)) }
        XCTAssertEqual(quality.scale, 1)
    }
    func testNeutralWindowsUnavailableTimingAndResizeResetBreakStreaks() {
        var quality = AdaptiveQuality()
        quality.reset(at: 0)
        _ = quality.record(duration: 0.03, at: 2)
        _ = quality.record(duration: 0.020, at: 3)
        _ = quality.record(duration: 0.03, at: 4)
        XCTAssertNil(quality.record(duration: nil, at: 5))
        XCTAssertEqual(quality.scale, 1)
        XCTAssertNil(quality.record(duration: 0.03, at: 6))
        _ = quality.record(duration: 0.03, at: 7)
        _ = quality.record(duration: 0.03, at: 8)
        quality.reset(at: 8)
        _ = quality.record(duration: 0.03, at: 10)
        XCTAssertNil(quality.record(duration: 0.03, at: 11))
        XCTAssertEqual(quality.record(duration: 0.03, at: 12), 0.85)
        XCTAssertNil(quality.record(duration: .nan, at: 13))
        XCTAssertEqual(quality.scale, 0.85)
    }
}
