#if os(macOS)
import Foundation
import Darwin

nonisolated enum RequestPaths {
    static func canonical(_ url: URL, remainingLinks: Int = 40) -> String {
        if let path = realpath(url.path, nil) { defer { free(path) }; return String(cString: path) }
        if remainingLinks > 0, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            let destination = target.hasPrefix("/") ? URL(fileURLWithPath: target)
                : url.deletingLastPathComponent().appendingPathComponent(target)
            return canonical(destination.standardizedFileURL, remainingLinks: remainingLinks - 1)
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return url.standardizedFileURL.path }
        return URL(fileURLWithPath: canonical(parent, remainingLinks: remainingLinks)).appendingPathComponent(url.lastPathComponent).path
    }
}

nonisolated struct DetachedCheckoutAcknowledgement: Codable, Sendable, Equatable {
    var requestID: UUID
    var directory: String
    var repository: String
    var checkoutID: String?
}

nonisolated public struct ShaderRequestConfiguration: Codable, Sendable, Equatable {
    public var repository: String
    public var codex: String
    public var python: String
    public var git: String
    public var shaderTool: String
    public var model: String
    public var reasoning: String
    public var checkoutID: String?
    var detachedOwner: DetachedCheckoutAcknowledgement?
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
    struct GroupOperations: Sendable {
        var isAlive: @Sendable (Int32) -> Bool = { $0 > 1 && kill(-$0, 0) == 0 }
        var signal: @Sendable (Int32, Int32) -> Int32 = { kill(-$0, $1) }
        var schedule: @Sendable (DispatchWorkItem) -> Void = { DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: $0) }
    }
    static var bundledScript: URL? { Bundle.module.url(forResource: "shader_requests", withExtension: "py") }
    let process = Process()
    private let scriptOverride: URL?
    private let groups: GroupOperations
    init(script: URL? = nil, groups: GroupOperations = .init()) { scriptOverride = script; self.groups = groups }
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private let lock = NSLock()
    private let drained = DispatchGroup()
    private var started = false
    private var stopping = false
    private var groupRetired = false
    private var completed = false
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
            guard !completed, !groupRetired else { return }
            stopping = true
            guard started else { return }
            guard groupIsLiveLocked() else { return }
            // The Python worker and its descendants form one process group.
            if groups.signal(process.processIdentifier, SIGTERM) != 0, process.isRunning { process.terminate() }
            if escalation == nil {
                let escalation = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        guard self.stopping, !self.completed, self.groupIsLiveLocked() else { return }
                        if self.groups.isAlive(self.process.processIdentifier) { _ = self.groups.signal(self.process.processIdentifier, SIGKILL) }
                        else if self.process.isRunning { self.process.terminate() }
                    }
                }
                self.escalation = escalation
                groups.schedule(escalation)
            }
        }
    }
    // Once disappearance is observed, this instance never consults or signals that PGID again.
    private func groupIsLiveLocked() -> Bool {
        guard started, !groupRetired else { return false }
        if !process.isRunning, !groups.isAlive(process.processIdentifier) {
            groupRetired = true; escalation?.cancel(); escalation = nil
            return false
        }
        return true
    }
    func run(mode: String, configuration: ShaderRequestConfiguration, directory: URL) -> AsyncThrowingStream<RequestWorkerEvent, Error> {
        AsyncThrowingStream { continuation in
            drained.enter()
            DispatchQueue(label: "Holodeck.request-worker").async { [self] in
                defer {
                    lock.withLock { completed = !started || !groupIsLiveLocked() }
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
                if !lock.withLock({ groupIsLiveLocked() }) { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            lock.withLock { if groupIsLiveLocked(), pid > 1 { _ = groups.signal(pid, SIGKILL) } }
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            while lock.withLock({ groupIsLiveLocked() }) { try? await Task.sleep(for: .milliseconds(50)) }
        }.value
        // Also finish pipe draining and identity-file cleanup before reusing this journal.
        await withCheckedContinuation { continuation in
            drained.notify(queue: .global()) { continuation.resume() }
        }
        lock.withLock { completed = true; groupRetired = true; escalation?.cancel(); escalation = nil }
    }

    private struct WorkerIdentity: Codable { let pid: Int32; let script: String; let directory: String }
    static func reconcileOrphan(in directory: URL) throws {
        let file = directory.appendingPathComponent("process.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let bytes = try Data(contentsOf: file)
        guard let identity = try? JSONDecoder().decode(WorkerIdentity.self, from: bytes) else {
            throw ShaderRequestError.unavailable("Worker identity is unreadable. Repair the journal marker or detach the checkout while retaining its evidence.")
        }
        guard identity.pid > 1, RequestPaths.canonical(URL(fileURLWithPath: identity.directory)) == RequestPaths.canonical(directory) else {
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
    public enum Kind: Sendable { case cleanup, reconciliation }
    public let id: UUID
    public let kind: Kind
    public let repository: String
    public let python: String
    public let git: String
    public let message: String
    public let isRunning: Bool
}

public struct ShaderRequestPublicationStatus: Sendable {
    public let revision: String
    public let sequence: UInt64
    public let warnings: [ShaderPreviewWarning]
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
    private let reconcileWorker: @Sendable (URL) async throws -> Void
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
    private struct ReconciliationAttempt { let id = UUID(); let task: Task<UUID?, Error> }
    private var reconciliationTask: ReconciliationAttempt?
    private var reconciled = false
    private var reconciliationKickID: UUID?
    private var reconciliationFailure: String?
    private static let reconciliationStatusID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var latestPublication: ShaderRequestPublicationStatus?
    private var publicationSequence: UInt64 = 0
    private struct PublicationWaiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private struct PublicationRequest { var force: Bool; var waiters: [PublicationWaiter] }
    private var pendingPublication: PublicationRequest?
    private var activePublication: PublicationRequest?
    private enum ScheduledWork { case execute(UUID), cleanup(UUID), publication }
    private var schedulingActive = false
    private var initialized = false
    private var detachedOwners: [DetachedCheckoutAcknowledgement] = []
    private var suspended = false
    private var loaded = false
    private var recoveryID: UUID?
    private var setupMessage = "Enable shader requests in Mac Settings."

    public init(catalog: DirectoryCatalog, directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Holodeck/Requests")) {
        self.catalog = catalog; self.directory = directory; self.workerScript = nil
        self.reconcileWorker = { try RequestWorkerProcess.reconcileOrphan(in: $0) }
    }
    init(catalog: DirectoryCatalog, directory: URL, workerScript: URL,
         reconcileWorker: @escaping @Sendable (URL) async throws -> Void = { try RequestWorkerProcess.reconcileOrphan(in: $0) }) {
        self.catalog = catalog; self.directory = directory; self.workerScript = workerScript
        self.reconcileWorker = reconcileWorker
    }
    private func workerProcess() -> RequestWorkerProcess { RequestWorkerProcess(script: workerScript) }

    public func start(configuration: ShaderRequestConfiguration) throws {
        try initialize(configuration: configuration)
        activateScheduling()
    }
    public func initialize(configuration: ShaderRequestConfiguration) throws {
        try load()
        let preferences = directory.appendingPathComponent("preferences.json")
        self.configuration = (try? Data(contentsOf: preferences)).flatMap { try? JSONDecoder().decode(ShaderRequestConfiguration.self, from: $0) } ?? configuration
        if !configuration.shaderTool.isEmpty { self.configuration.shaderTool = configuration.shaderTool }
        if detachedOwners.contains(where: { Self.sameCheckout(self.configuration, repository: $0.repository, checkoutID: $0.checkoutID) }) {
            self.configuration.enabled = false
        }
        initialized = true
        setupMessage = self.configuration.enabled ? "Ready for shader requests" : "Enable shader requests in Mac Settings."
    }
    public func activateScheduling() { schedulingActive = true; kick() }
    private func load() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("journal.json")
        let acknowledgements = directory.appendingPathComponent("detached-checkouts.json")
        let hasAcknowledgements = FileManager.default.fileExists(atPath: acknowledgements.path)
        if hasAcknowledgements { detachedOwners = try JSONDecoder().decode([DetachedCheckoutAcknowledgement].self, from: Data(contentsOf: acknowledgements)) }
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
            if !hasAcknowledgements, records[id]?.detached == true, let record = records[id] {
                detachedOwners.append(Self.acknowledgement(id: id, job: folder(id), configuration: record.configuration))
            }
            if detachedOwners.contains(where: { $0.requestID == id }) {
                records[id]?.detached = true; records[id]?.cleanupPending = false
                if records[id]?.status.stage.terminal == false {
                    records[id]?.status.stage = .failed
                    records[id]?.status.message = "Checkout detached; unpublished files and evidence were retained"
                }
            }
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
    public func publicationStatus() async -> ShaderRequestPublicationStatus? {
        let revision = await catalog.publicationRevisionValue()
        guard let latestPublication, latestPublication.revision == revision else { return nil }
        return latestPublication
    }
    var pendingPublicationWaiterCount: Int { pendingPublication?.waiters.count ?? 0 }
    private func published(_ publication: CatalogReloadResult) {
        publicationSequence &+= 1
        latestPublication = ShaderRequestPublicationStatus(revision: publication.catalog.publicationRevision,
            sequence: publicationSequence, warnings: publication.previewWarnings)
    }
    public func recoveryStatuses() -> [ShaderRequestRecoveryStatus] {
        var statuses = records.values.filter { $0.cleanupPending == true }.map {
            ShaderRequestRecoveryStatus(id: $0.status.id, kind: .cleanup, repository: $0.configuration.repository,
                python: $0.configuration.python, git: $0.configuration.git,
                message: $0.cleanupFailure ?? $0.cleanupMessage ?? "Checkout cleanup is pending",
                isRunning: activeID == $0.status.id)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        if let reconciliationFailure {
            statuses.append(ShaderRequestRecoveryStatus(id: Self.reconciliationStatusID, kind: .reconciliation,
                repository: configuration.repository, python: configuration.python, git: configuration.git,
                message: reconciliationFailure, isRunning: reconciliationTask != nil))
        }
        return statuses
    }

    private func reconcileWorkers() async throws {
        guard !reconciled else { return }
        if reconciliationTask == nil {
            let folders = records.values.filter { $0.detached != true }.map { folder($0.status.id) }
                + [directory.appendingPathComponent("setup"), directory.appendingPathComponent("publication")]
            let known = records.values.filter { $0.detached != true }.map { ($0.status.id, $0.configuration, folder($0.status.id)) }
            let reconcile = reconcileWorker
            reconciliationTask = ReconciliationAttempt(task: Task.detached {
                for folder in folders { try await reconcile(folder) }
                var inspected: Set<String> = []
                for (_, configuration, _) in known {
                    let key = configuration.repository + "\0" + configuration.git
                    guard inspected.insert(key).inserted, let gitdir = try? Self.gitDirectory(configuration),
                          let bytes = try? BoundedCatalogReader(root: gitdir).read("holodeck-request-owner.json", limit: CatalogLimits.headBytes).bytes,
                          let owner = try? JSONSerialization.jsonObject(with: bytes) as? [String: String],
                          let ownerID = owner["id"].flatMap(UUID.init(uuidString:)) else { continue }
                    if let match = known.first(where: {
                        $0.0 == ownerID && owner["directory"].map { RequestPaths.canonical(URL(fileURLWithPath: $0)) } == RequestPaths.canonical($0.2)
                    }) { return match.0 }
                }
                return nil
            })
        }
        guard let attempt = reconciliationTask else { return }
        do {
            let discoveredOwner = try await attempt.task.value
            guard reconciliationTask?.id == attempt.id else { return }
            if let owner = discoveredOwner, records[owner]?.detached != true {
                recoveryID = owner
                if let stage = records[owner]?.status.stage, stage.terminal || stage == .awaitingActivation || stage == .awaitingClarification {
                    records[owner]?.cleanupPending = true
                    records[owner]?.cleanupMessage = "Cleaning interrupted owned work; pushed commits are retained"
                    if !stage.terminal { try update(owner, stage: .failed, message: "Interrupted checkout cleanup is required") }
                    else { try persist() }
                } else if records[owner]?.status.stage != .repairing {
                    try update(owner, stage: .repairing, message: "Recovering interrupted owned work")
                }
            }
            reconciled = true; reconciliationTask = nil; reconciliationFailure = nil
        } catch {
            if reconciliationTask?.id == attempt.id {
                reconciliationTask = nil; reconciliationFailure = "Worker recovery failed: " + error.localizedDescription
                setupMessage = reconciliationFailure!
                try? persist()
            }
            throw error
        }
    }

    public func retryReconciliation() async throws {
        guard activeID == nil, !maintenanceBusy else { throw ShaderRequestError.unavailable("Wait for active checkout work to finish.") }
        reconciled = false
        // Existing waiters retain their own attempt identity and cannot clear a subsequent retry.
        reconciliationTask = nil; reconciliationKickID = nil
        try await reconcileWorkers()
        try persist(); kick()
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
        reconciled = false; reconciliationTask = nil; reconciliationKickID = nil
        try persist()
        try await reconcileWorkers()
    }

    public func detachCheckout(_ id: UUID? = nil) async throws {
        let selected = id.flatMap { records[$0]?.configuration } ?? configuration
        let ids = records.keys.filter { key in
            guard let candidate = records[key]?.configuration else { return false }
            return Self.sameCheckout(candidate, repository: selected.repository, checkoutID: selected.checkoutID)
        }
        guard activeID == nil || ids.contains(activeID!) else {
            throw ShaderRequestError.unavailable("Wait for the other checkout’s active request before detaching this checkout.")
        }
        configuration.enabled = false
        execution?.interrupted = true
        for key in ids {
            guard let record = records[key] else { continue }
            let acknowledgement = Self.acknowledgement(id: key, job: folder(key), configuration: record.configuration)
            detachedOwners.removeAll { $0.requestID == key }; detachedOwners.append(acknowledgement)
            records[key]?.detached = true; records[key]?.interrupted = true
            records[key]?.cleanupPending = false; records[key]?.cleanupFailure = nil
            if !record.status.stage.terminal {
                records[key]?.status.stage = .failed
                records[key]?.status.message = "Checkout detached; unpublished files and evidence were retained"
            }
        }
        // Durable intent precedes all asynchronous teardown, including for terminal records.
        try persist()
        try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
        let cancellation = CancellationError()
        for waiter in pendingPublication?.waiters ?? [] { waiter.continuation.resume(throwing: cancellation) }
        pendingPublication = nil
        for waiter in activePublication?.waiters ?? [] { waiter.continuation.resume(throwing: cancellation) }
        activePublication?.waiters = []
        activeProcess?.stop()
        if let activeProcess { await activeProcess.waitForExit() }
        if let workerTask { await workerTask.value }
        let folders = ids.map { folder($0) } + [directory.appendingPathComponent("setup"), directory.appendingPathComponent("publication")]
        for folder in folders {
            do { try await Task.detached { try RequestWorkerProcess.reconcileOrphan(in: folder) }.value }
            catch {
                // Quarantine an unverifiable app-owned marker as evidence; never signal its PID.
                let marker = folder.appendingPathComponent("process.json")
                if FileManager.default.fileExists(atPath: marker.path) {
                    try FileManager.default.moveItem(at: marker, to: folder.appendingPathComponent("process-detached-" + UUID().uuidString + ".json"))
                }
            }
        }
        reconciled = false; reconciliationTask = nil; reconciliationKickID = nil; reconciliationFailure = nil
        setupMessage = "Requests disabled. Select a checkout and verify setup before enabling requests again."
        try persist()
    }

    /// Cache restoration and forced rebuilds share the checkout scheduler with recovery and jobs.
    public func ensurePublication(force: Bool = false) async throws {
        guard initialized else { throw ShaderRequestError.unavailable("Initialize shader requests before preparing the library.") }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                var request = pendingPublication ?? PublicationRequest(force: force, waiters: [])
                request.force = request.force || force
                request.waiters.append(PublicationWaiter(id: id, continuation: continuation))
                pendingPublication = request
                kick()
            }
        } onCancel: { Task { await self.cancelPublicationWaiter(id) } }
    }
    private func cancelPublicationWaiter(_ id: UUID) {
        if let index = pendingPublication?.waiters.firstIndex(where: { $0.id == id }) {
            pendingPublication?.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
            if pendingPublication?.waiters.isEmpty == true { pendingPublication = nil }
        }
        if let index = activePublication?.waiters.firstIndex(where: { $0.id == id }) {
            activePublication?.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
            if activePublication?.waiters.isEmpty == true { execution?.interrupted = true; activeProcess?.stop() }
        }
    }
    private func runPublication(operation: UUID) async {
        let process = workerProcess(); activeProcess = process
        do {
            if activePublication?.force != true {
                do {
                    if try await catalog.cached() != nil { try checkExecution(operation); finishPublication(); return }
                } catch is CancellationError { throw CancellationError() }
                catch { Diagnostics.catalog.error("Previous publication unavailable; rebuilding: \(error.localizedDescription, privacy: .public)") }
            }
            try checkExecution(operation)
            var ready = false
            for try await event in process.run(mode: "publication", configuration: configuration, directory: directory.appendingPathComponent("publication")) {
                try checkExecution(operation)
                switch event.event {
                case "preparePublication": try await preparePublication(event, process: process, operation: operation)
                case "publicationReady": ready = true
                case "failure": throw ShaderRequestError.unavailable(event.message ?? "Publication rebuild failed")
                default: break
                }
            }
            await process.waitForExit()
            try checkExecution(operation)
            guard ready, let preparedID else { throw ShaderRequestError.unavailable("Publication rebuild did not complete.") }
            let publication = try await catalog.install(preparedID)
            self.preparedID = nil; published(publication)
            try persist()
            finishPublication()
        } catch {
            process.stop(); await process.waitForExit()
            if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
            if execution?.interrupted == true, activePublication?.waiters.isEmpty == false {
                let request = activePublication!
                if pendingPublication == nil { pendingPublication = request }
                else {
                    var pending = pendingPublication!
                    pending.force = pending.force || request.force; pending.waiters += request.waiters
                    pendingPublication = pending
                }
                activePublication = nil
                finishPublication()
            } else { finishPublication(error: error) }
        }
    }
    private func finishPublication(error: Error? = nil) {
        let waiters = activePublication?.waiters ?? []
        activePublication = nil; activeProcess = nil; execution = nil; maintenanceBusy = false; workerTask = nil
        for waiter in waiters {
            if let error { waiter.continuation.resume(throwing: error) }
            else { waiter.continuation.resume() }
        }
        kick()
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
        try JSONEncoder().encode(detachedOwners).write(to: directory.appendingPathComponent("detached-checkouts.json"), options: .atomic)
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
        maintenanceBusy = true
        defer { maintenanceBusy = false; kick() }
        try await reconcileWorkers()
        let acknowledgements = detachedOwners
        let checkout = candidate
        candidate.detachedOwner = try await Task.detached { try Self.detachedOwner(for: checkout, acknowledgements: acknowledgements) }.value
        candidate.checkoutID = nil
        let process = workerProcess(), operation = Execution()
        activeProcess = process; execution = operation
        defer { activeProcess = nil; execution = nil }
        var verified = false
        do {
            for try await event in process.run(mode: "preflight", configuration: candidate, directory: directory.appendingPathComponent("setup")) {
                try checkExecution(operation.id)
                if event.event == "failure" { throw ShaderRequestError.unavailable(event.message ?? "Setup failed") }
                if event.event == "preflight" { verified = true; candidate.checkoutID = event.checkoutID }
            }
            await process.waitForExit()
            try checkExecution(operation.id)
            guard verified else { throw ShaderRequestError.unavailable("Setup did not complete.") }
        } catch {
            process.stop(); await process.waitForExit()
            throw error
        }
        candidate.detachedOwner = nil
        configuration = candidate; configuration.enabled = true
        detachedOwners.removeAll { Self.sameCheckout(candidate, repository: $0.repository, checkoutID: $0.checkoutID) }
        if !initialized { initialized = true; schedulingActive = true }
        try persist()
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
        guard loaded, initialized, !suspended, !maintenanceBusy, activeID == nil, workerTask == nil else { return }
        if !reconciled {
            guard reconciliationKickID == nil else { return }
            let id = UUID(); reconciliationKickID = id
            Task {
                do {
                    try await reconcileWorkers()
                    guard reconciliationKickID == id else { return }
                    reconciliationKickID = nil; kick()
                } catch {
                    guard reconciliationKickID == id else { return }
                    reconciliationKickID = nil
                }
            }
            return
        }
        let eligible = records.values.filter { !$0.revoked && $0.detached != true }.map(\.status)
        if let recoveryID, records[recoveryID]?.cleanupFailure != nil { return }
        let ownerCleanup = recoveryID.flatMap { records[$0]?.cleanupPending == true ? $0 : nil }
        let cleanupID = ownerCleanup ?? records.values.filter { $0.cleanupPending == true && $0.cleanupFailure == nil }.sorted { $0.status.createdAt < $1.status.createdAt }.first?.status.id
        let interrupted = recoveryID.flatMap { id -> UUID? in
            guard configuration.enabled, schedulingActive || pendingPublication != nil,
                  let value = records[id], !value.revoked, value.detached != true,
                  value.cleanupPending != true, value.status.stage == .repairing || value.status.stage == .queued else { return nil }
            return id
        }
        let work: ScheduledWork
        if let interrupted { work = .execute(interrupted) }
        else if let cleanupID { work = .cleanup(cleanupID) }
        else if hasPendingCleanup() { return }
        else if pendingPublication != nil { work = .publication }
        else if schedulingActive, configuration.enabled, let id = ShaderRequestScheduling.next(in: eligible, recoveringID: recoveryID) { work = .execute(id) }
        else { return }
        let operation = Execution(); execution = operation
        if case .publication = work {
            activePublication = pendingPublication; pendingPublication = nil; maintenanceBusy = true
            workerTask = Task { [weak self] in await self?.runPublication(operation: operation.id) }
            return
        }
        let id: UUID
        switch work { case .execute(let job), .cleanup(let job): id = job; case .publication: return }
        do {
            try JSONEncoder().encode(id).write(to: directory.appendingPathComponent("active.json"), options: .atomic)
            records[id]?.executionID = operation.id; records[id]?.interrupted = false
            if case .execute = work { try update(id, stage: .implementing, message: "Preparing the managed checkout") }
            else { try persist() }
        } catch {
            execution = nil; try? update(id, stage: .failed, message: error.localizedDescription)
            return
        }
        activeID = id
        workerTask = Task { [weak self] in
            switch work {
            case .cleanup(let id): await self?.cleanup(id, operation: operation.id)
            case .execute(let id): await self?.execute(id, operation: operation.id)
            case .publication: break
            }
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
                    published(publication)
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

    nonisolated private static func sameCheckout(_ configuration: ShaderRequestConfiguration, repository: String, checkoutID: String?) -> Bool {
        if let identity = configuration.checkoutID, let checkoutID { return identity == checkoutID }
        return RequestPaths.canonical(URL(fileURLWithPath: configuration.repository)) == RequestPaths.canonical(URL(fileURLWithPath: repository))
    }
    nonisolated private static func acknowledgement(id: UUID, job: URL, configuration: ShaderRequestConfiguration) -> DetachedCheckoutAcknowledgement {
        DetachedCheckoutAcknowledgement(requestID: id, directory: RequestPaths.canonical(job),
            repository: RequestPaths.canonical(URL(fileURLWithPath: configuration.repository)), checkoutID: configuration.checkoutID)
    }
    nonisolated private static func detachedOwner(for configuration: ShaderRequestConfiguration, acknowledgements: [DetachedCheckoutAcknowledgement]) throws -> DetachedCheckoutAcknowledgement? {
        guard !acknowledgements.isEmpty else { return nil }
        let gitdir = try gitDirectory(configuration)
        guard let bytes = try? BoundedCatalogReader(root: gitdir).read("holodeck-request-owner.json", limit: CatalogLimits.headBytes).bytes,
              let marker = try? JSONSerialization.jsonObject(with: bytes) as? [String: String],
              let id = marker["id"].flatMap(UUID.init(uuidString:)), let path = marker["directory"] else { return nil }
        let identity = (try? String(contentsOf: gitdir.appendingPathComponent("holodeck-checkout-id"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return acknowledgements.first {
            guard $0.requestID == id, RequestPaths.canonical(URL(fileURLWithPath: $0.directory)) == RequestPaths.canonical(URL(fileURLWithPath: path)) else { return false }
            if let expected = $0.checkoutID { return identity == expected }
            return RequestPaths.canonical(URL(fileURLWithPath: $0.repository)) == RequestPaths.canonical(URL(fileURLWithPath: configuration.repository))
        }
    }

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
        let owned = owner?["id"]?.lowercased() == id.uuidString.lowercased() && owner?["directory"].map { RequestPaths.canonical(URL(fileURLWithPath: $0)) } == RequestPaths.canonical(job)
        let sameCheckout = configuration.checkoutID != nil && identity == configuration.checkoutID
        guard owned || sameCheckout, owner == nil || owned else {
            throw ShaderRequestError.unavailable("Selected checkout does not belong to this request. Locate its owned checkout or detach it without deleting files.")
        }
    }

}
#endif
