import XCTest

@MainActor
final class HolodeckUITests: XCTestCase {
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws { continueAfterFailure = false }

    func testCatalogRefreshPreservesFocusPlaybackAndShowsNinthShader() {
        let app = isolatedApp()
        app.launchArguments.append("--ui-test-refresh-catalog")
        app.launch()
        XCTAssertTrue(app.staticTexts["Press Select to choose a shader"].waitForExistence(timeout: 15))
        openPicker(in: app)
        remote.press(.right)
        let aurora = card("aurora", in: app)
        waitForFocus(aurora)
        remote.press(.playPause)
        waitForFocus(aurora)
        XCTAssertEqual(aurora.value as? String, "")
        remote.press(.right)
        let plasma = card("plasma", in: app)
        waitForFocus(plasma)
        XCTAssertEqual(plasma.value as? String, "Now showing")
        remote.press(.right)
        let ninth = card("ninth-shader", in: app)
        waitForFocus(ninth)
        XCTAssertTrue(ninth.label.contains("Updated"))
        remote.press(.select)
        XCTAssertTrue(app.otherElements["shader-picker"].waitForNonExistence(timeout: 10))
        openPicker(in: app)
        waitForFocus(ninth)
        XCTAssertEqual(ninth.value as? String, "Now showing")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Remote catalog with preview and update date"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testDefaultLaunchSelectionAndFocusRestoration() {
        let app = launchShowcase()
        openPicker(in: app)
        let plasma = card("plasma", in: app)
        XCTAssertEqual(plasma.value as? String, "Now showing")
        waitForFocus(plasma)
        remote.press(.right)
        waitForFocus(card("aurora", in: app))
        remote.press(.select)
        XCTAssertTrue(app.otherElements["shader-picker"].waitForNonExistence(timeout: 10))
        openPicker(in: app)
        waitForFocus(card("aurora", in: app))
        XCTAssertEqual(card("aurora", in: app).value as? String, "Now showing")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Shader picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testBackDismissesWithoutChangingShader() {
        let app = launchShowcase()
        openPicker(in: app)
        remote.press(.right)
        remote.press(.menu)
        XCTAssertTrue(app.otherElements["shader-picker"].waitForNonExistence(timeout: 5))
        let leavesForeground = XCTNSPredicateExpectation(predicate: NSPredicate(format: "state != %d", XCUIApplication.State.runningForeground.rawValue), object: app)
        leavesForeground.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [leavesForeground], timeout: 2), .completed)
        openPicker(in: app)
        XCTAssertEqual(card("plasma", in: app).value as? String, "Now showing")
        waitForFocus(card("plasma", in: app))
    }

    func testRelaunchRestoresLastSuccessfullyActivatedShader() {
        let app = launchShowcase()
        openPicker(in: app)
        remote.press(.right)
        waitForFocus(card("aurora", in: app))
        remote.press(.select)
        XCTAssertTrue(app.otherElements["shader-picker"].waitForNonExistence(timeout: 10))
        app.terminate()
        // Retain this test's storage suite across processes.
        app.launch()
        XCTAssertTrue(app.staticTexts["Press Select to choose a shader"].waitForExistence(timeout: 15))
        openPicker(in: app)
        waitForFocus(card("aurora", in: app))
        XCTAssertEqual(card("aurora", in: app).value as? String, "Now showing")
    }

    func testEveryShader() {
        let app = launchShowcase()
        let ids = ["plasma", "aurora", "waves", "kaleidoscope", "starfield", "chrome", "brushed-gold", "iridescent"]
        for (index, id) in ids.enumerated() {
            openPicker(in: app)
            if index > 0 { remote.press(.right) }
            let item = card(id, in: app)
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            waitForFocus(item)
            remote.press(.select)
            XCTAssertTrue(app.otherElements["shader-picker"].waitForNonExistence(timeout: 10))
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = id
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    func testBackgroundResume() {
        let app = launchShowcase()
        openPicker(in: app)
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(app.otherElements["shader-picker"].waitForNonExistence(timeout: 10))
        remote.press(.home)
        waitForBackground(app)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        let surface = app.otherElements["shader-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        waitForFocus(surface)
        openPicker(in: app)
        XCTAssertEqual(card("aurora", in: app).value as? String, "Now showing")
        waitForFocus(card("aurora", in: app))
    }

    func testUnavailableRendererKeepsErrorAndBackReturnsHome() {
        let app = isolatedApp()
        app.launchArguments += ["--ui-test-metal-unavailable"]
        app.launch()
        let status = app.staticTexts["shader-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Metal rendering is unavailable on this device.")
        waitForFocus(app.otherElements["shader-surface"])
        remote.press(.select)
        XCTAssertEqual(status.label, "Metal rendering is unavailable on this device.")
        XCTAssertTrue(app.otherElements["shader-picker"].exists)
        remote.press(.menu)
        waitForBackground(app)
    }

    func testInitialLoadingPreservesOpenPickerAndBrowsingFocus() {
        checkInitialResultPreservesBrowsing(fails: false)
    }

    func testInitialFailurePreservesOpenPickerAndBrowsingFocus() {
        checkInitialResultPreservesBrowsing(fails: true)
    }

    private func checkInitialResultPreservesBrowsing(fails: Bool) {
        let app = isolatedApp()
        app.launchArguments += ["--ui-test-hold-initial-shader"]
        if fails { app.launchArguments.append("--ui-test-fail-initial-shader") }
        app.launch()
        XCTAssertTrue(app.staticTexts["Loading Plasma…"].waitForExistence(timeout: 5))
        openPicker(in: app)
        browseToChrome(in: app)
        remote.press(.playPause)
        let text = fails ? "Couldn’t load Plasma" : "Now showing Plasma"
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", text),
                                                object: app.staticTexts["shader-status"])
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
        XCTAssertTrue(app.otherElements["shader-picker"].exists)
        waitForFocus(card("chrome", in: app))
        XCTAssertFalse(app.staticTexts["Press Select to choose a shader"].exists)
    }

    func testStartupBackRestoresLoadingHint() {
        let app = isolatedApp()
        app.launchArguments += ["--ui-test-hold-initial-shader"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Loading Plasma…"].waitForExistence(timeout: 5))
        openPicker(in: app)
        remote.press(.menu)
        XCTAssertTrue(app.otherElements["shader-picker"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Loading Plasma…"].waitForExistence(timeout: 5))
        remote.press(.playPause)
        XCTAssertTrue(app.staticTexts["Press Select to choose a shader"].waitForExistence(timeout: 10))
    }

    func testPickerOpenBackgroundResumeKeepsBrowsingFocus() {
        let app = launchShowcase()
        openPicker(in: app)
        browseToChrome(in: app)
        remote.press(.home)
        waitForBackground(app)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(app.otherElements["shader-picker"].waitForExistence(timeout: 5))
        waitForFocus(card("chrome", in: app))
        XCTAssertTrue(app.staticTexts["shader-status"].label.hasPrefix("Now showing Plasma"))
    }

    func testControlCenterResumeKeepsBrowsingFocus() {
        let app = launchShowcase()
        openPicker(in: app)
        browseToChrome(in: app)
        remote.press(.home, forDuration: 1.5)
        let system = XCUIApplication(bundleIdentifier: "com.apple.TVSystemUIService")
        let controlCenterButton = system.buttons["com.apple.TVSystemUIService.status.controlCenter"]
        XCTAssertTrue(controlCenterButton.waitForExistence(timeout: 5))
        waitForFocus(controlCenterButton)
        let controlCenter = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        controlCenter.name = "Control Center over picker"
        controlCenter.lifetime = .keepAlways
        add(controlCenter)
        remote.press(.menu)
        XCTAssertTrue(controlCenterButton.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        waitForFocus(card("chrome", in: app))
        XCTAssertTrue(app.otherElements["shader-picker"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Picker after Control Center"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testRepeatedActivationKeepsBrowsingFocus() {
        let app = isolatedApp()
        app.launchArguments += ["--ui-test-repeat-activation"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Press Select to choose a shader"].waitForExistence(timeout: 15))
        openPicker(in: app)
        browseToChrome(in: app)
        for _ in 0..<3 {
            remote.press(.playPause)
            waitForFocus(card("chrome", in: app))
        }
    }

    private func browseToChrome(in app: XCUIApplication) {
        waitForFocus(card("plasma", in: app))
        for id in ["aurora", "waves", "kaleidoscope", "starfield", "chrome"] {
            remote.press(.right)
            waitForFocus(card(id, in: app))
        }
    }

    private func waitForFocus(_ element: XCUIElement) {
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed, element.identifier)
    }

    private func waitForBackground(_ app: XCUIApplication) {
        let states = [XCUIApplication.State.runningBackground.rawValue,
                      XCUIApplication.State.runningBackgroundSuspended.rawValue] as NSArray
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "state IN %@", states), object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 5), .completed)
    }

    private func isolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-storage-suite", "me.haroldmartin.Holodeck.ui-tests." + UUID().uuidString]
        return app
    }

    private func launchShowcase() -> XCUIApplication {
        let app = isolatedApp()
        app.launch()
        XCTAssertTrue(app.staticTexts["Press Select to choose a shader"].waitForExistence(timeout: 15))
        return app
    }

    private func openPicker(in app: XCUIApplication) {
        remote.press(.select)
        XCTAssertTrue(app.otherElements["shader-picker"].waitForExistence(timeout: 5))
    }

    private func card(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "shader-\(id)").firstMatch
    }
}
