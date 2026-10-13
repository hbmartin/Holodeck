import AppKit
import XCTest

private enum MacUITestSettings {
    static let bundleIdentifier = (Bundle(for: HolodeckMacUITests.self).bundleIdentifier ?? "me.haroldmartin.HolodeckMacUITests")
        .replacingOccurrences(of: "HolodeckMacUITests", with: "HolodeckMac")
    static let ignoreSavedStateArguments = ["-ApplePersistenceIgnoreState", "YES"]
}

private struct TestHelperError: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
}

@MainActor
final class HolodeckMacUITests: XCTestCase {
    private var cleanups: [ObjectIdentifier: StorageSuiteCleanup] = [:]
    nonisolated override func setUpWithError() throws { continueAfterFailure = false }

    private func app(suite: String? = "HolodeckMacUITests-" + UUID().uuidString, arguments: [String] = [], discovery: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        // Teardown is LIFO: this runs after cleanup, even if cleanup is interrupted.
        addTeardownBlock { @MainActor in app.terminate() }
        app.launchArguments = MacUITestSettings.ignoreSavedStateArguments + (suite.map { ["--ui-test-storage-suite", $0] } ?? []) + arguments
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: discovery ? "DiscoveryFixture" : "CatalogFixture", withExtension: "json", subdirectory: "TestSupport"))
        app.launchEnvironment["HOLODECK_UI_TEST_CATALOG"] = try String(contentsOf: url, encoding: .utf8)
        if let suite {
            let cleanup = StorageSuiteCleanup(app: app, suite: suite)
            cleanups[ObjectIdentifier(app)] = cleanup
            addTeardownBlock { @MainActor in try cleanup.run() }
        }
        return app
    }
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testLocalFolderManualReloadRollbackAndBookmarkRestoration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HolodeckAuthoring-" + UUID().uuidString)
        let shader = root.appendingPathComponent("shaders/plasma")
        try FileManager.default.createDirectory(at: shader, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let manifest = try XCTUnwrap(fixture["manifest"] as? [String: Any])
        let entries = try XCTUnwrap(manifest["shaders"] as? [[String: Any]])
        var metadata = try XCTUnwrap(entries.first { $0["id"] as? String == "plasma" })
        let sources = try XCTUnwrap(fixture["sources"] as? [String: String])
        let source = try XCTUnwrap(sources["plasma"])
        metadata["shared"] = ["common", "fragment"]
        let metadataURL = shader.appendingPathComponent("metadata.json")
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        try Data(source.utf8).write(to: shader.appendingPathComponent("body.metal"))
        for name in ["common", "fragment"] { try Data().write(to: root.appendingPathComponent("shared/\(name).metal")) }
        try JSONSerialization.data(withJSONObject: ["shaders": ["plasma"], "defaultShaderID": "plasma"]).write(to: root.appendingPathComponent("index.json"))
        let previewURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "preview-" + (metadata["previewSHA256"] as! String), withExtension: "png", subdirectory: "TestSupport"))
        let preview = try Data(contentsOf: previewURL)
        try preview.write(to: shader.appendingPathComponent("preview.png"))

        let app = try app(arguments: ["--ui-test-local-library"])
        app.launch()
        let choose = element("choose-shader-folder", in: app)
        XCTAssertTrue(choose.waitForExistence(timeout: 10)); choose.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(root.path); app.typeKey(.return, modifierFlags: [])
        let confirm = app.windows["open-panel"].buttons["OKButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.click()
        waitForTitle("Plasma", in: app)
        metadata["name"] = "Edited Plasma"
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        try Data((source + "\n// Reload test\n").utf8).write(to: shader.appendingPathComponent("body.metal"))
        XCTAssertFalse(app.staticTexts["Edited Plasma"].exists)
        element("shader-library-settings", in: app).click()
        let reload = element("reload-shaders", in: app)
        XCTAssertTrue(reload.waitForExistence(timeout: 10)); reload.click()
        waitForTitle("Edited Plasma", in: app)
        try Data("invalid preview".utf8).write(to: shader.appendingPathComponent("preview.png"))
        reload.click()
        let failure = app.windows["com_apple_SwiftUI_Settings_window"].descendants(matching: .any).matching(identifier: "shader-library-error").firstMatch
        let namedFile = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
            "shaders/plasma/preview.png", "shaders/plasma/preview.png"), object: failure)
        XCTAssertEqual(XCTWaiter.wait(for: [namedFile], timeout: 10), .completed)
        waitForTitle("Edited Plasma", in: app)
        try preview.write(to: shader.appendingPathComponent("preview.png"))
        app.terminate(); app.launch()
        waitForTitle("Edited Plasma", in: app)
        XCTAssertFalse(element("choose-shader-folder", in: app).exists)
    }
    private func authoringFolderWithInvalidShader() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HolodeckBrokenShader-" + UUID().uuidString)
        let shader = root.appendingPathComponent("shaders/plasma")
        try FileManager.default.createDirectory(at: shader, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let manifest = try XCTUnwrap(fixture["manifest"] as? [String: Any])
        let entries = try XCTUnwrap(manifest["shaders"] as? [[String: Any]])
        var metadata = try XCTUnwrap(entries.first { $0["id"] as? String == "plasma" })
        metadata["shared"] = ["common", "fragment"]
        try JSONSerialization.data(withJSONObject: metadata).write(to: shader.appendingPathComponent("metadata.json"))
        try Data("THIS IS NOT METAL;".utf8).write(to: shader.appendingPathComponent("body.metal"))
        for name in ["common", "fragment"] { try Data().write(to: root.appendingPathComponent("shared/\(name).metal")) }
        try JSONSerialization.data(withJSONObject: ["shaders": ["plasma"], "defaultShaderID": "plasma"]).write(to: root.appendingPathComponent("index.json"))
        let previewURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "preview-" + (metadata["previewSHA256"] as! String), withExtension: "png", subdirectory: "TestSupport"))
        try Data(contentsOf: previewURL).write(to: shader.appendingPathComponent("preview.png"))
        return root
    }
    func testStartupSelectionErrorDeferredDuringReloadPresentsWhenReloadFinishes() throws {
        let root = try authoringFolderWithInvalidShader()
        let app = try app(arguments: ["--ui-test-local-library", "--ui-test-hold-library-reload"])
        app.launch()
        let choose = element("choose-shader-folder", in: app)
        XCTAssertTrue(choose.waitForExistence(timeout: 10)); choose.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(root.path); app.typeKey(.return, modifierFlags: [])
        let confirm = app.windows["open-panel"].buttons["OKButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.click()
        element("shader-library-settings", in: app).click()
        let pending = element("test-reload-selection-failure", in: app)
        XCTAssertTrue(pending.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Unable to Load Scenes"].exists)
        element("finish-test-library-reload", in: app).click()
        XCTAssertTrue(app.staticTexts["Unable to Load Scenes"].waitForExistence(timeout: 10), app.debugDescription)
        let viewer = app.windows["holodeck-viewer-window"]
        XCTAssertTrue(viewer.buttons["Retry"].firstMatch.exists)
        viewer.buttons["OK"].firstMatch.click()
    }
    func testRendererFailurePresentsWithoutConfiguredShaderFolder() throws {
        let app = try app(arguments: ["--ui-test-local-library", "--ui-test-metal-unavailable"])
        app.launch()
        XCTAssertTrue(app.staticTexts["Renderer Unavailable"].waitForExistence(timeout: 10), app.debugDescription)
        app.windows["holodeck-viewer-window"].buttons["OK"].firstMatch.click()
        XCTAssertTrue(element("choose-shader-folder", in: app).exists)
    }

    private func requirePhysicalInputAccess(file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipIf(!CGPreflightPostEventAccess(), "Mac UI test runner needs permission to post physical input", file: file, line: line)
    }
    private func launch(_ app: XCUIApplication) throws {
        app.launch()
        let window = app.windows["holodeck-viewer-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        // Avoid leaving a menu open during normal-window tests. Native restoration can
        // still resume fullscreen independently of the isolated scene-preferences suite.
        if !window.buttons[XCUIIdentifierMinimizeWindow].exists {
            try exitFullScreen(in: app)
        }
        XCTAssertTrue(window.buttons[XCUIIdentifierMinimizeWindow].waitForExistence(timeout: 15))
    }
    private func exitFullScreen(in app: XCUIApplication) throws {
        try requirePhysicalInputAccess()
        let window = app.windows["holodeck-viewer-window"]
        // Fullscreen menu revelation depends on WindowServer receiving mouse movement;
        // XCTest's window-targeted hover can leave the menu bar hidden.
        let point = CGPoint(x: window.frame.midX, y: window.frame.minY)
        let hover = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
                                  "Unable to create fullscreen menu-bar hover")
        hover.post(tap: .cghidEventTap)
        try openViewMenu(in: app)
        let exit = app.menuItems["Exit Full Screen"]
        try waitForMenuElement(exit, named: "Exit Full Screen")
        // The menu is already open. Avoid XCTest reopening its ancestor menu.
        exit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(window.buttons[XCUIIdentifierMinimizeWindow].waitForExistence(timeout: 15))
    }
    private func openViewMenu(in app: XCUIApplication) throws {
        let view = app.menuBars.menuBarItems["View"]
        try waitForMenuElement(view, named: "View menu bar item")
        view.click()
    }
    private func menuReadinessIssue(_ element: XCUIElement) -> String? {
        guard element.exists else { return "element does not exist" }
        guard !element.frame.isEmpty else { return "element has an empty frame: \(element.frame)" }
        guard element.isHittable else { return "element is not hittable (frame: \(element.frame))" }
        return nil
    }
    private func waitForMenuElement(_ element: XCUIElement, named name: String) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            menuReadinessIssue(element) == nil
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 15)
        guard result == .completed else {
            let reason = menuReadinessIssue(element) ?? "waiter returned \(result)"
            throw TestHelperError(description: "\(name) was not ready within 15 seconds: \(reason).\n\(element.debugDescription)")
        }
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
        try launch(app)
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
        try launch(app)
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
        app.terminate(); try launch(app)
        waitForTitle("Plasma", in: app)
        XCTAssertEqual(element("toggle-favorite", in: app).label, "Remove from Favorites")
        element("favorites-filter", in: app).click()
        element("toggle-favorite", in: app).click()
        XCTAssertTrue(app.staticTexts["No Favorites Yet"].waitForExistence(timeout: 5))
        waitForTitle("Plasma", in: app)
    }

    func testSidebarRestorationDefaultStartupAndSingleWindowReopening() async throws {
        let app = try app()
        try launch(app)
        waitForTitle("Plasma", in: app)
        select("aurora", title: "Aurora", in: app)
        element("refresh-scenes", in: app).click()
        waitForTitle("Aurora", in: app)
        element("toggle-sidebar", in: app).click()
        XCTAssertTrue(element("scene-search", in: app).waitForNonExistence(timeout: 5))
        app.terminate(); try launch(app)
        waitForTitle("Plasma", in: app)
        XCTAssertFalse(element("scene-search", in: app).exists)
        element("toggle-sidebar", in: app).click()
        XCTAssertTrue(element("scene-search", in: app).waitForExistence(timeout: 5))
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(element("scene-search", in: app).waitForNonExistence(timeout: 5))
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(element("scene-search", in: app).waitForExistence(timeout: 5))
        // Hide and reactivate the app; the Window scene must remain singular.
        try await hideAndReopen(app)
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

    private func runningApplication(for app: XCUIApplication, expectedPID: Int32? = nil) throws -> NSRunningApplication {
        guard app.state != .notRunning else {
            throw TestHelperError(description: "The test app is not running during native hide/reopen checks (expected PID: \(expectedPID.map(String.init) ?? "unspecified")).")
        }
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: MacUITestSettings.bundleIdentifier)
        guard !candidates.isEmpty else {
            throw TestHelperError(description: "No running application matches \(MacUITestSettings.bundleIdentifier) (expected PID: \(expectedPID.map(String.init) ?? "unspecified")).")
        }
        guard candidates.count == 1 else {
            throw TestHelperError(description: "Expected only the test build for native hide/reopen checks; found \(candidates.count) instances of \(MacUITestSettings.bundleIdentifier) with PIDs \(candidates.map(\.processIdentifier)).")
        }
        let running = candidates[0]
        guard !running.isTerminated else {
            throw TestHelperError(description: "The test app terminated during native hide/reopen checks (PID: \(running.processIdentifier)).")
        }
        if let expectedPID, running.processIdentifier != expectedPID {
            throw TestHelperError(description: "The test app PID changed from \(expectedPID) to \(running.processIdentifier) during native hide/reopen checks.")
        }
        return running
    }
    private func hideAndReopen(_ app: XCUIApplication) async throws {
        let running = try runningApplication(for: app)
        let pid = running.processIdentifier
        app.typeKey("h", modifierFlags: .command)
        var processError: Error?
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            do {
                guard !running.isTerminated else {
                    throw TestHelperError(description: "The test app terminated while waiting to hide (PID: \(pid)).")
                }
                return try runningApplication(for: app, expectedPID: pid).isHidden
            } catch {
                processError = error
                return true // Stop waiting immediately when the expected process becomes invalid.
            }
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [hidden], timeout: 10)
        if let processError { throw processError }
        let current = try runningApplication(for: app, expectedPID: pid)
        guard result == .completed, current.isHidden else {
            throw TestHelperError(description: "The test app did not finish hiding within 10 seconds (PID: \(pid), hidden: \(current.isHidden), active: \(current.isActive), state: \(app.state), waiter: \(result)).")
        }
        try await reopen(app, expectedPID: pid)
    }
    private func reopen(_ app: XCUIApplication, expectedPID: Int32? = nil) async throws {
        let running = try runningApplication(for: app, expectedPID: expectedPID)
        let url = try XCTUnwrap(running.bundleURL)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = expectation(description: "Dock-style reopen finishes")
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        await fulfillment(of: [opened], timeout: 10)
        _ = try runningApplication(for: app, expectedPID: running.processIdentifier)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    func testCommandFRevealsSidebarAndFocusesInsertedSearch() throws {
        let app = try app()
        try launch(app)
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
        try requirePhysicalInputAccess()
        let app = try app()
        try launch(app)
        waitForTitle("Plasma", in: app)
        let window = app.windows.firstMatch
        try openViewMenu(in: app)
        let enter = app.menuItems["Enter Full Screen"]
        try waitForMenuElement(enter, named: "Enter Full Screen")
        enter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(window.buttons[XCUIIdentifierMinimizeWindow].waitForNonExistence(timeout: 15))
        XCTAssertTrue(element("scene-search", in: app).exists)
        waitForTitle("Plasma", in: app)
        try exitFullScreen(in: app)
        XCTAssertTrue(window.buttons[XCUIIdentifierMinimizeWindow].waitForExistence(timeout: 15))
        XCTAssertTrue(element("scene-search", in: app).exists)
    }

    func testCachedUpdateFailureIsInlineAndRetryRecovers() throws {
        let app = try app(arguments: ["--ui-test-fail-refresh"])
        try launch(app)
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
        XCTAssertTrue(offline.staticTexts["Couldn’t load scenes. Choose or reload your shader folder and try again."].exists)
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

    func testReactivationRecoveryClosesPendingCatalogSheet() async throws {
        let app = try app(arguments: ["--ui-test-metal-unavailable", "--ui-test-download-catalog", "--ui-test-fail-catalog-once"])
        app.launch()
        XCTAssertTrue(app.staticTexts["Renderer Unavailable"].waitForExistence(timeout: 10))
        app.windows.firstMatch.buttons["OK"].click()
        let failure = app.staticTexts["Unable to Load Scenes"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        try await hideAndReopen(app)
        XCTAssertTrue(element("shader-aurora", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(failure.waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.windows.firstMatch.sheets.count, 0)
        let search = element("scene-search", in: app)
        XCTAssertTrue(search.isHittable)
        search.click()
        search.typeText("aurora")
        XCTAssertFalse(element("shader-plasma", in: app).exists)
        XCTAssertTrue(app.staticTexts["Metal rendering is unavailable on this device."].exists)
    }

    func testRendererAlertSupportsReturn() throws {
        try assertRendererAlertDismissal(using: .return)
    }

    func testRendererAlertSupportsEscape() throws {
        try assertRendererAlertDismissal(using: .escape)
    }

    private func assertRendererAlertDismissal(using key: XCUIKeyboardKey) throws {
        if key == .escape { try requirePhysicalInputAccess() }
        let app = try app(arguments: ["--ui-test-metal-unavailable"])
        app.launch()
        let failure = app.staticTexts["Renderer Unavailable"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        failure.click()
        if key == .escape {
            // Exercise physical Escape delivery; XCTest's special-key synthesis
            // does not deliver this key to native sheets on this test host.
            let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
            let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false))
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        } else {
            app.typeKey(key, modifierFlags: [])
        }
        XCTAssertTrue(failure.waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.windows.firstMatch.sheets.count, 0)
        XCTAssertTrue(app.staticTexts["Metal rendering is unavailable on this device."].exists)
        app.terminate()
    }

    func testReplacedCatalogAndRendererFailuresShowCurrentSheet() throws {
        for action in ["OK", "Retry"] {
            let arguments = action == "Retry"
                ? ["--ui-test-download-catalog", "--ui-test-fail-catalog-once"]
                : ["--ui-test-empty-cache"]
            let app = try app(arguments: arguments + ["--ui-test-replace-presented-failure"])
            app.launch()
            let replacement = app.staticTexts["A newer scene download failure occurred."]
            XCTAssertTrue(replacement.waitForExistence(timeout: 10))
            XCTAssertEqual(app.windows.firstMatch.sheets.count, 1)
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.staticTexts["A newer scene download failure occurred."].exists)
            XCTAssertFalse(sheet.staticTexts["Couldn’t load scenes. Choose or reload your shader folder and try again."].exists)
            sheet.buttons[action].click()
            XCTAssertTrue(replacement.waitForNonExistence(timeout: 10))
            if action == "Retry" { waitForTitle("Plasma", in: app) }
            else { XCTAssertTrue(app.staticTexts["No Scenes Yet"].exists) }
            XCTAssertEqual(app.windows.firstMatch.sheets.count, 0)
            app.terminate()
        }
        let renderer = try app(arguments: ["--ui-test-metal-unavailable", "--ui-test-replace-presented-failure"])
        renderer.launch()
        let replacement = renderer.staticTexts["A newer renderer startup failure occurred."]
        XCTAssertTrue(replacement.waitForExistence(timeout: 10))
        XCTAssertEqual(renderer.windows.firstMatch.sheets.count, 1)
        let sheet = renderer.windows.firstMatch.sheets.firstMatch
        XCTAssertTrue(sheet.staticTexts["A newer renderer startup failure occurred."].exists)
        XCTAssertFalse(sheet.buttons["Retry"].exists)
        sheet.buttons["OK"].click()
        XCTAssertTrue(replacement.waitForNonExistence(timeout: 10))
        XCTAssertTrue(renderer.staticTexts["Renderer Unavailable"].waitForNonExistence(timeout: 10))
        XCTAssertEqual(renderer.windows.firstMatch.sheets.count, 0)
        XCTAssertTrue(renderer.staticTexts["Metal rendering is unavailable on this device."].exists)
    }

    func testReplacedSelectionFailureRetriesTheNewerScene() throws {
        let app = try app(arguments: ["--ui-test-selection-failure", "--ui-test-replace-presented-failure"])
        app.launch()
        let replacement = app.staticTexts["A newer Waves selection failure occurred."]
        XCTAssertTrue(replacement.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["An older Aurora selection failure occurred."].exists)
        XCTAssertEqual(app.windows.firstMatch.sheets.count, 1)
        waitForTitle("Plasma", in: app)
        app.windows.firstMatch.sheets.firstMatch.buttons["Retry"].click()
        waitForTitle("Waves", in: app)
        XCTAssertTrue(replacement.waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.windows.firstMatch.sheets.count, 0)
    }

    func testRepeatedRendererInstallationKeepsThePendingSheet() throws {
        let app = try app(arguments: ["--ui-test-metal-unavailable", "--ui-test-repeat-renderer-installation"])
        app.launch()
        let sheet = app.windows.firstMatch.sheets["renderer-reinstallation-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(sheet.staticTexts["Renderer Unavailable"].exists)
        XCTAssertEqual(app.windows.firstMatch.sheets.count, 1)
        sheet.buttons["OK"].click()
        XCTAssertTrue(app.staticTexts["Renderer Unavailable"].waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.windows.firstMatch.sheets.count, 0)
        XCTAssertTrue(app.staticTexts["Metal rendering is unavailable on this device."].exists)
    }

    func testCleanupReadinessTimeoutTerminatesAndCanRetry() throws {
        let suite = "HolodeckMacUITests-" + UUID().uuidString
        let app = try app(suite: suite)
        let cleanup = try XCTUnwrap(cleanups[ObjectIdentifier(app)])
        var readinessChecks = 0
        XCTAssertThrowsError(try cleanup.run(waitForWindow: { _ in
            readinessChecks += 1
            return false
        })) { error in
            XCTAssertEqual(error as? StorageSuiteCleanup.ReadinessError, .windowNotReady(suite: suite))
        }
        XCTAssertEqual(app.state, .notRunning)
        try cleanup.run(waitForWindow: { application in
            readinessChecks += 1
            return application.windows["holodeck-viewer-window"].waitForExistence(timeout: 15)
        })
        XCTAssertEqual(app.state, .notRunning)
        try cleanup.run(waitForWindow: { _ in
            readinessChecks += 1
            return false
        })
        XCTAssertEqual(readinessChecks, 2, "Completed cleanup must not launch or wait again")
        XCTAssertEqual(app.state, .notRunning)
    }

    func testNamedWindowFramePersistsAndCleanupCannotRecreateIt() throws {
        let suite = "HolodeckMacUITests-" + UUID().uuidString
        let name = "HolodeckViewer-" + suite
        let live = savedFrame("HolodeckViewer-live", allowMissing: true)
        let app = try app(suite: suite)
        try launch(app)
        waitForTitle("Plasma", in: app)
        resizeWindow(in: app)
        let resized = app.windows["holodeck-viewer-window"].frame.size
        // Termination flushes AppKit's autosaved preferences before reading their disk copy.
        app.terminate()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in savedFrame(name, allowMissing: true) != nil }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        let frame = try XCTUnwrap(savedFrame(name))
        try launch(app)
        XCTAssertEqual(app.windows["holodeck-viewer-window"].frame.width, resized.width, accuracy: 1)
        XCTAssertEqual(app.windows["holodeck-viewer-window"].frame.height, resized.height, accuracy: 1)
        XCTAssertEqual(savedFrame(name), frame)
        app.terminate()
        let cleanup = try XCTUnwrap(cleanups[ObjectIdentifier(app)])
        try cleanup.run()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in savedFrame(name, allowMissing: true) == nil }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertNil(savedFrame(name, allowMissing: true), "Cleanup must not save another frame while terminating")
        XCTAssertEqual(savedFrame("HolodeckViewer-live", allowMissing: true), live)
    }

    func testImplicitFixtureDoesNotSaveWindowFrame() throws {
        let controlSuite = "HolodeckMacUITests-" + UUID().uuidString
        let controlName = "HolodeckViewer-" + controlSuite
        let control = try app(suite: controlSuite)
        try launch(control)
        waitForTitle("Plasma", in: control)
        resizeWindow(in: control)
        control.terminate()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in savedFrame(controlName, allowMissing: true) != nil }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        XCTAssertNotNil(savedFrame(controlName), "The reader must observe a frame written by this test build")
        let before = savedViewerFrameNames()
        let live = savedFrame("HolodeckViewer-live")
        let app = try app(suite: nil) // The fixture environment alone selects implicit in-memory storage.
        try launch(app)
        waitForTitle("Plasma", in: app)
        resizeWindow(in: app)
        app.terminate()
        // Earlier cleanup writes may still be flushing; only new frames indicate a leak.
        XCTAssertTrue(savedViewerFrameNames().subtracting(before).isEmpty)
        XCTAssertEqual(savedFrame("HolodeckViewer-live"), live)
        XCTAssertNotNil(savedFrame(controlName))
    }

    func testPreferencesReaderRejectsMissingAndMalformedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try AppPreferencesReader.read(at: directory, allowMissing: true))
        let url = directory.appendingPathComponent("preferences.plist")
        XCTAssertThrowsError(try AppPreferencesReader.read(at: url))
        XCTAssertTrue(try AppPreferencesReader.read(at: url, allowMissing: true).isEmpty)
        try Data("invalid plist".utf8).write(to: url)
        XCTAssertThrowsError(try AppPreferencesReader.read(at: url, allowMissing: true))
        try PropertyListSerialization.data(fromPropertyList: ["unexpected root"], format: .binary, options: 0).write(to: url)
        XCTAssertThrowsError(try AppPreferencesReader.read(at: url))
    }

    private func savedFrame(_ name: String, allowMissing: Bool = false) -> String? {
        savedAppDefaults(allowMissing: allowMissing)["NSWindow Frame " + name] as? String
    }

    private func savedViewerFrameNames() -> Set<String> {
        Set(savedAppDefaults().keys.filter { $0.hasPrefix("NSWindow Frame HolodeckViewer-") })
    }

    private func savedAppDefaults(allowMissing: Bool = false) -> [String: Any] {
        do { return try AppPreferencesReader.read(at: AppPreferencesReader.appURL(bundleIdentifier: MacUITestSettings.bundleIdentifier), allowMissing: allowMissing) }
        catch {
            XCTFail("Unable to read viewer preferences: \(error)")
            return [:]
        }
    }

    private func resizeWindow(in app: XCUIApplication) {
        let window = app.windows["holodeck-viewer-window"]
        let size = window.frame.size
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -1, dy: 0))
        edge.click(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: -80, dy: 0)))
        XCTAssertNotEqual(window.frame.size, size)
    }

    func testDiscoveryFiltersSearchAndResetPreservePlayback() throws {
        let app = try app(discovery: true)
        try launch(app)
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

@MainActor
private final class StorageSuiteCleanup {
    enum ReadinessError: LocalizedError, Equatable {
        case windowNotReady(suite: String)

        var errorDescription: String? {
            switch self {
            case .windowNotReady(let suite): "Cleanup viewer window did not appear for storage suite \(suite)."
            }
        }
    }

    private let app: XCUIApplication
    private let suite: String
    private var completed = false

    init(app: XCUIApplication, suite: String) { self.app = app; self.suite = suite }

    func run(waitForWindow: ((XCUIApplication) -> Bool)? = nil) throws {
        guard !completed else { return }
        app.terminate()
        app.launchEnvironment.removeAll()
        app.launchArguments = MacUITestSettings.ignoreSavedStateArguments + ["--ui-test-storage-suite", suite, "--ui-test-cleanup-storage-suite"]
        app.launch()
        let ready = waitForWindow?(app) ?? app.windows["holodeck-viewer-window"].waitForExistence(timeout: 15)
        app.terminate()
        guard ready else { throw ReadinessError.windowNotReady(suite: suite) }
        completed = true
    }
}
