import XCTest

@MainActor
final class HolodeckUITests: XCTestCase {
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws { continueAfterFailure = false }

    func testDefaultLaunchSelectionAndFocusRestoration() {
        let app = launchShowcase()
        openPicker(in: app)
        let plasma = card("plasma", in: app)
        XCTAssertEqual(plasma.value as? String, "Now showing")
        XCTAssertTrue(plasma.hasFocus)
        remote.press(.right)
        XCTAssertTrue(card("aurora", in: app).hasFocus)
        remote.press(.select)
        XCTAssertTrue(app.otherElements["shader-picker"].waitForNonExistence(timeout: 10))
        openPicker(in: app)
        XCTAssertTrue(card("aurora", in: app).hasFocus)
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
        XCTAssertEqual(app.state, .runningForeground)
        openPicker(in: app)
        XCTAssertEqual(card("plasma", in: app).value as? String, "Now showing")
        XCTAssertTrue(card("plasma", in: app).hasFocus)
    }

    func testEveryShader() {
        let app = launchShowcase()
        let ids = ["plasma", "aurora", "waves", "kaleidoscope", "starfield", "chrome", "brushed-gold", "iridescent"]
        for (index, id) in ids.enumerated() {
            openPicker(in: app)
            if index > 0 { remote.press(.right) }
            let item = card(id, in: app)
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            XCTAssertTrue(item.hasFocus, id)
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
        let focusRestored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: surface)
        XCTAssertEqual(XCTWaiter.wait(for: [focusRestored], timeout: 5), .completed)
        openPicker(in: app)
        XCTAssertEqual(card("aurora", in: app).value as? String, "Now showing")
        XCTAssertTrue(card("aurora", in: app).hasFocus)
    }

    func testUnavailableRendererKeepsErrorAndBackReturnsHome() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-metal-unavailable"]
        app.launch()
        let status = app.staticTexts["shader-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Metal rendering is unavailable on this device.")
        XCTAssertTrue(app.otherElements["shader-surface"].hasFocus)
        remote.press(.select)
        XCTAssertEqual(status.label, "Metal rendering is unavailable on this device.")
        XCTAssertTrue(app.otherElements["shader-picker"].exists)
        remote.press(.menu)
        waitForBackground(app)
    }

    func testInitialLoadingPreservesOpenPickerAndBrowsingFocus() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-hold-initial-shader"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Loading Plasma…"].waitForExistence(timeout: 5))
        openPicker(in: app)
        for id in ["aurora", "waves", "kaleidoscope", "starfield", "chrome"] {
            remote.press(.right)
            XCTAssertTrue(card(id, in: app).hasFocus)
        }
        remote.press(.playPause)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "Now showing Plasma"),
                                              object: app.staticTexts["shader-status"])
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        XCTAssertTrue(app.otherElements["shader-picker"].exists)
        XCTAssertTrue(card("chrome", in: app).hasFocus)
        XCTAssertFalse(app.staticTexts["Press Select to choose a shader"].exists)
    }

    private func waitForBackground(_ app: XCUIApplication) {
        let states = [XCUIApplication.State.runningBackground.rawValue,
                      XCUIApplication.State.runningBackgroundSuspended.rawValue] as NSArray
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "state IN %@", states), object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 5), .completed)
    }

    private func launchShowcase() -> XCUIApplication {
        let app = XCUIApplication()
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
