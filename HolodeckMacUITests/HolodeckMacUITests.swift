import XCTest

@MainActor
final class HolodeckMacUITests: XCTestCase {
    nonisolated override func setUpWithError() throws { continueAfterFailure = false }

    private func app(suite: String = "HolodeckMacUITests-" + UUID().uuidString, arguments: [String] = [], discovery: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-storage-suite", suite] + arguments
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: discovery ? "DiscoveryFixture" : "CatalogFixture", withExtension: "json", subdirectory: "TestSupport"))
        app.launchEnvironment["HOLODECK_UI_TEST_CATALOG"] = try String(contentsOf: url, encoding: .utf8)
        return app
    }
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func waitForTitle(_ title: String, in app: XCUIApplication) {
        let label = element("active-scene-title", in: app)
        XCTAssertTrue(label.waitForExistence(timeout: 15))
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ OR label == %@", title, title), object: label)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed)
    }
    private func select(_ id: String, title: String, in app: XCUIApplication) {
        let row = element("shader-" + id, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        waitForTitle(title, in: app)
    }

    func testEverySceneAndArrowSelection() throws {
        let app = try app()
        app.launch()
        waitForTitle("Plasma", in: app)
        select("aurora", title: "Aurora", in: app)
        app.typeKey(.downArrow, modifierFlags: [])
        waitForTitle("Waves", in: app)
        for (id, title) in [("kaleidoscope", "Kaleidoscope"), ("starfield", "Starfield"), ("chrome", "Chrome"),
                            ("brushed-gold", "Brushed Gold"), ("iridescent", "Iridescent"), ("plasma", "Plasma")] {
            select(id, title: title, in: app)
        }
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSearchFavoritesAndPersistenceDoNotInterruptPlayback() throws {
        let suite = "HolodeckMacUITests-" + UUID().uuidString
        let app = try app(suite: suite)
        app.launch()
        waitForTitle("Plasma", in: app)
        element("toggle-favorite", in: app).click()
        let search = element("scene-search", in: app)
        search.click(); search.typeText("REFLECTING")
        XCTAssertTrue(element("shader-chrome", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("shader-plasma", in: app).exists)
        waitForTitle("Plasma", in: app)
        element("favorites-filter", in: app).click()
        XCTAssertTrue(app.staticTexts["No Matching Scenes"].waitForExistence(timeout: 5))
        search.click(); search.typeKey("a", modifierFlags: .command); search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(element("shader-plasma", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("shader-aurora", in: app).exists)
        app.terminate(); app.launch()
        waitForTitle("Plasma", in: app)
        XCTAssertEqual(element("toggle-favorite", in: app).label, "Remove from Favorites")
        element("favorites-filter", in: app).click()
        element("toggle-favorite", in: app).click()
        XCTAssertTrue(app.staticTexts["No Favorites Yet"].waitForExistence(timeout: 5))
        waitForTitle("Plasma", in: app)
    }

    func testSidebarRestorationDefaultStartupAndSingleWindowReopening() throws {
        let app = try app()
        app.launch()
        waitForTitle("Plasma", in: app)
        select("aurora", title: "Aurora", in: app)
        element("refresh-scenes", in: app).click()
        waitForTitle("Aurora", in: app)
        element("toggle-sidebar", in: app).click()
        XCTAssertTrue(element("scene-search", in: app).waitForNonExistence(timeout: 5))
        app.terminate(); app.launch()
        waitForTitle("Plasma", in: app)
        XCTAssertFalse(element("scene-search", in: app).exists)
        element("toggle-sidebar", in: app).click()
        XCTAssertTrue(element("scene-search", in: app).waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertTrue(element("scene-search", in: app).exists)
        app.typeKey("f", modifierFlags: [.command, .control])
        // Hide and reactivate the app; the Window scene must remain singular.
        app.typeKey("h", modifierFlags: .command)
        app.activate()
        XCTAssertEqual(app.windows.count, 1)
        waitForTitle("Plasma", in: app)
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        app.activate()
        if app.windows.count == 0 {
            app.menuBars.menuBarItems["Window"].click()
            app.menuItems["Holodeck"].click()
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
        select("aurora", title: "Aurora", in: app)
    }

    func testDownloadFailureCanRetryAndRendererFailureAlerts() throws {
        let offline = try app(arguments: ["--ui-test-empty-cache"])
        offline.launch()
        XCTAssertTrue(offline.windows.firstMatch.buttons["Retry"].firstMatch.waitForExistence(timeout: 10), offline.debugDescription)
        XCTAssertTrue(offline.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "internet connection", "internet connection")).firstMatch.exists)
        offline.windows.firstMatch.buttons["Retry"].firstMatch.click()
        XCTAssertTrue(offline.windows.firstMatch.buttons["Retry"].firstMatch.waitForExistence(timeout: 10), offline.debugDescription)
        offline.windows.firstMatch.buttons["OK"].firstMatch.click()
        XCTAssertTrue(offline.staticTexts["No Scenes Yet"].exists)
        offline.terminate()
        let unavailable = try app(arguments: ["--ui-test-metal-unavailable"])
        unavailable.launch()
        XCTAssertTrue(unavailable.windows.firstMatch.buttons["OK"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(unavailable.staticTexts["Renderer Unavailable"].exists)
        unavailable.windows.firstMatch.buttons["OK"].firstMatch.click()
    }

    func testDiscoveryFiltersSearchAndResetPreservePlayback() throws {
        let app = try app(discovery: true)
        app.launch()
        waitForTitle("Plasma", in: app)
        element("collection-filter", in: app).click()
        app.menuItems["Atmospheric"].click()
        XCTAssertTrue(element("shader-aurora", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("shader-plasma", in: app).exists)
        waitForTitle("Plasma", in: app)
        let filtered = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        filtered.name = "Mac Atmospheric collection keeps Plasma playing"
        filtered.lifetime = .keepAlways
        add(filtered)
        element("mood-filter", in: app).click()
        app.menuItems["Energetic"].click()
        XCTAssertTrue(app.staticTexts["No Matching Scenes"].waitForExistence(timeout: 5))
        waitForTitle("Plasma", in: app)
        let empty = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        empty.name = "Mac empty intersection and Reset Filters"
        empty.lifetime = .keepAlways
        add(empty)
        element("reset-filters", in: app).click()
        let search = element("scene-search", in: app)
        search.click(); search.typeText("material")
        XCTAssertTrue(element("shader-chrome", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("shader-aurora", in: app).exists)
        waitForTitle("Plasma", in: app)
        element("reset-filters", in: app).click()
        XCTAssertTrue(element("shader-plasma", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("active-scene-discovery", in: app).exists)
    }
}
