#if os(macOS)
import Foundation
import Darwin

nonisolated struct RequestWorkerTeardownError: LocalizedError, Sendable {
    var cause: String? = nil
    var errorDescription: String? { "Worker processes did not exit within ten seconds. Checkout recovery is required; process evidence was retained." + (cause.map { " Original error: " + $0 } ?? "") }
}

nonisolated struct RequestWorkerEvidenceError: LocalizedError, Sendable {
    let cause: String
    var errorDescription: String? { cause + " Repair the journal or detach while retaining its files and evidence." }
}

nonisolated struct RequestProcessIdentity: Codable, Sendable, Equatable, Hashable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
    init?(pid: Int32) {
        var info = proc_bsdinfo()
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_status != SZOMB else { return nil }
        self.pid = pid; seconds = info.pbi_start_tvsec; microseconds = info.pbi_start_tvusec
    }
    var isCurrent: Bool { Self(pid: pid) == self }
    static func checkedGroup(_ pid: Int32) throws -> [Self] { try enumerateGroup(pid) }
    private static func enumerateGroup(_ pid: Int32) throws -> [Self] {
        var capacity = 1024
        while capacity <= 262144 {
            var pids = [Int32](repeating: 0, count: capacity)
            errno = 0
            let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count)) }
            guard bytes >= 0, bytes != 0 || errno == 0 else { throw RequestWorkerTeardownError(cause: "Cannot enumerate owned process group.") }
            if bytes < capacity * MemoryLayout<Int32>.size {
                guard bytes % Int32(MemoryLayout<Int32>.size) == 0 else { throw RequestWorkerTeardownError(cause: "Invalid process group enumeration.") }
                return pids.prefix(Int(bytes) / MemoryLayout<Int32>.size).compactMap { Self(pid: $0) }
            }
            capacity *= 2
        }
        throw RequestWorkerTeardownError(cause: "Process group enumeration exceeds its capacity.")
    }
    struct Supervision: Decodable {
        let formatVersion: Int
        let supervisor: RequestProcessIdentity
        let command: RequestProcessIdentity?
        let state: String
        let failure: String?
        let failureKind: String?
        let recoveryRequired: Bool?
        let sessionID: UUID?
        let revision: Int?
        let clock: String?
        let pipeDrainComplete: Bool?
        let processesSettled: Bool?
        let deadline: TimeInterval?
    }
    struct Observation {
        var identities: [RequestProcessIdentity]
        var uncertainty: String?
        var evidenceError: String?
        var sessions: [RequestProcessIdentity: [RequestProcessIdentity]] = [:]
        var deadline: TimeInterval?
    }
    static func observe(in directory: URL, known additional: [Self] = [],
                        group: (Int32) throws -> [Self] = checkedGroup) throws -> Observation {
        struct Entry: Decodable { let leader: RequestProcessIdentity; var members: [RequestProcessIdentity] }
        var result = Observation(identities: [])
        let reader = try BoundedCatalogReader(root: directory)
        let supervision: Supervision?
        do {
            let file = directory.appendingPathComponent("supervision.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let value = try JSONDecoder().decode(Supervision.self, from: reader.read("supervision.json", limit: CatalogLimits.headBytes).bytes)
                guard [1, 2].contains(value.formatVersion), value.supervisor.pid > 1, (value.command?.pid ?? 2) > 1,
                      ["starting", "running", "draining", "settled", "failed", "cancelled"].contains(value.state),
                      value.formatVersion == 1 || (value.sessionID != nil && (value.revision ?? -1) >= 0 && value.clock == "darwin-uptime-raw" && value.pipeDrainComplete != nil && value.processesSettled != nil && value.deadline?.isFinite != false) else {
                    throw RequestWorkerEvidenceError(cause: "Invalid supervision evidence.")
                }
                supervision = value
            } else { supervision = nil }
        } catch {
            supervision = nil
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("supervision.json").path) {
                result.evidenceError = "Supervision evidence is unreadable: " + error.localizedDescription
            }
        }
        var entries: [Entry] = []
        do {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("children.json").path) {
                let values = try JSONDecoder().decode([Entry].self, from: reader.read("children.json", limit: CatalogLimits.headBytes).bytes)
                guard values.allSatisfy({ $0.leader.pid > 1 && $0.members.allSatisfy { $0.pid > 1 } }) else {
                    throw RequestWorkerEvidenceError(cause: "Invalid validation process identities.")
                }
                entries = values
            }
        } catch {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("children.json").path) {
                result.evidenceError = "Validation process registry is unreadable: " + error.localizedDescription
            }
        }
        if let supervision {
            // Both files independently retain ownership, including a known command that
            // closed its pipes before its supervisor or registry disappeared.
            let members = [supervision.supervisor] + [supervision.command].compactMap { $0 }
            if let index = entries.firstIndex(where: { $0.leader == supervision.supervisor }) { entries[index].members += members }
            else { entries.append(Entry(leader: supervision.supervisor, members: members)) }
            if (supervision.recoveryRequired == true && supervision.failureKind == "pipeDrain") ||
                (supervision.formatVersion >= 2 && !supervision.supervisor.isCurrent && supervision.pipeDrainComplete != true) {
                result.evidenceError = supervision.failure ?? "Output pipe completion is unverified."
            }
            if supervision.formatVersion == 2, supervision.processesSettled != true || supervision.pipeDrainComplete != true {
                result.deadline = supervision.deadline
            }
        }
        for entry in entries {
            let known = (entry.members + additional).filter(\.isCurrent)
            if entry.leader.isCurrent {
                let observed = try group(entry.leader.pid)
                result.identities += Array(Set(known + observed))
                if entry.leader == supervision?.supervisor {
                    result.sessions[entry.leader] = Array(Set(entry.members.filter(\.isCurrent) + observed))
                }
            } else {
                result.identities += known
                // A retired anchor does not authorize adopting unfamiliar identities.
                if Self(pid: entry.leader.pid) == nil,
                   try group(entry.leader.pid).contains(where: { !known.contains($0) }) {
                    result.uncertainty = "Unverified validation descendants remain."
                }
            }
        }
        return result
    }
    static func shutdownTargets(_ identities: [Self], sessions: [Self: [Self]], signal: Int32, allowOwnerRetirement: Bool = true) -> [Self] {
        let currentSessions = sessions.filter { $0.key.isCurrent }
        return identities.filter { identity in
            if let members = currentSessions[identity] {
                return signal == SIGTERM || (allowOwnerRetirement && !members.contains(where: { $0 != identity }))
            }
            if signal == SIGTERM, currentSessions.values.contains(where: { $0.contains(identity) }) { return false }
            return true
        }
    }
    static func signal(_ identities: [Self], _ signal: Int32) {
        for identity in identities where identity.isCurrent { _ = kill(identity.pid, signal) }
    }
}

/// Nonblocking pipe readers remain active even when retaining a log fails.
nonisolated private final class RequestPipeDrain: @unchecked Sendable {
    let source: DispatchSourceRead
    init(handle: FileHandle, group: DispatchGroup, receive: @escaping @Sendable (Data) -> Void) throws {
        let descriptor = handle.fileDescriptor
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "Holodeck.worker-pipe"))
        group.enter()
        source.setEventHandler { [weak source] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 { receive(Data(buffer.prefix(count))); continue }
                if count == -1 && errno == EINTR { continue }
                if count == 0 || (count < 0 && errno != EAGAIN) { source?.cancel() }
                return
            }
        }
        source.setCancelHandler { group.leave() }
        source.resume()
    }
    func cancel() { source.cancel() }
}

nonisolated private final class RequestEventParser: @unchecked Sendable {
    private var pending = Data()
    func receive(_ bytes: Data, continuation: AsyncThrowingStream<RequestWorkerEvent, Error>.Continuation) {
        pending.append(bytes)
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
            if let event = try? JSONDecoder().decode(RequestWorkerEvent.self, from: line) { continuation.yield(event) }
        }
    }
}

nonisolated final class RequestWorkerProcess: @unchecked Sendable {
    struct GroupOperations: Sendable {
        var identity: @Sendable (Int32) -> RequestProcessIdentity? = { RequestProcessIdentity(pid: $0) }
        var signal: @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) }
        var group: @Sendable (Int32) throws -> [RequestProcessIdentity] = { try RequestProcessIdentity.checkedGroup($0) }
        var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var wait: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        var schedule: @Sendable (DispatchWorkItem) -> Void = { DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: $0) }
    }
    static let bootstrap = """
    import json,runpy,sys
    if sys.version_info < (3,9):
        print(json.dumps({'event':'failure','message':'The shader checker requires Python 3.9 or later; choose a supported interpreter.'}),flush=True)
        sys.exit(2)
    sys.argv=sys.argv[1:]
    runpy.run_path(sys.argv[0],run_name='__main__')
    """
    static var bundledScript: URL? { Bundle.module.url(forResource: "shader_requests", withExtension: "py") }
    let process = Process()
    private let scriptOverride: URL?
    private let groups: GroupOperations
    private let input = Pipe(), output = Pipe(), error = Pipe()
    private let lock = NSLock(), drained = DispatchGroup()
    private var started = false, stopping = false, completed = false
    private var stopTime: TimeInterval?
    private var cancelRequested = false, escalated = false
    private var termSent: Set<RequestProcessIdentity> = [], killSent: Set<RequestProcessIdentity> = []
    private var registryError: Error?
    private var leader: RequestProcessIdentity?
    private var owned: [Int32: RequestProcessIdentity] = [:]
    private var supervisedSessions: [RequestProcessIdentity: [RequestProcessIdentity]] = [:]
    private var journal: URL?
    private var workerConfiguration: ShaderRequestConfiguration?
    private var firstError: Error?
    private var logFailed = false
    private var nextObservation: TimeInterval = 0
    private var observationFailures = 0
    private var observationInFlight = false
    private var rootStopObserved = false
    private var teardownFailed = false
    private var escalation: DispatchWorkItem?
    var beforeReplyWrite: (() -> Void)?
    var beforeIdentityWrite: (() throws -> Void)?
    var beforeLogWrite: (() throws -> Void)?
    init(script: URL? = nil, groups: GroupOperations = .init()) { scriptOverride = script; self.groups = groups }
    var recoveryTarget: (directory: URL, configuration: ShaderRequestConfiguration)? {
        lock.withLock {
            guard let journal, let workerConfiguration else { return nil }
            return (journal, workerConfiguration)
        }
    }

    func reply(_ accepted: Bool, message: String? = nil) throws {
        struct Reply: Encodable { let ok: Bool; let message: String? }
        try lock.withLock { guard started, !stopping, process.isRunning else { throw CancellationError() } }
        beforeReplyWrite?()
        try lock.withLock {
            guard started, !stopping, process.isRunning else { throw CancellationError() }
            var bytes = try JSONEncoder().encode(Reply(ok: accepted, message: message)); bytes.append(10)
            try input.fileHandleForWriting.write(contentsOf: bytes)
        }
    }
    private func refreshOwned(force: Bool = false) {
        // Only the observation queue performs I/O. Cancellation, replies and log readers
        // hold this lock briefly and never wait for enumeration or retry delays.
        let snapshot: (RequestProcessIdentity?, URL?, [RequestProcessIdentity], Bool)? = lock.withLock {
            guard !completed, !observationInFlight, force || groups.now() >= nextObservation else { return nil }
            observationInFlight = true; nextObservation = groups.now() + 0.25
            return (leader, journal, Array(owned.values), stopping)
        }
        guard let (root, directory, known, stoppingAtSnapshot) = snapshot else { return }
        var observed = known.filter { groups.identity($0.pid) == $0 }
        var observation = RequestProcessIdentity.Observation(identities: [])
        var failure: Error?
        do {
            var cached: [Int32: [RequestProcessIdentity]] = [:]
            func group(_ pid: Int32) throws -> [RequestProcessIdentity] {
                if let value = cached[pid] { return value }
                let value = try groups.group(pid); cached[pid] = value; return value
            }
            if let root {
                if groups.identity(root.pid) == root {
                    observed.append(root) // Root ownership never depends on enumeration succeeding.
                    observed += try group(root.pid)
                } else if groups.identity(root.pid) == nil,
                          try group(root.pid).contains(where: { !known.contains($0) }) {
                    observation.uncertainty = "Unverified worker descendants remain."
                }
            }
            if let directory {
                let result = try RequestProcessIdentity.observe(in: directory, known: observed, group: group)
                observation.identities = result.identities; observation.sessions = result.sessions; observation.deadline = result.deadline
                observation.uncertainty = result.uncertainty ?? observation.uncertainty; observation.evidenceError = result.evidenceError
            }
        } catch { failure = error }
        let shouldStop = lock.withLock { () -> Bool in
            observationInFlight = false
            guard !completed, journal == directory, leader == root else { return false }
            owned = owned.filter { groups.identity($0.key) == $0.value }
            for identity in observed + observation.identities where groups.identity(identity.pid) == identity { owned[identity.pid] = identity }
            termSent.formIntersection(Set(owned.values)); killSent.formIntersection(Set(owned.values))
            supervisedSessions = (failure == nil ? observation.sessions : supervisedSessions).filter { groups.identity($0.key.pid) == $0.key }
            if let failure {
                observationFailures += 1; registryError = failure
                if observationFailures >= 3 {
                    let detail = (failure as? RequestWorkerTeardownError)?.cause ?? failure.localizedDescription
                    firstError = firstError ?? ShaderRequestError.unavailable("Repeated process observation failure: " + detail)
                    return true
                }
                return false
            }
            observationFailures = 0
            if stopping, let deadline = observation.deadline { stopTime = min(stopTime ?? deadline - 10, deadline - 10) }
            if stoppingAtSnapshot { rootStopObserved = true }
            registryError = observation.uncertainty.map { RequestWorkerTeardownError(cause: $0) } ?? observation.evidenceError.map { RequestWorkerEvidenceError(cause: $0) }
            return false
        }
        if shouldStop { beginTeardown(cancelled: false) }
    }
    private func signalPendingLocked() {
        let signal = escalated || stopTime.map({ groups.now() - $0 >= 5 }) == true ? SIGKILL : SIGTERM
        let identities = owned.values.filter { identity in
            identity != leader || rootStopObserved || observationFailures >= 3 || signal == SIGKILL
        }
        for identity in RequestProcessIdentity.shutdownTargets(Array(identities), sessions: supervisedSessions, signal: signal, allowOwnerRetirement: observationFailures == 0 && rootStopObserved) where groups.identity(identity.pid) == identity {
            if termSent.insert(identity).inserted { _ = groups.signal(identity.pid, SIGTERM) }
            if signal == SIGKILL, groups.identity(identity.pid) == identity, killSent.insert(identity).inserted { _ = groups.signal(identity.pid, SIGKILL) }
        }
    }
    func stop() { beginTeardown(cancelled: true) }
    private func beginTeardown(cancelled: Bool) {
        lock.withLock {
            guard !completed else { return }
            cancelRequested = cancelRequested || cancelled
            if !stopping { nextObservation = 0 }
            stopping = true; stopTime = stopTime ?? groups.now()
            guard started else { return }
            signalPendingLocked()
            if escalation == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        guard !self.completed else { return }
                        self.escalated = true; self.signalPendingLocked()
                    }
                }
                escalation = work; groups.schedule(work)
            }
        }
    }
    private func record(_ error: Error) {
        lock.withLock { firstError = firstError ?? error }
        stop()
    }

    func run(mode: String, configuration: ShaderRequestConfiguration, directory: URL) -> AsyncThrowingStream<RequestWorkerEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { journal = directory; workerConfiguration = configuration }
            drained.enter()
            DispatchQueue(label: "Holodeck.request-worker").async { [self] in
                let pipes = DispatchGroup()
                var readers: [RequestPipeDrain] = []
                defer {
                    readers.forEach { $0.cancel() }
                    lock.withLock { completed = true; escalation?.cancel(); escalation = nil }
                    drained.leave()
                }
                do {
                    guard let script = scriptOverride ?? Self.bundledScript else { throw ShaderRequestError.unavailable("Bundled shader request worker is missing.") }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("configuration.json"), options: .atomic)
                    process.executableURL = URL(fileURLWithPath: configuration.python)
                    process.arguments = ["-I", "-c", Self.bootstrap, script.path, mode, directory.appendingPathComponent("configuration.json").path, directory.path]
                    process.standardInput = input; process.standardOutput = output; process.standardError = error
                    process.currentDirectoryURL = URL(fileURLWithPath: configuration.repository)
                    let parser = RequestEventParser()
                    for (pipe, name, parsesEvents) in [(output, "worker.log", true), (error, "worker-stderr.log", false)] {
                        let url = directory.appendingPathComponent(name)
                        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                        let log = try FileHandle(forWritingTo: url); try log.seekToEnd()
                        readers.append(try RequestPipeDrain(handle: pipe.fileHandleForReading, group: pipes) { bytes in
                            if self.lock.withLock({ !self.logFailed }) {
                                do { try self.beforeLogWrite?(); try log.write(contentsOf: bytes) }
                                catch { self.lock.withLock { self.logFailed = true }; self.record(error) }
                            }
                            if parsesEvents { parser.receive(bytes, continuation: continuation) }
                        })
                    }
                    try lock.withLock {
                        guard !stopping else { throw CancellationError() }
                        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw POSIXError(.EIO) }
                        try process.run(); started = true
                        leader = groups.identity(process.processIdentifier)
                        if let leader { owned[leader.pid] = leader }
                    }
                    do {
                        try beforeIdentityWrite?()
                        try JSONEncoder().encode(WorkerIdentity(pid: process.processIdentifier, script: script.path, directory: directory.path, birth: leader))
                            .write(to: directory.appendingPathComponent("process.json"), options: .atomic)
                    } catch { record(error) }
                    while process.isRunning {
                        refreshOwned()
                        let expired = lock.withLock { () -> Bool in
                            if stopping { signalPendingLocked() }
                            return stopTime.map { groups.now() - $0 >= 10 } ?? false
                        }
                        if expired { lock.withLock { teardownFailed = true }; break }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    let leaderExited = groups.now()
                    lock.withLock { nextObservation = 0 }
                    while true {
                        refreshOwned()
                        let outstanding = lock.withLock { () -> Bool in
                            if stopping { signalPendingLocked() }
                            return registryError != nil || owned.values.contains { groups.identity($0.pid) == $0 }
                        }
                        let pipesDone = pipes.wait(timeout: .now()) == .success
                        if pipesDone, let failure = lock.withLock({ registryError as? RequestWorkerEvidenceError }),
                           lock.withLock({ owned.isEmpty }) { throw failure }
                        if pipesDone && !outstanding {
                            refreshOwned(force: true)
                            if lock.withLock({ registryError == nil && !owned.values.contains { groups.identity($0.pid) == $0 } }) { break }
                        }
                        // Permit short natural EOF/registry settlement without declaring cancellation.
                        if lock.withLock({ stopTime == nil }), groups.now() - leaderExited >= 0.1 {
                            beginTeardown(cancelled: false)
                        }
                        if lock.withLock({ stopTime.map { groups.now() - $0 >= 10 } ?? false }) {
                            lock.withLock { teardownFailed = true }; break
                        }
                        groups.wait(0.025)
                    }
                    if lock.withLock({ teardownFailed }) {
                        throw RequestWorkerTeardownError(cause: lock.withLock { firstError?.localizedDescription ?? registryError?.localizedDescription })
                    }
                    if let failure = lock.withLock({ firstError }) { throw failure }
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("process.json"))
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("children.json"))
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("supervision.json"))
                    if lock.withLock({ cancelRequested }) { throw CancellationError() }
                    if process.terminationStatus != 0 { throw ShaderRequestError.unavailable("Worker exited \(process.terminationStatus). See its retained log.") }
                    continuation.finish()
                } catch {
                    if process.isRunning { stop() }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] reason in if case .cancelled = reason { self?.stop() } }
        }
    }
    func waitForExit() async throws {
        let finished: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in continuation.resume(returning: drained.wait(timeout: .now() + 11) == .success) }
        }
        guard finished, !lock.withLock({ teardownFailed }) else { stop(); throw RequestWorkerTeardownError(cause: lock.withLock { firstError?.localizedDescription }) }
    }
    private struct WorkerIdentity: Codable { let pid: Int32; let script: String; let directory: String; var birth: RequestProcessIdentity? }
    static func reconcileOrphan(in directory: URL, groups: GroupOperations = .init()) throws {
        let file = directory.appendingPathComponent("process.json")
        var root: RequestProcessIdentity?
        var markerError: String?
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let identity: WorkerIdentity
                do { identity = try JSONDecoder().decode(WorkerIdentity.self, from: BoundedCatalogReader(root: directory).read("process.json", limit: CatalogLimits.headBytes).bytes) }
                catch { throw ShaderRequestError.unavailable("Worker identity is unreadable. Repair the journal marker or detach the checkout while retaining its evidence.") }
                guard identity.pid > 1, RequestPaths.canonical(URL(fileURLWithPath: identity.directory)) == RequestPaths.canonical(directory) else {
                    throw ShaderRequestError.unavailable("Worker identity does not belong to this request journal.")
                }
                if let birth = identity.birth {
                    root = birth // A retired birth still identifies the group whose unfamiliar members must remain unowned.
                } else if let birth = RequestProcessIdentity(pid: identity.pid) {
                    let task = Process(), output = Pipe()
                    task.executableURL = URL(fileURLWithPath: "/bin/ps"); task.arguments = ["-p", String(identity.pid), "-o", "command="]
                    task.standardOutput = output; try task.run()
                    let command = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); task.waitUntilExit()
                    if birth.isCurrent, command.contains(identity.script), command.contains(identity.directory) { root = birth }
                }
            } catch { markerError = error.localizedDescription }
        }
        var targets = root.map { [$0] } ?? []
        var deadline = groups.now() + 10
        var termSent: Set<RequestProcessIdentity> = [], killSent: Set<RequestProcessIdentity> = []
        var uncertainty: String?, failures = 0
        var evidenceError = markerError
        var sessions: [RequestProcessIdentity: [RequestProcessIdentity]] = [:]
        while true {
            do {
                var cache: [Int32: [RequestProcessIdentity]] = [:]
                func group(_ pid: Int32) throws -> [RequestProcessIdentity] {
                    if let value = cache[pid] { return value }
                    let value = try groups.group(pid); cache[pid] = value; return value
                }
                if let root, root.isCurrent { targets += try group(root.pid) }
                else if let root, RequestProcessIdentity(pid: root.pid) == nil,
                        try group(root.pid).contains(where: { !targets.contains($0) }) {
                    throw RequestWorkerTeardownError(cause: "Unverified worker descendants remain.")
                }
                let observation = try RequestProcessIdentity.observe(in: directory, known: targets, group: group)
                targets += observation.identities; sessions = observation.sessions
                deadline = min(deadline, observation.deadline ?? deadline)
                uncertainty = observation.uncertainty; evidenceError = observation.evidenceError ?? markerError; failures = 0
            } catch { failures += 1; uncertainty = error.localizedDescription }
            targets = Array(Set(targets.filter(\.isCurrent)))
            let signal = groups.now() >= deadline - 5 ? SIGKILL : SIGTERM
            let pending = RequestProcessIdentity.shutdownTargets(targets, sessions: sessions, signal: signal, allowOwnerRetirement: failures == 0)
            let term = pending.filter { termSent.insert($0).inserted }
            RequestProcessIdentity.signal(term, SIGTERM)
            if signal == SIGKILL {
                RequestProcessIdentity.signal(pending.filter { killSent.insert($0).inserted }, SIGKILL)
            }
            if uncertainty == nil, !targets.contains(where: \.isCurrent) {
                // A second observation after signalling closes the final-fork window.
                do {
                    let final = try RequestProcessIdentity.observe(in: directory, known: targets, group: groups.group)
                    let rootGroup = try root.flatMap { root -> [RequestProcessIdentity]? in
                        let current = RequestProcessIdentity(pid: root.pid)
                        return current == nil || current == root ? try groups.group(root.pid) : nil
                    } ?? []
                    if final.uncertainty == nil, final.identities.isEmpty, rootGroup.isEmpty {
                        if let detail = final.evidenceError ?? evidenceError { throw RequestWorkerEvidenceError(cause: detail) }
                        for name in ["process.json", "children.json", "supervision.json"] {
                            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                        }
                        return
                    }
                    targets += final.identities; uncertainty = final.uncertainty
                } catch let error as RequestWorkerEvidenceError { throw error }
                catch { failures += 1; uncertainty = error.localizedDescription }
            }
            guard groups.now() < deadline else { throw RequestWorkerTeardownError(cause: uncertainty) }
            // Retries are observation intervals, never sleeps inside an ownership lock.
            groups.wait(0.25)
        }
    }
}
#endif
