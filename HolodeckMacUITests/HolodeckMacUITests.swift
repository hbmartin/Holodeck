import AppKit
import XCTest

@MainActor
final class HolodeckMacUITests: XCTestCase {
    nonisolated override func setUpWithError() throws { continueAfterFailure = false }

    private func app(suite: String = "HolodeckMacUITests-" + UUID().uuidString, arguments: [String] = [], discovery: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-storage-suite", suite] + arguments
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: discovery ? "DiscoveryFixture" : "CatalogFixture", withExtension: "json", subdirectory: "TestSupport"))
        app.launchEnvironment["HOLODECK_UI_TEST_CATALOG"] = try String(contentsOf: url, encoding: .utf8)
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchEnvironment.removeAll()
            app.launchArguments = ["--ui-test-storage-suite", suite, "--ui-test-cleanup-storage-suite"]
            app.launch()
            app.terminate()
        }
        return app
    }
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func launch(_ app: XCUIApplication) {
        app.launch()
        // AppKit restoration is separate from the isolated scene-preferences suite.
        app.menuBars.menuBarItems["View"].click()
        let exit = app.menuItems["Exit Full Screen"]
        if exit.exists { exit.click() }
        else { app.typeKey(.escape, modifierFlags: []) }
        XCTAssertTrue(app.windows.firstMatch.buttons[XCUIIdentifierMinimizeWindow].waitForExistence(timeout: 15))
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

    func testDiskCachedScenesRemainVisibleWithUnavailableRenderer() throws {
        let app = try app(arguments: ["--ui-test-disk-cache", "--ui-test-metal-unavailable"])
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.buttons["OK"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Renderer Unavailable"].exists)
        app.windows.firstMatch.buttons["OK"].firstMatch.click()
        let row = element("shader-plasma", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(row.isEnabled)
        XCTAssertFalse(app.staticTexts["No Scenes Yet"].exists)
    }

    func testEverySceneAndArrowSelection() throws {
        let app = try app()
        launch(app)
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
        launch(app)
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
        app.terminate(); launch(app)
        waitForTitle("Plasma", in: app)
        XCTAssertEqual(element("toggle-favorite", in: app).label, "Remove from Favorites")
        element("favorites-filter", in: app).click()
        element("toggle-favorite", in: app).click()
        XCTAssertTrue(app.staticTexts["No Favorites Yet"].waitForExistence(timeout: 5))
        waitForTitle("Plasma", in: app)
    }

    func testSidebarRestorationDefaultStartupAndSingleWindowReopening() async throws {
        let app = try app()
        launch(app)
        waitForTitle("Plasma", in: app)
        select("aurora", title: "Aurora", in: app)
        element("refresh-scenes", in: app).click()
        waitForTitle("Aurora", in: app)
        element("toggle-sidebar", in: app).click()
        XCTAssertTrue(element("scene-search", in: app).waitForNonExistence(timeout: 5))
        app.terminate(); launch(app)
        waitForTitle("Plasma", in: app)
        XCTAssertFalse(element("scene-search", in: app).exists)
        element("toggle-sidebar", in: app).click()
        XCTAssertTrue(element("scene-search", in: app).waitForExistence(timeout: 5))
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(element("scene-search", in: app).waitForNonExistence(timeout: 5))
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(element("scene-search", in: app).waitForExistence(timeout: 5))
        // Hide and reactivate the app; the Window scene must remain singular.
        app.typeKey("h", modifierFlags: .command)
        try await reopen(app)
        XCTAssertEqual(app.windows.count, 1)
        waitForTitle("Plasma", in: app)
        app.windows.firstMatch.buttons[XCUIIdentifierMinimizeWindow].click()
        try await reopen(app)
        XCTAssertTrue(element("toggle-sidebar", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("toggle-sidebar", in: app).isHittable)
        XCTAssertEqual(app.windows.count, 1)
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        try await reopen(app)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
        select("aurora", title: "Aurora", in: app)
        app.menuBars.menuBarItems["Window"].click()
        XCTAssertLessThanOrEqual(app.menuItems.matching(identifier: "Holodeck").count, 1)
        app.typeKey(.escape, modifierFlags: [])
    }

    private func reopen(_ app: XCUIApplication) async throws {
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: "me.haroldmartin.HolodeckMac")
        XCTAssertEqual(candidates.count, 1, "Only the test build may be running during native reopen checks")
        let running = try XCTUnwrap(candidates.first)
        let url = try XCTUnwrap(running.bundleURL)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = expectation(description: "Dock-style reopen finishes")
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        await fulfillment(of: [opened], timeout: 10)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    func testCommandFRevealsSidebarAndFocusesInsertedSearch() throws {
        let app = try app()
        launch(app)
        waitForTitle("Plasma", in: app)
        for _ in 0..<2 {
            element("toggle-sidebar", in: app).click()
            XCTAssertTrue(element("scene-search", in: app).waitForNonExistence(timeout: 5))
            app.typeKey("f", modifierFlags: .command)
            let search = element("scene-search", in: app)
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            app.typeText("REFLECTING")
            XCTAssertTrue(element("shader-plasma", in: app).waitForNonExistence(timeout: 5))
            XCTAssertTrue(element("shader-chrome", in: app).exists)
            search.typeKey("a", modifierFlags: .command)
            search.typeKey(.delete, modifierFlags: [])
            XCTAssertTrue(element("shader-plasma", in: app).waitForExistence(timeout: 5))
        }
        waitForTitle("Plasma", in: app)
    }

    func testNativeFullScreenPreservesSidebarAndPlayback() throws {
        let app = try app()
        launch(app)
        waitForTitle("Plasma", in: app)
        let window = app.windows.firstMatch
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Enter Full Screen"].click()
        app.menuBars.menuBarItems["View"].click()
        XCTAssertTrue(app.menuItems["Exit Full Screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("scene-search", in: app).exists)
        waitForTitle("Plasma", in: app)
        app.menuItems["Exit Full Screen"].click()
        XCTAssertTrue(window.buttons[XCUIIdentifierMinimizeWindow].waitForExistence(timeout: 15))
        XCTAssertTrue(element("scene-search", in: app).exists)
    }

    func testCachedUpdateFailureIsInlineAndRetryRecovers() throws {
        let app = try app(arguments: ["--ui-test-fail-refresh"])
        launch(app)
        waitForTitle("Plasma", in: app)
        let notice = element("catalog-update-notice", in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertFalse(app.windows.firstMatch.buttons["OK"].exists)
        element("retry-scene-updates", in: app).click()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 10))
        waitForTitle("Plasma", in: app)
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
        XCTAssertTrue(unavailable.staticTexts["Metal rendering is unavailable on this device."].exists)
        XCTAssertFalse(element("shader-aurora", in: unavailable).isEnabled)
        XCTAssertFalse(unavailable.staticTexts["Loading…"].exists)
    }

    func testRendererAndCatalogFailuresPresentSeparateAlertsAndCatalogRetryRecovers() throws {
        let app = try app(arguments: ["--ui-test-metal-unavailable", "--ui-test-download-catalog", "--ui-test-fail-catalog-once"])
        app.launch()
        let renderer = app.staticTexts["Renderer Unavailable"]
        XCTAssertTrue(renderer.waitForExistence(timeout: 10))
        XCTAssertFalse(app.windows.firstMatch.buttons["Retry"].exists)
        app.windows.firstMatch.buttons["OK"].click()
        XCTAssertTrue(app.staticTexts["Unable to Load Scenes"].waitForExistence(timeout: 10))
        XCTAssertFalse(renderer.exists)
        let retry = app.windows.firstMatch.buttons["Retry"]
        XCTAssertTrue(retry.exists)
        retry.click()
        XCTAssertTrue(element("shader-aurora", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Unable to Load Scenes"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(element("shader-aurora", in: app).isEnabled)
        XCTAssertTrue(app.staticTexts["Metal rendering is unavailable on this device."].exists)
    }

    func testStaleAlertActionsCannotDismissNewerFailures() throws {
        for action in ["OK", "Retry"] {
            let app = try app(arguments: ["--ui-test-empty-cache", "--ui-test-replace-presented-failure"])
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.buttons[action].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["A newer scene download failure occurred."].exists)
            app.windows.firstMatch.buttons[action].click()
            XCTAssertTrue(app.staticTexts["A newer scene download failure occurred."].waitForExistence(timeout: 10))
            app.windows.firstMatch.buttons["OK"].click()
            XCTAssertTrue(app.staticTexts["A newer scene download failure occurred."].waitForNonExistence(timeout: 10))
            app.terminate()
        }
        let renderer = try app(arguments: ["--ui-test-metal-unavailable", "--ui-test-replace-presented-failure"])
        renderer.launch()
        XCTAssertTrue(renderer.staticTexts["Renderer Unavailable"].waitForExistence(timeout: 10))
        renderer.windows.firstMatch.buttons["OK"].click()
        XCTAssertTrue(renderer.staticTexts["A newer renderer startup failure occurred."].waitForExistence(timeout: 10))
        XCTAssertFalse(renderer.windows.firstMatch.buttons["Retry"].exists)
    }

    func testNamedWindowFramePersistsAndCleanupCannotRecreateIt() throws {
        let suite = "HolodeckMacUITests-" + UUID().uuidString
        let name = "HolodeckViewer-" + suite
        let live = savedFrame("HolodeckViewer-live")
        let app = try app(suite: suite)
        launch(app)
        waitForTitle("Plasma", in: app)
        resizeWindow(in: app)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in savedFrame(name) != nil }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        let frame = try XCTUnwrap(savedFrame(name))
        app.terminate()
        launch(app)
        XCTAssertEqual(savedFrame(name), frame)
        app.terminate()
        app.launchEnvironment.removeAll()
        app.launchArguments = ["--ui-test-storage-suite", suite, "--ui-test-cleanup-storage-suite"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertNil(savedFrame(name))
        app.terminate()
        XCTAssertNil(savedFrame(name), "Cleanup must not save another frame while terminating")
        XCTAssertEqual(savedFrame("HolodeckViewer-live"), live)
    }

    func testImplicitFixtureDoesNotSaveWindowFrame() throws {
        let before = savedViewerFrameNames()
        let app = try app()
        app.launchArguments = [] // The fixture environment alone selects implicit in-memory storage.
        launch(app)
        waitForTitle("Plasma", in: app)
        resizeWindow(in: app)
        app.terminate()
        XCTAssertEqual(savedViewerFrameNames(), before)
    }

    private func savedFrame(_ name: String) -> String? {
        savedAppDefaults()["NSWindow Frame " + name] as? String
    }

    private func savedViewerFrameNames() -> Set<String> {
        Set(savedAppDefaults().keys.filter { $0.hasPrefix("NSWindow Frame HolodeckViewer-") })
    }

    private func savedAppDefaults() -> [String: Any] {
        // The app is sandboxed; the unsandboxed UI runner's CFPreferences domain is separate.
        let path = "Library/Containers/me.haroldmartin.HolodeckMac/Data/Library/Preferences/me.haroldmartin.HolodeckMac.plist"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return [:] }
        return values
    }

    private func resizeWindow(in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let size = window.frame.size
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -80, dy: -60)))
        XCTAssertNotEqual(window.frame.size, size)
    }

    func testDiscoveryFiltersSearchAndResetPreservePlayback() throws {
        let app = try app(discovery: true)
        launch(app)
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
