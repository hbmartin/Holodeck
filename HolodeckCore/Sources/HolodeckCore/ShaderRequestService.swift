#if os(macOS)
import Foundation
import Darwin

nonisolated public struct ShaderRequestConfiguration: Codable, Sendable, Equatable {
    public var repository: String
    public var codex: String
    public var python: String
    public var git: String
    public var shaderTool: String
    public var model: String
    public var reasoning: String
    public var checkoutID: String?
    public var enabled: Bool
    public init(repository: String = "", codex: String = "/opt/homebrew/bin/codex", python: String = "/usr/bin/python3",
                git: String = "/usr/bin/git", shaderTool: String = "", model: String = "", reasoning: String = "high", enabled: Bool = false) {
        self.repository = repository; self.codex = codex; self.python = python; self.git = git
        self.shaderTool = shaderTool; self.model = model; self.reasoning = reasoning; self.enabled = enabled
    }
}

nonisolated struct RequestWorkerEvent: Decodable, Sendable {
    var event: String
    var stage: String?
    var message: String?
    var question: String?
    var options: [String]?
    var requiredPreviewShaderIDs: [String]?
    var checkoutID: String?
    var result: ShaderRequestResult?
}

/// Reading subprocess pipes never occupies the UI or the catalog/server actor.
nonisolated final class RequestWorkerProcess: @unchecked Sendable {
    static var bundledScript: URL? { Bundle.module.url(forResource: "shader_requests", withExtension: "py") }
    let process = Process()
    private let scriptOverride: URL?
    init(script: URL? = nil) { scriptOverride = script }
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private let lock = NSLock()
    private let drained = DispatchGroup()
    private var started = false
    private var stopping = false
    private var escalation: DispatchWorkItem?
    var beforeReplyWrite: (() -> Void)?
    func reply(_ accepted: Bool, message: String? = nil) throws {
        struct Reply: Encodable { let ok: Bool; let message: String? }
        try lock.withLock {
            guard started, !stopping, process.isRunning else { throw CancellationError() }
            beforeReplyWrite?()
            var bytes = try JSONEncoder().encode(Reply(ok: accepted, message: message)); bytes.append(10)
            try input.fileHandleForWriting.write(contentsOf: bytes)
        }
    }
    func stop() {
        lock.withLock {
            stopping = true
            guard started else { return }
            // The Python worker and its descendants form one process group.
            if kill(-process.processIdentifier, SIGTERM) != 0, process.isRunning { process.terminate() }
            if escalation == nil {
                let escalation = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        guard self.stopping else { return }
                        if kill(-self.process.processIdentifier, 0) == 0 { kill(-self.process.processIdentifier, SIGKILL) }
                        else if self.process.isRunning { self.process.terminate() }
                    }
                }
                self.escalation = escalation
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: escalation)
            }
        }
    }
    func run(mode: String, configuration: ShaderRequestConfiguration, directory: URL) -> AsyncThrowingStream<RequestWorkerEvent, Error> {
        AsyncThrowingStream { continuation in
            drained.enter()
            DispatchQueue(label: "Holodeck.request-worker").async { [self] in
                defer {
                    lock.withLock { escalation?.cancel(); escalation = nil }
                    drained.leave()
                }
                do {
                    guard let script = scriptOverride ?? Self.bundledScript else {
                        throw ShaderRequestError.unavailable("Bundled shader request worker is missing.")
                    }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let config = directory.appendingPathComponent("configuration.json")
                    try JSONEncoder().encode(configuration).write(to: config, options: .atomic)
                    process.executableURL = URL(fileURLWithPath: configuration.python)
                    process.arguments = [script.path, mode, config.path, directory.path]
                    process.standardInput = input; process.standardOutput = output; process.standardError = error
                    process.currentDirectoryURL = URL(fileURLWithPath: configuration.repository)
                    let logURL = directory.appendingPathComponent("worker.log")
                    if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
                    let log = try FileHandle(forWritingTo: logURL)
                    try log.seekToEnd()
                    defer { try? log.close() }
                    // stderr has its own drain, including failures before the Python bridge starts.
                    let stderrURL = directory.appendingPathComponent("worker-stderr.log")
                    if !FileManager.default.fileExists(atPath: stderrURL.path) { FileManager.default.createFile(atPath: stderrURL.path, contents: nil) }
                    let stderrLog = try FileHandle(forWritingTo: stderrURL)
                    try stderrLog.seekToEnd()
                    let stderrDrained = DispatchGroup()
                    defer { stderrDrained.wait(); try? stderrLog.close() }
                    try lock.withLock {
                        guard !stopping else { throw CancellationError() }
                        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        try process.run(); started = true
                    }
                    stderrDrained.enter()
                    DispatchQueue(label: "Holodeck.request-worker.stderr").async { [self] in
                        defer { stderrDrained.leave() }
                        while true {
                            let bytes = error.fileHandleForReading.availableData
                            if bytes.isEmpty { break }
                            try? stderrLog.write(contentsOf: bytes)
                        }
                    }
                    try JSONEncoder().encode(WorkerIdentity(pid: process.processIdentifier, script: script.path, directory: directory.path))
                        .write(to: directory.appendingPathComponent("process.json"), options: .atomic)
                    var pending = Data()
                    while true {
                        let chunk = output.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        try log.write(contentsOf: chunk)
                        pending.append(chunk)
                        while let newline = pending.firstIndex(of: 10) {
                            let line = pending[..<newline]
                            pending.removeSubrange(...newline)
                            if let event = try? JSONDecoder().decode(RequestWorkerEvent.self, from: Data(line)) {
                                continuation.yield(event)
                            }
                        }
                    }
                    process.waitUntilExit()
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("process.json"))
                    if process.terminationStatus != 0 {
                        throw ShaderRequestError.unavailable("Worker exited \(process.terminationStatus). See its retained log.")
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.stop() }
            }
        }
    }

    func waitForExit() async {
        await Task.detached { [self] in
            let pid = process.processIdentifier
            for _ in 0..<100 {
                let descendants = pid > 1 && kill(-pid, 0) == 0
                if !process.isRunning, !descendants { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if pid > 1 { kill(-pid, SIGKILL) }
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            while pid > 1, kill(-pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(50)) }
        }.value
        // Also finish pipe draining and identity-file cleanup before reusing this journal.
        await withCheckedContinuation { continuation in
            drained.notify(queue: .global()) { continuation.resume() }
        }
    }

    private struct WorkerIdentity: Codable { let pid: Int32; let script: String; let directory: String }
    static func reconcileOrphan(in directory: URL) throws {
        let file = directory.appendingPathComponent("process.json")
        guard let bytes = try? Data(contentsOf: file), let identity = try? JSONDecoder().decode(WorkerIdentity.self, from: bytes) else { return }
        guard identity.pid > 1, URL(fileURLWithPath: identity.directory).standardizedFileURL == directory.standardizedFileURL else {
            throw ShaderRequestError.unavailable("Worker identity does not belong to this request journal.")
        }
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", String(identity.pid), "-o", "command="]
        task.standardOutput = pipe
        try task.run()
        let command = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        // Never signal a reused PID whose command does not belong to this exact journal.
        if command.contains(identity.script), command.contains(identity.directory) {
            kill(-identity.pid, SIGTERM)
            for _ in 0..<50 {
                if kill(-identity.pid, 0) != 0 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if kill(-identity.pid, 0) == 0 {
                // A PID can be reused during the grace period; recheck before escalation.
                let verification = Process(), output = Pipe()
                verification.executableURL = URL(fileURLWithPath: "/bin/ps")
                verification.arguments = ["-p", String(identity.pid), "-o", "command="]
                verification.standardOutput = output
                try verification.run()
                let current = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                verification.waitUntilExit()
                if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    (current.contains(identity.script) && current.contains(identity.directory)) {
                    kill(-identity.pid, SIGKILL)
                    while kill(-identity.pid, 0) == 0 { Thread.sleep(forTimeInterval: 0.05) }
                }
            }
        }
        try? FileManager.default.removeItem(at: file)
    }
}

public struct ShaderRequestRecoveryStatus: Sendable, Identifiable {
    public let id: UUID
    public let repository: String
    public let python: String
    public let git: String
    public let message: String
    public let isRunning: Bool
}

public actor ShaderRequestService {
    private struct Record: Codable, Sendable {
        var status: ShaderRequestStatus
        var configuration: ShaderRequestConfiguration
        var revoked = false
        var deliveryNonce: String?
        var cleanupPending: Bool?
        var cleanupFailure: String?
        var cleanupMessage: String?
        var interrupted: Bool?
        var executionID: UUID?
        var detached: Bool?
    }
    private let directory: URL
    private let catalog: DirectoryCatalog
    private let workerScript: URL?
    private var configuration = ShaderRequestConfiguration()
    private var records: [UUID: Record] = [:]
    private var observers: [UUID: AsyncStream<[ShaderRequestStatus]>.Continuation] = [:]
    private var activeID: UUID?
    private var activeProcess: RequestWorkerProcess?
    private var workerTask: Task<Void, Never>?
    private var preparedID: UUID?
    private struct Execution { let id = UUID(); var interrupted = false }
    private var execution: Execution?
    private var maintenanceBusy = false
    private var reconciliationTask: Task<UUID?, Error>?
    private var reconciled = false
    private var reconciling = false
    private var latestWarnings: [ShaderPreviewWarning] = []
    private var suspended = false
    private var loaded = false
    private var recoveryID: UUID?
    private var setupMessage = "Enable shader requests in Mac Settings."

    public init(catalog: DirectoryCatalog, directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Holodeck/Requests")) {
        self.catalog = catalog; self.directory = directory; self.workerScript = nil
    }
    init(catalog: DirectoryCatalog, directory: URL, workerScript: URL) {
        self.catalog = catalog; self.directory = directory; self.workerScript = workerScript
    }
    private func workerProcess() -> RequestWorkerProcess { RequestWorkerProcess(script: workerScript) }

    public func start(configuration: ShaderRequestConfiguration) throws {
        try load()
        let preferences = directory.appendingPathComponent("preferences.json")
        self.configuration = (try? Data(contentsOf: preferences)).flatMap { try? JSONDecoder().decode(ShaderRequestConfiguration.self, from: $0) } ?? configuration
        if !configuration.shaderTool.isEmpty { self.configuration.shaderTool = configuration.shaderTool }
        setupMessage = self.configuration.enabled ? "Ready for shader requests" : "Enable shader requests in Mac Settings."
        kick()
    }
    private func load() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("journal.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let saved = try JSONDecoder().decode([Record].self, from: Data(contentsOf: file))
            records = Dictionary(uniqueKeysWithValues: saved.map { ($0.status.id, $0) })
            let active = directory.appendingPathComponent("active.json")
            if let bytes = try? Data(contentsOf: active), let id = try? JSONDecoder().decode(UUID.self, from: bytes),
               let stage = records[id]?.status.stage, (!stage.terminal || records[id]?.cleanupPending == true), stage != .awaitingActivation, stage != .awaitingClarification {
                recoveryID = id
                if !stage.terminal {
                    records[id]?.status.stage = .repairing
                    records[id]?.status.message = "Recovering interrupted request"
                }
            }
        }
        for id in records.keys {
            if records[id]?.revoked == true, records[id]?.status.stage.terminal == false, records[id]?.detached != true {
                records[id]?.cleanupPending = true
                records[id]?.cleanupMessage = "TV access was revoked; any pushed commit remains"
                records[id]?.status.stage = .failed
                records[id]?.status.message = "TV access was revoked; checkout cleanup is pending"
            }
            // A restart makes one new recovery attempt after the operator can repair the host.
            records[id]?.cleanupFailure = nil
        }
        loaded = true
        try persist()
    }
    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString) }
    public func artifacts(for id: UUID) -> URL { folder(id) }
    public func configurationValue() -> ShaderRequestConfiguration { configuration }
    public func hasPendingCleanup() -> Bool { records.values.contains { $0.cleanupPending == true } }
    public func publicationWarnings() -> [ShaderPreviewWarning] { latestWarnings }
    public func recoveryStatuses() -> [ShaderRequestRecoveryStatus] {
        records.values.filter { $0.cleanupPending == true }.map {
            ShaderRequestRecoveryStatus(id: $0.status.id, repository: $0.configuration.repository,
                python: $0.configuration.python, git: $0.configuration.git,
                message: $0.cleanupFailure ?? $0.cleanupMessage ?? "Checkout cleanup is pending",
                isRunning: activeID == $0.status.id)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func reconcileWorkers() async throws {
        guard !reconciled else { return }
        if reconciliationTask == nil {
            let folders = records.keys.map { folder($0) } + [directory.appendingPathComponent("setup"), directory.appendingPathComponent("publication")]
            let known = records.values.filter { $0.detached != true }.map { ($0.status.id, $0.configuration, folder($0.status.id)) }
            reconciliationTask = Task.detached {
                for folder in folders { try RequestWorkerProcess.reconcileOrphan(in: folder) }
                var inspected: Set<String> = []
                for (_, configuration, _) in known {
                    let key = configuration.repository + "\0" + configuration.git
                    guard inspected.insert(key).inserted, let gitdir = try? Self.gitDirectory(configuration),
                          let bytes = try? BoundedCatalogReader(root: gitdir).read("holodeck-request-owner.json", limit: CatalogLimits.headBytes).bytes,
                          let owner = try? JSONSerialization.jsonObject(with: bytes) as? [String: String],
                          let ownerID = owner["id"].flatMap(UUID.init(uuidString:)) else { continue }
                    // Only journal-owned identities and their exact artifact directory are eligible.
                    if let match = known.first(where: { $0.0 == ownerID && $0.2.path == owner["directory"] }) { return match.0 }
                }
                return nil
            }
        }
        let discoveredOwner = try await reconciliationTask?.value
        guard !reconciled else { return }
        if let owner = discoveredOwner, records[owner]?.detached != true {
            recoveryID = owner
            if let stage = records[owner]?.status.stage, stage.terminal || stage == .awaitingActivation || stage == .awaitingClarification {
                records[owner]?.cleanupPending = true
                records[owner]?.cleanupMessage = "Cleaning interrupted owned work; pushed commits are retained"
                if !stage.terminal { try update(owner, stage: .failed, message: "Interrupted checkout cleanup is required") }
                else { try persist() }
            }
        }
        reconciled = true
    }

    public func retryCleanup(_ id: UUID, repository: String, python: String, git: String) async throws {
        guard activeID == nil, !maintenanceBusy, let record = records[id], record.cleanupPending == true else {
            throw ShaderRequestError.unavailable("Wait for active checkout work to finish before retrying cleanup.")
        }
        maintenanceBusy = true
        defer { maintenanceBusy = false; kick() }
        var corrected = record.configuration
        corrected.repository = repository; corrected.python = python; corrected.git = git
        let job = folder(id)
        try await reconcileWorkers()
        try await Task.detached { try Self.validateRecoveryCheckout(corrected, id: id, job: job) }.value
        guard records[id]?.detached != true else { throw CancellationError() }
        let previous = record.configuration
        for key in records.keys where records[key]?.detached != true {
            guard let existing = records[key]?.configuration else { continue }
            let same: Bool
            if let identity = previous.checkoutID, let other = existing.checkoutID { same = identity == other }
            else { same = existing.repository == previous.repository }
            if same {
                records[key]?.configuration.repository = repository
                records[key]?.configuration.python = python; records[key]?.configuration.git = git
            }
        }
        if previous.checkoutID.map({ configuration.checkoutID == $0 }) ?? (configuration.repository == previous.repository) {
            configuration.repository = repository; configuration.python = python; configuration.git = git
            try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
        }
        records[id]?.cleanupFailure = nil; recoveryID = id
        try persist()
    }

    public func detachCheckout(_ id: UUID? = nil) async throws {
        let selected = id.flatMap { records[$0]?.configuration } ?? configuration
        let ids = records.keys.filter { key in
            guard let candidate = records[key]?.configuration else { return false }
            if let identity = selected.checkoutID, let other = candidate.checkoutID { return identity == other }
            return URL(fileURLWithPath: candidate.repository).standardizedFileURL == URL(fileURLWithPath: selected.repository).standardizedFileURL
        }
        guard activeID == nil || ids.contains(activeID!) else {
            throw ShaderRequestError.unavailable("Wait for the other checkout’s active request before detaching this checkout.")
        }
        configuration.enabled = false
        execution?.interrupted = true
        activeProcess?.stop()
        for key in ids {
            records[key]?.detached = true; records[key]?.interrupted = true
            records[key]?.cleanupPending = false; records[key]?.cleanupFailure = nil
            if records[key]?.status.stage.terminal == false {
                try update(key, stage: .failed, message: "Checkout detached; unpublished files and evidence were retained")
            }
        }
        try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
        if let activeProcess { await activeProcess.waitForExit() }
        if let workerTask { await workerTask.value }
        try await reconcileWorkers()
        setupMessage = "Requests disabled. Select a checkout and verify setup before enabling requests again."
        try persist()
    }

    /// Rebuild from a clean checkout under the Python worker's existing cross-process lease.
    public func ensurePublication() async throws {
        guard !maintenanceBusy, activeID == nil, !hasPendingCleanup() else {
            throw ShaderRequestError.unavailable("Finish checkout recovery before rebuilding the library.")
        }
        maintenanceBusy = true
        let operation = Execution(); execution = operation
        let process = workerProcess(); activeProcess = process
        defer { activeProcess = nil; execution = nil; maintenanceBusy = false; kick() }
        try await reconcileWorkers()
        try checkExecution(operation.id)
        do {
            if try await catalog.cached() != nil { return }
        } catch is CancellationError { throw CancellationError() }
        catch { Diagnostics.catalog.error("Previous publication unavailable; rebuilding from the authoring checkout: \(error.localizedDescription, privacy: .public)") }
        do {
            var ready = false
            for try await event in process.run(mode: "publication", configuration: configuration, directory: directory.appendingPathComponent("publication")) {
                try checkExecution(operation.id)
                switch event.event {
                case "preparePublication": try await preparePublication(event, process: process, operation: operation.id)
                case "publicationReady": ready = true
                case "failure": throw ShaderRequestError.unavailable(event.message ?? "Publication rebuild failed")
                default: break
                }
            }
            await process.waitForExit()
            try checkExecution(operation.id)
            guard ready, let preparedID else { throw ShaderRequestError.unavailable("Publication rebuild did not complete.") }
            let publication = try await catalog.install(preparedID)
            self.preparedID = nil; latestWarnings = publication.previewWarnings
            try persist()
        } catch {
            process.stop(); await process.waitForExit()
            if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
            throw error
        }
    }

    private func checkExecution(_ id: UUID) throws {
        guard execution?.id == id, execution?.interrupted == false, !suspended else { throw CancellationError() }
    }

    private func preparePublication(_ event: RequestWorkerEvent, process: RequestWorkerProcess, operation: UUID) async throws {
        if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
        let prepared: PreparedCatalogPublication
        do {
            prepared = try await catalog.prepare(from: URL(fileURLWithPath: configurationForActiveWorker.repository))
        } catch {
            try checkExecution(operation)
            try process.reply(false, message: error.localizedDescription)
            return
        }
        do {
            try checkExecution(operation)
            if let required = event.requiredPreviewShaderIDs {
                guard required.count <= CatalogLimits.shaderCount, Set(required).count == required.count,
                      required.allSatisfy(ShaderRequest.validID) else { throw ShaderRequestError.invalidRequest }
            }
            let failures = prepared.previewWarnings.filter { event.requiredPreviewShaderIDs?.contains($0.shaderID) ?? true }
            if !failures.isEmpty {
                await catalog.discard(prepared.id)
                try process.reply(false, message: failures.map { "\($0.shaderID): \($0.message)" }.joined(separator: "\n"))
            } else {
                preparedID = prepared.id
                try process.reply(true)
            }
        } catch { await catalog.discard(prepared.id); throw error }
    }
    private var configurationForActiveWorker: ShaderRequestConfiguration { activeID.flatMap { records[$0]?.configuration } ?? configuration }

    public func allJobs() -> [ShaderRequestStatus] { records.values.map(\.status).sorted { $0.createdAt > $1.createdAt } }
    public func updates() -> AsyncStream<[ShaderRequestStatus]> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation; continuation.yield(allJobs())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func persist() throws {
        try JSONEncoder().encode(Array(records.values)).write(to: directory.appendingPathComponent("journal.json"), options: .atomic)
        for observer in observers.values { observer.yield(allJobs()) }
    }
    private func update(_ id: UUID, stage: ShaderRequestStatus.Stage, message: String) throws {
        records[id]?.status.stage = stage; records[id]?.status.message = message
        records[id]?.status.updatedAt = Date(); records[id]?.status.sequence &+= 1
        try persist()
    }
    public func verify(configuration candidate: ShaderRequestConfiguration) async throws {
        try load()
        guard activeID == nil, !maintenanceBusy, !records.values.contains(where: { !$0.status.stage.terminal || $0.cleanupPending == true }) else {
            throw ShaderRequestError.unavailable("Finish or cancel queued requests before changing setup.")
        }
        var candidate = candidate
        candidate.checkoutID = nil
        let process = workerProcess()
        var verified = false
        for try await event in process.run(mode: "preflight", configuration: candidate, directory: directory.appendingPathComponent("setup")) {
            if event.event == "failure" { throw ShaderRequestError.unavailable(event.message ?? "Setup failed") }
            if event.event == "preflight" { verified = true; candidate.checkoutID = event.checkoutID }
        }
        guard verified else { throw ShaderRequestError.unavailable("Setup did not complete.") }
        configuration = candidate; configuration.enabled = true
        try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
        setupMessage = "Ready for shader requests"
        try persist(); kick()
    }
    public func disable() throws {
        guard activeID == nil, !maintenanceBusy, !records.values.contains(where: { !$0.status.stage.terminal || $0.cleanupPending == true }) else {
            throw ShaderRequestError.unavailable("Requests are still in progress.")
        }
        configuration.enabled = false; setupMessage = "Shader requests are disabled."
        try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
        try persist()
    }
    public func cancelQueued(_ id: UUID) throws {
        guard records[id]?.status.stage == .queued, activeID != id else {
            throw ShaderRequestError.unavailable("Only queued requests can be cancelled.")
        }
        try update(id, stage: .cancelled, message: "Cancelled on the Mac")
        kick()
    }
    public func deleteFinished(_ id: UUID) throws {
        guard records[id]?.status.stage.terminal == true, records[id]?.cleanupPending != true, activeID != id else { throw ShaderRequestError.invalidRequest }
        try FileManager.default.removeItem(at: folder(id)); records[id] = nil; try persist()
    }
    public func revoke(_ deviceID: String) throws {
        for id in records.keys where records[id]?.status.deviceID == deviceID && records[id]?.status.stage.terminal == false {
            records[id]?.revoked = true
            if records[id]?.status.stage == .queued, activeID != id {
                try update(id, stage: .cancelled, message: "TV access was revoked")
            } else if activeID != id {
                records[id]?.cleanupPending = true
                records[id]?.cleanupMessage = "TV access was revoked; any pushed commit remains"
                try update(id, stage: .failed, message: "TV access was revoked; checkout cleanup is pending")
            }
        }
        try persist(); kick()
    }

    public func control(operation: String, payload: ShaderRequestControl, deviceID: String) async throws -> ShaderRequestControlReply {
        try load()
        if operation == "requestSubmit" {
            guard configuration.enabled, !hasPendingCleanup() else { throw ShaderRequestError.unavailable(setupMessage) }
            guard let request = payload.request else { throw ShaderRequestError.invalidRequest }
            try request.validate()
            if let existing = records[request.id] {
                guard existing.status.deviceID == deviceID else { throw ShaderRequestError.notFound }
                let original = try JSONDecoder().decode(ShaderRequest.self, from: Data(contentsOf: folder(request.id).appendingPathComponent("request.json")))
                guard original == request else { throw ShaderRequestError.invalidRequest }
                return try await reply(deviceID: deviceID, requestID: request.id)
            }
            if request.purpose == .performance, let existing = records.values.first(where: {
                $0.status.deviceID == deviceID && !$0.status.stage.terminal && $0.status.request.purpose == .performance &&
                $0.status.request.context.shaderID == request.context.shaderID && $0.status.request.context.sourceHash == request.context.sourceHash
            }) { return try await reply(deviceID: deviceID, requestID: existing.status.id) }
            if request.purpose == .creative, records.values.contains(where: {
                $0.status.deviceID == deviceID && $0.status.blocksBrowsing
            }) { throw ShaderRequestError.unavailable("This TV already has a manual request in progress.") }
            let job = folder(request.id)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            try JSONEncoder().encode(request).write(to: job.appendingPathComponent("request.json"), options: .atomic)
            var lightweight = request
            lightweight.context.source = ""; lightweight.context.screenshot = Data()
            records[request.id] = Record(status: ShaderRequestStatus(request: lightweight, deviceID: deviceID), configuration: configuration)
            try persist() // Acknowledgement follows durable acceptance.
            kick()
            return try await reply(deviceID: deviceID, requestID: request.id)
        }
        if operation == "requestAnswer" || operation == "requestActivated" || operation == "requestDelivery" {
            guard let id = payload.requestID, let record = records[id], record.status.deviceID == deviceID, !record.revoked else {
                throw ShaderRequestError.notFound
            }
            if operation == "requestDelivery" {
                guard let nonce = payload.answer, UUID(uuidString: nonce) != nil else { throw ShaderRequestError.invalidRequest }
                if record.status.stage == .awaitingActivation, record.deliveryNonce != nonce {
                    records[id]?.deliveryNonce = nonce
                    try update(id, stage: .queued, message: "Refreshing latest committed result for this TV")
                    kick()
                }
            } else if operation == "requestAnswer" {
                guard record.status.stage == .awaitingClarification, let answer = payload.answer,
                      !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.utf8.count <= 16_384 else {
                    throw ShaderRequestError.invalidRequest
                }
                try JSONEncoder().encode(answer).write(to: folder(id).appendingPathComponent("answer.json"), options: .atomic)
                records[id]?.status.clarification = nil
                try update(id, stage: .queued, message: "Ready to continue after clarification")
                kick()
            } else if record.status.stage == .awaitingActivation {
                if let diagnostic = payload.diagnostic {
                    guard diagnostic.utf8.count <= 16_384 else { throw ShaderRequestError.invalidRequest }
                    try JSONEncoder().encode(["attemptID": UUID().uuidString, "shaderID": record.status.result?.shaderID ?? "", "diagnostic": diagnostic])
                        .write(to: folder(id).appendingPathComponent("repair.json"), options: .atomic)
                    try update(id, stage: .repairing, message: "Repairing the TV activation error")
                    kick()
                } else {
                    guard (record.status.request.purpose == .performance && payload.sourceHash == nil) ||
                          (payload.sourceHash.map({ CatalogHash.isSHA($0) }) == true && payload.sourceHash == record.status.result?.deliveredSourceHash) else {
                        throw ShaderRequestError.invalidRequest
                    }
                    records[id]?.status.result?.deliveredSourceHash = payload.sourceHash
                    try update(id, stage: .completed, message: record.status.result?.summary ?? "Request completed")
                }
            }
        }
        return try await reply(deviceID: deviceID, requestID: payload.requestID)
    }
    private func reply(deviceID: String, requestID: UUID?) async throws -> ShaderRequestControlReply {
        let owned = allJobs().filter { $0.deviceID == deviceID }
        let jobs = requestID.map { id in owned.filter { $0.id == id } } ?? owned.filter { !$0.stage.terminal }
        return ShaderRequestControlReply(enabled: configuration.enabled && !hasPendingCleanup(), message: setupMessage, jobs: jobs,
                                        publicationRevision: await catalog.publicationRevisionValue())
    }
    private func kick() {
        guard loaded, !suspended, !maintenanceBusy, activeID == nil else { return }
        if !reconciled {
            guard !reconciling else { return }
            reconciling = true
            Task {
                do { try await reconcileWorkers(); reconciling = false; kick() }
                catch { reconciling = false; setupMessage = "Worker recovery failed: " + error.localizedDescription; try? persist() }
            }
            return
        }
        let eligible = records.values.filter { !$0.revoked && $0.detached != true }.map(\.status)
        if let recoveryID, records[recoveryID]?.cleanupFailure != nil { return }
        let ownerCleanup = recoveryID.flatMap { records[$0]?.cleanupPending == true ? $0 : nil }
        let cleanupID = ownerCleanup ?? records.values.filter { $0.cleanupPending == true && $0.cleanupFailure == nil }.sorted { $0.status.createdAt < $1.status.createdAt }.first?.status.id
        let interrupted = recoveryID.flatMap { id -> UUID? in
            guard configuration.enabled, let value = records[id], !value.revoked, value.detached != true,
                  value.cleanupPending != true, value.status.stage == .repairing || value.status.stage == .queued else { return nil }
            return id
        }
        guard let id = interrupted ?? cleanupID ?? (configuration.enabled && !hasPendingCleanup() ? ShaderRequestScheduling.next(in: eligible, recoveringID: recoveryID) : nil) else { return }
        let operation = Execution(); execution = operation
        do {
            try JSONEncoder().encode(id).write(to: directory.appendingPathComponent("active.json"), options: .atomic)
            records[id]?.executionID = operation.id; records[id]?.interrupted = false
            if cleanupID == nil { try update(id, stage: .implementing, message: "Preparing the managed checkout") }
            else { try persist() }
        } catch {
            execution = nil; try? update(id, stage: .failed, message: error.localizedDescription)
            return
        }
        activeID = id
        workerTask = Task { [weak self] in
            if cleanupID != nil { await self?.cleanup(id, operation: operation.id) }
            else { await self?.execute(id, operation: operation.id) }
        }
    }
    private func cleanup(_ id: UUID, operation: UUID) async {
        guard let record = records[id] else { activeID = nil; return }
        let process = workerProcess(); activeProcess = process
        do {
            let job = folder(id)
            try await Task.detached { try RequestWorkerProcess.reconcileOrphan(in: job) }.value
            var discarded = false
            for try await event in process.run(mode: "discard", configuration: record.configuration, directory: job) {
                if event.event == "failure" { throw ShaderRequestError.unavailable(event.message ?? "Cleanup failed") }
                if event.event == "discarded" { discarded = true }
            }
            await process.waitForExit()
            try checkExecution(operation)
            guard discarded else { throw ShaderRequestError.unavailable("Cleanup did not complete.") }
            records[id]?.cleanupPending = false; records[id]?.cleanupFailure = nil
            try update(id, stage: .failed, message: record.cleanupMessage ?? "TV access was revoked; any pushed commit remains")
        } catch {
            process.stop(); await process.waitForExit()
            if execution?.interrupted == false, records[id]?.detached != true {
                records[id]?.cleanupFailure = error.localizedDescription
                setupMessage = "Checkout recovery is required. Correct the saved folder/tool paths and retry cleanup, or detach the checkout."
                try? update(id, stage: .failed, message: "Cleanup failed: \(error.localizedDescription). \(setupMessage)")
            }
        }
        finishWorker(id)
    }
    private func finishWorker(_ id: UUID) {
        let interrupted = execution?.interrupted == true
        activeProcess = nil; activeID = nil; workerTask = nil; execution = nil
        if records[id]?.detached != true, records[id]?.cleanupPending == true || (interrupted && records[id]?.status.stage.terminal == false) {
            recoveryID = id
            if !suspended { kick() }
        } else {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("active.json"))
            if recoveryID == id { recoveryID = nil }
            kick()
        }
    }
    private func execute(_ id: UUID, operation: UUID) async {
        guard let record = records[id] else { activeID = nil; return }
        let process = workerProcess(); activeProcess = process
        var outcomeSeen = false
        do {
            let job = folder(id)
            try await Task.detached { try RequestWorkerProcess.reconcileOrphan(in: job) }.value
            for try await event in process.run(mode: "run", configuration: record.configuration, directory: job) {
                try checkExecution(operation)
                switch event.event {
                case "stage":
                    if let value = event.stage, let stage = ShaderRequestStatus.Stage(rawValue: value) {
                        try update(id, stage: stage, message: event.message ?? value)
                    }
                case "preparePublication":
                    try await preparePublication(event, process: process, operation: operation)
                case "discardPublication":
                    if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
                case "clarification":
                    if records[id]?.revoked == true {
                        records[id]?.cleanupPending = true
                        records[id]?.cleanupMessage = "TV access was revoked; any pushed commit remains"
                    }
                    records[id]?.status.clarification = ShaderClarification(question: event.question ?? "Please clarify the request", options: event.options ?? [])
                    try update(id, stage: records[id]?.revoked == true ? .failed : .awaitingClarification,
                               message: records[id]?.revoked == true ? "Discarding revoked unpublished work" : "Waiting for a TV answer")
                    outcomeSeen = true
                case "result":
                    guard let result = event.result, ShaderRequest.validID(result.shaderID), let preparedID else {
                        throw ShaderRequestError.invalidRequest
                    }
                    try update(id, stage: .publishing, message: "Installing the committed library")
                    let publication = try await catalog.install(preparedID)
                    self.preparedID = nil
                    latestWarnings = publication.previewWarnings
                    records[id]?.status.result = result
                    if records[id]?.revoked == true {
                        try update(id, stage: .failed, message: "Pushed successfully; TV access was revoked")
                        outcomeSeen = true
                        continue
                    }
                    guard let output = publication.catalog.shaders.first(where: { $0.id == result.shaderID }) else {
                        try JSONEncoder().encode(["attemptID": UUID().uuidString, "shaderID": result.shaderID, "diagnostic": "The committed output was removed before TV delivery. Recreate it under a fresh unused ID."])
                            .write(to: job.appendingPathComponent("repair.json"), options: .atomic)
                        try update(id, stage: .repairing, message: "Recreating the output removed before delivery")
                        outcomeSeen = true
                        continue
                    }
                    records[id]?.status.result?.deliveredSourceHash = output.sourceHash
                    try update(id, stage: records[id]?.revoked == true ? .failed : .awaitingActivation,
                               message: records[id]?.revoked == true ? "Pushed successfully; TV access was revoked" : "Waiting for the TV to play the result")
                    outcomeSeen = true
                case "failure": throw ShaderRequestError.unavailable(event.message ?? "Shader request failed")
                default: break
                }
            }
            try checkExecution(operation)
            if !outcomeSeen { throw ShaderRequestError.unavailable("Worker ended without a verified result.") }
        } catch {
            process.stop()
            if execution?.interrupted == false, records[id]?.detached != true {
                records[id]?.cleanupPending = true
                records[id]?.cleanupMessage = error.localizedDescription
                try? update(id, stage: .failed, message: error.localizedDescription)
            }
        }
        // A suspended/revoked process must release its lease before recovery or cleanup starts.
        if execution?.interrupted == true { process.stop() }
        await process.waitForExit()
        if records[id]?.revoked == true, records[id]?.status.stage.terminal == false, records[id]?.detached != true {
            records[id]?.cleanupPending = true
            records[id]?.cleanupMessage = "TV access was revoked; any pushed commit remains"
            try? update(id, stage: .failed, message: "TV access was revoked; checkout cleanup is pending")
        }
        if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
        finishWorker(id)
    }
    public func suspend() {
        suspended = true; execution?.interrupted = true
        if let id = activeID {
            records[id]?.interrupted = true
            if records[id]?.status.stage.terminal == false {
                try? update(id, stage: .repairing, message: "Waiting for the Mac to resume")
            } else { try? persist() }
        }
        activeProcess?.stop()
    }
    public func resume() { suspended = false; kick() }

    nonisolated private static func gitDirectory(_ configuration: ShaderRequestConfiguration) throws -> URL {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.git)
        process.arguments = ["rev-parse", "--absolute-git-dir"]
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.repository)
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        defer { watchdog.cancel() }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ShaderRequestError.unavailable(String(decoding: error, as: UTF8.self)) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated private static func validateRecoveryCheckout(_ configuration: ShaderRequestConfiguration, id: UUID, job: URL) throws {
        let gitdir = try gitDirectory(configuration)
        let owner = (try? Data(contentsOf: gitdir.appendingPathComponent("holodeck-request-owner.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        let identity = (try? String(contentsOf: gitdir.appendingPathComponent("holodeck-checkout-id"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let owned = owner?["id"]?.lowercased() == id.uuidString.lowercased() && owner?["directory"] == job.path
        let sameCheckout = configuration.checkoutID != nil && identity == configuration.checkoutID
        guard owned || sameCheckout, owner == nil || owned else {
            throw ShaderRequestError.unavailable("Selected checkout does not belong to this request. Locate its owned checkout or detach it without deleting files.")
        }
    }

}
#endif
