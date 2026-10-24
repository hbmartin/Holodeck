import AppKit
import Darwin
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
            if arguments.contains("--ui-test-local-library") {
                app.launchEnvironment["HOLODECK_UI_TEST_REQUEST_DIRECTORY"] = requestDirectory(suite: suite).path
            }
            let cleanup = StorageSuiteCleanup(app: app, suite: suite)
            cleanups[ObjectIdentifier(app)] = cleanup
            addTeardownBlock { @MainActor in try cleanup.run() }
        }
        return app
    }
    private func requestDirectory(suite: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holodeck/Requests-tests-\(suite)")
    }
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testShaderRequestSettingsWindowQueuedCancellationAndRetainedRecord() throws {
        let suite = "HolodeckMacUITests-" + UUID().uuidString
        let directory = requestDirectory(suite: suite)
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(id), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let request: [String: Any] = ["id": id, "purpose": "creative", "origin": "manual", "prompt": "UI request fixture", "context": [
            "shaderID": "plasma", "name": "Plasma", "category": "PROCEDURAL", "description": "Captured scene", "colors": [[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]],
            "source": "", "sourceHash": String(repeating: "0", count: 64), "screenshot": "", "animationTime": 3.0, "drawableWidth": 1920, "drawableHeight": 1080]]
        let status: [String: Any] = ["id": id, "request": request, "deviceID": "fixture-TV", "createdAt": Date().timeIntervalSinceReferenceDate,
            "updatedAt": Date().timeIntervalSinceReferenceDate, "stage": "queued", "message": "Waiting for the Mac worker", "sequence": 0]
        let config: [String: Any] = ["repository": "", "codex": "/opt/homebrew/bin/codex", "python": "/usr/bin/python3", "git": "/usr/bin/git", "shaderTool": "", "model": "", "reasoning": "high", "enabled": false]
        let journal = try JSONSerialization.data(withJSONObject: [["status": status, "configuration": config, "revoked": false]])
        let app = try app(suite: suite, arguments: ["--ui-test-local-library"])
        app.launchEnvironment["HOLODECK_UI_TEST_REQUEST_JOURNAL"] = String(decoding: journal, as: UTF8.self)
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows["holodeck-viewer-window"].waitForExistence(timeout: 15))
        let settings = element("shader-library-settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.click()
        XCTAssertTrue(element("request-model", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(element("enable-shader-requests", in: app).isEnabled)
        app.buttons["Open Requests"].firstMatch.click()
        let requests = element("shader-requests-list", in: app)
        XCTAssertTrue(requests.waitForExistence(timeout: 10))
        let row = element("shader-request-" + id, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
        let cancel = app.buttons["Cancel Queued Request"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.click()
        XCTAssertTrue(app.buttons["Delete Record"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open Logs and Evidence"].firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Requests window retains cancelled work"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["Delete Record"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Choose a request to inspect its progress, logs and visual evidence."].waitForExistence(timeout: 10))
        XCTAssertFalse(element("shader-request-" + id, in: app).exists)
    }

    func testCheckoutRecoveryPathsAndDetachKeepEvidence() throws {
        let suite = "HolodeckMacUITests-" + UUID().uuidString, id = UUID().uuidString
        let directory = requestDirectory(suite: suite)
        let job = directory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let evidence = job.appendingPathComponent("changes.patch")
        try Data("retained unpublished evidence".utf8).write(to: evidence)
        let request: [String: Any] = ["id": id, "purpose": "creative", "origin": "manual", "prompt": "Recovery fixture", "context": [
            "shaderID": "plasma", "name": "Plasma", "category": "PROCEDURAL", "description": "Captured scene", "colors": [[0.0,0.0,0.0],[1.0,1.0,1.0]],
            "source": "", "sourceHash": String(repeating: "0", count: 64), "screenshot": "", "animationTime": 3.0, "drawableWidth": 1920, "drawableHeight": 1080]]
        let status: [String: Any] = ["id": id, "request": request, "deviceID": "fixture-TV", "createdAt": Date().timeIntervalSinceReferenceDate,
            "updatedAt": Date().timeIntervalSinceReferenceDate, "stage": "failed", "message": "Cleanup pending", "sequence": 0]
        let config: [String: Any] = ["repository": directory.appendingPathComponent("missing-checkout").path, "codex": "/unavailable/codex",
            "python": "/unavailable/python", "git": "/usr/bin/git", "shaderTool": "", "model": "", "reasoning": "high", "enabled": false]
        let journal = try JSONSerialization.data(withJSONObject: [["status": status, "configuration": config, "revoked": false, "cleanupPending": true]])
        let app = try app(suite: suite, arguments: ["--ui-test-local-library"])
        app.launchEnvironment["HOLODECK_UI_TEST_REQUEST_JOURNAL"] = String(decoding: journal, as: UTF8.self)
        app.launch(); app.activate()
        let settings = element("shader-library-settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.click()
        let retry = element("retry-checkout-cleanup", in: app)
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: retry)
        XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 10), .completed)
        let python = element("recovery-python", in: app)
        app.activate()
        XCTAssertTrue(app.wait(for:.runningForeground,timeout:5))
        python.click(); python.typeKey("a", modifierFlags: .command); python.typeText("/usr/bin/python3")
        XCTAssertTrue(element("recovery-repository", in: app).exists)
        XCTAssertTrue(element("recovery-git", in: app).exists)
        retry.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: retry)], timeout: 10), .completed)
        element("detach-checkout", in: app).click()
        let detach = app.windows.buttons["Detach and Keep Files"].firstMatch
        XCTAssertTrue(detach.waitForExistence(timeout: 10)); detach.click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: retry)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertTrue(element("choose-shader-folder", in: app).isEnabled)
        XCTAssertEqual(try String(contentsOf: evidence, encoding: .utf8), "retained unpublished evidence")
    }

    func testReconciliationRecoveryWithoutPendingCleanupCanRetry() throws {
        let suite = "HolodeckMacUITests-" + UUID().uuidString
        let directory = requestDirectory(suite: suite)
        let setup = directory.appendingPathComponent("setup")
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let marker = setup.appendingPathComponent("process.json")
        try Data("{}".utf8).write(to: marker)
        let app = try app(suite: suite, arguments: ["--ui-test-local-library"])
        app.launch(); app.activate()
        let settings = element("shader-library-settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.click()
        let retry = element("retry-checkout-cleanup", in: app)
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertFalse(element("recovery-repository", in: app).exists)
        try FileManager.default.removeItem(at: marker)
        retry.click()
        let recovered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: retry)
        XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 10), .completed)
        XCTAssertTrue(element("choose-shader-folder", in: app).isEnabled)
    }

    private func managedRecoveryFixture() throws -> (app: XCUIApplication, authoring: URL, marker: URL, name: String, source: Data) {
        let authoring = try authoringFolderWithInvalidShader()
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let sources = try XCTUnwrap(fixture["sources"] as? [String: String]), source = try XCTUnwrap(sources["plasma"]).data(using: .utf8)!
        try source.write(to: authoring.appendingPathComponent("shaders/plasma/body.metal"))
        var ancestor = Bundle(for:Self.self).bundleURL
        var candidates: [URL] = []
        for _ in 0..<6 {
            candidates.append(ancestor.appendingPathComponent("HolodeckCore_HolodeckCore.bundle/Contents/Resources/shader_checker.lock.json"))
            candidates.append(ancestor.appendingPathComponent("HolodeckMac.app/Contents/Resources/Tools/HolodeckCore_HolodeckCore.bundle/Contents/Resources/shader_checker.lock.json"))
            ancestor.deleteLastPathComponent()
        }
        let releaseLock = try XCTUnwrap(candidates.first { FileManager.default.fileExists(atPath:$0.path) },"Packaged checker lock is missing")
        try Data(contentsOf:releaseLock).write(to:authoring.appendingPathComponent("shader_checker.lock.json"))
        for arguments in [["init", "--quiet", "-b", "main"], ["add", "--all"],
                          ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "UI fixture"]] {
            // /usr/bin/git invokes xcrun, which is unavailable in the sandboxed UI runner.
            let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
            let git = Process(), errors = Pipe()
            git.executableURL = URL(fileURLWithPath: developer).appendingPathComponent("usr/bin/git")
            git.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + arguments
            git.environment = ProcessInfo.processInfo.environment.merging(["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]) { _, new in new }
            git.currentDirectoryURL = authoring; git.standardOutput = Pipe(); git.standardError = errors
            try git.run(); git.waitUntilExit()
            guard git.terminationStatus == 0 else {
                throw TestHelperError(description: "Fixture git \(arguments): " + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            }
        }
        let suite = "HolodeckMacUITests-" + UUID().uuidString, directory = requestDirectory(suite: suite)
        let setup = directory.appendingPathComponent("setup")
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let marker = setup.appendingPathComponent("process.json")
        try Data("{}".utf8).write(to: marker)
        let config: [String: Any] = ["repository": authoring.path, "codex": "/unavailable/codex", "python": "/usr/bin/python3", "git": "/usr/bin/git",
            "shaderTool": "", "model": "fixture", "reasoning": "high", "enabled": true]
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("preferences.json"))
        try JSONSerialization.data(withJSONObject: config).write(to: setup.appendingPathComponent("configuration.json"))
        let app = try app(suite: suite, arguments: ["--ui-test-local-library"])
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: authoring.appendingPathComponent("shaders/plasma/metadata.json"))) as? [String: Any])
        return (app, authoring, marker, metadata["name"] as! String, source)
    }
    private func waitForLibraryError(_ text: String, in app: XCUIApplication) {
        let error = element("shader-library-error", in: app)
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text), object: error)
        let result = XCTWaiter.wait(for: [expected], timeout: 15)
        XCTAssertEqual(result, .completed, "Expected \(text); observed: \(error.exists ? String(describing: error.value) + " / " + error.label : app.debugDescription)")
    }
    private func waitForLibraryIdle(in app: XCUIApplication) {
        let spinner = element("shader-library-reloading", in: app)
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: spinner)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 15), .completed)
    }

    private func dismissInitialCatalogFailure(in app: XCUIApplication) {
        // The empty initial catalog and checkout recovery have no shared operation ID.
        // Keep the independent catalog alert visible until the user dismisses it.
        XCTAssertTrue(app.staticTexts["Unable to Load Scenes"].waitForExistence(timeout: 15))
        app.windows["holodeck-viewer-window"].buttons["OK"].firstMatch.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.staticTexts["Unable to Load Scenes"])], timeout: 10), .completed)
    }

    func testPublicationRecoveryReportsLockContentionAndExplicitRebuildRecovers() throws {
        let f = try managedRecoveryFixture(), app = f.app
        let lease = open(f.authoring.appendingPathComponent(".git/holodeck-requests.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(lease, 0); XCTAssertEqual(flock(lease, LOCK_EX | LOCK_NB), 0)
        defer { flock(lease, LOCK_UN); close(lease) }
        app.launch(); app.activate()
        dismissInitialCatalogFailure(in: app)
        let settings = element("shader-library-settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.click()
        waitForLibraryError("needs checkout recovery", in: app); waitForLibraryIdle(in: app)
        XCTAssertFalse(element("rebuild-shader-library", in: app).isEnabled)
        try FileManager.default.removeItem(at: f.marker)
        let recoveryButton = element("retry-checkout-cleanup", in: app)
        XCTAssertTrue(recoveryButton.waitForExistence(timeout:10),app.debugDescription)
        recoveryButton.click()
        waitForLibraryError("Checkout is busy in another process", in: app); waitForLibraryIdle(in: app)
        XCTAssertEqual(flock(lease, LOCK_UN), 0)
        element("rebuild-shader-library", in: app).click()
        waitForTitle(f.name, in: app); waitForLibraryIdle(in: app)
        XCTAssertFalse(element("shader-library-error", in: app).exists)
    }

    func testAutomaticPublicationFailureEndsSpinnerAndExplicitRetryRecovers() throws {
        let f = try managedRecoveryFixture(), app = f.app
        app.launch(); app.activate()
        dismissInitialCatalogFailure(in: app)
        let settings = element("shader-library-settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.click()
        waitForLibraryError("needs checkout recovery", in: app); waitForLibraryIdle(in: app)
        try Data("dirty checkout".utf8).write(to: f.authoring.appendingPathComponent("shaders/plasma/body.metal"))
        try FileManager.default.removeItem(at: f.marker)
        let recoveryButton = element("retry-checkout-cleanup", in: app)
        XCTAssertTrue(recoveryButton.waitForExistence(timeout:10),app.debugDescription)
        recoveryButton.click()
        waitForLibraryError("clean main checkout", in: app); waitForLibraryIdle(in: app)
        let rebuild = element("rebuild-shader-library", in: app)
        XCTAssertTrue(rebuild.isEnabled)
        try f.source.write(to: f.authoring.appendingPathComponent("shaders/plasma/body.metal"))
        rebuild.click()
        waitForTitle(f.name, in: app); waitForLibraryIdle(in: app)
        XCTAssertFalse(element("shader-library-error", in: app).exists)
    }

    func testPostStartupFolderSelectionThenImmediateRebuildUsesSelectedCheckout() throws {
        let f = try managedRecoveryFixture(), app = f.app
        try FileManager.default.removeItem(at: f.marker)
        let directory = f.marker.deletingLastPathComponent().deletingLastPathComponent(), preferences = directory.appendingPathComponent("preferences.json")
        var config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: preferences)) as? [String: Any]); config["enabled"] = false
        try JSONSerialization.data(withJSONObject: config).write(to: preferences)
        app.launchEnvironment["HOLODECK_UI_TEST_SHADER_BOOKMARK"] = try f.authoring.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
        let selected = FileManager.default.temporaryDirectory.appendingPathComponent("SelectedCheckout-"+UUID().uuidString)
        try FileManager.default.copyItem(at: f.authoring, to: selected); addTeardownBlock { try? FileManager.default.removeItem(at: selected) }
        app.launch(); app.activate(); waitForTitle(f.name,in: app)
        element("shader-library-settings",in: app).click(); waitForLibraryIdle(in: app)
        element("choose-shader-folder",in: app).click()
        app.typeKey("g",modifierFlags:[.command,.shift]); app.typeText(selected.path); app.typeKey(.return,modifierFlags:[])
        let confirm = app.windows["open-panel"].buttons["OKButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout:10)); confirm.click()
        waitForLibraryIdle(in: app)
        let rebuild=element("rebuild-shader-library",in:app)
        let enabled=XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:rebuild)
        XCTAssertEqual(XCTWaiter.wait(for:[enabled],timeout:15),.completed); rebuild.click()
        waitForLibraryIdle(in:app)
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("publication/configuration.json").path),"Unmanaged rebuild must not launch a Git publication worker")
        let saved=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:preferences)) as? [String:Any])
        XCTAssertEqual(URL(fileURLWithPath:try XCTUnwrap(saved["repository"] as? String)).resolvingSymlinksInPath(),selected.resolvingSymlinksInPath())

    }

    func testUnrelatedApprovalAndRevocationErrorsDoNotSuppressCatalogAlerts() throws {
        for origin in ["approval","revocation"] {
            let app = try app(arguments:["--ui-test-local-library"])
            app.launchEnvironment["HOLODECK_UI_TEST_ERROR_ASSOCIATION"]="1"
            app.launch();app.activate()
            let settings=element("shader-library-settings",in:app)
            XCTAssertTrue(settings.waitForExistence(timeout:15));settings.click();waitForLibraryIdle(in:app)
            element("test-"+origin+"-catalog-failure",in:app).click()
            XCTAssertTrue(app.staticTexts["Unable to Load Scenes"].waitForExistence(timeout:10))
            XCTAssertTrue(app.staticTexts["Independent catalog failure"].exists)
            app.windows["holodeck-viewer-window"].buttons["OK"].firstMatch.click()
            waitForLibraryError("Previous "+origin+" failed",in:app)
            let presentations = element("test-catalog-alert-count", in: app)
            XCTAssertEqual(presentations.value as? String, "1")
            app.terminate()
        }
    }

    func testPresentedCatalogAlertRetainsActionsWhenCorrelationMetadataChanges() throws {
        let app = try app(arguments:["--ui-test-local-library", "--ui-test-extend-catalog-correlation"])
        app.launchEnvironment["HOLODECK_UI_TEST_ERROR_ASSOCIATION"] = "1"
        app.launch(); app.activate()
        let settings = element("shader-library-settings",in:app)
        XCTAssertTrue(settings.waitForExistence(timeout:15)); settings.click(); waitForLibraryIdle(in:app)
        element("test-approval-catalog-failure",in:app).click()
        let sheet = element("catalog-correlation-sheet",in:app)
        XCTAssertTrue(sheet.waitForExistence(timeout:10))
        let presentations = element("test-catalog-alert-count",in:app)
        let replacement = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value != %@", "1"),object:presentations)
        replacement.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for:[replacement],timeout:2),.completed)
        sheet.buttons["OK"].click()
        let dismissed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:sheet)
        XCTAssertEqual(XCTWaiter.wait(for:[dismissed],timeout:5),.completed)
        waitForLibraryError("Previous approval failed",in:app)
    }

    func testPresentedCatalogAlertUsesNewCorrelationMetadataForSuppression() throws {
        let app = try app(arguments:["--ui-test-local-library", "--ui-test-associate-presented-catalog"])
        app.launchEnvironment["HOLODECK_UI_TEST_ERROR_ASSOCIATION"] = "1"
        app.launch(); app.activate()
        let settings = element("shader-library-settings",in:app)
        XCTAssertTrue(settings.waitForExistence(timeout:15)); settings.click(); waitForLibraryIdle(in:app)
        element("test-approval-catalog-failure",in:app).click()
        waitForLibraryError("Presented catalog failure is represented here",in:app)
        let alert = app.staticTexts["Unable to Load Scenes"]
        let dismissed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:alert)
        XCTAssertEqual(XCTWaiter.wait(for:[dismissed],timeout:5),.completed)
        XCTAssertEqual(element("test-catalog-alert-count",in:app).value as? String,"1")
    }

    func testCorrelatedCatalogFailureIsShownOnce() throws {
        let app = try app(arguments:["--ui-test-local-library"])
        app.launchEnvironment["HOLODECK_UI_TEST_ERROR_ASSOCIATION"] = "1"
        app.launch(); app.activate()
        let settings = element("shader-library-settings",in:app)
        XCTAssertTrue(settings.waitForExistence(timeout:15));settings.click();waitForLibraryIdle(in:app)
        element("test-correlated-catalog-failure",in:app).click()
        waitForLibraryError("Correlated catalog failure",in:app)
        let presentations = element("test-catalog-alert-count", in: app)
        XCTAssertTrue(presentations.waitForExistence(timeout: 10))
        let unexpected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", "0"), object: presentations)
        unexpected.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpected], timeout: 2), .completed)
        XCTAssertFalse(app.staticTexts["Unable to Load Scenes"].exists)
    }

    func testVerifyWaitsForStartupProposalAndLaunchesAgainstAcceptedFolder() throws {
        let f = try managedRecoveryFixture(), app = f.app
        let directory = f.marker.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.removeItem(at: f.marker)
        let preferences = directory.appendingPathComponent("preferences.json")
        var config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: preferences)) as? [String: Any])
        config["enabled"] = false; try JSONSerialization.data(withJSONObject: config).write(to: preferences)
        let selected = FileManager.default.temporaryDirectory.appendingPathComponent("StartupProposal-" + UUID().uuidString)
        try FileManager.default.copyItem(at: f.authoring, to: selected)
        addTeardownBlock { try? FileManager.default.removeItem(at: selected) }
        app.launchArguments += ["--ui-test-hold-startup-selection"]
        app.launchEnvironment["HOLODECK_UI_TEST_SHADER_BOOKMARK"] = try selected.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
        app.launch(); app.activate()
        let settings = element("shader-library-settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.click()
        let release = element("finish-startup-selection", in: app)
        XCTAssertTrue(release.waitForExistence(timeout: 10))
        let setup = directory.appendingPathComponent("setup/configuration.json")
        try? FileManager.default.removeItem(at: setup)
        element("enable-shader-requests", in: app).click()
        let prematurelyLaunched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: setup.path) }, object: nil)
        prematurelyLaunched.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [prematurelyLaunched], timeout: 1), .completed)
        release.click()
        let launched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: setup.path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [launched], timeout: 15), .completed)
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: setup)) as? [String: Any])
        XCTAssertEqual(actual["repository"] as? String, selected.resolvingSymlinksInPath().path)
    }

    func testRejectedStartupBookmarkStillRestoresCachedLibraryAndServer() throws {
        let f = try managedRecoveryFixture(), app = f.app
        try FileManager.default.removeItem(at:f.marker)
        let directory = f.marker.deletingLastPathComponent().deletingLastPathComponent(), preferences = directory.appendingPathComponent("preferences.json")
        var config = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:preferences)) as? [String:Any])
        config["enabled"] = false;try JSONSerialization.data(withJSONObject:config).write(to:preferences)
        app.launchEnvironment["HOLODECK_UI_TEST_SHADER_BOOKMARK"] = try f.authoring.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil).base64EncodedString()
        app.launch();app.activate();waitForTitle(f.name,in:app);app.terminate()
        let rejected = try authoringFolderWithInvalidShader(), journal = directory.appendingPathComponent("setup").resolvingSymlinksInPath().path
        let entry: [String:Any] = ["id":UUID().uuidString,"journal":journal,"disposition":"resume","message":"Independent recovery"]
        try JSONSerialization.data(withJSONObject:["formatVersion":1,"legacyMigrationComplete":true,"entries":[journal:entry]])
            .write(to:directory.appendingPathComponent("recovery.json"))
        app.launchEnvironment["HOLODECK_UI_TEST_SHADER_BOOKMARK"] = try rejected.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil).base64EncodedString()
        app.launch();app.activate();waitForTitle(f.name,in:app)
        element("shader-library-settings",in:app).click();waitForLibraryIdle(in:app)
        let serving = element("shader-serving-status",in:app)
        let ready = XCTNSPredicateExpectation(predicate:NSPredicate(format:"label CONTAINS %@ OR value CONTAINS %@","Serving shaders","Serving shaders"),object:serving)
        XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:15),.completed)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:preferences)) as? [String:Any])
        XCTAssertEqual(saved["repository"] as? String,f.authoring.resolvingSymlinksInPath().path)
    }

    func testUnmanagedBookmarkSelectionSurvivesRequestInitialization() throws {
        let f = try managedRecoveryFixture(), app = f.app
        try FileManager.default.removeItem(at: f.marker)
        let preferences = f.marker.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("preferences.json")
        var config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: preferences)) as? [String: Any])
        let previous = try authoringFolderWithInvalidShader()
        config["enabled"] = false; config["repository"] = previous.path
        try JSONSerialization.data(withJSONObject: config).write(to: preferences)
        app.launchEnvironment["HOLODECK_UI_TEST_SHADER_BOOKMARK"] = try f.authoring.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
        app.launch(); app.activate()
        let settings = element("shader-library-settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.click()
        waitForTitle(f.name, in: app); waitForLibraryIdle(in: app)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: preferences)) as? [String: Any])
        let repository = URL(fileURLWithPath: try XCTUnwrap(saved["repository"] as? String))
        XCTAssertEqual(repository.resolvingSymlinksInPath(), f.authoring.resolvingSymlinksInPath())
    }

    func testAutomaticPublicationRecoveryPreservesUnrelatedBookmarkError() throws {
        let f = try managedRecoveryFixture(), app = f.app
        app.launchEnvironment["HOLODECK_UI_TEST_SHADER_BOOKMARK"] = Data("invalid bookmark".utf8).base64EncodedString()
        app.launch(); app.activate()
        dismissInitialCatalogFailure(in: app)
        let settings = element("shader-library-settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.click()
        XCTAssertTrue(element("retry-checkout-cleanup", in: app).waitForExistence(timeout: 10),app.debugDescription)
        waitForLibraryIdle(in: app); waitForLibraryError("Choose your shader folder again", in: app)
        try FileManager.default.removeItem(at: f.marker)
        let recoveryButton = element("retry-checkout-cleanup", in: app)
        XCTAssertTrue(recoveryButton.waitForExistence(timeout:10),app.debugDescription)
        recoveryButton.click()
        waitForTitle(f.name, in: app); waitForLibraryIdle(in: app)
        waitForLibraryError("Choose your shader folder again", in: app)
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

        let suite = "HolodeckMacUITests-" + UUID().uuidString, id = UUID().uuidString
        let directory = requestDirectory(suite: suite)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let request: [String: Any] = ["id": id, "purpose": "creative", "origin": "manual", "prompt": "Finished warning fixture", "context": [
            "shaderID": "plasma", "name": "Plasma", "category": "PROCEDURAL", "description": "Fixture", "colors": [[0.0,0.0,0.0],[1.0,1.0,1.0]],
            "source": "", "sourceHash": String(repeating: "0", count: 64), "screenshot": "", "animationTime": 3.0, "drawableWidth": 1920, "drawableHeight": 1080]]
        let status: [String: Any] = ["id": id, "request": request, "deviceID": "TV", "createdAt": 0, "updatedAt": 0,
            "stage": "cancelled", "message": "Cancelled fixture", "sequence": 0]
        let config: [String: Any] = ["repository": "", "codex": "/unavailable/codex", "python": "/usr/bin/python3", "git": "/usr/bin/git",
            "shaderTool": "", "model": "", "reasoning": "high", "enabled": false]
        let journal = try JSONSerialization.data(withJSONObject: [["status": status, "configuration": config, "revoked": false]])
        let app = try app(suite: suite, arguments: ["--ui-test-local-library"])
        app.launchEnvironment["HOLODECK_UI_TEST_REQUEST_JOURNAL"] = String(decoding: journal, as: UTF8.self)
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
        try Data("invalid JSON".utf8).write(to: metadataURL)
        reload.click()
        let failure = app.windows["com_apple_SwiftUI_Settings_window"].descendants(matching: .any).matching(identifier: "shader-library-error").firstMatch
        let namedFile = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
            "shaders/plasma/metadata.json", "shaders/plasma/metadata.json"), object: failure)
        XCTAssertEqual(XCTWaiter.wait(for: [namedFile], timeout: 10), .completed)
        waitForTitle("Edited Plasma", in: app)
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        // Rebuild must recover from the failed selection task without restarting or requiring Git.
        element("rebuild-shader-library", in: app).click()
        let cleared = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:failure)
        XCTAssertEqual(XCTWaiter.wait(for:[cleared],timeout:20),.completed)
        waitForTitle("Edited Plasma",in:app)
        app.terminate(); app.launch()
        waitForTitle("Edited Plasma", in: app)
        XCTAssertFalse(app.windows["holodeck-viewer-window"].descendants(matching: .any)
            .matching(identifier: "choose-shader-folder").firstMatch.exists)

        // A failed preview for an unselected scene must not block local publication or playback.
        let broken = root.appendingPathComponent("shaders/broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        var brokenMetadata = metadata
        brokenMetadata["id"] = "broken"; brokenMetadata["name"] = "Broken preview"
        try JSONSerialization.data(withJSONObject: brokenMetadata).write(to: broken.appendingPathComponent("metadata.json"))
        try Data("invalid Metal".utf8).write(to: broken.appendingPathComponent("body.metal"))
        try JSONSerialization.data(withJSONObject: ["shaders": ["plasma", "broken"], "defaultShaderID": "plasma"])
            .write(to: root.appendingPathComponent("index.json"))
        element("shader-library-settings", in: app).click()
        element("reload-shaders", in: app).click()
        let warning = element("shader-preview-warning-broken", in: app)
        XCTAssertTrue(warning.waitForExistence(timeout: 20))
        waitForTitle("Edited Plasma", in: app)
        // An unrelated journal update must preserve the manual reload's warnings.
        app.buttons["Open Requests"].firstMatch.click()
        let row = element("shader-request-" + id, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
        app.buttons["Delete Record"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Choose a request to inspect its progress, logs and visual evidence."].waitForExistence(timeout: 10))
        app.windows["Shader Requests"].buttons[XCUIIdentifierCloseWindow].firstMatch.click()
        XCTAssertTrue(warning.exists)
        try Data(source.utf8).write(to: broken.appendingPathComponent("body.metal"))
        element("reload-shaders", in: app).click()
        let recovered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: warning)
        XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 20), .completed)
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
        let key = "NSWindow Frame HolodeckViewer-" + suite
        let liveKey = "NSWindow Frame HolodeckViewer-live"
        let live = try inspectPreferences(allowMissing: true)[liveKey]
        let app = try app(suite: suite)
        try launch(app)
        waitForTitle("Plasma", in: app)
        resizeWindow(in: app)
        let resized = app.windows["holodeck-viewer-window"].frame.size
        app.terminate()
        let frame = try XCTUnwrap(inspectPreferences(allowMissing: true, until: { $0[key] != nil })[key])
        try launch(app)
        XCTAssertEqual(app.windows["holodeck-viewer-window"].frame.width, resized.width, accuracy: 1)
        XCTAssertEqual(app.windows["holodeck-viewer-window"].frame.height, resized.height, accuracy: 1)
        app.terminate()
        XCTAssertEqual(try inspectPreferences(until: { $0[key] == frame })[key], frame)
        let cleanup = try XCTUnwrap(cleanups[ObjectIdentifier(app)])
        try cleanup.run()
        let after = try inspectPreferences(allowMissing: true, until: { $0[key] == nil })
        XCTAssertNil(after[key], "Cleanup and inspection must not save another viewer frame")
        XCTAssertEqual(after[liveKey], live)
    }

    func testImplicitFixtureDoesNotSaveWindowFrame() throws {
        let controlSuite = "HolodeckMacUITests-" + UUID().uuidString
        let controlKey = "NSWindow Frame HolodeckViewer-" + controlSuite
        let liveKey = "NSWindow Frame HolodeckViewer-live"
        let control = try app(suite: controlSuite)
        try launch(control)
        waitForTitle("Plasma", in: control)
        resizeWindow(in: control)
        control.terminate()
        let before = try inspectPreferences(allowMissing: true, until: { $0[controlKey] != nil })
        XCTAssertNotNil(before[controlKey], "The probe must observe a frame written by this test build")
        let app = try app(suite: nil)
        try launch(app)
        waitForTitle("Plasma", in: app)
        resizeWindow(in: app)
        app.terminate()
        let after = try inspectPreferences()
        XCTAssertTrue(Set(after.keys).subtracting(before.keys).isEmpty)
        XCTAssertEqual(after[liveKey], before[liveKey])
        XCTAssertEqual(after[controlKey], before[controlKey])
    }

    func testPreferencesInspectionDoesNotCreateViewerFramesOrStartLibrary() throws {
        let before = try inspectPreferences(allowMissing: true)
        let after = try inspectPreferences(allowMissing: true)
        XCTAssertEqual(after, before)
    }

    func testPreferencesReaderRejectsMalformedOrMismatchedSnapshots() throws {
        func payload(_ overrides: [String: Any] = [:]) throws -> String {
            var raw: [String: Any] = ["schemaVersion": 3, "refreshGeneration": 0, "bundleIdentifier": MacUITestSettings.bundleIdentifier,
                "domainExists": true, "frames": ["NSWindow Frame HolodeckViewer-test": "saved frame"],
                "lifecycle": ["modelCreations": 0, "libraryCreations": 0, "serverStartAttempts": 0]]
            for (key, value) in overrides { raw[key] = value }
            return String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
        }
        func read(_ text: String, allowMissing: Bool = false) throws -> [String: String] {
            try AppPreferencesReader.read(text, bundleIdentifier: MacUITestSettings.bundleIdentifier, allowMissing: allowMissing)
        }
        XCTAssertEqual(try read(payload())["NSWindow Frame HolodeckViewer-test"], "saved frame")
        for text in ["invalid JSON", "[]", "{}", try payload(["frames": ["NSWindow Frame HolodeckViewer-test": 2]]),
                     try payload(["frames": ["unexpected": "value"]]), try payload(["domainExists": false]), try payload(["refreshGeneration": -1]), try payload(["lifecycle": [:]]),
                     try payload(["lifecycle": ["modelCreations": -1, "libraryCreations": 0, "serverStartAttempts": 0]])] {
            XCTAssertThrowsError(try read(text, allowMissing: true))
        }
        XCTAssertThrowsError(try read(payload(["schemaVersion": 2])))
        XCTAssertThrowsError(try read(payload(["bundleIdentifier": "another.app"])))
        let missing = try payload(["domainExists": false, "frames": [String: String]()])
        XCTAssertThrowsError(try read(missing))
        XCTAssertTrue(try read(missing, allowMissing: true).isEmpty)
    }

    private func inspectPreferences(allowMissing: Bool = false,
                                    until predicate: ([String: String]) -> Bool = { _ in true }) throws -> [String: String] {
        let probe = XCUIApplication()
        guard probe.state == .notRunning else { throw TestHelperError(description: "Terminate the viewer before inspecting saved preferences") }
        probe.launchEnvironment.removeAll()
        probe.launchArguments = MacUITestSettings.ignoreSavedStateArguments + ["--ui-test-inspect-preferences"]
        probe.launch()
        defer { probe.terminate() }
        let snapshot = element("ui-test-preferences-snapshot", in: probe)
        guard snapshot.waitForExistence(timeout: 15) else {
            throw TestHelperError(description: "Preferences snapshot unavailable: " + probe.debugDescription)
        }
        XCTAssertFalse(element("holodeck-viewer-window", in: probe).exists)
        XCTAssertFalse(element("shader-serving-status", in: probe).exists)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        func readSnapshot() throws -> AppPreferencesReader.Snapshot {
            guard let payload = snapshot.value as? String else { throw AppPreferencesReader.ReadError.invalidSnapshot }
            let value = try AppPreferencesReader.snapshot(payload, bundleIdentifier: MacUITestSettings.bundleIdentifier, allowMissing: allowMissing)
            XCTAssertTrue(value.lifecycle.isIdle, "Inspection started application components: \(value.lifecycle)")
            return value
        }
        var last = try readSnapshot(), first = true
        func refreshSnapshot() throws -> AppPreferencesReader.Snapshot {
            let expected = last.refreshGeneration + 1
            probe.buttons["ui-test-refresh-preferences"].click()
            last = try AppPreferencesReader.acknowledged(read: readSnapshot, generation: expected, deadline: deadline)
            return last
        }
        let result = try AppPreferencesReader.wait(read: {
            if first { first = false; return last }
            return try refreshSnapshot()
        }, until: { predicate($0.frames) }, deadline: deadline)
        // An acknowledged refresh proves that the action actually ran, even when values stay equal.
        _ = try refreshSnapshot()
        return result.frames
    }

    func testPreferencesPollingWaitsForVisibilityAndReportsTimeoutOrMalformedData() throws {
        let lifecycle = AppPreferencesReader.Lifecycle(modelCreations: 0, libraryCreations: 0, serverStartAttempts: 0)
        var time: TimeInterval = 0
        var reads = 0
        let result = try AppPreferencesReader.wait(read: {
            reads += 1
            return AppPreferencesReader.Snapshot(schemaVersion: 3, refreshGeneration: 0, bundleIdentifier: "test", domainExists: true,
                frames: time >= 0.5 ? ["frame": "saved"] : [:], lifecycle: lifecycle)
        }, until: { $0.frames["frame"] != nil }, now: { time }, sleep: { time += $0 })
        XCTAssertEqual(result.frames["frame"], "saved"); XCTAssertEqual(reads, 3)
        XCTAssertThrowsError(try AppPreferencesReader.wait(read: { result }, until: { _ in false },
            now: { time }, sleep: { time += $0 }, timeout: 0.5)) { error in
            XCTAssertEqual(error as? AppPreferencesReader.ReadError, .timedOut)
        }
        reads = 0
        XCTAssertThrowsError(try AppPreferencesReader.wait(read: {
            reads += 1; throw AppPreferencesReader.ReadError.invalidSnapshot
        }, until: { _ in false }))
        XCTAssertEqual(reads, 1, "Malformed snapshots must fail immediately")
    }

    func testPreferencesRefreshWaitsForAcknowledgementEvenWhenValuesAreUnchanged() throws {
        let lifecycle = AppPreferencesReader.Lifecycle(modelCreations: 0, libraryCreations: 0, serverStartAttempts: 0)
        var time: TimeInterval = 0
        func value(_ generation: Int) -> AppPreferencesReader.Snapshot {
            .init(schemaVersion: 3, refreshGeneration: generation, bundleIdentifier: "test", domainExists: true,
                frames: ["frame": "saved"], lifecycle: lifecycle)
        }
        let fresh = try AppPreferencesReader.acknowledged(read: { value(time >= 0.5 ? 1 : 0) }, generation: 1,
            deadline: 1, now: { time }, sleep: { time += $0 })
        XCTAssertEqual(fresh.refreshGeneration, 1); XCTAssertEqual(fresh.frames, value(0).frames)
        time = 0
        XCTAssertThrowsError(try AppPreferencesReader.acknowledged(read: { value(0) }, generation: 1,
            deadline: 0.5, now: { time }, sleep: { time += $0 })) { error in
            XCTAssertEqual(error as? AppPreferencesReader.ReadError, .refreshTimedOut(expected: 1, observed: 0))
            XCTAssertTrue(error.localizedDescription.contains("last observed 0"))
        }
        time = 0.75
        XCTAssertThrowsError(try AppPreferencesReader.acknowledged(read: { value(1) }, generation: 1,
            deadline: 0.5, now: { time }, sleep: { time += $0 }))
        time = 0
        XCTAssertThrowsError(try AppPreferencesReader.acknowledged(read: { throw AppPreferencesReader.ReadError.invalidSnapshot },
            generation: 1, deadline: 1, now: { time }, sleep: { time += $0 }))
        XCTAssertEqual(time, 0)
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
