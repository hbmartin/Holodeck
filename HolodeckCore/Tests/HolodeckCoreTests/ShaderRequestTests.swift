import Foundation
import XCTest
@testable import HolodeckCore

@MainActor
final class ShaderRequestTests: XCTestCase {
    private func context() throws -> ShaderRequestContext {
        let png = try RequestScreenshot.encode(pixels: Data([128, 64, 32, 255]), width: 1, height: 1, bytesPerRow: 4)
        return .init(shader: TestCatalog.initialShader, screenshot: png, animationTime: 3.25, width: 1920, height: 1080)
    }
    #if os(macOS)
    func testBundledRequestWorkerRemainsAvailable() throws {
        let script = try XCTUnwrap(RequestWorkerProcess.bundledScript)
        let bytes = try Data(contentsOf: script)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("def main("))
    }
    #endif

    func testCapturedContextPreservesExactSourceAndRejectsTampering() throws {
        let original = try context()
        var request = ShaderRequest(prompt: "Make it warmer", context: original)
        try request.validate()
        let restored = try JSONDecoder().decode(ShaderRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(restored.context, original)
        request.context.source += "changed"
        XCTAssertThrowsError(try request.validate())
        request.context = original; request.context.screenshot = Data("not an image".utf8)
        XCTAssertThrowsError(try request.validate())
        request.context = original; request.context.animationTime = .nan
        XCTAssertThrowsError(try request.validate())
        request.context = original; request.context.colors = [[.infinity, 0, 0]]
        XCTAssertThrowsError(try request.validate())
    }
    func testPerformanceEvidenceMustMatchCapturedVersionAndContinuousSlowdown() throws {
        let context = try context()
        var request = ShaderRequest(purpose: .performance, origin: .automatic, prompt: "Optimize", context: context,
            performance: .init(framesPerSecond: Array(repeating: 24, count: 10), gpuMilliseconds: [35], device: "Apple TV", sourceHash: context.sourceHash))
        try request.validate()
        request.performance?.sourceHash = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try request.validate())
        request.performance?.sourceHash = context.sourceHash; request.performance?.framesPerSecond[5] = 27
        XCTAssertThrowsError(try request.validate())
    }
    func testNativeTVPolicyAndDeliveredFramesWarmupAndThreshold() {
        XCTAssertEqual(RenderingPolicy.tv.framesPerSecond, 30)
        XCTAssertFalse(RenderingPolicy.tv.adaptiveResolution)
        var monitor = ShaderPerformanceMonitor(); monitor.reset(at: 0)
        for second in 0..<2 {
            for frame in 0..<20 { XCTAssertNil(monitor.presented(at: Double(second) + Double(frame) / 20)) }
        }
        var result: (fps: [Double], gpu: [Double])?
        // Exactly twenty delivered frames in each one-second display window.
        for tick in 120...720 {
            let value = monitor.observe(at: Double(tick) / 60, deliveredFrames: tick % 3 == 0 ? 1 : 0, gpuMilliseconds: 35)
            if let value { result = value; break }
        }
        XCTAssertEqual(result?.fps.count, 10)
        XCTAssertTrue(result?.fps.allSatisfy { $0 < 27 } == true)
        XCTAssertTrue(result?.gpu.allSatisfy { abs($0 - 35) < 0.001 } == true)
    }
    func testHealthyWindowAndActivityResetBreakSlowStreakAndZeroFramesTrigger() {
        var monitor = ShaderPerformanceMonitor(); monitor.reset(at: 0)
        for tick in 120..<420 { XCTAssertNil(monitor.observe(at: Double(tick) / 60, deliveredFrames: tick % 3 == 0 ? 1 : 0)) }
        for tick in 420..<540 { XCTAssertNil(monitor.observe(at: Double(tick) / 60, deliveredFrames: tick % 2 == 0 ? 1 : 0)) }
        for tick in 540..<900 { XCTAssertNil(monitor.observe(at: Double(tick) / 60, deliveredFrames: 0)) }
        monitor.reset(at: 15)
        var result: (fps: [Double], gpu: [Double])?
        for tick in 900...1620 {
            if let value = monitor.observe(at: Double(tick) / 60, deliveredFrames: 0) { result = value; break }
        }
        XCTAssertEqual(result?.fps, Array(repeating: 0, count: 10))
    }
    func testManualPriorityFIFOAndParkedJobs() throws {
        let context = try context()
        func job(_ origin: ShaderRequest.Origin, _ time: Double, stage: ShaderRequestStatus.Stage = .queued) -> ShaderRequestStatus {
            var result = ShaderRequestStatus(request: .init(purpose: .performance, origin: origin, prompt: "Optimize", context: context), deviceID: "TV", date: Date(timeIntervalSince1970: time))
            result.stage = stage; return result
        }
        let auto = job(.automatic, 1), manual = job(.manual, 3), retry = job(.manual, 2)
        let parked = job(.manual, 0, stage: .awaitingClarification)
        XCTAssertEqual(ShaderRequestScheduling.next(in: [auto, manual, retry, parked]), retry.id)
        XCTAssertEqual(ShaderRequestScheduling.next(in: [auto, manual, parked]), manual.id)
        XCTAssertEqual(ShaderRequestScheduling.next(in: [auto, manual], recoveringID: auto.id), auto.id)
        XCTAssertNil(ShaderRequestScheduling.next(in: [parked]))
        XCTAssertFalse(auto.blocksBrowsing)
        XCTAssertTrue(ShaderRequestStatus(request: .init(prompt: "Edit", context: context), deviceID: "TV").blocksBrowsing)
    }
    #if os(macOS)
    func testNativeSubprocessStreamsProgressBeforeExitAndPublicationHandshake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("bridge.py")
        try Data("""
        import contextlib, json, os, sys
        with contextlib.suppress(PermissionError): os.setsid()
        print(json.dumps({'event':'stage', 'stage':'validating', 'message':'live progress'}), flush=True)
        print(json.dumps({'event':'preparePublication'}), flush=True)
        assert json.loads(sys.stdin.readline())['ok']
        print(json.dumps({'event':'preflight'}), flush=True)
        """.utf8).write(to: script)
        let worker = RequestWorkerProcess(script: script)
        let timeout = Task.detached { do { try await Task.sleep(for: .seconds(5)); worker.stop() } catch {} }
        defer { timeout.cancel() }
        var events: [String] = []
        for try await event in worker.run(mode: "preflight", configuration: .init(repository: root.path), directory: root.appendingPathComponent("job")) {
            events.append(event.event)
            if event.event == "stage" { XCTAssertTrue(worker.process.isRunning) }
            if event.event == "preparePublication" { worker.reply(true) }
        }
        XCTAssertEqual(events, ["stage", "preparePublication", "preflight"])
    }

    func testConfiguredRealCodexPublicationAndActivation() async throws {
        guard let path = ProcessInfo.processInfo.environment["HOLODECK_REQUEST_FIXTURE_CONFIG"] else {
            throw XCTSkip("Set HOLODECK_REQUEST_FIXTURE_CONFIG to a disposable checkout/remote with explicit model settings.")
        }
        let configuration = try JSONDecoder().decode(ShaderRequestConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        // The opt-in fixture must use a local bare remote, never the user's hosted origin.
        let git = Process(), pipe = Pipe()
        git.executableURL = URL(fileURLWithPath: configuration.git); git.currentDirectoryURL = URL(fileURLWithPath: configuration.repository)
        git.arguments = ["remote", "get-url", "origin"]; git.standardOutput = pipe
        try git.run(); let remote = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines); git.waitUntilExit()
        guard remote.hasPrefix("/"), remote.hasSuffix(".git"), configuration.repository.hasPrefix("/tmp/") else {
            throw ShaderRequestError.unavailable("Live test requires a /tmp checkout and local .git origin.")
        }
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        let catalog = DirectoryCatalog(directory: root.appendingPathComponent("publication"))
        let baseline = try await catalog.reload(from: URL(fileURLWithPath: configuration.repository)).catalog
        let shader = try XCTUnwrap(baseline.shaders.first { $0.id == "plasma" })
        let generator = ShaderPreviewGenerator(directory: root.appendingPathComponent("captured-preview"))
        let screenshot = try await generator.preview(source: shader.source, colors: shader.colors.map { [$0.x, $0.y, $0.z] })
        XCTAssertNil(screenshot.diagnostic)
        let service = ShaderRequestService(catalog: catalog, directory: root.appendingPathComponent("requests"))
        try await service.start(configuration: .init())
        try await service.verify(configuration: configuration)
        let request = ShaderRequest(prompt: "Edit the existing plasma shader to use a distinctly warm orange, red and golden palette instead of cyan, blue, violet and magenta. Keep its existing ID, flowing composition, detail and real-time motion. Keep its existing metadata and discovery labels. This request is an explicit edit, not a new shader.",
            context: .init(shader: shader, screenshot: screenshot.png, animationTime: 3, width: 1920, height: 1080))
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "live-fixture-TV")
        let deadline = Date().addingTimeInterval(900)
        var status: ShaderRequestStatus?
        while Date() < deadline {
            status = await service.allJobs().first { $0.id == request.id }
            if status?.stage == .awaitingActivation || status?.stage.terminal == true { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let status, status.stage == .awaitingActivation, let result = status.result else {
            await service.suspend()
            return XCTFail("Live worker did not publish: \(status?.message ?? "timeout"); retained evidence in \(root.path)")
        }
        XCTAssertEqual(result.shaderID, shader.id); XCTAssertEqual(result.outputKind, .edited); XCTAssertTrue(result.changed)
        XCTAssertNotEqual(result.deliveredSourceHash, shader.sourceHash)
        let publication = try await catalog.cached()
        XCTAssertEqual(publication?.shaders.first { $0.id == result.shaderID }?.sourceHash, result.deliveredSourceHash)
        _ = try await service.control(operation: "requestActivated", payload: .init(requestID: request.id, sourceHash: result.deliveredSourceHash), deviceID: "live-fixture-TV")
        let finished = await service.allJobs().first { $0.id == request.id }
        XCTAssertEqual(finished?.stage, ShaderRequestStatus.Stage.completed)
        print("Live Codex request \(request.id): \(result.commitSHA ?? "no commit"), retained evidence: \(root.path)")
    }

    private func service(_ directory: URL) async throws -> ShaderRequestService {
        let result = ShaderRequestService(catalog: DirectoryCatalog(directory: directory.appendingPathComponent("catalog")), directory: directory)
        await result.suspend() // Acceptance/queue tests do not launch a command fixture.
        try await result.start(configuration: .init(model: "explicit-model", enabled: true))
        return result
    }
    func testDurableIdempotencyOwnershipQueuedCancellationAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let service = try await service(root)
        let request = ShaderRequest(prompt: "Edit the current scene", context: try context())
        let accepted = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV-A")
        XCTAssertEqual(accepted.jobs.count, 1)
        let duplicate = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV-A")
        XCTAssertEqual(duplicate.jobs.first?.id, request.id)
        var altered = request; altered.prompt = "A different request reusing the UUID"
        do { _ = try await service.control(operation: "requestSubmit", payload: .init(request: altered), deviceID: "TV-A"); XCTFail("Changed duplicate payload accepted") }
        catch ShaderRequestError.invalidRequest {}
        do { _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV-B"); XCTFail("Cross-device ID accepted") }
        catch ShaderRequestError.notFound {}
        let hidden = try await service.control(operation: "requestStatus", payload: .init(requestID: request.id), deviceID: "TV-B")
        XCTAssertTrue(hidden.jobs.isEmpty)
        let restarted = try await self.service(root)
        let restored = try await restarted.control(operation: "requestStatus", payload: .init(requestID: request.id), deviceID: "TV-A")
        XCTAssertEqual(restored.jobs.first?.stage, .queued)
        let bytes = try Data(contentsOf: root.appendingPathComponent(request.id.uuidString).appendingPathComponent("request.json"))
        XCTAssertEqual(try JSONDecoder().decode(ShaderRequest.self, from: bytes).context.source, request.context.source)
        try await restarted.cancelQueued(request.id)
        let cancelled = try await restarted.control(operation: "requestStatus", payload: .init(requestID: request.id), deviceID: "TV-A")
        XCTAssertEqual(cancelled.jobs.first?.stage, .cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(request.id.uuidString).path))
        try await restarted.deleteFinished(request.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(request.id.uuidString).path))
    }
    func testInterruptedActiveJobRecoversBeforeQueuedJobsAndCannotBeCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let service = try await service(root), context = try context()
        let request = ShaderRequest(prompt: "Interrupted", context: context)
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV-A")
        try JSONEncoder().encode(request.id).write(to: root.appendingPathComponent("active.json"), options: .atomic)
        let restarted = try await self.service(root)
        let restored = await restarted.allJobs()
        XCTAssertEqual(restored.first?.stage, .repairing)
        XCTAssertEqual(ShaderRequestScheduling.next(in: restored, recoveringID: request.id), request.id)
        do { try await restarted.cancelQueued(request.id); XCTFail("Interrupted running job was cancellable") }
        catch ShaderRequestError.unavailable {}
    }

    func testPerformanceDedupPerDeviceShaderVersionAndRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let service = try await service(root), context = try context()
        var request = ShaderRequest(purpose: .performance, origin: .automatic, prompt: "Optimize", context: context,
            performance: .init(framesPerSecond: Array(repeating: 20, count: 10), gpuMilliseconds: [], device: "TV", sourceHash: context.sourceHash))
        let first = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV-A")
        request.id = UUID()
        let same = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV-A")
        XCTAssertEqual(first.jobs.first?.id, same.jobs.first?.id)
        let other = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV-B")
        XCTAssertEqual(other.jobs.first?.id, request.id)
        try await service.revoke("TV-A")
        let jobs = await service.allJobs()
        XCTAssertEqual(jobs.first { $0.deviceID == "TV-A" }?.stage, .cancelled)
        XCTAssertEqual(jobs.first { $0.deviceID == "TV-B" }?.stage, .queued)
    }
    #endif
}
