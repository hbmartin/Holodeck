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
    func testDisplayCadenceTargetsAndHealthyPlaybackAt24And25FPS() throws {
        XCTAssertEqual(ShaderPerformanceMonitor.attainableTarget(displayFramesPerSecond: 24), 24)
        XCTAssertEqual(ShaderPerformanceMonitor.attainableTarget(displayFramesPerSecond: 50), 25)
        XCTAssertEqual(ShaderPerformanceMonitor.attainableTarget(displayFramesPerSecond: 60), 30)
        XCTAssertEqual(ShaderPerformanceMonitor.attainableTarget(displayFramesPerSecond: 120), 30)
        for target in [24.0, 25.0, 30.0] {
            var healthy = ShaderPerformanceMonitor(); healthy.reset(at: 0); healthy.setTargetFramesPerSecond(target, at: 0)
            let display = target * 2
            for tick in 0...Int(display * 16) {
                XCTAssertNil(healthy.observe(at: Double(tick) / display, deliveredFrames: tick % 2 == 0 ? 1 : 0), "Healthy \\(target) fps triggered optimization")
            }
            var slow = ShaderPerformanceMonitor(); slow.reset(at: 0); slow.setTargetFramesPerSecond(target, at: 0)
            let fps = floor(target * 0.7)
            var evidence: (fps: [Double], gpu: [Double])?
            for tick in 0...Int(display * 16) {
                let frames = Int(Double(tick + 1) * fps / display) - Int(Double(tick) * fps / display)
                if let value = slow.observe(at: Double(tick) / display, deliveredFrames: frames) { evidence = value; break }
            }
            XCTAssertEqual(evidence?.fps.count, 10)
            XCTAssertTrue(evidence!.fps.allSatisfy { $0 < target * 0.9 })
            slow.setTargetFramesPerSecond(target == 24 ? 25 : 24, at: 20)
            XCTAssertNil(slow.observe(at: 21, deliveredFrames: 0))
        }
    }
    func testPerformanceEvidenceDecodesOldPayloadAndValidatesAttainableTarget() throws {
        let context = try context()
        let old = PerformanceEvidence(framesPerSecond: Array(repeating: 24, count: 10), gpuMilliseconds: [], device: "TV", sourceHash: context.sourceHash)
        let decoded = try JSONDecoder().decode(PerformanceEvidence.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.targetFramesPerSecond)
        var request = ShaderRequest(purpose: .performance, origin: .automatic, prompt: "Optimize", context: context, performance: decoded)
        try request.validate()
        request.performance?.targetFramesPerSecond = 24
        XCTAssertThrowsError(try request.validate())
        request.performance?.framesPerSecond = Array(repeating: 20, count: 10)
        try request.validate()
        request.performance?.targetFramesPerSecond = .nan
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
            if event.event == "preparePublication" { try worker.reply(true) }
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

    private func recoveryFixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("worker.py")
        try """
        import contextlib, json, os, signal, subprocess, sys, time
        from pathlib import Path
        with contextlib.suppress(PermissionError): os.setsid()
        mode=sys.argv[1]; job=Path(sys.argv[3])
        def emit(event, **data): print(json.dumps(dict(event=event, **data)), flush=True)
        if mode=='preflight': emit('preflight'); raise SystemExit(0)
        if mode=='discard':
            (job/'cleanup-started').touch()
            while (job/'hold-cleanup').exists(): time.sleep(.005)
            if (job/'fail-cleanup').exists(): emit('failure',message='Fixture cleanup unavailable'); raise SystemExit(1)
            (job/'owned-patch').unlink(missing_ok=True)
            if (job/'hold-descendant').exists():
                subprocess.Popen([sys.executable,'-c',"import sys,time; from pathlib import Path; gate=Path(sys.argv[1]); Path(sys.argv[2]).touch(); exec('while gate.exists(): time.sleep(.005)'); print('descendant stderr drained',file=sys.stderr,flush=True)",str(job/'hold-descendant'),str(job/'descendant-started')],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL)
                while not (job/'descendant-started').exists(): time.sleep(.005)
                (job/'cleanup-parent-finished').touch()
            emit('discarded'); raise SystemExit(0)
        def stop(*args):
            (job/'stopping').touch()
            while (job/'hold-exit').exists(): time.sleep(.005)
            raise SystemExit(1)
        signal.signal(signal.SIGTERM, stop)
        (job/'worker-started').touch()
        count=job/'worker-count'
        count.write_text(str(int(count.read_text())+1 if count.exists() else 1))
        emit('stage',stage='implementing',message='Fixture running')
        while True: time.sleep(.005)
        """.write(to: script, atomically: true, encoding: .utf8)
        return (root, script)
    }
    private func recoveryService(_ root: URL, script: URL, enabled: Bool = true) async throws -> ShaderRequestService {
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root, workerScript: script)
        await service.suspend()
        try await service.start(configuration: .init(repository: root.path, model: "fixture", enabled: enabled))
        return service
    }
    private func waitFor(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Fixture transition timed out", file: file, line: line); throw ShaderRequestError.unavailable("Test backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testRevokedRecoveredRepairCleansBeforeOtherJobsAndPersistsTerminalOutcome() async throws {
        let (root, script) = try recoveryFixture()
        let initial = try await recoveryService(root, script: script)
        let first = ShaderRequest(prompt: "Recovered", context: try context())
        let second = ShaderRequest(prompt: "Next", context: try context())
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: first), deviceID: "TV-A")
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: second), deviceID: "TV-B")
        try JSONEncoder().encode(first.id).write(to: root.appendingPathComponent("active.json"), options: .atomic)
        let recovered = try await recoveryService(root, script: script)
        let job = root.appendingPathComponent(first.id.uuidString)
        try Data().write(to: job.appendingPathComponent("hold-cleanup"))
        try Data().write(to: job.appendingPathComponent("owned-patch"))
        try await recovered.revoke("TV-A")
        // Restart before cleanup to exercise the durable pending-cleanup field.
        let restarted = try await recoveryService(root, script: script, enabled: false)
        await restarted.resume()
        try await waitFor { FileManager.default.fileExists(atPath: job.appendingPathComponent("cleanup-started").path) }
        let waiting = await restarted.allJobs()
        XCTAssertEqual(waiting.first { $0.id == second.id }?.stage, .queued)
        XCTAssertEqual(waiting.first { $0.id == first.id }?.stage, .failed)
        try FileManager.default.removeItem(at: job.appendingPathComponent("hold-cleanup"))
        try await waitFor { !(await restarted.hasPendingCleanup()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("owned-patch").path))
        try await restarted.cancelQueued(second.id)
        try await restarted.disable() // All persisted states now permit setup changes.
        let again = try await recoveryService(root, script: script, enabled: false)
        let durable = await again.allJobs()
        XCTAssertEqual(durable.first { $0.id == first.id }?.stage, .failed)
        XCTAssertEqual(durable.first { $0.id == second.id }?.stage, .cancelled)
    }
    func testRevokeDuringSuspendedProcessTeardownWaitsForExitAndCleanup() async throws {
        let (root, script) = try recoveryFixture()
        let service = try await recoveryService(root, script: script)
        let first = ShaderRequest(prompt: "Running", context: try context())
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: first), deviceID: "TV-A")
        let job = root.appendingPathComponent(first.id.uuidString)
        try Data().write(to: job.appendingPathComponent("hold-exit"))
        try Data().write(to: job.appendingPathComponent("hold-cleanup"))
        await service.resume()
        try await waitFor { FileManager.default.fileExists(atPath: job.appendingPathComponent("worker-started").path) }
        try await service.revoke("TV-A")
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("stopping").path)) // Revocation does not preempt a running job.
        await service.suspend()
        try await waitFor { FileManager.default.fileExists(atPath: job.appendingPathComponent("stopping").path) }
        let second = ShaderRequest(prompt: "Queued", context: try context())
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: second), deviceID: "TV-B")
        await service.resume()
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("cleanup-started").path))
        try FileManager.default.removeItem(at: job.appendingPathComponent("hold-exit"))
        try await waitFor { FileManager.default.fileExists(atPath: job.appendingPathComponent("cleanup-started").path) }
        let statuses = await service.allJobs()
        XCTAssertEqual(statuses.first { $0.id == second.id }?.stage, .queued)
        try await service.cancelQueued(second.id)
        try FileManager.default.removeItem(at: job.appendingPathComponent("hold-cleanup"))
        try await waitFor { !(await service.hasPendingCleanup()) }
        try await service.disable()
    }
    func testCleanupFailureBlocksReadinessAndRestartRetriesIt() async throws {
        let (root, script) = try recoveryFixture()
        let initial = try await recoveryService(root, script: script)
        let request = ShaderRequest(prompt: "Interrupted", context: try context())
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV-A")
        try JSONEncoder().encode(request.id).write(to: root.appendingPathComponent("active.json"), options: .atomic)
        let service = try await recoveryService(root, script: script)
        let job = root.appendingPathComponent(request.id.uuidString)
        try Data().write(to: job.appendingPathComponent("fail-cleanup"))
        try await service.revoke("TV-A"); await service.resume()
        try await waitFor { await service.allJobs().first?.message.contains("Cleanup failed") == true }
        let failed = await service.allJobs().first
        XCTAssertEqual(failed?.stage, .failed)
        XCTAssertFalse(failed?.blocksBrowsing ?? true)
        let pendingCleanup = await service.hasPendingCleanup()
        XCTAssertTrue(pendingCleanup)
        let reply = try await service.control(operation: "requestStatus", payload: .init(), deviceID: "TV-B")
        XCTAssertFalse(reply.enabled)
        do { try await service.disable(); XCTFail("Enabled setup while owned cleanup was incomplete") } catch ShaderRequestError.unavailable {}
        await service.suspend()
        try FileManager.default.removeItem(at: job.appendingPathComponent("fail-cleanup"))
        let restarted = try await recoveryService(root, script: script, enabled: false)
        await restarted.resume()
        try await waitFor { !(await restarted.hasPendingCleanup()) }
        try await restarted.disable()
    }

    func testLateReplyAfterExitIsAnErrorRatherThanSIGPIPE() async throws {
        let (root, _) = try recoveryFixture()
        let script = root.appendingPathComponent("late-reply.py")
        try """
        import contextlib, json, os, sys
        with contextlib.suppress(PermissionError): os.setsid()
        print(json.dumps({'event':'preparePublication'}),flush=True)
        sys.stdin.readline()
        """.write(to: script, atomically: true, encoding: .utf8)
        let worker = RequestWorkerProcess(script: script)
        var iterator = worker.run(mode: "run", configuration: .init(repository: root.path), directory: root.appendingPathComponent("late")).makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertEqual(event?.event, "preparePublication")
        worker.beforeReplyWrite = {
            worker.process.terminate()
            worker.process.waitUntilExit()
        }
        XCTAssertThrowsError(try worker.reply(true))
        worker.beforeReplyWrite = nil
        worker.stop(); await worker.waitForExit()
    }

    func testCleanupRetainsSchedulingSlotUntilDescendantExitAndStderrDrain() async throws {
        let (root, script) = try recoveryFixture()
        let initial = try await recoveryService(root, script: script)
        let first = ShaderRequest(prompt: "Cleanup", context: try context())
        let next = ShaderRequest(prompt: "Next", context: try context())
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: first), deviceID: "TV-A")
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: next), deviceID: "TV-B")
        try JSONEncoder().encode(first.id).write(to: root.appendingPathComponent("active.json"))
        let service = try await recoveryService(root, script: script)
        let job = root.appendingPathComponent(first.id.uuidString)
        addTeardownBlock { try? await service.detachCheckout(first.id) }
        try Data().write(to: job.appendingPathComponent("hold-descendant"))
        try await service.revoke("TV-A"); await service.resume()
        try await waitFor { FileManager.default.fileExists(atPath: job.appendingPathComponent("cleanup-parent-finished").path) }
        let pending = await service.hasPendingCleanup()
        XCTAssertTrue(pending)
        let waiting = await service.allJobs()
        XCTAssertEqual(waiting.first { $0.id == next.id }?.stage, .queued)
        try FileManager.default.removeItem(at: job.appendingPathComponent("hold-descendant"))
        try await waitFor { !(await service.hasPendingCleanup()) }
        XCTAssertTrue(try String(contentsOf: job.appendingPathComponent("worker-stderr.log"), encoding: .utf8).contains("descendant stderr drained"))
        try await service.detachCheckout(next.id)
    }

    func testStoppingWorkerEscalatesWhileDescendantHoldsOutputPipe() async throws {
        let (root, _) = try recoveryFixture()
        let script = root.appendingPathComponent("held-pipe.py"), job = root.appendingPathComponent("held-pipe")
        try """
        import contextlib, json, os, signal, subprocess, sys, time
        from pathlib import Path
        with contextlib.suppress(PermissionError): os.setsid()
        job=Path(sys.argv[3])
        subprocess.Popen([sys.executable,'-c',"import signal,sys,time; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); Path(sys.argv[1]).touch(); time.sleep(60)",str(job/'child-started')])
        while not (job/'child-started').exists(): time.sleep(.005)
        print(json.dumps({'event':'stage','stage':'implementing'}),flush=True)
        while True: time.sleep(.005)
        """.write(to: script, atomically: true, encoding: .utf8)
        let worker = RequestWorkerProcess(script: script)
        addTeardownBlock { worker.stop(); await worker.waitForExit() }
        var iterator = worker.run(mode: "run", configuration: .init(repository: root.path), directory: job).makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertEqual(event?.stage, "implementing")
        worker.stop()
        do { _ = try await iterator.next(); XCTFail("Stopped worker succeeded") } catch {}
        await worker.waitForExit()
    }

    func testQuickResumeRetainsInterruptedExecutionAndDetachPreservesFiles() async throws {
        let (root, script) = try recoveryFixture(), service = try await recoveryService(root, script: script)
        let request = ShaderRequest(prompt: "Suspend", context: try context())
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        let job = root.appendingPathComponent(request.id.uuidString)
        try Data().write(to: job.appendingPathComponent("hold-exit"))
        try Data("retained".utf8).write(to: job.appendingPathComponent("owned-patch"))
        await service.resume()
        try await waitFor { FileManager.default.fileExists(atPath: job.appendingPathComponent("worker-started").path) }
        await service.suspend()
        try await waitFor { FileManager.default.fileExists(atPath: job.appendingPathComponent("stopping").path) }
        await service.resume()
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("cleanup-started").path))
        try FileManager.default.removeItem(at: job.appendingPathComponent("hold-exit"))
        try await waitFor { (try? String(contentsOf: job.appendingPathComponent("worker-count"), encoding: .utf8)) == "2" }
        let jobs = await service.allJobs()
        XCTAssertFalse(jobs.first!.stage.terminal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("cleanup-started").path))
        try await service.detachCheckout(request.id)
        let config = await service.configurationValue(), detached = await service.allJobs()
        XCTAssertFalse(config.enabled); XCTAssertEqual(detached.first?.stage, .failed)
        XCTAssertEqual(try String(contentsOf: job.appendingPathComponent("owned-patch"), encoding: .utf8), "retained")
    }

    private func initializeRecoveryGit(_ root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--quiet", root.path]; try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return root.appendingPathComponent(".git")
    }

    func testCleanupRetryValidatesOwnershipAndAcceptsMovedCheckout() async throws {
        let (root, script) = try recoveryFixture(), initial = try await recoveryService(root, script: script)
        let request = ShaderRequest(prompt: "Recover", context: try context())
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        try JSONEncoder().encode(request.id).write(to: root.appendingPathComponent("active.json"), options: .atomic)
        let service = try await recoveryService(root, script: script)
        let job = root.appendingPathComponent(request.id.uuidString)
        try Data().write(to: job.appendingPathComponent("fail-cleanup"))
        try await service.revoke("TV"); await service.resume()
        try await waitFor { await service.recoveryStatuses().first?.message.contains("Fixture cleanup") == true }
        let wrong = root.appendingPathComponent("wrong-checkout"), moved = root.appendingPathComponent("moved-checkout")
        _ = try initializeRecoveryGit(wrong)
        do { try await service.retryCleanup(request.id, repository: wrong.path, python: "/usr/bin/python3", git: "/usr/bin/git"); XCTFail("Foreign checkout accepted") }
        catch ShaderRequestError.unavailable {}
        let gitdir = try initializeRecoveryGit(moved)
        try JSONSerialization.data(withJSONObject: ["id": request.id.uuidString, "directory": job.path])
            .write(to: gitdir.appendingPathComponent("holodeck-request-owner.json"))
        try Data("preserved".utf8).write(to: moved.appendingPathComponent("unrelated"))
        try FileManager.default.removeItem(at: job.appendingPathComponent("fail-cleanup"))
        try await service.retryCleanup(request.id, repository: moved.path, python: "/usr/bin/python3", git: "/usr/bin/git")
        try await waitFor { !(await service.hasPendingCleanup()) }
        let statuses = await service.allJobs()
        XCTAssertEqual(statuses.first?.stage, .failed)
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("unrelated"), encoding: .utf8), "preserved")
        try await service.disable()
    }

    func testAllKnownOrphansAreReconciledBeforeOtherJobCleanup() async throws {
        let (root, script) = try recoveryFixture(), initial = try await recoveryService(root, script: script)
        let first = ShaderRequest(prompt: "Orphan", context: try context()), second = ShaderRequest(prompt: "Cleanup", context: try context())
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: first), deviceID: "A")
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: second), deviceID: "B")
        try JSONEncoder().encode(second.id).write(to: root.appendingPathComponent("active.json"), options: .atomic)
        let revoked = try await recoveryService(root, script: script)
        try await revoked.revoke("B")
        try JSONEncoder().encode(first.id).write(to: root.appendingPathComponent("active.json"), options: .atomic)
        let job = root.appendingPathComponent(first.id.uuidString), orphanScript = root.appendingPathComponent("orphan.py")
        try """
        import contextlib, fcntl, os, sys, time
        from pathlib import Path
        with contextlib.suppress(PermissionError): os.setsid()
        lease=Path(sys.argv[1]).parent/'lease'
        with lease.open('w') as file:
            fcntl.flock(file,fcntl.LOCK_EX)
            (Path(sys.argv[1])/'orphan-ready').touch()
            while True: time.sleep(.01)
        """.write(to: orphanScript, atomically: true, encoding: .utf8)
        let orphan = Process(); orphan.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); orphan.arguments = [orphanScript.path, job.path]
        try orphan.run()
        defer { if orphan.isRunning { orphan.terminate() } }
        try await waitFor { FileManager.default.fileExists(atPath: job.appendingPathComponent("orphan-ready").path) }
        try JSONSerialization.data(withJSONObject: ["pid": orphan.processIdentifier, "script": orphanScript.path, "directory": job.path])
            .write(to: job.appendingPathComponent("process.json"))
        // The cleanup fixture also needs the shared lease; without reconciliation this fails.
        var source = try String(contentsOf: script, encoding: .utf8)
        source = source.replacingOccurrences(of: "if mode=='discard':", with: "if mode=='discard':\n    import fcntl\n    lease=(job.parent/'lease').open('w')\n    fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)")
        try source.write(to: script, atomically: true, encoding: .utf8)
        let restarted = try await recoveryService(root, script: script)
        await restarted.resume()
        try await waitFor { !(await restarted.hasPendingCleanup()) }
        XCTAssertFalse(orphan.isRunning)
        let jobs = await restarted.allJobs()
        XCTAssertEqual(jobs.first { $0.id == second.id }?.stage, .failed)
        try await restarted.detachCheckout(first.id)
    }

    private func requestAuthoringFixture(_ root: URL, includesUnrelated: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: true)
        try Data("COMMON\n".utf8).write(to: root.appendingPathComponent("shared/common.metal"))
        try Data("FRAGMENT\n".utf8).write(to: root.appendingPathComponent("shared/fragment.metal"))
        let ids = includesUnrelated ? ["plasma", "unrelated"] : ["plasma"]
        for id in ids {
            let folder = root.appendingPathComponent("shaders/\(id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var entry = TestCatalog.snapshot.manifest.shaders[0]; entry.id = id
            var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
            metadata["shared"] = ["common", "fragment"]
            try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appendingPathComponent("metadata.json"))
            try Data((id == "unrelated" ? "UNRELATED\n" : "BODY\n").utf8).write(to: folder.appendingPathComponent("body.metal"))
        }
        try JSONSerialization.data(withJSONObject: ["shaders": ids, "defaultShaderID": "plasma"]).write(to: root.appendingPathComponent("index.json"))
        return root
    }

    func testInterruptedPreparationDiscardsCandidateWithoutFailingRequest() async throws {
        let (root, script) = try recoveryFixture()
        var source = try String(contentsOf: script, encoding: .utf8)
        source = source.replacingOccurrences(of: "emit('stage',stage='implementing',message='Fixture running')", with: "emit('preparePublication')\nsys.stdin.readline()")
        try source.write(to: script, atomically: true, encoding: .utf8)
        let gate = RequestPreparationGate()
        let generator = ShaderPreviewGenerator(directory: root.appendingPathComponent("previews")) { _ in
            await gate.hold()
            return try ShaderPNG.gradient(colors: [[0,0,0],[1,1,1]])
        }
        // Reuse a real authoring fixture and pin preview generation at its suspension point.
        let authoring = try requestAuthoringFixture(root.appendingPathComponent("authoring"))
        let catalog = DirectoryCatalog(directory: root.appendingPathComponent("catalog"), previewGenerator: generator)
        let service = ShaderRequestService(catalog: catalog, directory: root, workerScript: script)
        await service.suspend(); try await service.start(configuration: .init(repository: authoring.path, enabled: true))
        let request = ShaderRequest(prompt: "Prepare", context: try context())
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        await service.resume()
        try await waitFor { await gate.entered }
        await service.suspend(); await service.resume()
        await gate.release()
        try await waitFor { (try? String(contentsOf: root.appendingPathComponent(request.id.uuidString).appendingPathComponent("worker-count"), encoding: .utf8)) == "2" }
        let jobs = await service.allJobs()
        XCTAssertFalse(jobs.first!.stage.terminal)
        let cleanup = await service.hasPendingCleanup()
        XCTAssertFalse(cleanup)
        try await service.detachCheckout(request.id)
    }

    func testPreviewGateAllowsOnlyUnrelatedWarnings() async throws {
        for requireUnrelated in [false, true] {
            let (root, script) = try recoveryFixture()
            let authoring = try requestAuthoringFixture(root.appendingPathComponent("authoring"), includesUnrelated: true)
            let required = requireUnrelated ? "['plasma','unrelated']" : "['plasma']"
            try """
            import json, sys
            def emit(event,**data): print(json.dumps(dict(event=event,**data)),flush=True)
            if sys.argv[1]=='discard': emit('discarded'); raise SystemExit(0)
            emit('preparePublication',requiredPreviewShaderIDs=\(required))
            reply=json.loads(sys.stdin.readline())
            if not reply['ok']: emit('failure',message=reply['message']); raise SystemExit(1)
            emit('result',result={'outputKind':'edited','shaderID':'plasma','changed':False,'summary':'Fixture','approximations':[]})
            """.write(to: script, atomically: true, encoding: .utf8)
            let previews = ShaderPreviewGenerator(directory: root.appendingPathComponent("previews")) { source in
                if source.contains("UNRELATED") { throw ShaderCompilationError.missingFunction("fixture unrelated shader") }
                return try ShaderPNG.gradient(colors: [[0,0,0],[1,1,1]])
            }
            let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog"), previewGenerator: previews), directory: root, workerScript: script)
            await service.suspend(); try await service.start(configuration: .init(repository: authoring.path, enabled: true))
            let request = ShaderRequest(prompt: "Preview", context: try context())
            _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
            await service.resume()
            try await waitFor { let stage = await service.allJobs().first?.stage; return stage == .awaitingActivation || stage == .failed }
            if requireUnrelated {
                try await waitFor { !(await service.hasPendingCleanup()) }
                let job = await service.allJobs().first
                XCTAssertEqual(job?.stage, .failed); XCTAssertTrue(job?.message.contains("unrelated") == true)
            } else {
                let warnings = await service.publicationWarnings()
                XCTAssertEqual(warnings.map(\.shaderID), ["unrelated"])
                try await service.detachCheckout(request.id)
            }
        }
    }

    func testFreshPublicationBootstrapAndDirtyCheckoutRejection() async throws {
        let (root, _) = try recoveryFixture()
        let authoring = try requestAuthoringFixture(root.appendingPathComponent("checkout"))
        _ = try initializeRecoveryGit(authoring)
        func git(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = authoring; process.arguments = arguments
            process.standardOutput = Pipe(); process.standardError = Pipe()
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        try git(["symbolic-ref", "HEAD", "refs/heads/main"])
        try git(["add", "--all"])
        try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Bootstrap"])
        let previews = ShaderPreviewGenerator(directory: root.appendingPathComponent("previews")) { _ in try ShaderPNG.gradient(colors: [[0,0,0],[1,1,1]]) }
        let catalog = DirectoryCatalog(directory: root.appendingPathComponent("catalog"), previewGenerator: previews)
        let service = ShaderRequestService(catalog: catalog, directory: root.appendingPathComponent("service"))
        try await service.start(configuration: .init(repository: authoring.path, enabled: true))
        try await service.ensurePublication()
        let publication = try await catalog.cached()
        XCTAssertEqual(publication?.shaders.map(\.id), ["plasma"])
        try Data("dirty".utf8).write(to: authoring.appendingPathComponent("shaders/plasma/body.metal"))
        let cold = DirectoryCatalog(directory: root.appendingPathComponent("cold"), previewGenerator: previews)
        let other = ShaderRequestService(catalog: cold, directory: root.appendingPathComponent("other-service"))
        try await other.start(configuration: .init(repository: authoring.path, enabled: true))
        do { try await other.ensurePublication(); XCTFail("Dirty checkout bootstrapped") } catch {}
        XCTAssertEqual(try String(contentsOf: authoring.appendingPathComponent("shaders/plasma/body.metal"), encoding: .utf8), "dirty")
    }

    func testCheckoutOwnerCleanupPrecedesOlderPendingJobAndSurvivesDetach() async throws {
        for detach in [false, true] {
            let (root, script) = try recoveryFixture(), initial = try await recoveryService(root, script: script, enabled: false)
            // Accept requests while suspended, then disable scheduling in the restarted service.
            try await initial.start(configuration: .init(repository: root.path, enabled: true))
            let older = ShaderRequest(prompt: "Older cleanup", context: try context()), owner = ShaderRequest(prompt: "Owner", context: try context())
            _ = try await initial.control(operation: "requestSubmit", payload: .init(request: older), deviceID: "B")
            _ = try await initial.control(operation: "requestSubmit", payload: .init(request: owner), deviceID: "A")
            let journal = root.appendingPathComponent("journal.json")
            var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
            for index in records.indices {
                var status = try XCTUnwrap(records[index]["status"] as? [String: Any]); status["stage"] = "failed"
                records[index]["status"] = status
                records[index]["cleanupPending"] = (status["id"] as? String) == older.id.uuidString
            }
            try JSONSerialization.data(withJSONObject: records).write(to: journal, options: .atomic)
            let gitdir = try initializeRecoveryGit(root), ownerJob = root.appendingPathComponent(owner.id.uuidString)
            let marker = gitdir.appendingPathComponent("holodeck-request-owner.json")
            try JSONSerialization.data(withJSONObject: ["id": owner.id.uuidString, "directory": ownerJob.path]).write(to: marker)
            if detach { try Data().write(to: ownerJob.appendingPathComponent("fail-cleanup")) }
            var source = try String(contentsOf: script, encoding: .utf8)
            source = source.replacingOccurrences(of: "emit('discarded'); raise SystemExit(0)", with: """
            marker=job.parent/'.git/holodeck-request-owner.json'
                if marker.exists():
                    assert json.loads(marker.read_text())['id']==job.name, 'Foreign checkout owner'
                    marker.unlink()
                with (job.parent/'cleanup-order').open('a') as log: log.write(job.name+'\\n')
                emit('discarded'); raise SystemExit(0)
            """)
            try source.write(to: script, atomically: true, encoding: .utf8)
            let service = try await recoveryService(root, script: script, enabled: false)
            await service.resume()
            if detach {
                try await waitFor { await service.recoveryStatuses().contains { $0.id == owner.id && $0.message.contains("Fixture cleanup") } }
                try await service.detachCheckout(owner.id)
                let pending = await service.hasPendingCleanup()
                XCTAssertFalse(pending); XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            } else {
                try await waitFor { !(await service.hasPendingCleanup()) }
                let order = try String(contentsOf: root.appendingPathComponent("cleanup-order"), encoding: .utf8).split(separator: "\n").map(String.init)
                XCTAssertEqual(order, [owner.id.uuidString, older.id.uuidString])
            }
        }
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

#if os(macOS)
private actor RequestPreparationGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold() async {
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
#endif
