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
    private var started = false
    private var stopping = false
    func reply(_ accepted: Bool) {
        lock.withLock {
            try? input.fileHandleForWriting.write(contentsOf: Data(("{\"ok\":\(accepted)}\n").utf8))
        }
    }
    func stop() {
        lock.withLock {
            stopping = true
            guard started, process.isRunning else { return }
            // The Python worker and its descendants form one process group.
            if kill(-process.processIdentifier, SIGTERM) != 0 { process.terminate() }
        }
    }
    func run(mode: String, configuration: ShaderRequestConfiguration, directory: URL) -> AsyncThrowingStream<RequestWorkerEvent, Error> {
        AsyncThrowingStream { continuation in
            DispatchQueue(label: "Holodeck.request-worker").async { [self] in
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
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                    let log = try FileHandle(forWritingTo: logURL)
                    try log.seekToEnd()
                    defer { try? log.close() }
                    // stderr has its own drain, including failures before the Python bridge starts.
                    let stderrURL = directory.appendingPathComponent("worker-stderr.log")
                    if !FileManager.default.fileExists(atPath: stderrURL.path) { FileManager.default.createFile(atPath: stderrURL.path, contents: nil) }
                    let stderrLog = try FileHandle(forWritingTo: stderrURL)
                    try stderrLog.seekToEnd()
                    error.fileHandleForReading.readabilityHandler = { handle in
                        let bytes = handle.availableData
                        if bytes.isEmpty { handle.readabilityHandler = nil }
                        else { try? stderrLog.write(contentsOf: bytes) }
                    }
                    try lock.withLock {
                        guard !stopping else { throw CancellationError() }
                        try process.run(); started = true
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
                    error.fileHandleForReading.readabilityHandler = nil
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
            for _ in 0..<100 {
                if !process.isRunning { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning { kill(-process.processIdentifier, SIGKILL) }
        }.value
    }

    private struct WorkerIdentity: Codable { let pid: Int32; let script: String; let directory: String }
    static func reconcileOrphan(in directory: URL) throws {
        let file = directory.appendingPathComponent("process.json")
        guard let bytes = try? Data(contentsOf: file), let identity = try? JSONDecoder().decode(WorkerIdentity.self, from: bytes) else { return }
        guard identity.pid > 1 else { return }
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
                if kill(identity.pid, 0) != 0 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if kill(identity.pid, 0) == 0 { kill(-identity.pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: file)
    }
}

public actor ShaderRequestService {
    private struct Record: Codable, Sendable {
        var status: ShaderRequestStatus
        var configuration: ShaderRequestConfiguration
        var revoked = false
        var deliveryNonce: String?
    }
    private let directory: URL
    private let catalog: DirectoryCatalog
    private var configuration = ShaderRequestConfiguration()
    private var records: [UUID: Record] = [:]
    private var observers: [UUID: AsyncStream<[ShaderRequestStatus]>.Continuation] = [:]
    private var activeID: UUID?
    private var activeProcess: RequestWorkerProcess?
    private var workerTask: Task<Void, Never>?
    private var preparedID: UUID?
    private var suspended = false
    private var loaded = false
    private var recoveryID: UUID?
    private var setupMessage = "Enable shader requests in Mac Settings."

    public init(catalog: DirectoryCatalog, directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Holodeck/Requests")) {
        self.catalog = catalog; self.directory = directory
    }

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
               let stage = records[id]?.status.stage, !stage.terminal, stage != .awaitingActivation, stage != .awaitingClarification {
                recoveryID = id
                records[id]?.status.stage = .repairing
                records[id]?.status.message = "Recovering interrupted request"
            }
        }
        loaded = true
        try persist()
    }
    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString) }
    public func artifacts(for id: UUID) -> URL { folder(id) }
    public func configurationValue() -> ShaderRequestConfiguration { configuration }
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
        guard activeID == nil, !records.values.contains(where: { !$0.status.stage.terminal }) else {
            throw ShaderRequestError.unavailable("Finish or cancel queued requests before changing setup.")
        }
        let process = RequestWorkerProcess()
        var verified = false
        for try await event in process.run(mode: "preflight", configuration: candidate, directory: directory.appendingPathComponent("setup")) {
            if event.event == "failure" { throw ShaderRequestError.unavailable(event.message ?? "Setup failed") }
            if event.event == "preflight" { verified = true }
        }
        guard verified else { throw ShaderRequestError.unavailable("Setup did not complete.") }
        configuration = candidate; configuration.enabled = true
        try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
        setupMessage = "Ready for shader requests"
        try persist(); kick()
    }
    public func disable() throws {
        guard !records.values.contains(where: { !$0.status.stage.terminal }) else {
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
        guard records[id]?.status.stage.terminal == true else { throw ShaderRequestError.invalidRequest }
        try FileManager.default.removeItem(at: folder(id)); records[id] = nil; try persist()
    }
    public func revoke(_ deviceID: String) throws {
        for id in records.keys where records[id]?.status.deviceID == deviceID && records[id]?.status.stage.terminal == false {
            records[id]?.revoked = true
            if records[id]?.status.stage == .queued, activeID != id {
                try update(id, stage: .cancelled, message: "TV access was revoked")
            } else if records[id]?.status.stage == .awaitingActivation || records[id]?.status.stage == .awaitingClarification {
                try update(id, stage: .failed, message: "TV access was revoked; any pushed commit remains")
            }
        }
        try persist()
    }

    public func control(operation: String, payload: ShaderRequestControl, deviceID: String) async throws -> ShaderRequestControlReply {
        try load()
        if operation == "requestSubmit" {
            guard configuration.enabled else { throw ShaderRequestError.unavailable(setupMessage) }
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
                    try JSONEncoder().encode(["shaderID": record.status.result?.shaderID ?? "", "diagnostic": diagnostic])
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
        return ShaderRequestControlReply(enabled: configuration.enabled, message: setupMessage, jobs: jobs,
                                        publicationRevision: await catalog.publicationRevisionValue())
    }
    private func kick() {
        guard loaded, configuration.enabled, !suspended, activeID == nil else { return }
        let eligible = records.values.filter { !$0.revoked }.map(\.status)
        guard let id = ShaderRequestScheduling.next(in: eligible, recoveringID: recoveryID) else { return }
        do {
            try JSONEncoder().encode(id).write(to: directory.appendingPathComponent("active.json"), options: .atomic)
            try update(id, stage: .implementing, message: "Preparing the managed checkout")
        } catch {
            try? update(id, stage: .failed, message: error.localizedDescription)
            return
        }
        activeID = id
        workerTask = Task { [weak self] in await self?.execute(id) }
    }
    private func execute(_ id: UUID) async {
        guard let record = records[id] else { activeID = nil; return }
        let process = RequestWorkerProcess(); activeProcess = process
        var outcomeSeen = false
        do {
            let job = folder(id)
            try await Task.detached { try RequestWorkerProcess.reconcileOrphan(in: job) }.value
            for try await event in process.run(mode: "run", configuration: record.configuration, directory: job) {
                if suspended { break }
                switch event.event {
                case "stage":
                    if let value = event.stage, let stage = ShaderRequestStatus.Stage(rawValue: value) {
                        try update(id, stage: stage, message: event.message ?? value)
                    }
                case "preparePublication":
                    if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
                    do {
                        let prepared = try await catalog.prepare(from: URL(fileURLWithPath: record.configuration.repository))
                        guard prepared.previewWarnings.isEmpty else {
                            await catalog.discard(prepared.id)
                            throw ShaderRequestError.unavailable("Publication previews could not be rendered.")
                        }
                        preparedID = prepared.id; process.reply(true)
                    } catch { process.reply(false) }
                case "discardPublication":
                    if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
                case "clarification":
                    records[id]?.status.clarification = ShaderClarification(question: event.question ?? "Please clarify the request", options: event.options ?? [])
                    try update(id, stage: records[id]?.revoked == true ? .failed : .awaitingClarification,
                               message: records[id]?.revoked == true ? "TV access was revoked" : "Waiting for a TV answer")
                    outcomeSeen = true
                case "result":
                    guard let result = event.result, ShaderRequest.validID(result.shaderID), let preparedID else {
                        throw ShaderRequestError.invalidRequest
                    }
                    try update(id, stage: .publishing, message: "Installing the committed library")
                    let publication = try await catalog.install(preparedID)
                    self.preparedID = nil
                    records[id]?.status.result = result
                    if records[id]?.revoked == true {
                        try update(id, stage: .failed, message: "Pushed successfully; TV access was revoked")
                        outcomeSeen = true
                        continue
                    }
                    guard let output = publication.catalog.shaders.first(where: { $0.id == result.shaderID }) else {
                        try JSONEncoder().encode(["shaderID": result.shaderID, "diagnostic": "The committed output was removed before TV delivery. Recreate it under a fresh unused ID."])
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
            if !outcomeSeen, !suspended { throw ShaderRequestError.unavailable("Worker ended without a verified result.") }
        } catch {
            process.stop()
            if !suspended {
                try? update(id, stage: .failed, message: error.localizedDescription)
                await process.waitForExit()
                // Operational failures discard only this request's owned, unpublished work.
                let cleanup = RequestWorkerProcess()
                do { for try await _ in cleanup.run(mode: "discard", configuration: record.configuration, directory: folder(id)) {} }
                catch { cleanup.stop() }
            }
        }
        if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
        activeProcess = nil; activeID = nil; workerTask = nil
        if !suspended {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("active.json"))
            if recoveryID == id { recoveryID = nil }
            kick()
        } else { recoveryID = id }
    }
    public func suspend() {
        suspended = true; activeProcess?.stop()
        if let id = activeID { try? update(id, stage: .repairing, message: "Waiting for the Mac to resume") }
    }
    public func resume() { suspended = false; kick() }
}
#endif
