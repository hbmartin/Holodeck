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
                let warnings = await service.publicationStatus()?.warnings ?? []
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
        try await service.initialize(configuration: .init(repository: authoring.path, enabled: true))
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
            await initial.suspend(); try await initial.start(configuration: .init(repository: authoring.path, enabled: true))
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
            try await service.initialize(configuration: .init(repository: authoring.path, enabled: true))
            try await service.ensurePublication()
            let order = try String(contentsOf: root.appendingPathComponent("operation-order"), encoding: .utf8).split(separator: "\n").map(String.init)
            XCTAssertEqual(order, interrupted ? ["run:" + owner.id.uuidString, "discard:" + owner.id.uuidString, "publication:publication"] : ["publication:publication"])
            let jobs = await service.allJobs()
            XCTAssertEqual(jobs.first { $0.id == queued.id }?.stage, .queued)
            await service.activateScheduling()
            try await waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent(queued.id.uuidString).appendingPathComponent("worker-started").path) }
            try await service.detachCheckout(queued.id)
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
        try await service.initialize(configuration: .init(repository: authoring.path, enabled: true))
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

    func testDetachedAcknowledgementSurvivesDeletionAndReverificationAcrossAliases() async throws {
        let (root, script) = try recoveryFixture(), initial = try await recoveryService(root, script: script)
        let request = ShaderRequest(prompt: "Detach", context: try context())
        _ = try await initial.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        let gitdir = try initializeRecoveryGit(root)
        let job = root.appendingPathComponent(request.id.uuidString), alias = root.appendingPathComponent("job-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: job)
        let marker = gitdir.appendingPathComponent("holodeck-request-owner.json")
        try JSONSerialization.data(withJSONObject: ["id": request.id.uuidString, "directory": alias.path]).write(to: marker)
        try await initial.detachCheckout(request.id)
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
        addTeardownBlock { try? await service.detachCheckout(owner.id) }
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
        let worker = RequestWorkerProcess(script: script, groups: .init(isAlive: { probe.alive($0) }, signal: { probe.signal($0, $1) }, schedule: { probe.schedule($0) }))
        for try await _ in worker.run(mode: "run", configuration: .init(repository: root.path), directory: root.appendingPathComponent("completed")) {}
        try await worker.waitForExit()
        probe.reuseGroup()
        worker.stop(); worker.stop()
        probe.fireTimers()
        XCTAssertEqual(probe.signalCount, 0)
        XCTAssertEqual(probe.timerCount, 0)
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
        try await service.retryReconciliation()
        await gate.release()
        do { try await old.value; XCTFail("Old attempt unexpectedly succeeded") } catch {}
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
        try await service.detachCheckout(request.id)
        let restarted = try await recoveryService(root, script: script)
        let configuration = await restarted.configurationValue(), statuses = await restarted.allJobs()
        XCTAssertFalse(configuration.enabled)
        XCTAssertEqual(statuses.first?.stage, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let evidence = try FileManager.default.contentsOfDirectory(atPath: job.path)
        XCTAssertTrue(evidence.contains { $0.hasPrefix("process-detached-") })
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
        try await service.initialize(configuration: .init(repository: authoring.path, enabled: true))
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
            try await service.detachCheckout(queued.id)
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
            if mode == "detach" { try await f.service.detachCheckout() }
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
            await f.service.resume(); try await f.service.retryReconciliation()
            try await waitFor { await preparation.entered }
            await reconciliation.release()
            do { try await old.value; XCTFail("Old reconciliation unexpectedly succeeded") } catch {}
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
            let restarted = try await recoveryService(root, script: script)
            try await restarted.retryReconciliation()
            await restarted.resume()
            try await waitFor { (try? String(contentsOf: job.appendingPathComponent("worker-count"), encoding: .utf8)) == "2" }
            let status = await restarted.allJobs().first
            XCTAssertFalse(status?.stage.terminal ?? true); XCTAssertFalse(status?.message.contains("revoked") ?? true)
            await restarted.suspend()
            try await restarted.detachCheckout(request.id)
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
        await service.suspend(); try await service.start(configuration: .init(repository: authoring.path, enabled: true))
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
        do { try await service.detachCheckout(request.id); XCTFail("Incomplete teardown detached") } catch is RequestWorkerTeardownError {}
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
        try await original.detachCheckout(request.id)
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
        let status = await service.recoveryStatuses().first { $0.kind == .reconciliation }
        XCTAssertNil(status?.checkout); XCTAssertEqual(status?.journal?.resolvingSymlinksInPath(), journal.resolvingSymlinksInPath())
        do { try await service.detachCheckout(); XCTFail("Guessed current checkout") }
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
            } catch { XCTAssertEqual((error as? POSIXError)?.code, .ENOSPC) }
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
        try await service.detachCheckout(first.id)
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
        try await original.detachCheckout(request.id)
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
        try await service.detachCheckout()
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
        try await service.detachCheckout()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: publication.path).contains { $0.hasPrefix("process-detached-") })
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
        }
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
private final class RequestSignalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reused = false
    private var signals = 0
    private var timers: [DispatchWorkItem] = []
    func alive(_ pid: Int32) -> Bool { lock.withLock { reused || (pid > 1 && kill(-pid, 0) == 0) } }
    func signal(_ pid: Int32, _ signal: Int32) -> Int32 { lock.withLock { signals += 1 }; return 0 }
    func schedule(_ item: DispatchWorkItem) { lock.withLock { timers.append(item) } }
    func reuseGroup() { lock.withLock { reused = true } }
    func fireTimers() { let items = lock.withLock { timers }; items.forEach { $0.perform() } }
    var signalCount: Int { lock.withLock { signals } }
    var timerCount: Int { lock.withLock { timers.count } }
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
