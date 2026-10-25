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
        worker.stop(); try await worker.waitForExit()
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
        addTeardownBlock { try? await service.detachCheckout(.request(first.id)) }
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
        try await service.detachCheckout(.request(next.id))
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
        addTeardownBlock { worker.stop(); try await worker.waitForExit() }
        var iterator = worker.run(mode: "run", configuration: .init(repository: root.path), directory: job).makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertEqual(event?.stage, "implementing")
        worker.stop()
        do { _ = try await iterator.next(); XCTFail("Stopped worker succeeded") } catch {}
        try await worker.waitForExit()
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
        let operation = try XCTUnwrap(RequestWorkerOperation.read(in: job))
        await service.suspend()
        try await waitFor { FileManager.default.fileExists(atPath: job.appendingPathComponent("stopping").path) }
        await service.resume()
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("cleanup-started").path))
        try FileManager.default.removeItem(at: job.appendingPathComponent("hold-exit"))
        try await waitFor { (try? String(contentsOf: job.appendingPathComponent("worker-count"), encoding: .utf8)) == "2" }
        XCTAssertEqual(try RequestWorkerOperation.read(in: job)?.id, operation.id)
        XCTAssertEqual(try RequestWorkerOperation.read(in: job)?.phase, .initial)
        let jobs = await service.allJobs()
        XCTAssertFalse(jobs.first!.stage.terminal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("cleanup-started").path))
        try await service.detachCheckout(.request(request.id))
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

    func testCleanupRetryRequiresOriginalPathAndValidatesOwnership() async throws {
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
        do { try await service.retryCleanup(request.id, repository: moved.path, python: "/usr/bin/python3", git: "/usr/bin/git"); XCTFail("Moved checkout accepted") }
        catch ShaderRequestError.unavailable {}
        let originalGit = try initializeRecoveryGit(root)
        try JSONSerialization.data(withJSONObject: ["id": request.id.uuidString, "directory": job.path])
            .write(to: originalGit.appendingPathComponent("holodeck-request-owner.json"))
        try await service.retryCleanup(request.id, repository: root.path, python: "/usr/bin/python3", git: "/usr/bin/git")
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
        try await waitFor { FileManager.default.fileExists(atPath: job.appendingPathComponent("worker-started").path) }
        XCTAssertFalse(orphan.isRunning)
        // The owner resumes before B's cleanup. Revoke and interrupt it to release the slot.
        try await restarted.revoke("A")
        await restarted.suspend(); await restarted.resume()
        try await waitFor { !(await restarted.hasPendingCleanup()) }
        let jobs = await restarted.allJobs()
        XCTAssertEqual(jobs.first { $0.id == second.id }?.stage, .failed)
        try await restarted.detachCheckout(.request(first.id))
    }

    private func requestAuthoringFixture(_ root: URL, includesUnrelated: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: true)
        let checkerLock = try XCTUnwrap(NativeShaderToolFixture.lock)
        try Data(contentsOf:checkerLock).write(to:root.appendingPathComponent("shader_checker.lock.json"))
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
        await service.suspend(); try await service.start(configuration: .init(repository: authoring.path, shaderTool: NativeShaderToolFixture.executable.path, enabled: true))
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
        try await service.detachCheckout(.request(request.id))
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
            await service.suspend(); try await service.start(configuration: .init(repository: authoring.path, shaderTool: NativeShaderToolFixture.executable.path, enabled: true))
            let request = ShaderRequest(prompt: "Preview", context: try context())
            _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
            await service.resume()
            try await waitFor { let stage = await service.allJobs().first?.stage; return stage == .awaitingActivation || stage == .failed }
            if requireUnrelated {
                try await waitFor { !(await service.hasPendingCleanup()) }
                let job = await service.allJobs().first
                XCTAssertEqual(job?.stage, .failed); XCTAssertTrue(job?.message.contains("unrelated") == true)
            } else {
                let warnings = await service.publicationStatus()?.warnings ?? []
                XCTAssertEqual(warnings.map(\.shaderID), ["unrelated"])
                try await service.detachCheckout(.request(request.id))
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
        try await service.start(configuration: .init(repository: authoring.path, shaderTool: NativeShaderToolFixture.executable.path, enabled: true))
        try await service.ensurePublication()
        let publication = try await catalog.cached()
        XCTAssertEqual(publication?.shaders.map(\.id), ["plasma"])
        try Data("dirty".utf8).write(to: authoring.appendingPathComponent("shaders/plasma/body.metal"))
        let cold = DirectoryCatalog(directory: root.appendingPathComponent("cold"), previewGenerator: previews)
        let other = ShaderRequestService(catalog: cold, directory: root.appendingPathComponent("other-service"))
        try await other.start(configuration: .init(repository: authoring.path, shaderTool: NativeShaderToolFixture.executable.path, enabled: true))
        do { try await other.ensurePublication(); XCTFail("Dirty checkout bootstrapped") } catch {}
        XCTAssertEqual(try String(contentsOf: authoring.appendingPathComponent("shaders/plasma/body.metal"), encoding: .utf8), "dirty")
    }

    private func commitFixture(_ authoring: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = authoring
        process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-am", "Fixture update"]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }

    func testForcedPublicationCoalescesAcrossSuspensionAndPreservesCurrentOnFailure() async throws {
        let (root, _) = try recoveryFixture()
        let authoring = try requestAuthoringFixture(root.appendingPathComponent("checkout"))
        _ = try initializeRecoveryGit(authoring)
        for args in [["symbolic-ref", "HEAD", "refs/heads/main"], ["add", "--all"]] {
            let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.currentDirectoryURL = authoring; git.arguments = args
            try git.run(); git.waitUntilExit(); XCTAssertEqual(git.terminationStatus, 0)
        }
        try commitFixture(authoring)
        let previews = ShaderPreviewGenerator(directory: root.appendingPathComponent("previews")) { _ in try ShaderPNG.gradient(colors: [[0,0,0],[1,1,1]]) }
        let catalog = DirectoryCatalog(directory: root.appendingPathComponent("catalog"), previewGenerator: previews)
        let service = ShaderRequestService(catalog: catalog, directory: root.appendingPathComponent("service"))
        try await service.initialize(configuration: .init(repository: authoring.path, shaderTool: NativeShaderToolFixture.executable.path, enabled: true))
        try await service.ensurePublication()
        let first = await service.publicationStatus()
        try Data("CHANGED BODY\n".utf8).write(to: authoring.appendingPathComponent("shaders/plasma/body.metal"))
        try commitFixture(authoring)
        // A cache-only pass may keep the current publication.
        try await service.ensurePublication()
        let cached = await service.publicationStatus()
        XCTAssertEqual(first?.revision, cached?.revision)
        XCTAssertEqual(first?.sequence, cached?.sequence)
        // While suspended, a forced request upgrades the pending cache-only pass.
        await service.suspend()
        let cacheOnly = Task { try await service.ensurePublication() }
        try await waitFor { await service.pendingPublicationWaiterCount == 1 }
        let forced = Task { try await service.ensurePublication(force: true) }
        try await waitFor { await service.pendingPublicationWaiterCount == 2 }
        await service.resume()
        try await cacheOnly.value; try await forced.value
        let rebuilt = await service.publicationStatus()
        XCTAssertNotEqual(first?.revision, rebuilt?.revision)
        XCTAssertEqual(rebuilt?.sequence, (first?.sequence ?? 0) + 1)
        // A failed forced rebuild preserves both durable and served publications.
        try Data("dirty".utf8).write(to: authoring.appendingPathComponent("shaders/plasma/body.metal"))
        do { try await service.ensurePublication(force: true); XCTFail("Dirty forced rebuild accepted") } catch {}
        let retained = try JSONDecoder().decode(CatalogHead.self, from: await catalog.get(.head, limit: CatalogLimits.headBytes))
        let restored = try await catalog.cached()
        XCTAssertEqual(retained.revision, rebuilt?.revision)
        XCTAssertEqual(restored?.publicationRevision, rebuilt?.revision)
        XCTAssertEqual(try String(contentsOf: authoring.appendingPathComponent("shaders/plasma/body.metal"), encoding: .utf8), "dirty")
        _ = try await catalog.reload(from: authoring)
        let obsolete = await service.publicationStatus()
        XCTAssertNil(obsolete, "Manual reload must not inherit the prior service publication's warnings")
    }

    func testStartupRecoversAndCleansBeforeBootstrapThenActivatesOrdinaryJobs() async throws {
        for interrupted in [false, true] {
            let (root, script) = try recoveryFixture()
            let authoring = try requestAuthoringFixture(root.appendingPathComponent("authoring"))
            let previews = ShaderPreviewGenerator(directory: root.appendingPathComponent("previews")) { _ in try ShaderPNG.gradient(colors: [[0,0,0],[1,1,1]]) }
            let catalog = DirectoryCatalog(directory: root.appendingPathComponent("catalog"), previewGenerator: previews)
            let initial = ShaderRequestService(catalog: catalog, directory: root, workerScript: script)
            await initial.suspend(); try await initial.start(configuration: .init(repository: authoring.path, shaderTool: NativeShaderToolFixture.executable.path, enabled: true))
            let owner = ShaderRequest(prompt: "Interrupted", context: try context()), queued = ShaderRequest(prompt: "Queued", context: try context())
            if interrupted {
                _ = try await initial.control(operation: "requestSubmit", payload: .init(request: owner), deviceID: "A")
                try JSONEncoder().encode(owner.id).write(to: root.appendingPathComponent("active.json"), options: .atomic)
            }
            _ = try await initial.control(operation: "requestSubmit", payload: .init(request: queued), deviceID: "B")
            var scriptSource = try String(contentsOf: script, encoding: .utf8)
            scriptSource = scriptSource.replacingOccurrences(of: "if mode=='preflight':", with: """
            with (job.parent/'operation-order').open('a') as log: log.write(mode+':'+job.name+'\\n')
            if mode=='publication':
                emit('preparePublication',requiredPreviewShaderIDs=[])
                reply=json.loads(sys.stdin.readline())
                assert reply['ok'],reply
                emit('publicationReady'); raise SystemExit(0)
            if mode=='run' and job.name=='\(owner.id.uuidString)':
                emit('failure',message='Fixture candidate failed'); raise SystemExit(1)
            if mode=='preflight':
            """)
            try scriptSource.write(to: script, atomically: true, encoding: .utf8)
            let service = ShaderRequestService(catalog: catalog, directory: root, workerScript: script)
            try await service.initialize(configuration: .init(repository: authoring.path, shaderTool: NativeShaderToolFixture.executable.path, enabled: true))
            try await service.ensurePublication()
            let order = try String(contentsOf: root.appendingPathComponent("operation-order"), encoding: .utf8).split(separator: "\n").map(String.init)
            XCTAssertEqual(order, interrupted ? ["run:" + owner.id.uuidString, "discard:" + owner.id.uuidString, "publication:publication"] : ["publication:publication"])
            let jobs = await service.allJobs()
            XCTAssertEqual(jobs.first { $0.id == queued.id }?.stage, .queued)
            await service.activateScheduling()
            try await waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent(queued.id.uuidString).appendingPathComponent("worker-started").path) }
            try await service.detachCheckout(.request(queued.id))
        }
    }

    func testPublicationPreparationResumesAfterSleepAndCancelledWaiterLeavesNoWork() async throws {
        let (root, script) = try recoveryFixture()
        let authoring = try requestAuthoringFixture(root.appendingPathComponent("authoring"))
        try """
        import contextlib,json,os,sys
        with contextlib.suppress(PermissionError): os.setsid()
        print(json.dumps({'event':'preparePublication','requiredPreviewShaderIDs':[]}),flush=True)
        reply=json.loads(sys.stdin.readline())
        assert reply['ok'],reply
        print(json.dumps({'event':'publicationReady'}),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let gate = RequestPreparationGate()
        let previews = ShaderPreviewGenerator(directory: root.appendingPathComponent("previews")) { _ in
            await gate.hold(); return try ShaderPNG.gradient(colors: [[0,0,0],[1,1,1]])
        }
        let catalog = DirectoryCatalog(directory: root.appendingPathComponent("catalog"), previewGenerator: previews)
        let service = ShaderRequestService(catalog: catalog, directory: root, workerScript: script)
        try await service.initialize(configuration: .init(repository: authoring.path, shaderTool: NativeShaderToolFixture.executable.path, enabled: true))
        let rebuild = Task { try await service.ensurePublication(force: true) }
        try await waitFor { await gate.entered }
        await service.suspend(); await service.resume(); await gate.release()
        try await rebuild.value
        let status = await service.publicationStatus()
        XCTAssertNotNil(status)
        await service.suspend()
        let cancelled = Task { try await service.ensurePublication(force: true) }
        try await waitFor { await service.pendingPublicationWaiterCount == 1 }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled waiter succeeded") } catch is CancellationError {}
        let pending = await service.pendingPublicationWaiterCount
        XCTAssertEqual(pending, 0)
        await service.resume()
        let unchanged = await service.publicationStatus()
        XCTAssertEqual(unchanged?.revision, status?.revision)
        XCTAssertEqual(unchanged?.sequence, status?.sequence)
    }

    func testSetupInterruptionWaitsForExitAndCannotEnableAfterQuickResume() async throws {
        let (root, script) = try recoveryFixture()
        try """
        import contextlib,json,os,signal,sys,time
        from pathlib import Path
        with contextlib.suppress(PermissionError): os.setsid()
        job=Path(sys.argv[3])
        def stop(*args):
            (job/'stopping').touch()
            while (job/'hold-exit').exists(): time.sleep(.005)
            raise SystemExit(1)
        signal.signal(signal.SIGTERM,stop)
        (job/'setup-started').touch()
        while True: time.sleep(.005)
        """.write(to: script, atomically: true, encoding: .utf8)
        let setup = root.appendingPathComponent("setup")
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        try Data().write(to: setup.appendingPathComponent("hold-exit"))
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root, workerScript: script)
        try await service.initialize(configuration: .init(repository: root.path, enabled: false))
        let verify = Task { try await service.verify(configuration: .init(repository: root.path, enabled: false)) }
        try await waitFor { FileManager.default.fileExists(atPath: setup.appendingPathComponent("setup-started").path) }
        await service.suspend(); await service.resume()
        try await waitFor { FileManager.default.fileExists(atPath: setup.appendingPathComponent("stopping").path) }
        try FileManager.default.removeItem(at: setup.appendingPathComponent("hold-exit"))
        do { try await verify.value; XCTFail("Interrupted setup enabled requests") } catch {}
        let configuration = await service.configurationValue()
        XCTAssertFalse(configuration.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.appendingPathComponent("process.json").path))
    }

    func testRecordedFailureSurvivesReplyAfterWorkerRetirement() async throws {
        let (root, script) = try recoveryFixture(), worker = RequestWorkerProcess(script: script)
        try """
        print('{"event":"failure","failureKind":"supervision","message":"Original supervision fault"}',flush=True)
        raise SystemExit(7)
        """.write(to: script, atomically: true, encoding: .utf8)
        var events = worker.run(mode: "run", configuration: .init(repository: root.path), directory: root.appendingPathComponent("job")).makeAsyncIterator()
        _ = try await events.next(); try await worker.waitForExit()
        XCTAssertThrowsError(try worker.reply(true)) {
            XCTAssertTrue($0 is RequestWorkerSupervisionError)
            XCTAssertEqual($0.localizedDescription, "Original supervision fault")
        }
        do { _ = try await events.next(); XCTFail("Failed worker succeeded") }
        catch { XCTAssertTrue(error is RequestWorkerSupervisionError) }
    }

    func testRecordedFaultDuringPublicationPreparationRetainsPatchAndRetries() async throws {
        let gate = RequestPreparationGate(), f = try await publicationRecoveryFixture(gate: gate)
        let original = try String(contentsOf: f.script, encoding: .utf8)
        try """
        import json,sys,time
        from pathlib import Path
        job=Path(sys.argv[3])
        if sys.argv[1]=='run':
            counter=job/'attempts';n=int(counter.read_text())+1 if counter.exists() else 1;counter.write_text(str(n))
            (job/'owned-patch').write_bytes(b'keep exact unpublished bytes\\r\\n')
            if n==1:
                print(json.dumps(dict(event='preparePublication',requiredPreviewShaderIDs=[])),flush=True)
                while not (job/'send-fault').exists():time.sleep(.005)
                print(json.dumps(dict(event='failure',failureKind='supervision',message='Recorded fault during preparation')),flush=True)
                raise SystemExit(7)
            print(json.dumps(dict(event='clarification',question='Choose output',options=['A','B'])),flush=True)
            raise SystemExit(0)
        \(original)
        """.write(to: f.script, atomically: true, encoding: .utf8)
        let request = ShaderRequest(prompt: "Keep work", context: try context())
        _ = try await f.service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        let job = f.root.appendingPathComponent(request.id.uuidString)
        await f.service.activateScheduling(); await f.service.resume(); try await waitFor { await gate.entered }
        try Data().write(to: job.appendingPathComponent("send-fault"))
        try await waitFor { !RequestProcessIdentity.evidenceExists(job.appendingPathComponent("process.json")) }
        await gate.release()
        try await waitFor { await f.service.allJobs().first?.stage == .awaitingClarification }
        XCTAssertEqual(try String(contentsOf: job.appendingPathComponent("attempts"), encoding: .utf8), "2")
        XCTAssertEqual(try Data(contentsOf: job.appendingPathComponent("owned-patch")), Data("keep exact unpublished bytes\r\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("cleanup-started").path))
        await f.service.suspend()
    }

    func testUnexplainedPostLaunchExitRetriesOnceWithoutDiscard() async throws {
        let (root, script) = try recoveryFixture()
        try """
        import sys
        from pathlib import Path
        job=Path(sys.argv[3])
        if sys.argv[1]=='discard':(job/'cleanup-started').touch();raise SystemExit(0)
        counter=job/'attempts';counter.write_text(str(int(counter.read_text())+1 if counter.exists() else 1))
        (job/'owned-patch').write_bytes(b'keep patch')
        raise SystemExit(7)
        """.write(to: script, atomically: true, encoding: .utf8)
        let service = try await recoveryService(root, script: script)
        let request = ShaderRequest(prompt: "Preserve unexpected exit", context: try context())
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        let job = root.appendingPathComponent(request.id.uuidString)
        await service.resume(); try await waitFor { (try? RequestWorkerOperation.read(in: job)?.phase) == .paused }
        XCTAssertEqual(try String(contentsOf: job.appendingPathComponent("attempts"), encoding: .utf8), "2")
        XCTAssertEqual(try Data(contentsOf: job.appendingPathComponent("owned-patch")), Data("keep patch".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("cleanup-started").path))
        await service.suspend()
    }

    func testHealthyAutomaticRetryAcceptsQueuedRequestWithoutLaunchingIt() async throws {
        let (root, script) = try recoveryFixture()
        try """
        import json,sys,time
        from pathlib import Path
        job=Path(sys.argv[3]);counter=job/'attempts';n=int(counter.read_text())+1 if counter.exists() else 1;counter.write_text(str(n))
        if n==1:
            print(json.dumps(dict(event='failure',failureKind='supervision',message='Original fault')),flush=True);raise SystemExit(1)
        (job/'retry-started').touch()
        while not (job/'release').exists():time.sleep(.005)
        print(json.dumps(dict(event='clarification',question='Choose output',options=['A','B'])),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let service = try await recoveryService(root, script: script)
        let first = ShaderRequest(prompt: "Retry", context: try context()), second = ShaderRequest(prompt: "Queue", context: try context())
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: first), deviceID: "A")
        let job = root.appendingPathComponent(first.id.uuidString)
        await service.resume(); try await waitFor { FileManager.default.fileExists(atPath: job.appendingPathComponent("retry-started").path) }
        let reply = try await service.control(operation: "requestSubmit", payload: .init(request: second), deviceID: "B")
        XCTAssertTrue(reply.enabled); XCTAssertEqual(reply.jobs.first?.stage, .queued)
        let recoveries = await service.recoveryStatuses(); XCTAssertTrue(recoveries.contains { $0.isRetrying && $0.isRunning })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(second.id.uuidString + "/attempts").path))
        await service.suspend(); try Data().write(to: job.appendingPathComponent("release"))
    }

    func testCancelledInitialVerifyAllowsChangedRepositoryOrPython() async throws {
        for changeRepository in [true, false] {
            let (root, script) = try recoveryFixture(), gate = RequestPreparationGate()
            let setup = root.appendingPathComponent("setup")
            let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
                directory: root, workerScript: script, waitForWorker: { process in
                    try await process.waitForExit()
                    await gate.hold()
                })
            let original = ShaderRequestConfiguration(repository: root.path)
            try await service.initialize(configuration: original)
            let verifying = Task { try await service.verify(configuration: original) }
            defer { verifying.cancel(); Task { await gate.release() } }
            try await waitFor { await gate.entered }
            let cancelled = try XCTUnwrap(RequestWorkerOperation.read(in: setup))
            XCTAssertEqual(cancelled.phase, .initial)
            verifying.cancel(); await gate.release()
            do { try await verifying.value; XCTFail("Cancelled Verify succeeded") } catch is CancellationError {}
            XCTAssertEqual(try RequestWorkerOperation.read(in: setup)?.phase, .complete)
            let acceptedBeforeRetry = await service.configurationValue()
            XCTAssertEqual(acceptedBeforeRetry, original)

            var replacement = original
            if changeRepository {
                let folder = root.appendingPathComponent("other")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                replacement.repository = folder.path
            } else {
                let python = root.appendingPathComponent("python3")
                try FileManager.default.createSymbolicLink(atPath: python.path, withDestinationPath: original.python)
                replacement.python = python.path
            }
            try await service.verify(configuration: replacement)
            let accepted = await service.configurationValue()
            XCTAssertEqual(accepted.repository, RequestPaths.canonical(URL(fileURLWithPath: replacement.repository)))
            XCTAssertEqual(accepted.python, replacement.python); XCTAssertTrue(accepted.enabled)
            let completed = try XCTUnwrap(RequestWorkerOperation.read(in: setup))
            XCTAssertEqual(completed.phase, .complete); XCTAssertNotEqual(completed.id, cancelled.id)
            XCTAssertEqual(try RequestWorkerOperation.expectedID(in: setup), completed.id)
            let recoveries = await service.recoveryStatuses(); XCTAssertTrue(recoveries.isEmpty)
        }
    }

    func testDetachedAcknowledgementSurvivesDeletionAndReverificationAcrossAliases() async throws {
        let (root, script) = try recoveryFixture(), initial = try await recoveryService(root, script: script)
        let request = ShaderRequest(prompt: "Detach", context: try context())
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        let gitdir = try initializeRecoveryGit(root)
        let job = root.appendingPathComponent(request.id.uuidString), alias = root.appendingPathComponent("job-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: job)
        let marker = gitdir.appendingPathComponent("holodeck-request-owner.json")
        try JSONSerialization.data(withJSONObject: ["id": request.id.uuidString, "directory": alias.path]).write(to: marker)
        try await initial.detachCheckout(.request(request.id))
        try await initial.deleteFinished(request.id)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root, workerScript: script)
        try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        let disabled = await service.configurationValue()
        XCTAssertFalse(disabled.enabled)
        // The actual Python setup suite covers lease, dirty, foreign and failed-check rejection.
        // Here the bridge must forward durable authorization after the creative record is gone.
        try """
        import json,sys
        from pathlib import Path
        config=json.loads(Path(sys.argv[2]).read_text()); proof=config['detachedOwner']
        marker=Path(config['repository'])/'.git/holodeck-request-owner.json'
        owner=json.loads(marker.read_text())
        assert owner['id']==proof['requestID']
        assert Path(owner['directory']).resolve()==Path(proof['directory']).resolve()
        marker.unlink()
        print(json.dumps({'event':'preflight'}),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try await service.verify(configuration: .init(repository: root.path, enabled: false))
        let enabled = await service.configurationValue()
        XCTAssertTrue(enabled.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let restarted = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root, workerScript: script)
        try await restarted.initialize(configuration: .init())
        let reloaded = await restarted.configurationValue(), jobs = await restarted.allJobs()
        XCTAssertTrue(reloaded.enabled)
        XCTAssertTrue(jobs.isEmpty)
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
                try await service.detachCheckout(.request(owner.id))
                let pending = await service.hasPendingCleanup()
                XCTAssertFalse(pending); XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            } else {
                try await waitFor { !(await service.hasPendingCleanup()) }
                let order = try String(contentsOf: root.appendingPathComponent("cleanup-order"), encoding: .utf8).split(separator: "\n").map(String.init)
                XCTAssertEqual(order, [owner.id.uuidString, older.id.uuidString])
            }
        }
    }

    func testInterruptedOwnerResumesInsteadOfCleaningWhenAnotherJobNeedsCleanup() async throws {
        let (root, script) = try recoveryFixture(), initial = try await recoveryService(root, script: script)
        let owner = ShaderRequest(prompt: "Interrupted", context: try context()), other = ShaderRequest(prompt: "Parked", context: try context())
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: owner), deviceID: "A")
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: other), deviceID: "B")
        let journal = root.appendingPathComponent("journal.json")
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
        for i in records.indices {
            var status = try XCTUnwrap(records[i]["status"] as? [String: Any])
            if status["id"] as? String == other.id.uuidString { status["stage"] = "awaitingClarification"; records[i]["status"] = status }
        }
        try JSONSerialization.data(withJSONObject: records).write(to: journal)
        try JSONEncoder().encode(owner.id).write(to: root.appendingPathComponent("active.json"))
        let service = try await recoveryService(root, script: script)
        addTeardownBlock { try? await service.detachCheckout(.request(owner.id)) }
        let job = root.appendingPathComponent(owner.id.uuidString)
        try Data("unpublished work".utf8).write(to: job.appendingPathComponent("owned-patch"))
        try await service.revoke("B"); await service.resume()
        try await waitFor { FileManager.default.fileExists(atPath: job.appendingPathComponent("worker-started").path) }
        XCTAssertEqual(try String(contentsOf: job.appendingPathComponent("owned-patch"), encoding: .utf8), "unpublished work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("cleanup-started").path))
        let statuses = await service.allJobs()
        XCTAssertEqual(statuses.first { $0.id == owner.id }?.stage, .implementing)
    }

    func testCompletedWorkerCannotSignalReusedProcessGroup() async throws {
        let (root, _) = try recoveryFixture(), script = root.appendingPathComponent("completed.py")
        try "import json; print(json.dumps({'event':'done'}),flush=True)".write(to: script, atomically: true, encoding: .utf8)
        let probe = RequestSignalProbe()
        let worker = RequestWorkerProcess(script: script, groups: .init(signal: { probe.signal($0, $1) }))
        for try await _ in worker.run(mode: "run", configuration: .init(repository: root.path), directory: root.appendingPathComponent("completed")) {}
        try await worker.waitForExit()
        worker.stop(); worker.stop()
        XCTAssertEqual(probe.signalCount, 0)
    }

    func testReconciliationFailureIsVisibleWithoutJobsAndCanRetry() async throws {
        let (root, script) = try recoveryFixture(), service = try await recoveryService(root, script: script, enabled: false)
        let setup = root.appendingPathComponent("setup")
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        let marker = setup.appendingPathComponent("process.json")
        try JSONSerialization.data(withJSONObject: ["pid": 99999, "script": script.path, "directory": root.appendingPathComponent("foreign").path]).write(to: marker)
        await service.resume()
        try await waitFor { await service.recoveryStatuses().contains { $0.kind == .reconciliation } }
        try FileManager.default.removeItem(at: marker)
        try await service.retryReconciliation()
        let status = await service.recoveryStatuses()
        XCTAssertTrue(status.isEmpty)
    }

    func testOldReconciliationFailureCannotPoisonNewSuccessfulAttempt() async throws {
        let (root, script) = try recoveryFixture(), gate = ReconciliationRetryGate()
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
            workerScript: script, reconcileWorker: { try await gate.reconcile($0) })
        try await service.initialize(configuration: .init(repository: root.path))
        let old = Task { try await service.retryReconciliation() }
        try await waitFor { await gate.entered }
        do { try await service.retryReconciliation(); XCTFail("Overlapping recovery acquired the lease") } catch {}
        await gate.release()
        do { try await old.value; XCTFail("Old attempt unexpectedly succeeded") } catch {}
        try await service.retryReconciliation()
        let statuses = await service.recoveryStatuses()
        XCTAssertTrue(statuses.isEmpty)
    }

    func testDetachIsDurableDespiteInvalidTerminalWorkerIdentity() async throws {
        let (root, script) = try recoveryFixture(), initial = try await recoveryService(root, script: script)
        let request = ShaderRequest(prompt: "Recovery", context: try context())
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        try await initial.cancelQueued(request.id)
        let job = root.appendingPathComponent(request.id.uuidString), marker = job.appendingPathComponent("process.json")
        try JSONSerialization.data(withJSONObject: ["pid": 99999, "script": script.path, "directory": root.appendingPathComponent("wrong").path]).write(to: marker)
        let service = try await recoveryService(root, script: script)
        await service.resume()
        try await waitFor { await service.recoveryStatuses().contains { $0.kind == .reconciliation } }
        try await service.detachCheckout(.request(request.id))
        let restarted = try await recoveryService(root, script: script)
        let configuration = await restarted.configurationValue(), statuses = await restarted.allJobs()
        XCTAssertFalse(configuration.enabled)
        XCTAssertEqual(statuses.first?.stage, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let evidence = try FileManager.default.contentsOfDirectory(atPath: job.path)
        XCTAssertTrue(evidence.contains { $0.hasPrefix("detached-") })
        try await restarted.deleteFinished(request.id)
        let acknowledgements = try JSONDecoder().decode([DetachedCheckoutAcknowledgement].self, from: Data(contentsOf: root.appendingPathComponent("detached-checkouts.json")))
        XCTAssertTrue(acknowledgements.contains { $0.requestID == request.id })
    }

    func testCadenceToleranceAtNominalAndFractionalRates() {
        for (rate, expected) in [(24.0,24.0),(25,25),(50,25),(59.94,29.97),(60,30),(60.0003,30),(120,30),(120.0003,30),(59.9997,29.99985)] {
            XCTAssertEqual(ShaderPerformanceMonitor.attainableTarget(displayFramesPerSecond: rate), expected, accuracy: 0.000001)
        }
        for (target, nominal) in [(24.0,24.0),(25,25),(24,48),(25,50),(30,60),(24,120),(30,120)] {
            for offset in [-0.01, -0.0003, 0.0003, 0.01] {
                let actual = ShaderPerformanceMonitor.attainableTarget(displayFramesPerSecond: nominal + offset, preferred: target)
                XCTAssertEqual(actual, min(target, (nominal + offset) / (nominal / target)), accuracy: 0.000001)
            }
        }
        XCTAssertEqual(ShaderPerformanceMonitor.attainableTarget(displayFramesPerSecond: 60.02), 30, accuracy: 0.000001)
        var monitor = ShaderPerformanceMonitor()
        monitor.setTargetFramesPerSecond(25, at: 100)
        XCTAssertNil(monitor.observe(at: 101, deliveredFrames: 0))
        monitor.setTargetFramesPerSecond(24, at: 101)
        XCTAssertNil(monitor.observe(at: 102, deliveredFrames: 0))
        XCTAssertEqual(monitor.targetFramesPerSecond, 24)
    }

    private func publicationRecoveryFixture(gate: RequestPreparationGate? = nil,
        reconcile: @escaping @Sendable (URL) async throws -> Void = { try RequestWorkerProcess.reconcileOrphan(in: $0) }
    ) async throws -> (root: URL, script: URL, authoring: URL, catalog: DirectoryCatalog, service: ShaderRequestService) {
        let (root, script) = try recoveryFixture()
        let authoring = try requestAuthoringFixture(root.appendingPathComponent("authoring"))
        _ = try initializeRecoveryGit(authoring)
        var source = try String(contentsOf: script, encoding: .utf8)
        source = source.replacingOccurrences(of: "if mode=='preflight':", with: """
        with (job.parent/'operations').open('a') as log: log.write(mode+':'+job.name+'\\n')
        if mode=='publication':
            count=job/'publication-count'
            count.write_text(str(int(count.read_text())+1 if count.exists() else 1))
            if (job/'fail-publication').exists(): emit('failure',message='Automatic fixture publication failed'); raise SystemExit(1)
            emit('preparePublication',requiredPreviewShaderIDs=[])
            reply=json.loads(sys.stdin.readline())
            assert reply['ok'],reply
            emit('publicationReady'); raise SystemExit(0)
        if mode=='preflight':
        """)
        source = source.replacingOccurrences(of: "emit('discarded'); raise SystemExit(0)", with: """
        marker=Path(json.loads(Path(sys.argv[2]).read_text())['repository'])/'.git/holodeck-request-owner.json'
            if marker.exists() and json.loads(marker.read_text())['id']==job.name: marker.unlink()
            emit('discarded'); raise SystemExit(0)
        """)
        try source.write(to: script, atomically: true, encoding: .utf8)
        let previews = ShaderPreviewGenerator(directory: root.appendingPathComponent("previews")) { _ in
            if let gate { await gate.hold() }
            return try ShaderPNG.gradient(colors: [[0,0,0],[1,1,1]])
        }
        let catalog = DirectoryCatalog(directory: root.appendingPathComponent("catalog"), previewGenerator: previews)
        let service = ShaderRequestService(catalog: catalog, directory: root, workerScript: script, reconcileWorker: reconcile)
        await service.suspend()
        try await service.initialize(configuration: .init(repository: authoring.path, shaderTool: NativeShaderToolFixture.executable.path, enabled: true))
        return (root, script, authoring, catalog, service)
    }
    private func brokenReconciliation(_ root: URL) throws -> URL {
        let setup = root.appendingPathComponent("setup")
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        let marker = setup.appendingPathComponent("process.json")
        try Data("{}".utf8).write(to: marker)
        let preferences = root.appendingPathComponent("preferences.json")
        if FileManager.default.fileExists(atPath: preferences.path) {
            try Data(contentsOf: preferences).write(to: setup.appendingPathComponent("configuration.json"))
        } else {
            try JSONEncoder().encode(ShaderRequestConfiguration(repository: root.appendingPathComponent("authoring").path))
                .write(to: setup.appendingPathComponent("configuration.json"))
        }
        return marker
    }
    private func recoveryFailure(_ task: Task<Void, Error>) async throws -> ShaderRequestPublicationFailure {
        let backstop = Task { try await Task.sleep(for: .seconds(8)); task.cancel() }
        defer { backstop.cancel() }
        do { try await task.value; XCTFail("Blocked publication succeeded") }
        catch let failure as ShaderRequestPublicationFailure {
            XCTAssertTrue(failure.recoveryRequired)
            XCTAssertTrue(failure.message.contains("recovery"))
            return failure
        }
        throw ShaderRequestError.unavailable("Expected typed recovery failure")
    }

    func testRecoveryFailureSettlesCoalescedWaitersAndAutomaticallyForcesPublicationBeforeJobs() async throws {
        for _ in 0..<3 {
            let f = try await publicationRecoveryFixture(), service = f.service
            let original = try await f.catalog.reload(from: f.authoring)
            try Data("UPDATED\n".utf8).write(to: f.authoring.appendingPathComponent("shaders/plasma/body.metal"))
            let marker = try brokenReconciliation(f.root)
            let queued = ShaderRequest(prompt: "After recovery", context: try context())
            _ = try await service.control(operation: "requestSubmit", payload: .init(request: queued), deviceID: "TV")
            let cache = Task { try await service.ensurePublication() }, forced = Task { try await service.ensurePublication(force: true) }
            try await waitFor { await service.pendingPublicationWaiterCount == 2 }
            await service.resume()
            let first = try await recoveryFailure(cache), second = try await recoveryFailure(forced)
            XCTAssertEqual(first, second)
            let failed = await service.publicationOperationStatus(), pending = await service.pendingPublicationWaiterCount
            XCTAssertEqual(failed.phase, .failed); XCTAssertEqual(failed.failure, first); XCTAssertEqual(pending, 0)
            let head = try JSONDecoder().decode(CatalogHead.self, from: await f.catalog.get(.head, limit: CatalogLimits.headBytes))
            XCTAssertEqual(head.revision, original.catalog.publicationRevision)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations").path))
            // An old caller's cancellation cannot cancel the service-owned retry intent.
            cache.cancel(); forced.cancel()
            try FileManager.default.removeItem(at: marker)
            await service.activateScheduling()
            try await service.retryReconciliation()
            try await waitFor { FileManager.default.fileExists(atPath: f.root.appendingPathComponent(queued.id.uuidString).appendingPathComponent("worker-started").path) }
            let publication = await service.publicationStatus()
            XCTAssertNotEqual(publication?.revision, original.catalog.publicationRevision)
            let operations = try String(contentsOf: f.root.appendingPathComponent("operations"), encoding: .utf8).split(separator: "\n").map(String.init)
            XCTAssertEqual(operations, ["publication:publication", "run:" + queued.id.uuidString])
            try await service.detachCheckout(.request(queued.id))
        }
    }

    func testOwnerAndRemainingFailedCleanupRejectPublicationThenRetryAutomatically() async throws {
        let f = try await publicationRecoveryFixture(), a = ShaderRequest(prompt: "Cleanup A", context: try context()), b = ShaderRequest(prompt: "Cleanup B", context: try context())
        for request in [a,b] { _ = try await f.service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: request.id.uuidString) }
        let journal = f.root.appendingPathComponent("journal.json")
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
        for i in rows.indices {
            var status = rows[i]["status"] as! [String: Any]; status["stage"] = "failed"
            rows[i]["status"] = status; rows[i]["cleanupPending"] = true
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: journal)
        let aJob = f.root.appendingPathComponent(a.id.uuidString), owner = f.authoring.appendingPathComponent(".git/holodeck-request-owner.json")
        try Data().write(to: aJob.appendingPathComponent("fail-cleanup"))
        try Data().write(to: aJob.appendingPathComponent("hold-cleanup"))
        func setOwner(_ request: ShaderRequest) throws {
            try JSONSerialization.data(withJSONObject: ["id": request.id.uuidString, "directory": f.root.appendingPathComponent(request.id.uuidString).path]).write(to: owner)
        }
        try setOwner(a)
        let service = ShaderRequestService(catalog: f.catalog, directory: f.root, workerScript: f.script)
        await service.suspend(); try await service.initialize(configuration: .init(repository: f.authoring.path, enabled: true))
        let first = Task { try await service.ensurePublication(force: true) }
        try await waitFor { await service.pendingPublicationWaiterCount == 1 }; await service.resume()
        try await waitFor { FileManager.default.fileExists(atPath: aJob.appendingPathComponent("cleanup-started").path) }
        let waiting = await service.pendingPublicationWaiterCount
        XCTAssertEqual(waiting, 1, "Active cleanup is contention, not a terminal publication failure")
        try FileManager.default.removeItem(at: aJob.appendingPathComponent("hold-cleanup"))
        _ = try await recoveryFailure(first)
        // A newly reconciled owner B cleans successfully; the remaining A failure must also settle callers.
        await service.suspend(); try setOwner(b)
        let second = Task { try await service.ensurePublication() }
        try await waitFor { await service.pendingPublicationWaiterCount == 1 }
        try await service.retryReconciliation(); await service.resume()
        _ = try await recoveryFailure(second)
        let jobs = await service.allJobs()
        XCTAssertTrue(jobs.allSatisfy { $0.stage == .failed })
        let recoveries = await service.recoveryStatuses()
        XCTAssertEqual(recoveries.map(\.id), [a.id])
        try FileManager.default.removeItem(at: aJob.appendingPathComponent("fail-cleanup")); try setOwner(a)
        try await service.retryCleanup(a.id, repository: f.authoring.path, python: "/usr/bin/python3", git: "/usr/bin/git")
        try await waitFor { await service.publicationOperationStatus().revision != nil }
        let cleanup = await service.hasPendingCleanup()
        XCTAssertFalse(cleanup)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("publication/publication-count"), encoding: .utf8), "1")
    }

    func testAutomaticPublicationSurvivesSleepWithoutWaitersAndIndividualCancellation() async throws {
        let gate = RequestPreparationGate(), f = try await publicationRecoveryFixture(gate: gate)
        let marker = try brokenReconciliation(f.root)
        let request = Task { try await f.service.ensurePublication(force: true) }
        try await waitFor { await f.service.pendingPublicationWaiterCount == 1 }; await f.service.resume()
        _ = try await recoveryFailure(request)
        try FileManager.default.removeItem(at: marker); try await f.service.retryReconciliation()
        try await waitFor { await gate.entered }
        await f.service.suspend()
        let cancelled = Task { try await f.service.ensurePublication() }
        try await waitFor { await f.service.pendingPublicationWaiterCount == 1 }; cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled caller completed") } catch is CancellationError {}
        await f.service.resume(); await gate.release()
        try await waitFor { await f.service.publicationOperationStatus().revision != nil }
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("publication/publication-count"), encoding: .utf8), "2")
        let pending = await f.service.pendingPublicationWaiterCount
        XCTAssertEqual(pending, 0)
    }

    func testNativeAutomaticPublicationReportsDirtyCheckoutFailure() async throws {
        let f = try await publicationRecoveryFixture()
        for arguments in [["symbolic-ref", "HEAD", "refs/heads/main"], ["add", "--all"]] {
            let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.currentDirectoryURL = f.authoring; git.arguments = arguments
            try git.run(); git.waitUntilExit(); XCTAssertEqual(git.terminationStatus, 0)
        }
        try commitFixture(f.authoring)
        let directory = f.root.appendingPathComponent("native")
        let marker = try brokenReconciliation(directory)
        let service = ShaderRequestService(catalog: f.catalog, directory: directory)
        try await service.initialize(configuration: .init(repository: f.authoring.path, enabled: true))
        let first = Task { try await service.ensurePublication(force: true) }
        _ = try await recoveryFailure(first)
        try Data("dirty".utf8).write(to: f.authoring.appendingPathComponent("shaders/plasma/body.metal"))
        try FileManager.default.removeItem(at: marker); try await service.retryReconciliation()
        try await waitFor { await service.publicationOperationStatus().failure?.recoveryRequired == false }
        let failure = await service.publicationOperationStatus().failure
        XCTAssertTrue(failure?.message.contains("clean main checkout") == true, "Observed \(String(describing: failure))")
    }

    func testAutomaticOperationalFailureIsVisibleAndDoesNotLoopThenExplicitRetrySucceeds() async throws {
        let f = try await publicationRecoveryFixture(), marker = try brokenReconciliation(f.root)
        let publication = f.root.appendingPathComponent("publication")
        try FileManager.default.createDirectory(at: publication, withIntermediateDirectories: true)
        try Data().write(to: publication.appendingPathComponent("fail-publication"))
        let request = Task { try await f.service.ensurePublication(force: true) }
        try await waitFor { await f.service.pendingPublicationWaiterCount == 1 }; await f.service.resume()
        let recovery = try await recoveryFailure(request)
        try FileManager.default.removeItem(at: marker); try await f.service.retryReconciliation()
        try await waitFor { await f.service.publicationOperationStatus().failure?.recoveryRequired == false }
        let failed = await f.service.publicationOperationStatus()
        XCTAssertGreaterThan(failed.sequence, recovery.operationSequence)
        XCTAssertTrue(failed.failure?.message.contains("Automatic fixture publication failed") == true)
        try await f.service.retryReconciliation()
        XCTAssertEqual(try String(contentsOf: publication.appendingPathComponent("publication-count"), encoding: .utf8), "1")
        try FileManager.default.removeItem(at: publication.appendingPathComponent("fail-publication"))
        try await f.service.ensurePublication(force: true)
        let restored = await f.service.publicationStatus()
        XCTAssertNotNil(restored)
    }

    func testDisableDetachAndCheckoutReplacementClearAutomaticPublicationIntent() async throws {
        for mode in ["disable", "detach", "replace"] {
            let f = try await publicationRecoveryFixture(), marker = try brokenReconciliation(f.root)
            let request = Task { try await f.service.ensurePublication(force: true) }
            try await waitFor { await f.service.pendingPublicationWaiterCount == 1 }; await f.service.resume()
            _ = try await recoveryFailure(request)
            if mode == "disable" { try await f.service.disable() }
            if mode == "detach" {
                let target = await f.service.recoveryStatuses().first { $0.kind == .reconciliation }!
                try await f.service.detachCheckout(.recovery(target.id))
            }
            if mode == "replace" {
                let other = try requestAuthoringFixture(f.root.appendingPathComponent("other"))
                try await f.service.initialize(configuration: .init(repository: other.path, enabled: true))
            }
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
            try await f.service.retryReconciliation()
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("publication/publication-count").path))
            let state = await f.service.publicationOperationStatus()
            XCTAssertEqual(state.phase, .idle)
        }
    }

    func testStaleReconciliationCannotRejectNewerPreparingPublication() async throws {
        for _ in 0..<3 {
            let reconciliation = ReconciliationRetryGate(), preparation = RequestPreparationGate()
            let f = try await publicationRecoveryFixture(gate: preparation, reconcile: { try await reconciliation.reconcile($0) })
            let old = Task { try await f.service.retryReconciliation() }
            try await waitFor { await reconciliation.entered }
            let request = Task { try await f.service.ensurePublication(force: true) }
            try await waitFor { await f.service.pendingPublicationWaiterCount == 1 }
            do { try await f.service.retryReconciliation(); XCTFail("Overlapping recovery acquired the lease") } catch {}
            await reconciliation.release()
            do { try await old.value; XCTFail("Old reconciliation unexpectedly succeeded") } catch {}
            try await f.service.retryReconciliation(); await f.service.resume()
            try await waitFor { await preparation.entered }
            let state = await f.service.publicationOperationStatus()
            XCTAssertEqual(state.phase, .preparing); XCTAssertNil(state.failure)
            await preparation.release(); try await request.value
        }
    }

    func testDetachedCopyCannotConsumeOriginalProofAndAliasConsumesOnlyItsOwnPath() async throws {
        let (root, script) = try recoveryFixture(), original = root.appendingPathComponent("original"), copy = root.appendingPathComponent("copy")
        let gitdir = try initializeRecoveryGit(original), id = UUID(), other = UUID(), identity = UUID().uuidString
        let job = root.appendingPathComponent(id.uuidString), otherJob = root.appendingPathComponent(other.uuidString)
        let marker = gitdir.appendingPathComponent("holodeck-request-owner.json")
        try Data(identity.utf8).write(to: gitdir.appendingPathComponent("holodeck-checkout-id"))
        try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "directory": job.path]).write(to: marker)
        try FileManager.default.copyItem(at: original, to: copy)
        let proofs = [DetachedCheckoutAcknowledgement(requestID: id, directory: job.path, repository: original.path, checkoutID: identity),
                      DetachedCheckoutAcknowledgement(requestID: other, directory: otherJob.path, repository: copy.path, checkoutID: identity)]
        let acknowledgements = root.appendingPathComponent("detached-checkouts.json")
        try JSONEncoder().encode(proofs).write(to: acknowledgements)
        try """
        import json,sys
        from pathlib import Path
        config=json.loads(Path(sys.argv[2]).read_text()); proof=config.get('detachedOwner')
        if not proof:
            print(json.dumps({'event':'failure','message':'Unacknowledged checkout owner'}),flush=True); raise SystemExit(1)
        assert Path(proof['repository']).resolve()==Path(config['repository']).resolve()
        marker=Path(config['repository'])/'.git/holodeck-request-owner.json'; marker.unlink()
        print(json.dumps({'event':'preflight','checkoutID':'\(identity)'}),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root, workerScript: script)
        try await service.initialize(configuration: .init(repository: original.path))
        do { try await service.verify(configuration: .init(repository: copy.path)); XCTFail("Copied owner was accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent(".git/holodeck-request-owner.json").path))
        XCTAssertEqual(try JSONDecoder().decode([DetachedCheckoutAcknowledgement].self, from: Data(contentsOf: acknowledgements)), proofs)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        try await service.verify(configuration: .init(repository: alias.path))
        let verified = await service.configurationValue()
        XCTAssertEqual(verified.repository, RequestPaths.canonical(original))
        XCTAssertEqual(try JSONDecoder().decode([DetachedCheckoutAcknowledgement].self, from: Data(contentsOf: acknowledgements)), [proofs[1]])
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: copy)
        let restarted = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root, workerScript: script)
        try await restarted.initialize(configuration: .init())
        let config = await restarted.configurationValue()
        XCTAssertTrue(config.enabled, "A proof for a different path with the same UUID must not disable this checkout")
        XCTAssertEqual(config.repository, RequestPaths.canonical(original), "Retargeting the selected alias cannot relocate ownership")
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

    func testSelectionRollbackFailureIsDurableAndRecoveryRestoresPreferences() async throws {
        let (root, script) = try recoveryFixture(), old = try requestAuthoringFixture(root.appendingPathComponent("old")), new = try requestAuthoringFixture(root.appendingPathComponent("new"))
        let catalogDirectory = root.appendingPathComponent("catalog"), preferences = root.appendingPathComponent("preferences.json")
        let originalCatalog = DirectoryCatalog(directory: catalogDirectory), previous = try await originalCatalog.reload(from: old)
        var files = DirectoryCatalogFileOperations()
        files.writeMarker = { _, _ in
            try FileManager.default.removeItem(at: preferences)
            try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: false)
            throw POSIXError(.EIO)
        }
        let catalog = DirectoryCatalog(directory: catalogDirectory, files: files)
        _ = try await catalog.cached()
        let writes = RecoveryWriteProbe()
        let service = ShaderRequestService(catalog: catalog, directory: root, workerScript: script,
            recoveryWriter: { data, url in writes.record(data); try data.write(to: url, options: .atomic) })
        await service.suspend(); try await service.initialize(configuration: .init(repository: old.path))
        do { _ = try await service.reloadRepository(new); XCTFail("Failed publication installed") } catch {}
        let store = try JSONDecoder().decode(RequestRecoveryStore.self, from: Data(contentsOf: root.appendingPathComponent("recovery.json")))
        XCTAssertEqual(store.entries.values.first?.preferencesRollback?.repository,old.path)
        XCTAssertEqual(writes.firstSelection?.preferencesRollback?.repository,old.path)
        let head = try JSONDecoder().decode(CatalogHead.self, from: await catalog.get(.head, limit: CatalogLimits.headBytes))
        XCTAssertEqual(head.revision,previous.catalog.publicationRevision)
        try FileManager.default.removeItem(at: preferences)
        try await service.retryReconciliation()
        let saved = try JSONDecoder().decode(ShaderRequestConfiguration.self,from:Data(contentsOf:preferences))
        XCTAssertEqual(saved.repository,old.path)
    }

    func testPostStartupRepositorySelectionDrivesNextForcedPublication() async throws {
        let f = try await publicationRecoveryFixture()
        let previous = try await f.catalog.reload(from: f.authoring)
        try await f.service.disable()
        let selected = try requestAuthoringFixture(f.root.appendingPathComponent("selected"))
        try Data("SELECTED\n".utf8).write(to: selected.appendingPathComponent("shaders/plasma/body.metal"))
        let accepted = try await f.service.reloadRepository(selected)
        XCTAssertEqual(accepted.configuration.repository, RequestPaths.canonical(selected))
        XCTAssertNotEqual(accepted.publication.catalog.publicationRevision, previous.catalog.publicationRevision)
        await f.service.resume(); try await f.service.ensurePublication(force: true)
        let cfg = try JSONDecoder().decode(ShaderRequestConfiguration.self, from: Data(contentsOf: f.root.appendingPathComponent("publication/configuration.json")))
        XCTAssertEqual(cfg.repository, RequestPaths.canonical(selected))
        let status = await f.service.publicationStatus(); XCTAssertEqual(status?.revision, accepted.publication.catalog.publicationRevision)
    }

    func testRejectedAndFailedRepositorySelectionPreservePreviousState() async throws {
        let f = try await publicationRecoveryFixture(), previous = try await f.catalog.reload(from: f.authoring)
        do { _ = try await f.service.selectRepository(f.root); XCTFail("Enabled checkout changed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Disable shader requests")) }
        try await f.service.disable()
        let before = try Data(contentsOf: f.root.appendingPathComponent("preferences.json"))
        do { _ = try await f.service.reloadRepository(f.root.appendingPathComponent("missing")); XCTFail("Invalid folder loaded") } catch {}
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("preferences.json")),before)
        let cfg = await f.service.configurationValue(); XCTAssertEqual(cfg.repository,f.authoring.path)
        let head = try JSONDecoder().decode(CatalogHead.self, from: await f.catalog.get(.head, limit: CatalogLimits.headBytes))
        XCTAssertEqual(head.revision,previous.catalog.publicationRevision)
    }

    func testRepositorySelectionOwnsLeaseUntilPublicationCompletes() async throws {
        for _ in 0..<10 {
            let gate = RequestPreparationGate(), f = try await publicationRecoveryFixture(gate: gate)
            try await f.service.disable()
            let selecting = Task { try await f.service.reloadRepository(f.authoring) }
            try await waitFor { await gate.entered }
            do { _ = try await f.service.selectRepository(f.root); XCTFail("Changed repository during preparation") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Wait for active")) }
            do { try await f.service.detachCheckout(.selectedCheckout); XCTFail("Detached during selection") }
            catch { XCTAssertTrue(error.localizedDescription.contains("finish loading")) }
            await gate.release(); _ = try await selecting.value
        }
    }

    func testUnsupportedInterpreterIsRejectedBeforeWorkerParsing() async throws {
        let (root, _) = try recoveryFixture(), interpreter = root.appendingPathComponent("old-python"), script = root.appendingPathComponent("invalid.py")
        try "this worker deliberately cannot parse!".write(to: script, atomically: true, encoding: .utf8)
        try """
        #!/usr/bin/python3
        import sys
        args=sys.argv[1:];index=args.index('-c');source=args[index+1]
        sys.argv=['-c']+args[index+2:];sys.version_info=(3,7,0)
        exec(compile(source,'bootstrap','exec'))
        """.write(to: interpreter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath: interpreter.path)
        var config = ShaderRequestConfiguration(repository: root.path); config.python = interpreter.path
        let worker = RequestWorkerProcess(script: script); var diagnostic: String?
        do { for try await event in worker.run(mode: "run", configuration: config, directory: root.appendingPathComponent("unsupported")) { diagnostic = event.message } }
        catch { XCTAssertTrue(error.localizedDescription.contains("exited 2") || error.localizedDescription.contains("exit 2")) }
        try await worker.waitForExit(); XCTAssertTrue(diagnostic?.contains("Python 3.9 or later") == true)
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("unsupported/worker-stderr.log"), encoding: .utf8).contains("SyntaxError"))
    }

    func testRepeatedStopSignalsEachBirthIdentityOnceAndRetiresIt() async throws {
        let (root, _) = try recoveryFixture(), script = root.appendingPathComponent("stop-once.py"), probe = RequestSignalProbe()
        try """
        import signal,time
        def stop(*args):
            signal.signal(signal.SIGTERM,signal.SIG_IGN)
            time.sleep(.1)
            raise SystemExit(0)
        signal.signal(signal.SIGTERM,stop)
        print('{"event":"ready"}',flush=True)
        time.sleep(60)
        """.write(to: script, atomically: true, encoding: .utf8)
        let worker = RequestWorkerProcess(script: script, groups: .init(signal: { pid, value in _ = probe.signal(pid,value); return kill(pid,value) }))
        do {
            for try await event in worker.run(mode: "run", configuration: .init(repository: root.path), directory: root.appendingPathComponent("stop-once")) {
                if event.event == "ready" { worker.stop(); worker.stop(); worker.stop() }
            }
            XCTFail("Cancellation succeeded")
        } catch is CancellationError {}
        try await worker.waitForExit()
        XCTAssertEqual(probe.signalCount,1)
        worker.stop(); worker.stop(); XCTAssertEqual(probe.signalCount,1)
    }

    func testTransientRegistryGapSettlesBeforeSuccessfulWorkerCompletion() async throws {
        for _ in 0..<10 {
            let (root, _) = try recoveryFixture(), script = root.appendingPathComponent("registry-gap.py")
            let bundled = try XCTUnwrap(RequestWorkerProcess.bundledScript)
            try """
            import importlib.util,subprocess,sys,time
            from pathlib import Path
            spec=importlib.util.spec_from_file_location('worker',\(String(reflecting: bundled.path)));w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
            job=Path(sys.argv[3]);gate=job/'go'
            code="import subprocess,sys,time;from pathlib import Path;gate=Path(sys.argv[1]);exec('while not gate.exists(): time.sleep(.005)');subprocess.Popen([sys.executable,'-c','import time;time.sleep(.2)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)"
            parent=subprocess.Popen([sys.executable,'-c',code,str(gate)],start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            birth=w.process_identity(parent.pid);w.write(job/'children.json',[{'leader':birth,'members':[birth]}])
            gate.touch();parent.wait()
            deadline=w.process_clock()+5
            while w.group_members(parent.pid):
                assert w.process_clock()<deadline, 'Fixture descendant did not settle'
                time.sleep(.005)
            (job/'children.json').unlink();print('{"event":"done"}',flush=True)
            """.write(to: script, atomically: true, encoding: .utf8)
            let worker = RequestWorkerProcess(script: script)
            var done = false
            for try await event in worker.run(mode: "run", configuration: .init(repository: root.path), directory: root.appendingPathComponent("gap")) { done = done || event.event == "done" }
            try await worker.waitForExit(); XCTAssertTrue(done)
        }
    }

    func testPostExitSupervisorIdleCPUAndPollBudget() async throws {
        guard ProcessInfo.processInfo.environment["HOLODECK_PROFILE_WORKER"] == "1" else { throw XCTSkip("Set HOLODECK_PROFILE_WORKER=1 with an optimized build") }
        let (root, _) = try recoveryFixture(), script = root.appendingPathComponent("idle.py"), bundled = try XCTUnwrap(RequestWorkerProcess.bundledScript)
        try """
        import importlib.util,subprocess,sys
        from pathlib import Path
        spec=importlib.util.spec_from_file_location('worker',\(String(reflecting: bundled.path)));w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
        child=subprocess.Popen([sys.executable,'-u','-c',"import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print('ready',flush=True);time.sleep(60)"],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        child.stdout.readline();birth=w.process_identity(child.pid)
        w.write(Path(sys.argv[3])/'children.json',[{'leader':birth,'members':[birth]}])
        """.write(to: script, atomically: true, encoding: .utf8)
        let waits = WorkerWaitCounter()
        let worker = RequestWorkerProcess(script: script, groups: .init(wait: { duration in waits.record(); Thread.sleep(forTimeInterval: duration) }))
        let start = Date(), cpu = clock()
        for try await _ in worker.run(mode: "run", configuration: .init(repository: root.path), directory: root.appendingPathComponent("idle")) {}
        try await worker.waitForExit()
        let elapsed = Date().timeIntervalSince(start), used = Double(clock()-cpu)/Double(CLOCKS_PER_SEC)
        XCTAssertLessThan(Double(waits.count)/elapsed,50); XCTAssertLessThan(used/elapsed,0.2)
        print("Supervisor idle: \(Double(waits.count)/elapsed) polls/s, \(used/elapsed*100)% CPU")
    }

    func testTeardownRecoveryPersistsResumeIntentWithoutDiscardingCheckpoint() async throws {
        for _ in 0..<10 {
            let (root, script) = try recoveryFixture(), gate = WorkerExitFailureGate()
            let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
                workerScript: script, waitForWorker: { try await gate.wait($0) })
            await service.suspend(); try await service.start(configuration: .init(repository: root.path, enabled: true))
            let request = ShaderRequest(prompt: "Preserve", context: try context()), job = root.appendingPathComponent(request.id.uuidString)
            _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
            try Data("preserved".utf8).write(to: job.appendingPathComponent("changes.patch"))
            await service.resume(); try await waitFor { FileManager.default.fileExists(atPath: job.appendingPathComponent("worker-started").path) }
            await service.suspend()
            try await waitFor { await service.recoveryStatuses().contains { $0.disposition == .resume } }
            let store = try JSONDecoder().decode(RequestRecoveryStore.self, from: Data(contentsOf: root.appendingPathComponent("recovery.json")))
            XCTAssertEqual(store.entries.values.first?.requestID, request.id)
            let saved = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("journal.json"))) as? [[String: Any]])?.first)
            XCTAssertNotEqual(saved["cleanupPending"] as? Bool, true)
            XCTAssertEqual(try String(contentsOf: job.appendingPathComponent("changes.patch"), encoding: .utf8), "preserved")
            let gitdir = try initializeRecoveryGit(root)
            try JSONSerialization.data(withJSONObject: ["id": request.id.uuidString, "directory": RequestPaths.canonical(job)]).write(to: gitdir.appendingPathComponent("holodeck-request-owner.json"))
            let restarted = try await recoveryService(root, script: script)
            try await restarted.retryReconciliation()
            await restarted.resume()
            try await waitFor { (try? String(contentsOf: job.appendingPathComponent("worker-count"), encoding: .utf8)) == "2" }
            let status = await restarted.allJobs().first
            XCTAssertFalse(status?.stage.terminal ?? true); XCTAssertFalse(status?.message.contains("revoked") ?? true)
            await restarted.suspend()
            try await restarted.detachCheckout(.request(request.id))
        }
    }

    func testPublishedResultSurvivesTeardownFailureAndRecovery() async throws {
        let (root, script) = try recoveryFixture(), gate = WorkerExitFailureGate()
        let authoring = try requestAuthoringFixture(root.appendingPathComponent("authoring"))
        try """
        import json,sys
        print(json.dumps({'event':'preparePublication','requiredPreviewShaderIDs':[]}),flush=True)
        assert json.loads(sys.stdin.readline())['ok']
        print(json.dumps({'event':'result','result':{'outputKind':'edited','shaderID':'plasma','changed':False,'summary':'Published','approximations':[]}}),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
            workerScript: script, waitForWorker: { try await gate.wait($0) })
        await service.suspend(); try await service.start(configuration: .init(repository: authoring.path, shaderTool: NativeShaderToolFixture.executable.path, enabled: true))
        let request = ShaderRequest(prompt: "Published", context: try context())
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        await service.resume(); try await waitFor { await service.recoveryStatuses().contains { $0.disposition == .retainResult } }
        let before = await service.allJobs().first
        XCTAssertEqual(before?.stage, .awaitingActivation); XCTAssertEqual(before?.result?.summary, "Published")
        try await service.retryReconciliation()
        let after = await service.allJobs().first
        XCTAssertEqual(after?.stage, .awaitingActivation); XCTAssertEqual(after?.result?.summary, before?.result?.summary)
    }

    func testPendingDetachSurvivesFailureAndRestartUntilRecoveryCompletes() async throws {
        let (root, script) = try recoveryFixture(), gate = DetachRecoveryFailureGate()
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
            workerScript: script, reconcileWorker: { try await gate.reconcile($0) })
        await service.suspend(); try await service.start(configuration: .init(repository: root.path, enabled: true))
        let request = ShaderRequest(prompt: "Detach", context: try context())
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        do { try await service.detachCheckout(.request(request.id)); XCTFail("Incomplete teardown detached") } catch is RequestWorkerTeardownError {}
        let store = try JSONDecoder().decode(RequestRecoveryStore.self, from: Data(contentsOf: root.appendingPathComponent("recovery.json")))
        XCTAssertEqual(store.entries.values.first?.disposition, .detach)
        do { try await service.deleteFinished(request.id); XCTFail("Deleted pending recovery") } catch {}
        let restarted = try await recoveryService(root, script: script)
        try await restarted.retryReconciliation()
        let status = await restarted.allJobs().first
        XCTAssertEqual(status?.stage, .failed); XCTAssertTrue(status?.message.contains("detached") == true)
        let entries = await restarted.recoveryStatuses(); XCTAssertTrue(entries.isEmpty)
        let config = await restarted.configurationValue(); XCTAssertFalse(config.enabled)
    }

    func testLegacyOwnershipFailureIsRecheckedUntilMigrationActuallySucceeds() async throws {
        let (root, script) = try recoveryFixture(), original = try await recoveryService(root, script: script)
        let gitdir = try initializeRecoveryGit(root), request = ShaderRequest(prompt: "Legacy", context: try context())
        _ = try await original.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        try await original.detachCheckout(.request(request.id))
        for name in ["detached-checkouts.json", "recovery.json"] { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        let preferences = root.appendingPathComponent("preferences.json")
        var config = try JSONDecoder().decode(ShaderRequestConfiguration.self, from: Data(contentsOf: preferences)); config.enabled = true
        try JSONEncoder().encode(config).write(to: preferences)
        let owner = gitdir.appendingPathComponent("holodeck-request-owner.json"); try Data("{".utf8).write(to: owner)
        let restarted = try await recoveryService(root, script: script)
        for _ in 0..<2 {
            do { try await restarted.retryReconciliation(); XCTFail("Skipped unreadable legacy proof") }
            catch { XCTAssertTrue(error.localizedDescription.contains("ownership marker is unreadable")) }
        }
        var store = try JSONDecoder().decode(RequestRecoveryStore.self, from: Data(contentsOf: root.appendingPathComponent("recovery.json")))
        XCTAssertFalse(store.legacyMigrationComplete)
        try FileManager.default.removeItem(at: owner); try await restarted.retryReconciliation()
        store = try JSONDecoder().decode(RequestRecoveryStore.self, from: Data(contentsOf: root.appendingPathComponent("recovery.json")))
        XCTAssertTrue(store.legacyMigrationComplete); XCTAssertTrue(store.entries.isEmpty)
        let restored = await restarted.configurationValue(); XCTAssertTrue(restored.enabled)
    }

    func testDamagedConfigurationDoesNotBlockSafeReconciliationAndUnknownTargetIsExplicit() async throws {
        let (root, script) = try recoveryFixture(), service = try await recoveryService(root, script: script)
        let journal = root.appendingPathComponent("publication")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: journal.appendingPathComponent("configuration.json"))
        try await service.retryReconciliation()
        try Data("{}".utf8).write(to: journal.appendingPathComponent("process.json"))
        do { try await service.retryReconciliation(); XCTFail("Ignored invalid process evidence") }
        catch { XCTAssertTrue(error.localizedDescription.contains("identity is unreadable")) }
        do { try await service.verify(configuration: .init(repository: root.path)); XCTFail("Verified an unreconciled journal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("identity is unreadable")) }
        let status = await service.recoveryStatuses().first { $0.kind == .reconciliation }
        XCTAssertNil(status?.checkout); XCTAssertEqual(status?.journal?.resolvingSymlinksInPath(), journal.resolvingSymlinksInPath())
        do { try await service.detachCheckout(.selectedCheckout); XCTFail("Guessed current checkout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no verified checkout target")) }
    }

    func testIdentityAndLogFailuresDrainFloodingWorkerAndPreserveOriginalError() async throws {
        for failure in ["identity", "log"] {
            let (root, _) = try recoveryFixture(), script = root.appendingPathComponent("flood.py")
            try """
            import contextlib,os,sys
            with contextlib.suppress(PermissionError): os.setsid()
            while True:
                os.write(1,b'x'*65536+b'\\n')
                os.write(2,b'e'*65536+b'\\n')
            """.write(to: script, atomically: true, encoding: .utf8)
            let worker = RequestWorkerProcess(script: script)
            if failure == "identity" { worker.beforeIdentityWrite = { Thread.sleep(forTimeInterval: 0.1); throw POSIXError(.ENOSPC) } }
            else { worker.beforeLogWrite = { throw POSIXError(.ENOSPC) } }
            let started = Date()
            do {
                for try await _ in worker.run(mode: "run", configuration: .init(repository: root.path), directory: root.appendingPathComponent(failure)) {}
                XCTFail("Write failure succeeded")
            } catch { XCTAssertEqual(((error as? RequestWorkerSupervisionError)?.underlyingError as? POSIXError)?.code, .ENOSPC) }
            try await worker.waitForExit()
            XCTAssertLessThan(Date().timeIntervalSince(started), 10)
            XCTAssertFalse(worker.process.isRunning)
        }
    }

    func testOrphanRegistryVerifiesBirthIdentityBeforeStoppingValidationGroup() async throws {
        let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("orphan-registry")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", "import contextlib,os,time\nwith contextlib.suppress(PermissionError): os.setsid()\nprint('ready',flush=True)\ntime.sleep(60)"]
        child.standardOutput = output
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        _ = output.fileHandleForReading.availableData
        let birth = try XCTUnwrap(RequestProcessIdentity(pid: child.processIdentifier))
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(birth)) as? [String: Any])
        value["seconds"] = birth.seconds + 1
        let registry = job.appendingPathComponent("children.json")
        try JSONSerialization.data(withJSONObject: [["leader": value, "members": [value]]]).write(to: registry)
        try RequestWorkerProcess.reconcileOrphan(in: job)
        XCTAssertTrue(child.isRunning, "A reused PID must not be signalled")
        value["seconds"] = birth.seconds
        try JSONSerialization.data(withJSONObject: [["leader": value, "members": [value]]]).write(to: registry)
        XCTAssertThrowsError(try RequestWorkerProcess.reconcileOrphan(in:job)) { XCTAssertTrue($0 is RequestWorkerOwnershipError) }
        XCTAssertTrue(child.isRunning)
        try JSONSerialization.data(withJSONObject:["pid":birth.pid,"birth":value,"script":"fixture","directory":job.path]).write(to:job.appendingPathComponent("process.json"))
        try RequestWorkerProcess.reconcileOrphan(in: job)
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning); XCTAssertFalse(FileManager.default.fileExists(atPath: registry.path))
    }

    func testCopiedCheckoutIDsDoNotCrossDetachAndStatusAdvances() async throws {
        let (root, script) = try recoveryFixture(), service = try await recoveryService(root, script: script)
        let original = root.appendingPathComponent("original"), copy = root.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        var config = ShaderRequestConfiguration(repository: original.path, enabled: true); config.checkoutID = "copied-id"
        try await service.initialize(configuration: config)
        let first = ShaderRequest(prompt: "Original", context: try context()), second = ShaderRequest(prompt: "Copy", context: try context())
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: first), deviceID: "A")
        config.repository = copy.path; try await service.initialize(configuration: config)
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: second), deviceID: "B")
        let before = await service.allJobs().first { $0.id == first.id }!
        try await service.detachCheckout(.request(first.id))
        let jobs = await service.allJobs()
        XCTAssertEqual(jobs.first { $0.id == second.id }?.stage, .queued)
        let detached = try XCTUnwrap(jobs.first { $0.id == first.id })
        XCTAssertEqual(detached.stage, .failed); XCTAssertGreaterThan(detached.sequence, before.sequence)
        XCTAssertGreaterThanOrEqual(detached.updatedAt, before.updatedAt)
    }

    func testOrphanWithUnrecordedDescendantRetainsRegistryUntilOwnershipIsProven() async throws {
        let (root, _) = try recoveryFixture(), gate = root.appendingPathComponent("leader-gate")
        try Data().write(to: gate)
        let parent = Process(), output = Pipe()
        parent.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        parent.arguments = ["-u", "-c", """
        import subprocess,sys,time
        from pathlib import Path
        child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        print(child.pid,flush=True)
        while Path(sys.argv[1]).exists(): time.sleep(.005)
        """, gate.path]
        parent.standardOutput = output
        try parent.run()
        defer { if parent.isRunning { parent.terminate() } }
        let pid = try XCTUnwrap(Int32(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let leader = try XCTUnwrap(RequestProcessIdentity(pid: parent.processIdentifier))
        let child = try XCTUnwrap(RequestProcessIdentity(pid: pid))
        defer { RequestProcessIdentity.signal([child], SIGKILL) }
        let registry = root.appendingPathComponent("children.json")
        let leaderValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(leader))
        let childValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(child))
        try JSONSerialization.data(withJSONObject: [["leader": leaderValue, "members": [leaderValue]]]).write(to: registry)
        try JSONSerialization.data(withJSONObject:["pid":leader.pid,"birth":leaderValue,"script":"fixture","directory":root.path]).write(to:root.appendingPathComponent("process.json"))
        try FileManager.default.removeItem(at: gate); parent.waitUntilExit()
        XCTAssertThrowsError(try RequestWorkerProcess.reconcileOrphan(in: root)) { XCTAssertTrue($0 is RequestWorkerTeardownError) }
        XCTAssertTrue(child.isCurrent); XCTAssertTrue(FileManager.default.fileExists(atPath: registry.path))
        try JSONSerialization.data(withJSONObject: [["leader": leaderValue, "members": [leaderValue, childValue]]]).write(to: registry)
        try RequestWorkerProcess.reconcileOrphan(in: root)
        XCTAssertFalse(child.isCurrent); XCTAssertFalse(FileManager.default.fileExists(atPath: registry.path))
    }

    func testLegacyDetachedHistoryWithoutLiveOwnerDoesNotDisableVerifiedCheckout() async throws {
        let (root, script) = try recoveryFixture(), original = try await recoveryService(root, script: script)
        _ = try initializeRecoveryGit(root)
        let request = ShaderRequest(prompt: "Historical", context: try context())
        _ = try await original.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        try await original.detachCheckout(.request(request.id))
        try FileManager.default.removeItem(at: root.appendingPathComponent("detached-checkouts.json"))
        let preferences = root.appendingPathComponent("preferences.json")
        var config = try JSONDecoder().decode(ShaderRequestConfiguration.self, from: Data(contentsOf: preferences))
        config.enabled = true; try JSONEncoder().encode(config).write(to: preferences)
        let restarted = try await recoveryService(root, script: script)
        let restored = await restarted.configurationValue()
        XCTAssertTrue(restored.enabled)
    }

    func testReconciliationRefusesSubmissionAndDetachUsesFailingCheckout() async throws {
        let (root, script) = try recoveryFixture(), service = try await recoveryService(root, script: script)
        let first = ShaderRequest(prompt: "Old checkout", context: try context()), second = ShaderRequest(prompt: "Current checkout", context: try context())
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: first), deviceID: "A")
        try await service.cancelQueued(first.id)
        let other = root.appendingPathComponent("other"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await service.initialize(configuration: .init(repository: other.path, enabled: true))
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: second), deviceID: "B")
        let badMarker = root.appendingPathComponent(first.id.uuidString).appendingPathComponent("process.json")
        try Data("{}".utf8).write(to: badMarker)
        await service.resume()
        try await waitFor { await service.recoveryStatuses().contains { $0.kind == .reconciliation } }
        let recovery = await service.recoveryStatuses().first { $0.kind == .reconciliation }
        XCTAssertEqual(recovery?.requestID, first.id)
        do {
            _ = try await service.control(operation: "requestSubmit", payload: .init(request: .init(prompt: "Rejected", context: try context())), deviceID: "C")
            XCTFail("Accepted work during failed reconciliation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("recovery required")) }
        try await service.detachCheckout(.recovery(try XCTUnwrap(recovery?.id)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: badMarker.path))
        let jobs = await service.allJobs()
        XCTAssertEqual(jobs.count, 2); XCTAssertEqual(jobs.first { $0.id == second.id }?.stage, .queued)
    }

    func testReconciliationTargetsPublicationStoredCheckoutAfterSelectionChanges() async throws {
        let (root, script) = try recoveryFixture(), service = try await recoveryService(root, script: script)
        let publication = root.appendingPathComponent("publication"), other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: publication, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let previous = ShaderRequestConfiguration(repository: root.path, enabled: true)
        try JSONEncoder().encode(previous).write(to: publication.appendingPathComponent("configuration.json"))
        let marker = publication.appendingPathComponent("process.json")
        try Data("{}".utf8).write(to: marker)
        try await service.initialize(configuration: .init(repository: other.path, enabled: true))
        await service.resume()
        try await waitFor { await service.recoveryStatuses().contains { $0.kind == .reconciliation } }
        let recovery = await service.recoveryStatuses().first { $0.kind == .reconciliation }
        XCTAssertEqual(recovery?.repository, root.path); XCTAssertNil(recovery?.requestID)
        try await service.detachCheckout(.recovery(try XCTUnwrap(recovery?.id)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: publication.path).contains { $0.hasPrefix("detached-") })
    }

    func testPublicationEventsRetainFailureAcrossNextPreparingAndResolveOnSuccess() async throws {
        for _ in 0..<10 {
            let gate = RequestPreparationGate(), f = try await publicationRecoveryFixture(gate: gate)
            let marker = try brokenReconciliation(f.root)
            var events = await f.service.publicationUpdates().makeAsyncIterator()
            _ = await events.next()
            let caller = Task { try await f.service.ensurePublication(force: true) }
            try await waitFor { await f.service.pendingPublicationWaiterCount == 1 }; await f.service.resume()
            let failure = try await recoveryFailure(caller)
            let failed = await events.next()
            XCTAssertEqual(failed?.unresolvedFailure, failure)
            try FileManager.default.removeItem(at: marker)
            try await f.service.retryReconciliation()
            try await waitFor { await gate.entered }
            let preparing = await events.next()
            XCTAssertEqual(preparing?.operation.phase, .preparing); XCTAssertEqual(preparing?.unresolvedFailure, failure)
            await gate.release()
            try await waitFor { await f.service.publicationOperationStatus().revision != nil }
            var event = await events.next()
            while event?.operation.revision == nil { event = await events.next() }
            XCTAssertNil(event?.unresolvedFailure)
        }
    }

    func testCancelActivePublicationDoesNotReportFailureOrCancelQueuedJobs() async throws {
        for _ in 0..<10 {
            let gate = RequestPreparationGate(), f = try await publicationRecoveryFixture(gate: gate)
            let queued = ShaderRequest(prompt: "Keep", context: try context())
            _ = try await f.service.control(operation: "requestSubmit", payload: .init(request: queued), deviceID: "TV")
            let caller = Task { try await f.service.ensurePublication(force: true) }
            await f.service.resume(); try await waitFor { await gate.entered }
            await f.service.cancelPublication(); await gate.release()
            do { try await caller.value; XCTFail("Cancelled caller succeeded") } catch is CancellationError {}
            try await waitFor { await f.service.publicationOperationStatus().phase == .idle }
            let operation = await f.service.publicationOperationStatus(), jobs = await f.service.allJobs()
            XCTAssertNil(operation.failure); XCTAssertEqual(jobs.first?.stage, .queued)
            XCTAssertEqual(try RequestWorkerOperation.read(in: f.root.appendingPathComponent("publication"))?.phase, .complete)
        }
    }

    func testUnchangedSelectionPreservesCheckoutIdentityAndPublicationGeneration() async throws {
        let (root, script) = try recoveryFixture(), authoring = try requestAuthoringFixture(root.appendingPathComponent("authoring"))
        let catalog = DirectoryCatalog(directory:root.appendingPathComponent("catalog"))
        let service = ShaderRequestService(catalog:catalog,directory:root,workerScript:script)
        var config = ShaderRequestConfiguration(repository:authoring.path); config.checkoutID = "stable-checkout"
        try await service.initialize(configuration:config)
        _ = try await service.reloadRepository(authoring)
        var beforeEvents = await service.publicationUpdates().makeAsyncIterator()
        let beforeValue = await beforeEvents.next(), before = try XCTUnwrap(beforeValue)
        let preferences = try Data(contentsOf:root.appendingPathComponent("preferences.json"))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:authoring)
        let accepted = try await service.selectRepository(alias)
        var afterEvents = await service.publicationUpdates().makeAsyncIterator()
        let afterValue = await afterEvents.next(), after = try XCTUnwrap(afterValue)
        XCTAssertEqual(accepted.checkoutID,"stable-checkout");XCTAssertEqual(before.generation,after.generation)
        XCTAssertEqual(before.publication?.sequence,after.publication?.sequence)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("preferences.json")),preferences)
        let reloaded = try await service.reloadRepository(alias)
        XCTAssertEqual(reloaded.configuration.checkoutID,"stable-checkout")
    }

    func testPublicationCallbackEligibilityRequiresInstalledRevisionAndGeneration() async throws {
        let (root, script) = try recoveryFixture(), authoring = try requestAuthoringFixture(root.appendingPathComponent("authoring"))
        let catalog = DirectoryCatalog(directory:root.appendingPathComponent("catalog"))
        let service = ShaderRequestService(catalog:catalog,directory:root,workerScript:script)
        try await service.initialize(configuration:.init(repository:authoring.path))
        _ = try await service.reloadRepository(authoring)
        var events = await service.publicationUpdates().makeAsyncIterator()
        let eventValue = await events.next(), event = try XCTUnwrap(eventValue), status = try XCTUnwrap(event.publication)
        let valid = await service.isCurrentPublication(status,generation:event.generation); XCTAssertTrue(valid)
        try Data("// different source\n".utf8).write(to:authoring.appendingPathComponent("shaders/plasma/body.metal"))
        _ = try await catalog.reload(from:authoring)
        let stale = await service.isCurrentPublication(status,generation:event.generation); XCTAssertFalse(stale)
        let wrongGeneration = await service.isCurrentPublication(status,generation:UUID()); XCTAssertFalse(wrongGeneration)
    }

    func testRecoveryOnlyStateAllowsDisablingRequests() async throws {
        let (root, script) = try recoveryFixture()
        let journal = root.appendingPathComponent("setup")
        let entry = RequestRecoveryStore.Entry(journal:RequestPaths.canonical(journal),requestID:nil,configuration:nil,disposition:.resume,message:"Needs recovery")
        var store = RequestRecoveryStore();store.entries[entry.journal] = entry
        try JSONEncoder().encode(store).write(to:root.appendingPathComponent("recovery.json"))
        let service = ShaderRequestService(catalog:DirectoryCatalog(directory:root.appendingPathComponent("catalog")),directory:root,workerScript:script)
        try await service.initialize(configuration:.init(repository:root.path,enabled:true))
        let allowed = await service.canDisableRequests();XCTAssertTrue(allowed)
        try await service.disable()
        let config = await service.configurationValue();XCTAssertFalse(config.enabled)
    }

    func testFinalWorkerRetirementPublishesDisableEligibilityAfterCompletedDelivery() async throws {
        let (root, script) = try recoveryFixture(), gate = RecoveryGate(), observations = DisableEligibilityRecorder()
        let authoring = try requestAuthoringFixture(root.appendingPathComponent("authoring"))
        try """
        import json,sys
        print(json.dumps({'event':'preparePublication','requiredPreviewShaderIDs':[]}),flush=True)
        assert json.loads(sys.stdin.readline())['ok']
        print(json.dumps({'event':'result','result':{'outputKind':'edited','shaderID':'plasma','changed':False,'summary':'Published','approximations':[]}}),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
            workerScript: script, waitForWorker: { process in try await process.waitForExit(); try await gate.wait() })
        await service.suspend(); try await service.start(configuration: .init(repository: authoring.path, enabled: true))
        let request = ShaderRequest(prompt: "Complete", context: try context())
        let stream = await service.updates()
        let observer = Task {
            for await jobs in stream {
                let allowed = await service.canDisableRequests()
                await observations.record(allowed, completed: jobs.first { $0.id == request.id }?.stage == .completed)
            }
        }
        defer { observer.cancel(); Task { await gate.release() } }
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        await service.resume(); try await waitFor { await gate.hasEntered }
        let result = await service.allJobs().first?.result
        _ = try await service.control(operation: "requestActivated", payload: .init(requestID: request.id, sourceHash: result?.deliveredSourceHash), deviceID: "TV")
        try await waitFor { await observations.completedWhileBlocked }
        await gate.release()
        try await waitFor { await observations.lastAllowed }
    }

    func testMissingPackagedProcessRuntimeReportsSetupFailure() async throws {
        let (root, _) = try recoveryFixture(), script = root.appendingPathComponent("copied-worker.py")
        try FileManager.default.copyItem(at: XCTUnwrap(RequestWorkerProcess.bundledScript), to: script)
        let worker = RequestWorkerProcess(script: script)
        var failure: RequestWorkerEvent?
        do {
            for try await event in worker.run(mode: "preflight", configuration: .init(repository: root.path), directory: root.appendingPathComponent("job")) {
                if event.event == "failure" { failure = event }
            }
            XCTFail("Missing runtime launched successfully")
        } catch { XCTAssertTrue(error.localizedDescription.contains("exited 2") || error.localizedDescription.contains("exit 2")) }
        try await worker.waitForExit()
        XCTAssertTrue(failure?.message?.contains("process runtime is missing or unreadable") == true)
        XCTAssertEqual(failure?.recoveryRequired, false)
    }

    func testPersistentObservationFailureRetainsCauseAfterSettlementRecovers() async throws {
        let (root, script) = try recoveryFixture()
        try """
        import time
        print('{"event":"ready"}',flush=True)
        time.sleep(60)
        """.write(to: script, atomically: true, encoding: .utf8)
        let probe = NativeObservationProbe(failures: 3)
        let worker = RequestWorkerProcess(script: script, groups: .init(group: { try probe.observe($0) }))
        do {
            for try await _ in worker.run(mode: "run", configuration: .init(repository: root.path), directory: root.appendingPathComponent("job")) {}
            XCTFail("Persistent observation failure was ignored")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Repeated process observation failure"))
            XCTAssertEqual((error as? RequestWorkerSupervisionError)?.retryable, true)
        }
        try await worker.waitForExit()
    }

    func testRetiredWorkerRootDoesNotAuthorizeUnknownOrphanDescendants() throws {
        let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("retired-root")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", "import subprocess,sys; p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);print(p.pid,flush=True);sys.stdin.read()"]
        child.standardInput = input; child.standardOutput = output
        try child.run()
        let helperPID = try XCTUnwrap(Int32(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let helper = try XCTUnwrap(RequestProcessIdentity(pid: helperPID))
        defer { RequestProcessIdentity.signal([helper],SIGKILL); if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let birth = try XCTUnwrap(RequestProcessIdentity(pid: child.processIdentifier))
        let marker: [String: Any] = ["pid":birth.pid,"birth":["pid":birth.pid,"seconds":birth.seconds,"microseconds":birth.microseconds],"script":"fixture.py","directory":job.path]
        let file = job.appendingPathComponent("process.json")
        try JSONSerialization.data(withJSONObject:marker).write(to:file)
        try input.fileHandleForWriting.close(); child.waitUntilExit()
        let probe = NativeObservationProbe()
        XCTAssertThrowsError(try RequestWorkerProcess.reconcileOrphan(in:job,groups:.init(now:{probe.now},wait:{probe.advance($0)})))
        XCTAssertTrue(helper.isCurrent); XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }

    func testNativeObservationRetriesOutsideOwnershipLock() async throws {
        let (root, script) = try recoveryFixture()
        try """
        import contextlib,os,json,time
        with contextlib.suppress(PermissionError):os.setsid()
        print(json.dumps({'event':'preflight'}),flush=True)
        time.sleep(1)
        """.write(to: script, atomically: true, encoding: .utf8)
        let probe = NativeObservationProbe(failures: 2)
        let worker = RequestWorkerProcess(script: script, groups: .init(group: { try probe.observe($0) }))
        for try await _ in worker.run(mode: "preflight", configuration: .init(repository: root.path), directory: root.appendingPathComponent("job")) {}
        try await worker.waitForExit()
        XCTAssertGreaterThanOrEqual(probe.calls, 3)
    }

    func testStopAndLogDrainingDoNotWaitForGroupEnumeration() async throws {
        let (root, script) = try recoveryFixture()
        try """
        import contextlib,os,signal,sys,time
        with contextlib.suppress(PermissionError):os.setsid()
        def stop(*args):
            print('stopped during observation',file=sys.stderr,flush=True)
            sys.exit(0)
        signal.signal(signal.SIGTERM,stop)
        print('ready',file=sys.stderr,flush=True)
        while True:
            print('observation heartbeat',file=sys.stderr,flush=True)
            time.sleep(.01)
        """.write(to: script, atomically: true, encoding: .utf8)
        let probe = NativeObservationProbe(held: true)
        let job = root.appendingPathComponent("job")
        let worker = RequestWorkerProcess(script: script, groups: .init(group: { try probe.observe($0) }))
        let consuming = Task { do { for try await _ in worker.run(mode: "preflight", configuration: .init(repository: root.path), directory: job) {} } catch {} }
        defer { probe.release(); consuming.cancel(); worker.stop() }
        try await waitFor { probe.entered && ((try? String(contentsOf: job.appendingPathComponent("worker-stderr.log"), encoding: .utf8).contains("ready")) == true) }
        let stopped = expectation(description: "Stop returns before observation is released")
        DispatchQueue.global().async { worker.stop(); stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertThrowsError(try worker.reply(true))
        let log = job.appendingPathComponent("worker-stderr.log")
        let size = try Data(contentsOf: log).count
        try await waitFor { (try? Data(contentsOf: log).count) ?? 0 > size }
        probe.release(); await consuming.value
        try await worker.waitForExit()
    }

    func testOrphanEnumerationFailureRetainsMarkerAndTerminatesVerifiedRoot() throws {
        let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("orphan")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", "import contextlib,os,time\nwith contextlib.suppress(PermissionError):os.setsid()\nprint('ready',flush=True);time.sleep(60)"]
        child.standardOutput = pipe; try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        _ = pipe.fileHandleForReading.availableData
        let birth = try XCTUnwrap(RequestProcessIdentity(pid: child.processIdentifier))
        let marker: [String: Any] = ["pid": birth.pid, "birth": ["pid":birth.pid,"seconds":birth.seconds,"microseconds":birth.microseconds], "script":"fixture.py", "directory":job.path]
        let file = job.appendingPathComponent("process.json")
        try JSONSerialization.data(withJSONObject: marker).write(to: file)
        let probe = NativeObservationProbe(failures: Int.max)
        XCTAssertThrowsError(try RequestWorkerProcess.reconcileOrphan(in: job, groups: .init(group: { try probe.observe($0) }, now: { probe.now }, wait: { probe.advance($0) })))
        child.waitUntilExit()
        XCTAssertFalse(birth.isCurrent); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testOlderCommandBudgetCannotBackdateWorkerRootEscalation() async throws {
        let (root, script) = try recoveryFixture(), bundled = try XCTUnwrap(RequestWorkerProcess.bundledScript)
        try """
        import importlib.util,json,os,signal,sys,time,uuid
        from pathlib import Path
        spec=importlib.util.spec_from_file_location('w',\(String(reflecting:bundled.path)))
        w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
        job=Path(sys.argv[3]);anchor=w.process_identity(os.getpid())
        w.save_registry(job/'children.json',[{'leader':anchor,'members':[anchor]}])
        now=w.process_clock();budget=w.Termination().record();budget.update(startedAt=now-6,deadline=now+4)
        status=w.new_status(anchor,str(uuid.uuid4()));status.update(state='draining',termination=budget,pipeDrainComplete=True,processesSettled=True)
        w.save_process_json(job/'supervision.json',status)
        def stop(*a):
            (job/'interrupted').touch()
            raise SystemExit(0)
        signal.signal(signal.SIGTERM,stop)
        print(json.dumps({'event':'ready'}),flush=True)
        while True:time.sleep(.01)
        """.write(to:script,atomically:true,encoding:.utf8)
        let probe = SignalRecordingProbe(), worker = RequestWorkerProcess(script:script,groups:.init(signal:{probe.signal($0,$1)}))
        let job = root.appendingPathComponent("job")
        do {
            for try await event in worker.run(mode:"run",configuration:.init(repository:root.path),directory:job) {
                if event.event == "ready" { worker.stop() }
            }
        } catch is CancellationError {}
        try await worker.waitForExit()
        XCTAssertTrue(FileManager.default.fileExists(atPath:job.appendingPathComponent("interrupted").path))
        XCTAssertEqual(probe.signals(for:worker.process.processIdentifier),[SIGTERM])
    }

    func testUnverifiedWorkerBirthNeverReleasesCheckoutExecution() async throws {
        let (root, script) = try recoveryFixture(), marker = root.appendingPathComponent("executed")
        try "from pathlib import Path;Path(\(String(reflecting:marker.path))).touch()".write(to:script,atomically:true,encoding:.utf8)
        let worker = RequestWorkerProcess(script:script,groups:.init(identity:{_ in nil}))
        do {
            for try await _ in worker.run(mode:"run",configuration:.init(repository:root.path),directory:root.appendingPathComponent("job")) {}
            XCTFail("Unverified launch succeeded")
        } catch { XCTAssertTrue(error is RequestWorkerSupervisionError) }
        try await worker.waitForExit()
        XCTAssertFalse(worker.process.isRunning);XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    }

    func testCancellationBeforeRegistrationClosesWorkerLaunchGate() async throws {
        let (root, script) = try recoveryFixture(), gate = PausedIdentityProbe(), marker = root.appendingPathComponent("executed")
        try "from pathlib import Path;Path(\(String(reflecting:marker.path))).touch()".write(to:script,atomically:true,encoding:.utf8)
        let worker = RequestWorkerProcess(script:script)
        worker.beforeIdentityWrite = { gate.armOnce(); _ = gate.identity(getpid()) }
        let consuming = Task { do { for try await _ in worker.run(mode:"run",configuration:.init(repository:root.path),directory:root.appendingPathComponent("job")) {} } catch {} }
        defer { gate.release();worker.stop();consuming.cancel() }
        try await waitFor { gate.entered }
        worker.stop();gate.release();await consuming.value;try await worker.waitForExit()
        XCTAssertFalse(worker.process.isRunning);XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    }

    func testUnknownWorkerMarkerCannotCancelLiveRegisteredCommand() async throws {
        let (root, script) = try recoveryFixture(), bundled = try XCTUnwrap(RequestWorkerProcess.bundledScript)
        let job = root.appendingPathComponent("job"), work = root.appendingPathComponent("retained.bin"), bytes = Data([0,255,13,10])
        try bytes.write(to:work)
        try """
        import importlib.util,os,sys
        from pathlib import Path
        spec=importlib.util.spec_from_file_location('w',\(String(reflecting:bundled.path)))
        w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
        class Worker:
            def __init__(self,*a):self.request={'id':'fixture'};self.checkpoint={};self.directory=Path(sys.argv[3])
            def perform(self):
                with w.ManagedChild([sys.executable,'-c',"import time;time.sleep(60)"],self.directory,dict(os.environ,HOLODECK_REQUEST_DIRECTORY=str(self.directory))) as child:
                    self.directory.joinpath('ready').touch()
                    list(child.output_chunks())
                    if child.command_returncode:raise w.OperationalError('Command was killed beneath live worker')
            def clean(self):self.directory.parent.joinpath('retained.bin').write_bytes(b'DISCARDED')
        w.Worker=Worker;w.main()
        """.write(to:script,atomically:true,encoding:.utf8)
        let worker = RequestWorkerProcess(script:script)
        let consuming = Task { do { for try await _ in worker.run(mode:"run",configuration:.init(repository:root.path),directory:job) {} } catch {} }
        defer { worker.stop();consuming.cancel() }
        try await waitFor { FileManager.default.fileExists(atPath:job.appendingPathComponent("ready").path) }
        try Data("{".utf8).write(to:job.appendingPathComponent("process.json"))
        XCTAssertThrowsError(try RequestWorkerProcess.reconcileOrphan(in:job)) { XCTAssertTrue($0 is RequestWorkerOwnershipError) }
        XCTAssertTrue(worker.process.isRunning);XCTAssertEqual(try Data(contentsOf:work),bytes)
        worker.stop();await consuming.value;try await worker.waitForExit()
        XCTAssertEqual(try Data(contentsOf:work),bytes)
    }

    func testNativeRecoveryGetsFreshBudgetAndIgnoresLegacyDeadline() throws {
        let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("deadline")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", "import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print('ready',flush=True);time.sleep(60)"]
        child.standardOutput = pipe; try child.run(); _ = pipe.fileHandleForReading.availableData
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let anchor = try XCTUnwrap(RequestProcessIdentity(pid: child.processIdentifier))
        let identity: [String: Any] = ["pid":anchor.pid,"seconds":anchor.seconds,"microseconds":anchor.microseconds]
        try JSONSerialization.data(withJSONObject: [["leader":identity,"members":[identity]]]).write(to: job.appendingPathComponent("children.json"))
        var status: [String: Any] = ["formatVersion":2,"sessionID":UUID().uuidString,"revision":1,"clock":"darwin-uptime-raw",
            "supervisor":identity,"state":"draining","processesSettled":false,"pipeDrainComplete":false,"deadline":0.5]
        let file = job.appendingPathComponent("supervision.json")
        try JSONSerialization.data(withJSONObject: status).write(to: file)
        XCTAssertNil(try RequestProcessIdentity.observe(in: job).evidenceError)
        status["formatVersion"] = 1
        try JSONSerialization.data(withJSONObject: status).write(to: file)
        XCTAssertNil(try RequestProcessIdentity.observe(in: job).evidenceError)
        status["formatVersion"] = 2
        try JSONSerialization.data(withJSONObject: status).write(to: file)
        try JSONSerialization.data(withJSONObject:["pid":anchor.pid,"birth":identity,"script":"fixture.py","directory":job.path]).write(to:job.appendingPathComponent("process.json"))
        let probe = NativeObservationProbe()
        XCTAssertThrowsError(try RequestWorkerProcess.reconcileOrphan(in: job, groups: .init(now: { probe.now }, wait: { probe.advance($0) })))
        XCTAssertGreaterThanOrEqual(probe.now,5); XCTAssertLessThanOrEqual(probe.now,10)
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        child.waitUntilExit(); XCTAssertFalse(anchor.isCurrent)
    }

    func testSupervisorRetirementRequiresFreshQuiescentGroupObservation() throws {
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", "import time;print('ready',flush=True);time.sleep(60)"]
        child.standardOutput = pipe; try child.run(); _ = pipe.fileHandleForReading.availableData
        let work = try XCTUnwrap(RequestProcessIdentity(pid: child.processIdentifier))
        child.terminate(); child.waitUntilExit()
        let anchor = try XCTUnwrap(RequestProcessIdentity(pid: getpid()))
        XCTAssertEqual(RequestProcessIdentity.shutdownTargets([anchor], sessions: [anchor:[anchor,work]], signal: SIGKILL), [])
        XCTAssertEqual(RequestProcessIdentity.shutdownTargets([anchor], sessions: [anchor:[anchor]], signal: SIGKILL, allowOwnerRetirement: false), [])
        XCTAssertEqual(RequestProcessIdentity.shutdownTargets([anchor], sessions: [anchor:[anchor]], signal: SIGKILL), [anchor])
    }

    func testDeadSupervisorCannotSuppressTermForKnownWork() throws {
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", "import time;print('ready',flush=True);time.sleep(60)"]
        child.standardOutput = pipe; try child.run(); _ = pipe.fileHandleForReading.availableData
        let anchor = try XCTUnwrap(RequestProcessIdentity(pid: child.processIdentifier))
        child.terminate(); child.waitUntilExit()
        let work = try XCTUnwrap(RequestProcessIdentity(pid: getpid()))
        XCTAssertEqual(RequestProcessIdentity.shutdownTargets([work], sessions: [anchor:[anchor,work]], signal: SIGTERM), [work])
    }

    func testNativeWorkerAcceptsSuccessfulCommandWithLateHelperAndRetainedSupervisor() async throws {
        let (root, script) = try recoveryFixture()
        let bundled = try XCTUnwrap(RequestWorkerProcess.bundledScript)
        try """
        import contextlib,importlib.util,json,os,sys
        from pathlib import Path
        with contextlib.suppress(PermissionError): os.setsid()
        spec=importlib.util.spec_from_file_location('w',\(String(reflecting: bundled.path)))
        w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
        job=Path(sys.argv[3]);env=dict(os.environ,HOLODECK_REQUEST_DIRECTORY=str(job))
        code="import subprocess,sys;from pathlib import Path;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)']);Path(sys.argv[1]).write_text(str(p.pid));print('finished')"
        result=w.managed_run([sys.executable,'-c',code,str(job/'late-helper')],job,env,5,None)
        assert result.returncode==0
        print(json.dumps({'event':'preflight'}),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let job = root.appendingPathComponent("native-supervisor"), process = RequestWorkerProcess(script: script)
        var ready = false
        for try await event in process.run(mode: "preflight", configuration: .init(repository: root.path), directory: job) {
            if event.event == "preflight" { ready = true }
        }
        try await process.waitForExit(); XCTAssertTrue(ready)
        let pid = try XCTUnwrap(Int32(String(contentsOf: job.appendingPathComponent("late-helper"), encoding: .utf8)))
        XCTAssertNil(RequestProcessIdentity(pid: pid))
        for name in ["process.json", "children.json", "supervision.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent(name).path))
        }
    }

    func testWorkerRecoveryFailureRetainsPatchWithoutDiscardIntent() async throws {
        let (root, script) = try recoveryFixture()
        try """
        import json,sys
        from pathlib import Path
        job=Path(sys.argv[3]);(job/'owned-patch').write_bytes(b'keep these bytes')
        print(json.dumps({'event':'failure','message':'External pipe ownership unresolved','recoveryRequired':True}),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let service = try await recoveryService(root, script: script)
        let request = ShaderRequest(prompt: "Keep recovery work", context: try context())
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        await service.resume()
        try await waitFor { await service.recoveryStatuses().contains { $0.disposition == .resume } }
        let job = root.appendingPathComponent(request.id.uuidString)
        XCTAssertEqual(try Data(contentsOf: job.appendingPathComponent("owned-patch")), Data("keep these bytes".utf8))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("journal.json"))) as? [[String: Any]])
        XCTAssertNotEqual(rows.first?["cleanupPending"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("cleanup-started").path))
        let store = try JSONDecoder().decode(RequestRecoveryStore.self, from: Data(contentsOf: root.appendingPathComponent("recovery.json")))
        XCTAssertEqual(store.entries[RequestPaths.canonical(job)]?.disposition, .resume)
    }

    func testDetachPreventsScheduledDiscardAndIncludesJournalCreatedWhileDraining() async throws {
        for _ in 0..<10 {
            let (root, script) = try recoveryFixture(), gate = RequestPreparationGate()
            let seed = try await recoveryService(root, script: script)
            let config = ShaderRequestConfiguration(repository: root.path, enabled: true)
            let request = ShaderRequest(prompt: "Keep unpublished work", context: try context())
            _ = try await seed.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
            try await seed.cancelQueued(request.id)
            let job = root.appendingPathComponent(request.id.uuidString), patch = job.appendingPathComponent("owned-patch")
            let bytes = Data("unpublished work\r\n".utf8); try bytes.write(to: patch)
            let journal = root.appendingPathComponent("journal.json")
            var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
            records[0]["cleanupPending"] = true
            try JSONSerialization.data(withJSONObject: records).write(to: journal)
            let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
                directory: root, workerScript: script, prepareCleanup: { await gate.hold() })
            await service.suspend(); try await service.start(configuration: config); await service.resume()
            try await waitFor { await gate.entered }
            let detach = Task { try await service.detachCheckout(.request(request.id)) }
            try await waitFor { await service.recoveryStatuses().contains { $0.disposition == .detach } }
            let publication = root.appendingPathComponent("publication")
            try FileManager.default.createDirectory(at: publication, withIntermediateDirectories: true)
            try JSONEncoder().encode(config).write(to: publication.appendingPathComponent("configuration.json"))
            try Data("{}".utf8).write(to: publication.appendingPathComponent("process.json"))
            await gate.release(); try await detach.value
            XCTAssertEqual(try Data(contentsOf: patch), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("cleanup-started").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: publication.appendingPathComponent("process.json").path))
            let statuses = await service.recoveryStatuses(); XCTAssertTrue(statuses.isEmpty)
        }
    }

    func testDetachReconcilesCanonicalJournalOnlyOnceAcrossDirectoryAlias() async throws {
        let (root, script) = try recoveryFixture(), visits = JournalVisitRecorder()
        let alias = root.appendingPathComponent("alias"), setup = root.appendingPathComponent("setup")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        let config = ShaderRequestConfiguration(repository: root.path)
        try JSONEncoder().encode(config).write(to: setup.appendingPathComponent("configuration.json"))
        let entry = RequestRecoveryStore.Entry(journal: RequestPaths.canonical(setup), requestID: nil,
            configuration: config, disposition: .resume, message: "Retained")
        var store = RequestRecoveryStore(); store.entries[entry.journal] = entry
        try JSONEncoder().encode(store).write(to: root.appendingPathComponent("recovery.json"))
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
            directory: alias, workerScript: script, reconcileWorker: { await visits.record($0) })
        try await service.initialize(configuration: config)
        try await service.detachCheckout(.recovery(entry.id))
        let count = await visits.count(setup); XCTAssertEqual(count, 1)
    }

    func testDetachCancelsVerificationBeforeWorkerLaunchAndWaitsForLease() async throws {
        for _ in 0..<10 {
            let (root, script) = try recoveryFixture(), gate = RequestPreparationGate()
            let sentinel = root.appendingPathComponent("unexpected-worker")
            try "from pathlib import Path; Path(\(String(reflecting: sentinel.path))).touch()".write(to: script, atomically: true, encoding: .utf8)
            let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
                workerScript: script, reconcileWorker: { _ in await gate.hold() })
            try await service.initialize(configuration: .init(repository: root.path))
            let verify = Task { try await service.verify(configuration: .init(repository: root.path)) }
            try await waitFor { await gate.entered }
            let detach = Task { try await service.detachCheckout(.selectedCheckout) }
            try await waitFor { await service.recoveryStatuses().contains { $0.disposition == .detach } }
            do { _ = try await service.selectRepository(root.appendingPathComponent("other")); XCTFail("Selection stole the reserved detach lease") } catch {}
            await gate.release()
            do { try await verify.value; XCTFail("Cancelled verification succeeded") } catch is CancellationError {}
            try await detach.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
            let config = await service.configurationValue(); XCTAssertFalse(config.enabled)
        }
    }

    func testDetachCancelsActivePublicationBeforeTakingItsLease() async throws {
        let gate = RequestPreparationGate(), f = try await publicationRecoveryFixture(gate: gate)
        await f.service.resume()
        let publication = Task { try await f.service.ensurePublication(force: true) }
        try await waitFor { await gate.entered }
        let detach = Task { try await f.service.detachCheckout(.selectedCheckout) }
        try await waitFor { await f.service.recoveryStatuses().contains { $0.disposition == .detach } }
        await gate.release()
        do { try await publication.value; XCTFail("Detached publication succeeded") } catch is CancellationError {}
        try await detach.value
        let config = await f.service.configurationValue(); XCTAssertFalse(config.enabled)
        let recoveries = await f.service.recoveryStatuses(); XCTAssertTrue(recoveries.isEmpty)
    }

    func testUnknownReconciliationDoesNotInheritAnotherEntriesCheckoutAndDetachUsesExactEntry() async throws {
        let (root, script) = try recoveryFixture(), publication = root.appendingPathComponent("publication"), setup = root.appendingPathComponent("setup")
        for journal in [publication, setup] { try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true) }
        let first = RequestRecoveryStore.Entry(journal: RequestPaths.canonical(publication), requestID: nil,
            configuration: .init(repository: root.appendingPathComponent("old-checkout").path), disposition: .resume, message: "Old failure")
        var store = RequestRecoveryStore(); store.entries[first.journal] = first
        try JSONEncoder().encode(store).write(to: root.appendingPathComponent("recovery.json"))
        try Data("{}".utf8).write(to: setup.appendingPathComponent("process.json"))
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
            workerScript: script, reconcileWorker: { folder in
                if folder.lastPathComponent == "setup" { throw ShaderRequestError.unavailable("Unknown setup owner") }
            })
        try await service.initialize(configuration: .init(repository: root.path))
        do { try await service.retryReconciliation(); XCTFail("Unknown target reconciled") } catch {}
        let statuses = await service.recoveryStatuses()
        let unknown = try XCTUnwrap(statuses.first { $0.journal?.lastPathComponent == "setup" })
        XCTAssertNil(unknown.checkout)
        do { try await service.detachCheckout(.recovery(unknown.id)); XCTFail("Unknown target detached") } catch {}
        try await service.detachCheckout(.recovery(first.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: setup.appendingPathComponent("process.json").path))
        let remaining = await service.recoveryStatuses(); XCTAssertEqual(remaining.count,1); XCTAssertNil(remaining.first?.checkout)
    }

    func testLegacyPipeEvidenceSurvivesMissingRegistryAndRequiresExplicitDetach() throws {
        let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("legacy-pipes")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let marker = job.appendingPathComponent("supervision.json")
        let value: [String: Any] = ["formatVersion":1,"supervisor":["pid":Int32.max,"seconds":1,"microseconds":0],
            "state":"failed","failureKind":"pipeDrain","failure":"Unresolved external pipes","recoveryRequired":true]
        let bytes = try JSONSerialization.data(withJSONObject:value)
        try bytes.write(to:marker)
        let observation = try RequestProcessIdentity.observe(in:job)
        XCTAssertNotNil(observation.evidenceError)
        XCTAssertThrowsError(try RequestWorkerProcess.reconcileOrphan(in:job)) { XCTAssertTrue($0 is RequestWorkerEvidenceError) }
        XCTAssertEqual(try Data(contentsOf:marker),bytes)
    }

    func testMalformedRegistryIsEvidenceErrorWithoutTeardownTimeout() throws {
        let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("malformed-registry")
        try FileManager.default.createDirectory(at:job,withIntermediateDirectories:true)
        let marker = job.appendingPathComponent("children.json"), bytes = Data("{".utf8)
        try bytes.write(to:marker)
        let probe = NativeObservationProbe()
        XCTAssertThrowsError(try RequestWorkerProcess.reconcileOrphan(in:job,groups:.init(now:{probe.now},wait:{probe.advance($0)}))) {
            XCTAssertTrue($0 is RequestWorkerEvidenceError)
        }
        XCTAssertEqual(probe.now,0); XCTAssertEqual(try Data(contentsOf:marker),bytes)
    }

    func testDetachArchivesMalformedChildEvidenceAndPreservesWork() async throws {
        let (root, script) = try recoveryFixture(), initial = try await recoveryService(root,script:script)
        let request = ShaderRequest(prompt:"Preserve work",context:try context())
        _ = try await initial.control(operation:"requestSubmit",payload:.init(request:request),deviceID:"TV")
        try await initial.cancelQueued(request.id)
        let job = root.appendingPathComponent(request.id.uuidString), marker = job.appendingPathComponent("children.json")
        let work = root.appendingPathComponent("unpublished.txt"), bytes = Data([0,255,10,13])
        try bytes.write(to:work);try Data("{".utf8).write(to:marker)
        let service = try await recoveryService(root,script:script)
        try await service.detachCheckout(.request(request.id))
        XCTAssertEqual(try Data(contentsOf:work),bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:job.path).contains{$0.hasPrefix("detached-")})
    }

    func testWorkerIsInterruptedBeforeNativeDescendantTermination() async throws {
        let (root, script) = try recoveryFixture(), bundled = try XCTUnwrap(RequestWorkerProcess.bundledScript)
        let work = root.appendingPathComponent("retained.bin"), original = Data([0,255,13,10])
        try original.write(to:work)
        try """
        import importlib.util,os,sys
        from pathlib import Path
        spec=importlib.util.spec_from_file_location('w',\(String(reflecting:bundled.path)))
        w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
        class Worker:
            def __init__(self,config,directory):
                self.request={'id':'test'};self.checkpoint={};self.directory=Path(directory)
                self.work=Path(config['repository'])/'retained.bin'
            def perform(self):
                code="import signal,sys,time,json;signal.signal(signal.SIGTERM,lambda *a:sys.exit(7));print(json.dumps(dict(event='ready')),flush=True);time.sleep(60)"
                with w.ManagedChild([sys.executable,'-c',code],self.directory,dict(os.environ,HOLODECK_REQUEST_DIRECTORY=str(self.directory))) as child:
                    for line in child.lines(''):print(line,flush=True)
                    if child.command_returncode:raise w.OperationalError('Command was killed before worker interruption')
            def clean(self,*args,**kwargs):self.work.write_bytes(b'ordinary failure cleanup')
        w.Worker=Worker;w.main()
        """.write(to:script,atomically:true,encoding:.utf8)
        let probe = WorkerCancellationProbe(), worker = RequestWorkerProcess(script:script,groups:.init(signal:{probe.signal($0,$1)}))
        worker.afterObservationCommit = { probe.observe($0) }
        let consuming = Task { do { for try await _ in worker.run(mode:"run",configuration:.init(repository:root.path),directory:root.appendingPathComponent("job")) {} } catch {} }
        defer { consuming.cancel();worker.stop() }
        try await waitFor { probe.hasDescendants }
        let pid = worker.process.processIdentifier
        worker.stop();await consuming.value;try await worker.waitForExit()
        XCTAssertEqual(probe.firstPID,pid)
        XCTAssertEqual(try Data(contentsOf:work),original)
    }

    func testSettlementBudgetValidatesClockAndStartsFreshRecovery() throws {
        let boot = UUID().uuidString.lowercased(), original = RequestSettlementBudget(now:100,boot:boot)
        let fresh = RequestSettlementBudget(now:111,boot:boot)
        XCTAssertEqual(fresh.deadline,121);XCTAssertNotEqual(fresh.attemptID,original.attemptID)
        var invalid = original;invalid.deadline = .infinity;XCTAssertFalse(invalid.valid)
        invalid.deadline = 100000;XCTAssertFalse(invalid.valid)
        XCTAssertNotNil(RequestSettlementBudget.bootIdentity)
    }

    func testIdentityObservationDoesNotHoldCancellationOrReplyLock() async throws {
        let (root, script) = try recoveryFixture(), probe = PausedIdentityProbe()
        try """
        import json,signal,sys,time
        signal.signal(signal.SIGTERM,lambda *args:sys.exit(0))
        while True:
            print('identity heartbeat',file=sys.stderr,flush=True)
            time.sleep(.01)
        """.write(to:script,atomically:true,encoding:.utf8)
        let job = root.appendingPathComponent("job"), worker = RequestWorkerProcess(script:script,groups:.init(identity:{probe.identity($0)}))
        worker.afterObservationCommit = { _ in probe.armOnce() }
        let consuming = Task { do { for try await _ in worker.run(mode:"run",configuration:.init(repository:root.path),directory:job) {} } catch {} }
        defer { probe.release();worker.stop();consuming.cancel() }
        try await waitFor { probe.entered }
        let stopped = expectation(description:"Stop does not wait for proc identity lookup")
        DispatchQueue.global().async { worker.stop();stopped.fulfill() }
        await fulfillment(of:[stopped],timeout:1)
        XCTAssertThrowsError(try worker.reply(true))
        let log = job.appendingPathComponent("worker-stderr.log"), size = try Data(contentsOf:log).count
        try await waitFor { (try? Data(contentsOf:log).count) ?? 0 > size }
        probe.release();await consuming.value;try await worker.waitForExit()
    }

    func testDetachCompletesAfterActiveWorkerRetiresWithEvidenceError() async throws {
        let (root, script) = try recoveryFixture()
        let service = ShaderRequestService(catalog:DirectoryCatalog(directory:root.appendingPathComponent("catalog")),directory:root,
            workerScript:script,waitForWorker:{ process in
                try await process.waitForExit()
                throw RequestWorkerEvidenceError(cause:"Retired worker has unverifiable evidence")
            })
        await service.suspend();try await service.start(configuration:.init(repository:root.path,enabled:true))
        let request = ShaderRequest(prompt:"Retain exact bytes",context:try context()), job = root.appendingPathComponent(request.id.uuidString)
        _ = try await service.control(operation:"requestSubmit",payload:.init(request:request),deviceID:"TV")
        let work = job.appendingPathComponent("changes.patch"), bytes = Data([0,255,13,10])
        try bytes.write(to:work);await service.resume()
        try await waitFor { FileManager.default.fileExists(atPath:job.appendingPathComponent("worker-started").path) }
        try await service.detachCheckout(.request(request.id))
        XCTAssertEqual(try Data(contentsOf:work),bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:job.appendingPathComponent("cleanup-started").path))
        let remaining = await service.recoveryStatuses();XCTAssertTrue(remaining.isEmpty)
        let configuration = await service.configurationValue();XCTAssertFalse(configuration.enabled)
        let acknowledgements = try JSONDecoder().decode([DetachedCheckoutAcknowledgement].self,from:Data(contentsOf:root.appendingPathComponent("detached-checkouts.json")))
        XCTAssertTrue(acknowledgements.contains{$0.requestID == request.id})
    }

    private func injectSupervisionFaults(_ script: URL, mode: String, count: Int, retryable: Bool = true) throws {
        let source = try String(contentsOf: script, encoding: .utf8)
        let prefix = """
        import json,sys
        from pathlib import Path
        mode=sys.argv[1]; job=Path(sys.argv[3])
        if mode==\(String(reflecting:mode)):
            counter=job/'supervision-launches'
            count=int(counter.read_text())+1 if counter.exists() else 1
            counter.write_text(str(count))
            limit=job.parent/'supervision-fault-limit'
            if count<=int(limit.read_text()):
                print(json.dumps(dict(event='failure',failureKind='supervision',retryable=\(retryable ? "True" : "False"),recoveryRequired=False,message='Injected supervision fault')),flush=True)
                raise SystemExit(1)
        """
        try (prefix + "\n" + source).write(to:script,atomically:true,encoding:.utf8)
        try String(count).write(to:script.deletingLastPathComponent().appendingPathComponent("supervision-fault-limit"),atomically:true,encoding:.utf8)
    }

    func testVerifyRetriesSettledSupervisionFaultOnce() async throws {
        let (root, script) = try recoveryFixture()
        try injectSupervisionFaults(script,mode:"preflight",count:1)
        let service = try await recoveryService(root,script:script,enabled:false)
        await service.resume()
        try await service.verify(configuration:.init(repository:root.path))
        let job = root.appendingPathComponent("setup")
        XCTAssertEqual(try String(contentsOf:job.appendingPathComponent("supervision-launches"),encoding:.utf8),"2")
        XCTAssertEqual(try RequestWorkerOperation.read(in:job)?.phase,.complete)
        let recoveries = await service.recoveryStatuses();XCTAssertTrue(recoveries.isEmpty)
    }

    func testRequestSupervisionRetryExhaustionPreservesWorkAndManualRetryResetsIt() async throws {
        let (root, script) = try recoveryFixture()
        var source = try String(contentsOf:script,encoding:.utf8)
        let last = try XCTUnwrap(source.range(of:"while True: time.sleep(.005)",options:.backwards))
        source.replaceSubrange(last,with:"emit('clarification',question='Choose output',options=['A','B'])")
        try source.write(to:script,atomically:true,encoding:.utf8)
        try injectSupervisionFaults(script,mode:"run",count:2)
        let service = try await recoveryService(root,script:script)
        let request = ShaderRequest(prompt:"Preserve work",context:try context())
        _ = try await service.control(operation:"requestSubmit",payload:.init(request:request),deviceID:"TV")
        let job = root.appendingPathComponent(request.id.uuidString), patch = job.appendingPathComponent("changes.patch"), bytes = Data([0,255,13,10])
        try bytes.write(to:patch);await service.resume()
        try await waitFor { (try? RequestWorkerOperation.read(in:job)?.phase) == .paused }
        XCTAssertEqual(try String(contentsOf:job.appendingPathComponent("supervision-launches"),encoding:.utf8),"2")
        XCTAssertEqual(try Data(contentsOf:patch),bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:job.appendingPathComponent("cleanup-started").path))
        let resumed = try await recoveryService(root,script:script)
        await resumed.resume()
        try await waitFor { !(await resumed.recoveryStatuses()).isEmpty }
        XCTAssertEqual(try String(contentsOf:job.appendingPathComponent("supervision-launches"),encoding:.utf8),"2")
        try "0".write(to:root.appendingPathComponent("supervision-fault-limit"),atomically:true,encoding:.utf8)
        let gitdir = try initializeRecoveryGit(root)
        try JSONSerialization.data(withJSONObject: ["id": request.id.uuidString, "directory": RequestPaths.canonical(job)]).write(to: gitdir.appendingPathComponent("holodeck-request-owner.json"))
        try await resumed.retryReconciliation()
        try await waitFor { await resumed.allJobs().first?.stage == .awaitingClarification }
        XCTAssertEqual(try String(contentsOf:job.appendingPathComponent("supervision-launches"),encoding:.utf8),"3")
        XCTAssertEqual(try Data(contentsOf:patch),bytes)
    }

    func testPersistenceSupervisionFailurePausesWithoutAutomaticRetry() async throws {
        let (root, script) = try recoveryFixture()
        try injectSupervisionFaults(script,mode:"run",count:2,retryable:false)
        let service = try await recoveryService(root,script:script)
        let request = ShaderRequest(prompt:"Retain on persistence failure",context:try context())
        _ = try await service.control(operation:"requestSubmit",payload:.init(request:request),deviceID:"TV")
        let job = root.appendingPathComponent(request.id.uuidString), patch = job.appendingPathComponent("changes.patch"), bytes = Data([0,255,13,10])
        try bytes.write(to:patch);await service.resume()
        try await waitFor { (try? RequestWorkerOperation.read(in:job)?.phase) == .paused }
        XCTAssertEqual(try String(contentsOf:job.appendingPathComponent("supervision-launches"),encoding:.utf8),"1")
        XCTAssertEqual(try Data(contentsOf:patch),bytes)
        let statuses = await service.recoveryStatuses();XCTAssertTrue(statuses.contains{$0.disposition == .resume})
        XCTAssertFalse(FileManager.default.fileExists(atPath:job.appendingPathComponent("cleanup-started").path))
    }

    func testCleanupRetriesSupervisionFaultWithoutLosingCleanupIntent() async throws {
        let (root, script) = try recoveryFixture()
        try injectSupervisionFaults(script,mode:"discard",count:1)
        let initial = try await recoveryService(root,script:script)
        let request = ShaderRequest(prompt:"Cleanup",context:try context())
        _ = try await initial.control(operation:"requestSubmit",payload:.init(request:request),deviceID:"TV")
        try await initial.cancelQueued(request.id)
        let file = root.appendingPathComponent("journal.json")
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [[String:Any]])
        records[0]["cleanupPending"] = true
        try JSONSerialization.data(withJSONObject:records).write(to:file)
        let job = root.appendingPathComponent(request.id.uuidString)
        try Data("owned".utf8).write(to:job.appendingPathComponent("owned-patch"))
        let service = try await recoveryService(root,script:script)
        await service.resume()
        try await waitFor { (try? RequestWorkerOperation.read(in:job)?.phase) == .complete }
        XCTAssertEqual(try String(contentsOf:job.appendingPathComponent("supervision-launches"),encoding:.utf8),"2")
        XCTAssertFalse(FileManager.default.fileExists(atPath:job.appendingPathComponent("owned-patch").path))
        let pending = await service.hasPendingCleanup();XCTAssertFalse(pending)
    }

    func testPublicationRetriesSettledSupervisionFaultOnce() async throws {
        let f = try await publicationRecoveryFixture()
        try injectSupervisionFaults(f.script,mode:"publication",count:1)
        await f.service.resume()
        try await f.service.ensurePublication(force:true)
        let job = f.root.appendingPathComponent("publication")
        XCTAssertEqual(try String(contentsOf:job.appendingPathComponent("supervision-launches"),encoding:.utf8),"2")
        XCTAssertEqual(try RequestWorkerOperation.read(in:job)?.phase,.complete)
        let recovery = await f.service.recoveryStatuses();XCTAssertTrue(recovery.isEmpty)
    }

    func testOperationJournalSurvivesRestartAndRejectsUnverifiableMetadata() throws {
        let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("operation")
        var initial = try RequestWorkerOperation.begin(mode:"run",configuration:.init(repository:root.path),in:job)
        initial.phase = .retryPending;try initial.save(in:job)
        let pending = try RequestWorkerOperation.begin(mode:"run",configuration:.init(repository:root.path),in:job)
        XCTAssertEqual(pending.id,initial.id);XCTAssertEqual(pending.phase,.retryPending)
        try RequestWorkerOperation.encodedConfiguration(.init(repository:root.path),id:initial.id).write(to:job.appendingPathComponent("configuration.json"))
        initial.phase = .retryRunning;try initial.save(in:job)
        XCTAssertThrowsError(try RequestWorkerOperation.begin(mode:"run",configuration:.init(repository:root.path),in:job))
        XCTAssertEqual(try RequestWorkerOperation.read(in:job)?.phase,.paused)
        try RequestWorkerOperation.restartPaused(in:job)
        XCTAssertNotEqual(try RequestWorkerOperation.read(in:job)?.id,initial.id)
        XCTAssertEqual(try RequestWorkerOperation.expectedID(in:job),try RequestWorkerOperation.read(in:job)?.id)
        let marker = job.appendingPathComponent(RequestWorkerOperation.filename)
        try Data("{".utf8).write(to:marker)
        XCTAssertThrowsError(try RequestWorkerOperation.begin(mode:"run",configuration:.init(repository:root.path),in:job))
        try FileManager.default.removeItem(at:marker)
        try FileManager.default.createSymbolicLink(at:marker,withDestinationURL:root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try RequestWorkerOperation.read(in:job))
        try FileManager.default.removeItem(at:marker)
        XCTAssertThrowsError(try RequestWorkerOperation.begin(mode:"run",configuration:.init(repository:root.path),in:job)) { XCTAssertTrue($0.localizedDescription.contains("missing")) }
    }

    func testPipeUncertaintyDoesNotOverwriteRegistryOrInventItsCause() throws {
        let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at:job,withIntermediateDirectories:true)
        try Data("{".utf8).write(to:job.appendingPathComponent("children.json"))
        let value: [String:Any] = ["formatVersion":2,"sessionID":UUID().uuidString,"revision":1,"clock":"darwin-uptime-raw",
            "supervisor":["pid":Int32.max,"seconds":1,"microseconds":0],"state":"failed","failureKind":"supervision",
            "failure":"Unrelated supervisor problem","recoveryRequired":true,"pipeDrainComplete":false,"processesSettled":true]
        try JSONSerialization.data(withJSONObject:value).write(to:job.appendingPathComponent("supervision.json"))
        let observation = try RequestProcessIdentity.observe(in:job)
        XCTAssertEqual(observation.evidenceErrors.count,2)
        XCTAssertTrue(observation.evidenceError?.contains("registry is unreadable") == true)
        XCTAssertTrue(observation.evidenceError?.contains("Output pipe completion is unverified") == true)
        XCTAssertFalse(observation.evidenceError?.contains("Unrelated supervisor problem") == true)
    }

    func testEvidenceOnlyRetirementPerformsFreshFinalObservation() async throws {
        let (root, script) = try recoveryFixture(), probe = EmptyObservationProbe()
        try """
        from pathlib import Path
        import sys
        Path(sys.argv[3]).joinpath('children.json').write_text('{')
        """.write(to:script,atomically:true,encoding:.utf8)
        let worker = RequestWorkerProcess(script:script)
        worker.afterObservationCommit = { identities in if identities.isEmpty { probe.observe() } }
        do {
            for try await _ in worker.run(mode:"run",configuration:.init(repository:root.path),directory:root.appendingPathComponent("job")) {}
            XCTFail("Malformed evidence was removed")
        } catch { XCTAssertTrue(error is RequestWorkerEvidenceError) }
        XCTAssertGreaterThanOrEqual(probe.count,2)
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("job/children.json").path))
    }

    func testOrphanReconciliationUsesInjectedBirthsAndSignalsThroughout() throws {
        let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("fake-orphan")
        try FileManager.default.createDirectory(at:job,withIntermediateDirectories:true)
        func identity(_ pid: Int32) throws -> RequestProcessIdentity {
            try JSONDecoder().decode(RequestProcessIdentity.self,from:JSONSerialization.data(withJSONObject:["pid":pid,"seconds":1,"microseconds":0]))
        }
        let worker = try identity(Int32.max-1), command = try identity(Int32.max-2), probe = InjectedOwnershipProbe([worker,command])
        try JSONSerialization.data(withJSONObject:["pid":worker.pid,"birth":["pid":worker.pid,"seconds":1,"microseconds":0],"script":"fixture","directory":job.path]).write(to:job.appendingPathComponent("process.json"))
        try JSONSerialization.data(withJSONObject:[["leader":["pid":command.pid,"seconds":1,"microseconds":0],"members":[["pid":command.pid,"seconds":1,"microseconds":0]]]]).write(to:job.appendingPathComponent("children.json"))
        try RequestWorkerProcess.reconcileOrphan(in:job,groups:.init(identity:{probe.identity($0)},signal:{probe.signal($0,$1)},group:{probe.group($0)},now:{probe.now},wait:{probe.wait($0)}))
        XCTAssertEqual(probe.signalled,[worker.pid,command.pid])
        XCTAssertFalse(FileManager.default.fileExists(atPath:job.appendingPathComponent("children.json").path))
    }

    func testCleanupPrelaunchEvidenceErrorEntersDurableRecovery() async throws {
        let (root, script) = try recoveryFixture(), initial = try await recoveryService(root,script:script)
        let request = ShaderRequest(prompt:"Cleanup evidence",context:try context())
        _ = try await initial.control(operation:"requestSubmit",payload:.init(request:request),deviceID:"TV")
        try await initial.cancelQueued(request.id)
        let journal = root.appendingPathComponent("journal.json")
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:journal)) as? [[String:Any]])
        records[0]["cleanupPending"] = true
        try JSONSerialization.data(withJSONObject:records).write(to:journal)
        let gate = CleanupEvidenceProbe(), job = root.appendingPathComponent(request.id.uuidString)
        let service = ShaderRequestService(catalog:DirectoryCatalog(directory:root.appendingPathComponent("catalog")),directory:root,workerScript:script,reconcileWorker:{ folder in
            if folder == job { try await gate.reconcile() }
            try RequestWorkerProcess.reconcileOrphan(in:folder)
        })
        await service.suspend();try await service.initialize(configuration:.init(repository:root.path,enabled:true));await service.resume()
        try await waitFor { await service.recoveryStatuses().contains{$0.kind == .reconciliation && $0.requestID == request.id} }
        let store = try JSONDecoder().decode(RequestRecoveryStore.self,from:Data(contentsOf:root.appendingPathComponent("recovery.json")))
        XCTAssertEqual(store.entries[RequestPaths.canonical(job)]?.disposition,.cleanup)
        XCTAssertFalse(FileManager.default.fileExists(atPath:job.appendingPathComponent("cleanup-started").path))
    }

    func testDetachDuringAutomaticRetryPreventsSecondLaunch() async throws {
        let (root, script) = try recoveryFixture(), gate = RequestPreparationGate()
        try injectSupervisionFaults(script,mode:"run",count:1)
        let service = ShaderRequestService(catalog:DirectoryCatalog(directory:root.appendingPathComponent("catalog")),directory:root,workerScript:script,reconcileWorker:{ journal in
            if (try RequestWorkerOperation.read(in:journal))?.phase == .retryPending { await gate.hold() }
            try RequestWorkerProcess.reconcileOrphan(in:journal)
        })
        await service.suspend();try await service.start(configuration:.init(repository:root.path,enabled:true))
        let request = ShaderRequest(prompt:"Retain on detach",context:try context())
        _ = try await service.control(operation:"requestSubmit",payload:.init(request:request),deviceID:"TV")
        let job = root.appendingPathComponent(request.id.uuidString), patch = job.appendingPathComponent("changes.patch"), bytes = Data([0,255,13,10])
        try bytes.write(to:patch);await service.resume();try await waitFor { await gate.entered }
        let detach = Task { try await service.detachCheckout(.request(request.id)) }
        try await waitFor { await service.recoveryStatuses().contains{$0.disposition == .detach} }
        await gate.release();try await detach.value
        XCTAssertEqual(try String(contentsOf:job.appendingPathComponent("supervision-launches"),encoding:.utf8),"1")
        XCTAssertEqual(try Data(contentsOf:patch),bytes)
    }

    func testNativeBootIdentityCacheRetriesFailureAndKeepsSuccess() {
        let probe = BootIdentityProbe(), cache = RequestBootIdentityCache(read:{probe.read()})
        XCTAssertNil(cache.value());XCTAssertEqual(cache.value(),probe.boot);XCTAssertEqual(cache.value(),probe.boot)
        XCTAssertEqual(probe.calls,2)
    }

    func testHealthyWorkerDoesNotQueueIdleSignalPasses() async throws {
        let (root, script) = try recoveryFixture(), signals = EmptyObservationProbe(), observations = EmptyObservationProbe()
        let worker = RequestWorkerProcess(script:script)
        worker.beforeSignalPass = { signals.observe() }
        worker.afterObservationCommit = { _ in observations.observe() }
        let consuming = Task { do { for try await _ in worker.run(mode:"run",configuration:.init(repository:root.path),directory:root.appendingPathComponent("job")) {} } catch {} }
        defer { worker.stop();consuming.cancel() }
        try await waitFor { observations.count >= 3 }
        XCTAssertEqual(signals.count,0)
        worker.stop();await consuming.value;try await worker.waitForExit()
        XCTAssertGreaterThanOrEqual(signals.count,1)
    }

    func testLegacyOrphanArgumentsUseInjectedProcessOperations() throws {
        let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("legacy-injected")
        try FileManager.default.createDirectory(at:job,withIntermediateDirectories:true)
        let identity = try JSONDecoder().decode(RequestProcessIdentity.self,from:Data("{\"pid\":2147483646,\"seconds\":1,\"microseconds\":0}".utf8))
        let probe = InjectedOwnershipProbe([identity])
        try JSONSerialization.data(withJSONObject:["pid":identity.pid,"script":"fixture.py","directory":job.path]).write(to:job.appendingPathComponent("process.json"))
        try RequestWorkerProcess.reconcileOrphan(in:job,groups:.init(identity:{probe.identity($0)},signal:{probe.signal($0,$1)},group:{probe.group($0)},now:{probe.now},wait:{probe.wait($0)},arguments:{_ in ["fixture.py",job.path]}))
        XCTAssertEqual(probe.signalled,[identity.pid])
        XCTAssertFalse(FileManager.default.fileExists(atPath:job.appendingPathComponent("process.json").path))
    }
    func testOperationBindingReplaysEveryDurableInterruptionWithoutNewAllowance() throws {
        for reset in [false, true] {
            for cut in 1...3 {
                let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("binding")
                let configuration = ShaderRequestConfiguration(repository: root.path)
                var prior = try RequestWorkerOperation.begin(mode: "preflight", configuration: configuration, in: job)
                prior.phase = reset ? .paused : .complete; try prior.save(in: job)
                var writes = 0
                let writer: RequestWorkerOperation.Writer = { data, file in
                    try RequestJournalWriter.write(data, to: file); writes += 1
                    if writes == cut { throw CancellationError() }
                }
                XCTAssertThrowsError(try {
                    if reset { try RequestWorkerOperation.restartPaused(in: job, configuration: configuration, writer: writer) }
                    else { _ = try RequestWorkerOperation.begin(mode: "preflight", configuration: configuration, in: job, writer: writer) }
                }())
                let interrupted = try XCTUnwrap(RequestWorkerOperation.read(in: job))
                XCTAssertNotEqual(interrupted.id, prior.id)
                let resumed = try RequestWorkerOperation.begin(mode: "preflight", configuration: configuration, in: job)
                XCTAssertEqual(resumed.id, interrupted.id); XCTAssertEqual(resumed.phase, .initial)
                XCTAssertNil(resumed.binding)
                try RequestWorkerOperation.validateLaunch(id: resumed.id, configuration: configuration, in: job)
            }
        }
    }

    func testOperationBindingRejectsUnrecordedConfigurationAndCheckout() throws {
        let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("binding")
        let configuration = ShaderRequestConfiguration(repository: root.path)
        var prior = try RequestWorkerOperation.begin(mode: "publication", configuration: configuration, in: job)
        prior.phase = .complete; try prior.save(in: job)
        var writes = 0
        XCTAssertThrowsError(try RequestWorkerOperation.begin(mode: "publication", configuration: configuration, in: job, writer: { data, file in
            try RequestJournalWriter.write(data, to: file); writes += 1
            if writes == 1 { throw POSIXError(.ENOSPC) }
        }))
        var modified = configuration; modified.git = "/unexpected/git"
        try RequestWorkerOperation.encodedConfiguration(modified, id: prior.id).write(to: job.appendingPathComponent("configuration.json"))
        XCTAssertThrowsError(try RequestWorkerOperation.begin(mode: "publication", configuration: configuration, in: job))
        XCTAssertThrowsError(try RequestWorkerOperation.begin(mode: "publication", configuration: .init(repository: root.appendingPathComponent("other").path), in: job))
        XCTAssertNotNil(try RequestWorkerOperation.read(in: job)?.binding)
    }

    func testLegacyUnexplainedBindingRequiresExplicitRecovery() throws {
        let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("legacy-binding")
        let configuration = ShaderRequestConfiguration(repository: root.path)
        let prior = try RequestWorkerOperation.begin(mode: "preflight", configuration: configuration, in: job)
        let legacy: [String: Any] = ["formatVersion": 1, "id": UUID().uuidString, "mode": "preflight", "phase": "initial"]
        try JSONSerialization.data(withJSONObject: legacy).write(to: job.appendingPathComponent(RequestWorkerOperation.filename))
        XCTAssertThrowsError(try RequestWorkerOperation.begin(mode: "preflight", configuration: configuration, in: job))
        XCTAssertThrowsError(try RequestWorkerOperation.restartPaused(in: job, configuration: configuration))
        try RequestWorkerOperation.restartPaused(in: job, configuration: configuration, repairLegacyMismatch: true)
        let restored = try RequestWorkerOperation.begin(mode: "preflight", configuration: configuration, in: job)
        XCTAssertNotEqual(restored.id, prior.id); XCTAssertEqual(restored.formatVersion, 2)
        try RequestWorkerOperation.validateLaunch(id: restored.id, configuration: configuration, in: job)
    }

    func testOrdinaryFailureAfterRetryClosesOperationForNextVerify() async throws {
        let (root, script) = try recoveryFixture()
        let source = try String(contentsOf: script, encoding: .utf8)
        let prefix = """
        import json,sys
        from pathlib import Path
        job=Path(sys.argv[3]); counter=job/'attempts'
        n=int(counter.read_text())+1 if counter.exists() else 1;counter.write_text(str(n))
        if n<=2:
            print(json.dumps(dict(event='failure',failureKind='supervision' if n==1 else 'operational',retryable=n==1,recoveryRequired=False,message='internal fault' if n==1 else 'dirty checkout')),flush=True)
            raise SystemExit(1)
        """
        try (prefix + "\n" + source).write(to: script, atomically: true, encoding: .utf8)
        let service = try await recoveryService(root, script: script, enabled: false); await service.resume()
        do { try await service.verify(configuration: .init(repository: root.path)); XCTFail("Ordinary failure succeeded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("dirty checkout")) }
        XCTAssertEqual(try RequestWorkerOperation.read(in: root.appendingPathComponent("setup"))?.phase, .complete)
        try await service.verify(configuration: .init(repository: root.path))
    }

    func testDetachmentArchivesBindingsAndDanglingMarkersResumably() throws {
        let (root, _) = try recoveryFixture(), job = root.appendingPathComponent("archive")
        _ = try RequestWorkerOperation.begin(mode: "publication", configuration: .init(repository: root.path), in: job)
        let marker = job.appendingPathComponent("supervision.json")
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: root.appendingPathComponent("missing"))
        let id = UUID(), archive = job.appendingPathComponent("detached-" + id.uuidString)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: job.appendingPathComponent(RequestWorkerOperation.filename), to: archive.appendingPathComponent(RequestWorkerOperation.filename))
        try RequestJournalWriter.archive(in: job, id: id)
        try RequestJournalWriter.archive(in: job, id: id)
        XCTAssertFalse(RequestProcessIdentity.evidenceExists(marker))
        XCTAssertTrue(RequestProcessIdentity.evidenceExists(archive.appendingPathComponent("supervision.json")))
        XCTAssertTrue(RequestProcessIdentity.evidenceExists(archive.appendingPathComponent("configuration.json")))
        _ = try RequestWorkerOperation.begin(mode: "publication", configuration: .init(repository: root.path), in: job)
    }

    func testDetachPausedPublicationThenVerifyAllowsFreshRebuild() async throws {
        let f = try await publicationRecoveryFixture()
        try injectSupervisionFaults(f.script, mode: "publication", count: 2)
        await f.service.resume()
        do { try await f.service.ensurePublication(force: true); XCTFail("Fault succeeded") } catch {}
        let entries = await f.service.recoveryStatuses(); let entry = try XCTUnwrap(entries.first)
        try await f.service.detachCheckout(.recovery(entry.id))
        try "0".write(to: f.root.appendingPathComponent("supervision-fault-limit"), atomically: true, encoding: .utf8)
        try await f.service.verify(configuration: .init(repository: f.authoring.path))
        try await f.service.ensurePublication(force: true)
        XCTAssertEqual(try RequestWorkerOperation.read(in: f.root.appendingPathComponent("publication"))?.phase, .complete)
    }
    func testRecoveryRepairsHealthyJournalEvenWhenAnotherIsCorrupt() async throws {
        let (root, script) = try recoveryFixture(), configuration = ShaderRequestConfiguration(repository: root.path)
        _ = try initializeRecoveryGit(root)
        let good = root.appendingPathComponent("publication"), bad = root.appendingPathComponent("setup")
        var operation = try RequestWorkerOperation.begin(mode: "publication", configuration: configuration, in: good)
        operation.phase = .paused; try operation.save(in: good)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: bad.appendingPathComponent(RequestWorkerOperation.filename))
        var store = RequestRecoveryStore()
        for journal in [good, bad] {
            let key = RequestPaths.canonical(journal)
            store.entries[key] = .init(journal: key, requestID: nil, configuration: configuration, disposition: .resume, message: "Original supervision failure")
        }
        try JSONEncoder().encode(store).write(to: root.appendingPathComponent("recovery.json"))
        let service = try await recoveryService(root, script: script, enabled: false)
        do { try await service.retryReconciliation(); XCTFail("Corrupt journal was ignored") }
        catch { XCTAssertTrue(error.localizedDescription.contains("setup")) }
        let repaired = try XCTUnwrap(RequestWorkerOperation.read(in: good))
        XCTAssertNotEqual(repaired.id, operation.id)
        try RequestWorkerOperation.validateLaunch(id: repaired.id, configuration: configuration, in: good)
        do { try await service.retryReconciliation(); XCTFail("Corruption disappeared") } catch {}
        XCTAssertEqual(try RequestWorkerOperation.read(in: good)?.id, repaired.id)
        let retained = try JSONDecoder().decode(RequestRecoveryStore.self, from: Data(contentsOf: root.appendingPathComponent("recovery.json")))
        XCTAssertEqual(retained.entries.count, 2)
        XCTAssertTrue(retained.entries[RequestPaths.canonical(bad)]?.message.contains("Original supervision failure") == true)
    }

    func testExplicitRecoveryCompletesSavedCleanupConfigurationIntent() async throws {
        for phase in [RequestWorkerOperation.Phase.initial, .paused] {
            let (root, script) = try recoveryFixture(), gitdir = try initializeRecoveryGit(root)
            let initial = try await recoveryService(root, script: script)
            let request = ShaderRequest(prompt: "Recover corrected paths", context: try context())
            _ = try await initial.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
            try await initial.cancelQueued(request.id)
            let job = root.appendingPathComponent(request.id.uuidString), key = RequestPaths.canonical(job)
            try JSONSerialization.data(withJSONObject: ["id": request.id.uuidString, "directory": key]).write(to: gitdir.appendingPathComponent("holodeck-request-owner.json"))
            var recordData = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("journal.json"))) as? [[String: Any]])
            recordData[0]["cleanupPending"] = true; recordData[0]["cleanupFailure"] = "Original cleanup failure"
            try JSONSerialization.data(withJSONObject: recordData).write(to: root.appendingPathComponent("journal.json"))
            var previous = try JSONDecoder().decode(ShaderRequestConfiguration.self, from: JSONSerialization.data(withJSONObject: recordData[0]["configuration"]!))
            previous.python = "/unavailable/python"; previous.git = "/unavailable/git"
            recordData[0]["configuration"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(previous))
            try JSONSerialization.data(withJSONObject: recordData).write(to: root.appendingPathComponent("journal.json"))
            try JSONEncoder().encode(previous).write(to: root.appendingPathComponent("preferences.json"))
            var corrected = previous; corrected.python = "/usr/bin/python3"; corrected.git = "/usr/bin/git"
            var operation = try RequestWorkerOperation.begin(mode: "discard", configuration: previous, in: job)
            operation.phase = phase; try operation.save(in: job)
            var store = RequestRecoveryStore()
            var entry = RequestRecoveryStore.Entry(journal: key, requestID: request.id, configuration: previous, disposition: .cleanup, message: "Original cleanup failure")
            entry.configurationRepair = .init(previous: previous, corrected: corrected, requestIDs: [request.id], updatePreferences: true)
            store.entries[key] = entry
            try JSONEncoder().encode(store).write(to: root.appendingPathComponent("recovery.json"))
            let resumed = try await recoveryService(root, script: script)
            try await resumed.retryReconciliation()
            let repairedRecords = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("journal.json"))) as? [[String: Any]])
            let saved = try JSONDecoder().decode(ShaderRequestConfiguration.self, from: JSONSerialization.data(withJSONObject: repairedRecords[0]["configuration"]!))
            XCTAssertEqual(saved.python, corrected.python); XCTAssertEqual(saved.git, corrected.git)
            try RequestWorkerOperation.validateLaunch(id: try XCTUnwrap(RequestWorkerOperation.read(in: job)?.id), configuration: corrected, in: job)
            let finalStore = try JSONDecoder().decode(RequestRecoveryStore.self, from: Data(contentsOf: root.appendingPathComponent("recovery.json")))
            XCTAssertTrue(finalStore.entries.isEmpty)
        }
    }
    func testLegacyPendingDetachAcquiresDurableArchiveIntentBeforeRetirement() async throws {
        let (root, script) = try recoveryFixture(), journal = root.appendingPathComponent("publication")
        let configuration = ShaderRequestConfiguration(repository: root.path)
        var operation = try RequestWorkerOperation.begin(mode: "publication", configuration: configuration, in: journal)
        operation.phase = .paused; try operation.save(in: journal)
        var store = RequestRecoveryStore()
        let key = RequestPaths.canonical(journal)
        store.entries[key] = .init(journal: key, requestID: nil, configuration: configuration, disposition: .detach, message: "Legacy pending detach")
        try JSONEncoder().encode(store).write(to: root.appendingPathComponent("recovery.json"))
        let service = try await recoveryService(root, script: script, enabled: false)
        try await service.retryReconciliation()
        XCTAssertFalse(RequestProcessIdentity.evidenceExists(journal.appendingPathComponent("configuration.json")))
        let archives = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("detached-") }
        XCTAssertEqual(archives.count, 1)
        XCTAssertTrue(RequestProcessIdentity.evidenceExists(archives[0].appendingPathComponent(RequestWorkerOperation.filename)))
    }

    private func injectCompletionThenFault(_ script: URL, mode: String, preparation: Bool = false) throws {
        let source = try String(contentsOf: script, encoding: .utf8)
        let prefix = """
        import json,sys
        from pathlib import Path
        mode=sys.argv[1];job=Path(sys.argv[3])
        def emit(event,**data):print(json.dumps(dict(event=event,**data)),flush=True)
        if mode==\(String(reflecting:mode)):
            counter=job/'isolated-attempts';n=int(counter.read_text())+1 if counter.exists() else 1;counter.write_text(str(n))
            if \(preparation ? "True" : "False"):
                emit('preparePublication',requiredPreviewShaderIDs=[])
                assert json.loads(sys.stdin.readline())['ok']
            if n==1:
                if mode=='preflight':emit('preflight',checkoutID='first-attempt-only')
                if mode=='publication':emit('publicationReady')
                if mode=='discard':emit('discarded')
                if mode=='run':emit('clarification',question='First attempt only',options=['A','B'])
                emit('failure',failureKind='supervision',retryable=True,recoveryRequired=False,message='Fault after completion')
                raise SystemExit(1)
            raise SystemExit(0)
        """
        try (prefix + "\n" + source).write(to: script, atomically: true, encoding: .utf8)
    }

    func testEveryRetryRequiresItsOwnCompletionEvent() async throws {
        do {
            let (root, script) = try recoveryFixture(); try injectCompletionThenFault(script, mode: "preflight")
            let service = try await recoveryService(root, script: script, enabled: false); await service.resume()
            do { try await service.verify(configuration: .init(repository: root.path)); XCTFail("Stale preflight was accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("completion event")) }
            let accepted = await service.configurationValue(); XCTAssertFalse(accepted.enabled); XCTAssertNil(accepted.checkoutID)
        }
        do {
            let f = try await publicationRecoveryFixture(); try injectCompletionThenFault(f.script, mode: "publication", preparation: true)
            await f.service.resume()
            do { try await f.service.ensurePublication(force: true); XCTFail("Stale publication confirmation was accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("completion event")) }
            let publication = await f.service.publicationStatus(); XCTAssertNil(publication)
        }
        do {
            let (root, script) = try recoveryFixture(); try injectCompletionThenFault(script, mode: "discard")
            let initial = try await recoveryService(root, script: script)
            let request = ShaderRequest(prompt: "Cleanup confirmation", context: try context())
            _ = try await initial.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
            try await initial.cancelQueued(request.id)
            var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("journal.json"))) as? [[String: Any]])
            records[0]["cleanupPending"] = true
            try JSONSerialization.data(withJSONObject: records).write(to: root.appendingPathComponent("journal.json"))
            let service = try await recoveryService(root, script: script); await service.resume()
            try await waitFor { await service.allJobs().first?.message.contains("completion event") == true }
            let pending = await service.hasPendingCleanup(); XCTAssertTrue(pending)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(request.id.uuidString + "/isolated-attempts"), encoding: .utf8), "2")
        }
        do {
            let (root, script) = try recoveryFixture(); try injectCompletionThenFault(script, mode: "run")
            let service = try await recoveryService(root, script: script)
            let request = ShaderRequest(prompt: "Result confirmation", context: try context())
            _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
            await service.resume()
            try await waitFor { await service.allJobs().first?.stage == .failed }
            let status = await service.allJobs().first; XCTAssertTrue(status?.message.contains("completion event") == true)
            await service.suspend()
        }
    }

    func testInterpreterExitBeforeEachLaunchGateStageHasTerminalDiagnostic() async throws {
        for stage in ["birth", "identity", "gate"] {
            let (root, script) = try recoveryFixture(), marker = root.appendingPathComponent("executed")
            try "from pathlib import Path;Path(\(String(reflecting:marker.path))).touch()".write(to: script, atomically: true, encoding: .utf8)
            let worker = RequestWorkerProcess(script: script)
            let crash = { kill(worker.process.processIdentifier, SIGKILL); worker.process.waitUntilExit() }
            switch stage {
            case "birth": worker.beforeBirthCapture = crash
            case "identity": worker.beforeIdentityWrite = crash
            default: worker.beforeGateRelease = crash
            }
            do {
                for try await _ in worker.run(mode: "run", configuration: .init(repository: root.path), directory: root.appendingPathComponent("job")) {}
                XCTFail("Crashed interpreter succeeded")
            } catch {
                XCTAssertTrue(error is ShaderRequestError, "\(stage): \(error)")
                XCTAssertTrue(error.localizedDescription.contains("signal 9")); XCTAssertTrue(error.localizedDescription.contains("worker-stderr.log"))
            }
            try await worker.waitForExit(); XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testDeterministicInterpreterLaunchFailureDoesNotRetryOrPause() async throws {
        let (root, script) = try recoveryFixture(), service = try await recoveryService(root, script: script, enabled: false)
        await service.resume()
        var configuration = ShaderRequestConfiguration(repository: root.path); configuration.python = root.appendingPathComponent("missing-python").path
        do { try await service.verify(configuration: configuration); XCTFail("Missing interpreter succeeded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("could not launch")) }
        let operation = try XCTUnwrap(RequestWorkerOperation.read(in: root.appendingPathComponent("setup")))
        XCTAssertEqual(operation.phase, .complete)
        let recovery = await service.recoveryStatuses(); XCTAssertTrue(recovery.isEmpty)
    }

    func testCancellationDuringRetryPreparationKeepsOriginalFailure() async throws {
        let (root, script) = try recoveryFixture(), gate = RequestPreparationGate()
        try injectSupervisionFaults(script, mode: "preflight", count: 1)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
            workerScript: script, reconcileWorker: { journal in
                if try RequestWorkerOperation.read(in: journal)?.phase == .retryPending { await gate.hold() }
                try RequestWorkerProcess.reconcileOrphan(in: journal)
            })
        try await service.initialize(configuration: .init(repository: root.path))
        let verifying = Task { try await service.verify(configuration: .init(repository: root.path)) }
        try await waitFor { await gate.entered }; verifying.cancel(); await gate.release()
        do { try await verifying.value; XCTFail("Cancelled Verify succeeded") } catch is CancellationError {}
        let recoveries = await service.recoveryStatuses()
        XCTAssertTrue(recoveries.contains { $0.message.contains("Injected supervision fault") })
        XCTAssertFalse(recoveries.contains { $0.message.contains("CancellationError") })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("setup/supervision-launches"), encoding: .utf8), "1")
    }
    func testConfirmedCommitIsDeliveredOnceAcrossSupervisionRetry() async throws {
        let f = try await publicationRecoveryFixture()
        let source = try String(contentsOf: f.script, encoding: .utf8), commit = String(repeating: "a", count: 40)
        let prefix = """
        import json,sys
        from pathlib import Path
        job=Path(sys.argv[3])
        def emit(event,**data):print(json.dumps(dict(event=event,**data)),flush=True)
        if sys.argv[1]=='run':
            counter=job/'commit-attempts';n=int(counter.read_text())+1 if counter.exists() else 1;counter.write_text(str(n))
            if n==1:
                emit('preparePublication',requiredPreviewShaderIDs=[])
                assert json.loads(sys.stdin.readline())['ok']
            emit('result',result=dict(outputKind='edited',shaderID='plasma',changed=False,summary='Confirmed',approximations=[],commitSHA='\(commit)'))
            if n==1:
                emit('failure',failureKind='supervision',retryable=True,recoveryRequired=False,message='Fault after confirmed commit')
                raise SystemExit(1)
            raise SystemExit(0)
        """
        try (prefix + "\n" + source).write(to: f.script, atomically: true, encoding: .utf8)
        let request = ShaderRequest(prompt: "Deliver once", context: try context())
        _ = try await f.service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        await f.service.activateScheduling(); await f.service.resume()
        let job = f.root.appendingPathComponent(request.id.uuidString)
        try await waitFor { (try? RequestWorkerOperation.read(in: job)?.phase) == .complete }
        let status = await f.service.allJobs().first, publication = await f.service.publicationStatus()
        XCTAssertEqual(status?.stage, .awaitingActivation); XCTAssertEqual(status?.result?.commitSHA, commit)
        XCTAssertEqual(publication?.sequence, 1)
        XCTAssertEqual(try String(contentsOf: job.appendingPathComponent("commit-attempts"), encoding: .utf8), "2")
    }
    func testJournalRetryAvoidsFullScanButExplicitRecoveryChecksOtherJournals() async throws {
        let recorder = JournalVisitRecorder()
        let f = try await publicationRecoveryFixture(reconcile: { journal in
            await recorder.record(journal); try RequestWorkerProcess.reconcileOrphan(in: journal)
        })
        try injectSupervisionFaults(f.script, mode: "publication", count: 1)
        await f.service.resume(); try await f.service.ensurePublication(force: true)
        let setup = f.root.appendingPathComponent("setup"), publication = f.root.appendingPathComponent("publication")
        let setupVisits = await recorder.count(setup), publicationVisits = await recorder.count(publication)
        XCTAssertEqual(setupVisits, 1); XCTAssertEqual(publicationVisits, 3)
        try await f.service.ensurePublication(force: true)
        let laterSetupVisits = await recorder.count(setup), laterPublicationVisits = await recorder.count(publication)
        XCTAssertEqual(laterSetupVisits, 1); XCTAssertEqual(laterPublicationVisits, 4)
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: setup.appendingPathComponent("children.json"))
        do { try await f.service.retryReconciliation(); XCTFail("Unrelated dirty journal was skipped") } catch {}
        let entries = await f.service.recoveryStatuses()
        XCTAssertTrue(entries.contains { $0.journal.map { RequestPaths.canonical($0) } == RequestPaths.canonical(setup) })
        let finalVisits = await recorder.count(setup); XCTAssertGreaterThan(finalVisits, laterSetupVisits)
    }

    func testDanglingProcessEvidenceBlocksDeletionAndExplicitDetachArchivesIt() async throws {
        let (root, script) = try recoveryFixture(), service = try await recoveryService(root, script: script)
        let request = ShaderRequest(prompt: "Keep marker evidence", context: try context())
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        try await service.cancelQueued(request.id)
        let job = root.appendingPathComponent(request.id.uuidString), marker = job.appendingPathComponent("supervision.json"), work = job.appendingPathComponent("retained")
        try Data([0, 255, 13, 10]).write(to: work)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: root.appendingPathComponent("missing"))
        do { try await service.deleteFinished(request.id); XCTFail("Deleted dangling evidence") } catch {}
        XCTAssertEqual(try Data(contentsOf: work), Data([0, 255, 13, 10]))
        try await service.detachCheckout(.request(request.id))
        XCTAssertFalse(RequestProcessIdentity.evidenceExists(marker))
        XCTAssertEqual(try Data(contentsOf: work), Data([0, 255, 13, 10]))
        let archives = try FileManager.default.contentsOfDirectory(at: job, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("detached-") }
        XCTAssertEqual(archives.count, 1)
        XCTAssertTrue(RequestProcessIdentity.evidenceExists(archives[0].appendingPathComponent("supervision.json")))
        try await service.retryReconciliation()
        let recoveries = await service.recoveryStatuses(); XCTAssertTrue(recoveries.isEmpty)
    }
    func testMaintenanceRecoveryDoesNotResetRetryForReplacedCheckoutIdentity() async throws {
        let (root, script) = try recoveryFixture(), gitdir = try initializeRecoveryGit(root)
        var configuration = ShaderRequestConfiguration(repository: root.path); configuration.checkoutID = "original-checkout"
        try Data("replacement-checkout".utf8).write(to: gitdir.appendingPathComponent("holodeck-checkout-id"))
        let journal = root.appendingPathComponent("publication"), key = RequestPaths.canonical(journal)
        var operation = try RequestWorkerOperation.begin(mode: "publication", configuration: configuration, in: journal)
        operation.phase = .paused; try operation.save(in: journal)
        var store = RequestRecoveryStore()
        store.entries[key] = .init(journal: key, requestID: nil, configuration: configuration, disposition: .resume, message: "Original failure")
        try JSONEncoder().encode(store).write(to: root.appendingPathComponent("recovery.json"))
        let service = try await recoveryService(root, script: script, enabled: false)
        do { try await service.retryReconciliation(); XCTFail("Replaced checkout replenished the retry") } catch {}
        XCTAssertEqual(try RequestWorkerOperation.read(in: journal)?.id, operation.id)
        XCTAssertEqual(try RequestWorkerOperation.read(in: journal)?.phase, .paused)
    }

    func testCleanupRepairPersistenceFailureLeavesRecordsPreferencesAndBindingUntouched() async throws {
        let (root, script) = try recoveryFixture(), gitdir = try initializeRecoveryGit(root)
        let initial = try await recoveryService(root, script: script)
        let request = ShaderRequest(prompt: "Repair write failure", context: try context())
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        try await initial.cancelQueued(request.id)
        let job = root.appendingPathComponent(request.id.uuidString)
        try JSONSerialization.data(withJSONObject: ["id": request.id.uuidString, "directory": RequestPaths.canonical(job)]).write(to: gitdir.appendingPathComponent("holodeck-request-owner.json"))
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("journal.json"))) as? [[String: Any]])
        records[0]["cleanupPending"] = true; records[0]["cleanupFailure"] = "Original cleanup failure"
        try JSONSerialization.data(withJSONObject: records).write(to: root.appendingPathComponent("journal.json"))
        let configuration = try JSONDecoder().decode(ShaderRequestConfiguration.self, from: JSONSerialization.data(withJSONObject: records[0]["configuration"]!))
        try JSONEncoder().encode(configuration).write(to: root.appendingPathComponent("preferences.json"))
        var operation = try RequestWorkerOperation.begin(mode: "discard", configuration: configuration, in: job)
        operation.phase = .paused; try operation.save(in: job)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
            workerScript: script, recoveryWriter: { data, file in
                let store = try JSONDecoder().decode(RequestRecoveryStore.self, from: data)
                if store.entries.values.contains(where: { $0.configurationRepair != nil }) { throw POSIXError(.ENOSPC) }
                try RequestJournalWriter.write(data, to: file)
            })
        await service.suspend(); try await service.initialize(configuration: configuration)
        let recordBytes = try Data(contentsOf: root.appendingPathComponent("journal.json")), preferences = try Data(contentsOf: root.appendingPathComponent("preferences.json"))
        let binding = try Data(contentsOf: job.appendingPathComponent("configuration.json"))
        do { try await service.retryCleanup(request.id, repository: root.path, python: "/corrected/python", git: "/usr/bin/git"); XCTFail("Failed intent write continued") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("journal.json")), recordBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("preferences.json")), preferences)
        XCTAssertEqual(try Data(contentsOf: job.appendingPathComponent("configuration.json")), binding)
        XCTAssertEqual(try RequestWorkerOperation.read(in: job)?.id, operation.id)
        XCTAssertEqual(try RequestWorkerOperation.read(in: job)?.phase, .paused)
    }

    func testVerifyExposesLegacyMismatchRecoveryAndExplicitRecoveryRepairsIt() async throws {
        let (root, script) = try recoveryFixture(); _ = try initializeRecoveryGit(root)
        let configuration = ShaderRequestConfiguration(repository: root.path), journal = root.appendingPathComponent("setup")
        let original = try RequestWorkerOperation.begin(mode: "preflight", configuration: configuration, in: journal)
        let legacy: [String: Any] = ["formatVersion": 1, "id": UUID().uuidString, "mode": "preflight", "phase": "initial"]
        try JSONSerialization.data(withJSONObject: legacy).write(to: journal.appendingPathComponent(RequestWorkerOperation.filename))
        let service = try await recoveryService(root, script: script, enabled: false); await service.resume()
        do { try await service.verify(configuration: configuration); XCTFail("Unexplained binding was accepted") } catch {}
        let entries = await service.recoveryStatuses()
        XCTAssertTrue(entries.contains { $0.journal.map { RequestPaths.canonical($0) } == RequestPaths.canonical(journal) })
        XCTAssertEqual(try RequestWorkerOperation.expectedID(in: journal), original.id)
        try await service.retryReconciliation()
        try await service.verify(configuration: configuration)
        let accepted = await service.configurationValue(); XCTAssertTrue(accepted.enabled)
        let remaining = await service.recoveryStatuses(); XCTAssertTrue(remaining.isEmpty)
    }

    func testUnexpectedSignalAfterLaunchRemainsRetryableSupervision() async throws {
        let (root, script) = try recoveryFixture()
        try "import os,signal;print('{\"event\":\"ready\"}',flush=True);os.kill(os.getpid(),signal.SIGKILL)".write(to: script, atomically: true, encoding: .utf8)
        let worker = RequestWorkerProcess(script: script)
        do {
            for try await _ in worker.run(mode: "run", configuration: .init(repository: root.path), directory: root.appendingPathComponent("job")) {}
            XCTFail("Killed worker succeeded")
        } catch {
            XCTAssertEqual((error as? RequestWorkerSupervisionError)?.retryable, true)
            XCTAssertTrue(error.localizedDescription.contains("signal 9"))
        }
        try await worker.waitForExit()
    }

    func testManualRecoveryDrainsSupersededObserverBeforeStartingAnotherPass() async throws {
        let gate = ReconciliationRetryGate(), recorder = JournalVisitRecorder()
        let f = try await publicationRecoveryFixture(reconcile: { journal in
            await recorder.record(journal); try await gate.reconcile(journal)
        })
        await f.service.resume(); try await waitFor { await gate.entered }
        let retry = Task { try await f.service.retryReconciliation() }
        try await waitFor { !(await f.service.canDisableRequests()) }
        let publication = f.root.appendingPathComponent("publication")
        let beforeDrain = await recorder.count(publication); XCTAssertEqual(beforeDrain, 1)
        await gate.release(); try await retry.value
        let afterDrain = await recorder.count(publication); XCTAssertEqual(afterDrain, 2)
        let statuses = await f.service.recoveryStatuses(); XCTAssertTrue(statuses.isEmpty)
        let allowed = await f.service.canDisableRequests(); XCTAssertTrue(allowed)
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

#if os(macOS)
private final class BootIdentityProbe: @unchecked Sendable {
    private let lock = NSLock();private var count = 0
    let boot = UUID().uuidString.lowercased()
    func read() -> String? { lock.withLock { count += 1;return count == 1 ? nil : boot } }
    var calls: Int { lock.withLock{count} }
}
private final class EmptyObservationProbe: @unchecked Sendable {
    private let lock = NSLock();private var value = 0
    func observe() { lock.withLock{value += 1} }
    var count: Int { lock.withLock{value} }
}
private final class InjectedOwnershipProbe: @unchecked Sendable {
    private let lock = NSLock();private var live: [Int32:RequestProcessIdentity];private var clock = 0.0;private var signals: [Int32] = []
    init(_ identities: [RequestProcessIdentity]) { live = Dictionary(uniqueKeysWithValues:identities.map{($0.pid,$0)}) }
    func identity(_ pid: Int32) -> RequestProcessIdentity? { lock.withLock{live[pid]} }
    func group(_ pid: Int32) -> [RequestProcessIdentity] { lock.withLock{live[pid].map{[$0]} ?? []} }
    func signal(_ pid: Int32, _ signal: Int32) -> Int32 { lock.withLock{signals.append(pid);live[pid] = nil};return 0 }
    func wait(_ amount: Double) { lock.withLock{clock += amount} }
    var now: Double { lock.withLock{clock} }
    var signalled: [Int32] { lock.withLock{signals} }
}
private actor CleanupEvidenceProbe {
    private var calls = 0
    func reconcile() throws { calls += 1;if calls == 2 { throw RequestWorkerEvidenceError(cause:"Prelaunch cleanup evidence is invalid") } }
}
private final class SignalRecordingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(Int32,Int32)] = []
    func signal(_ pid: Int32, _ signal: Int32) -> Int32 { lock.withLock { calls.append((pid,signal)) };return kill(pid,signal) }
    func signals(for pid: Int32) -> [Int32] { lock.withLock { calls.filter{$0.0 == pid}.map{$0.1} } }
}
private final class RequestSignalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var signals = 0
    func signal(_ pid: Int32, _ signal: Int32) -> Int32 { lock.withLock { signals += 1 }; return 0 }
    var signalCount: Int { lock.withLock { signals } }
}
private actor ReconciliationRetryGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func reconcile(_ folder: URL) async throws {
        if !entered {
            entered = true
            await withCheckedContinuation { continuation = $0 }
            throw ShaderRequestError.unavailable("Old failed reconciliation")
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}
#endif

#if os(macOS)
private actor WorkerExitFailureGate {
    func wait(_ worker: RequestWorkerProcess) async throws {
        try await worker.waitForExit()
        throw RequestWorkerTeardownError(cause: "Injected final teardown failure")
    }
}
private actor DetachRecoveryFailureGate {
    func reconcile(_ journal: URL) throws { throw RequestWorkerTeardownError(cause: "Injected live descendants") }
}
#endif

#if os(macOS)
private final class WorkerWaitCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func record() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
#endif

#if os(macOS)
private final class RecoveryWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var first: RequestRecoveryStore.Entry?
    func record(_ data: Data) {
        guard let store = try? JSONDecoder().decode(RequestRecoveryStore.self,from:data),
              let entry = store.entries.values.first(where: { $0.journal.hasSuffix("/selection") }) else { return }
        lock.withLock { if first == nil { first = entry } }
    }
    var firstSelection: RequestRecoveryStore.Entry? { lock.withLock { first } }
}
#endif

#if os(macOS)
private actor JournalVisitRecorder {
    private var visits: [String: Int] = [:]
    func record(_ journal: URL) { visits[RequestPaths.canonical(journal), default: 0] += 1 }
    func count(_ journal: URL) -> Int { visits[RequestPaths.canonical(journal), default: 0] }
}
#endif

#if os(macOS)
private actor DisableEligibilityRecorder {
    private(set) var completedWhileBlocked = false
    private(set) var lastAllowed = false
    func record(_ allowed: Bool, completed: Bool) {
        lastAllowed = allowed
        if completed && !allowed { completedWhileBlocked = true }
    }
}
#endif

#if os(macOS)
private final class NativeObservationProbe: @unchecked Sendable {
    private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var remaining: Int, held: Bool, count = 0, clock: TimeInterval = 0
    init(failures: Int = 0, held: Bool = false) { remaining = failures; self.held = held }
    var calls: Int { lock.withLock { count } }
    var entered: Bool { calls > 0 }
    var now: TimeInterval { lock.withLock { clock } }
    func advance(_ duration: TimeInterval) { lock.withLock { clock += duration } }
    func release() { gate.signal() }
    func observe(_ pid: Int32) throws -> [RequestProcessIdentity] {
        let (wait, fail) = lock.withLock { () -> (Bool, Bool) in
            count += 1
            let wait = held; held = false
            let fail = remaining > 0
            if fail { remaining -= 1 }
            return (wait, fail)
        }
        if wait { _ = gate.wait(timeout: .now() + 5) }
        if fail { throw POSIXError(.EIO) }
        return try RequestProcessIdentity.checkedGroup(pid)
    }
}
#endif

#if os(macOS)
private final class WorkerCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var descendants = false
    private var first: Int32?
    func observe(_ values: [RequestProcessIdentity]) { lock.withLock { descendants = descendants || values.count >= 3 } }
    var hasDescendants: Bool { lock.withLock { descendants } }
    var firstPID: Int32? { lock.withLock { first } }
    func signal(_ pid: Int32, _ value: Int32) -> Int32 {
        lock.withLock { if first == nil { first = pid } }
        return kill(pid,value)
    }
}
#endif

#if os(macOS)
private final class PausedIdentityProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false, held = false, observed = false
    func armOnce() {
        condition.lock();defer { condition.unlock() }
        if !armed { armed = true;held = true }
    }
    var entered: Bool { condition.lock();defer { condition.unlock() };return observed }
    func release() { condition.lock();held = false;condition.broadcast();condition.unlock() }
    func identity(_ pid: Int32) -> RequestProcessIdentity? {
        condition.lock()
        if held { observed = true }
        while held { condition.wait() }
        condition.unlock()
        return RequestProcessIdentity(pid:pid)
    }
}
#endif
