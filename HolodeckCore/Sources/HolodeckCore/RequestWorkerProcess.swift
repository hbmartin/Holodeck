#if os(macOS)
import Foundation
import Darwin

nonisolated struct RequestWorkerTeardownError: LocalizedError, Sendable {
    var cause: String? = nil
    var errorDescription: String? { "Worker processes did not exit within ten seconds. Checkout recovery is required; process evidence was retained." + (cause.map { " Original error: " + $0 } ?? "") }
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
    static func group(_ pid: Int32) -> [Self] { (try? checkedGroup(pid)) ?? [] }
    static func checkedGroup(_ pid: Int32) throws -> [Self] {
        try retryGroupObservation { try enumerateGroup(pid) }
    }
    static func retryGroupObservation(_ read: () throws -> [Self], wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> [Self] {
        for attempt in 0..<3 {
            do { return try read() }
            catch { if attempt == 2 { throw error }; wait(0.25) }
        }
        preconditionFailure("Exhausted process observation attempts")
    }
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
    }
    struct Observation {
        var identities: [RequestProcessIdentity]
        var uncertainty: String?
        var sessions: [RequestProcessIdentity: [RequestProcessIdentity]] = [:]
    }
    static func observe(in directory: URL, known additional: [Self] = []) throws -> Observation {
        struct Entry: Decodable { let leader: RequestProcessIdentity; let members: [RequestProcessIdentity] }
        let supervisionFile = directory.appendingPathComponent("supervision.json")
        let supervision: Supervision?
        if FileManager.default.fileExists(atPath: supervisionFile.path) {
            do { supervision = try JSONDecoder().decode(Supervision.self, from: BoundedCatalogReader(root: directory).read("supervision.json", limit: CatalogLimits.headBytes).bytes) }
            catch {
                if FileManager.default.fileExists(atPath: supervisionFile.path) { throw error }
                supervision = nil
            }
            if let value = supervision {
                guard value.formatVersion == 1, value.supervisor.pid > 1,
                      ["starting", "running", "draining", "settled", "failed"].contains(value.state) else {
                    throw ShaderRequestError.unavailable("Invalid supervision evidence. Repair the journal or detach while retaining its files.")
                }
                if value.recoveryRequired == true, value.failureKind == "pipeDrain" {
                    throw ShaderRequestError.unavailable(value.failure ?? "External pipe ownership is unresolved. Repair or detach while retaining its evidence.")
                }
            }
        } else { supervision = nil }
        let marker = directory.appendingPathComponent("children.json")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            if let supervision, supervision.supervisor.isCurrent {
                throw RequestWorkerTeardownError(cause: "Live supervisor has no process registry.")
            }
            return Observation(identities: [])
        }
        let entries: [Entry]
        do { entries = try JSONDecoder().decode([Entry].self, from: BoundedCatalogReader(root: directory).read("children.json", limit: CatalogLimits.headBytes).bytes) }
        catch {
            if !FileManager.default.fileExists(atPath: marker.path) { return Observation(identities: []) }
            throw error
        }
        guard entries.allSatisfy({ $0.leader.pid > 1 && $0.members.allSatisfy { $0.pid > 1 } }),
              supervision == nil || entries.contains(where: { $0.leader == supervision?.supervisor }) else {
            throw ShaderRequestError.unavailable("Invalid validation process registry. Retain the journal and repair or detach this checkout.")
        }
        var result = Observation(identities: [])
        for entry in entries {
            let known = (entry.members + additional).filter(\.isCurrent)
            if entry.leader.isCurrent {
                let observed = try checkedGroup(entry.leader.pid)
                result.identities += Array(Set(known + observed))
                if entry.leader == supervision?.supervisor {
                    result.sessions[entry.leader] = Array(Set(entry.members.filter(\.isCurrent) + observed))
                }
            } else {
                result.identities += known
                // A retired anchor does not authorize adopting unfamiliar identities.
                if Self(pid: entry.leader.pid) == nil,
                   try checkedGroup(entry.leader.pid).contains(where: { !known.contains($0) }) {
                    result.uncertainty = "Unverified validation descendants remain."
                }
            }
        }
        return result
    }
    static func shutdownTargets(_ identities: [Self], sessions: [Self: [Self]], signal: Int32) -> [Self] {
        identities.filter { identity in
            if let members = sessions[identity] {
                return signal == SIGTERM || !members.contains(where: { $0 != identity && $0.isCurrent })
            }
            if signal == SIGTERM, sessions.values.contains(where: { $0.contains(identity) }) { return false }
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
    private func refreshOwnedLocked() {
        owned = owned.filter { groups.identity($0.key) == $0.value }
        termSent.formIntersection(Set(owned.values)); killSent.formIntersection(Set(owned.values))
        var rootUncertainty: Error?
        if let leader, groups.identity(leader.pid) == leader {
            for identity in RequestProcessIdentity.group(leader.pid) { owned[identity.pid] = identity }
        } else if let leader, groups.identity(leader.pid) == nil,
                  RequestProcessIdentity.group(leader.pid).contains(where: { owned[$0.pid] != $0 }) {
            rootUncertainty = RequestWorkerTeardownError(cause: "Unverified worker descendants remain.")
        }
        if let journal {
            do {
                let observation = try RequestProcessIdentity.observe(in: journal, known: Array(owned.values))
                supervisedSessions = observation.sessions
                for identity in observation.identities { owned[identity.pid] = identity }
                registryError = observation.uncertainty.map { RequestWorkerTeardownError(cause: $0) } ?? rootUncertainty
            } catch { registryError = error }
        }
    }
    private func signalPendingLocked() {
        let signal = escalated || stopTime.map({ groups.now() - $0 >= 5 }) == true ? SIGKILL : SIGTERM
        for identity in RequestProcessIdentity.shutdownTargets(Array(owned.values), sessions: supervisedSessions, signal: signal) where groups.identity(identity.pid) == identity {
            if signal == SIGTERM {
                guard termSent.insert(identity).inserted else { continue }
            } else { guard killSent.insert(identity).inserted else { continue } }
            _ = groups.signal(identity.pid, signal)
        }
    }
    func stop() { beginTeardown(cancelled: true) }
    private func beginTeardown(cancelled: Bool) {
        lock.withLock {
            guard !completed else { return }
            cancelRequested = cancelRequested || cancelled
            stopping = true; stopTime = stopTime ?? groups.now()
            guard started else { return }
            refreshOwnedLocked(); signalPendingLocked()
            if escalation == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        guard !self.completed else { return }
                        self.escalated = true; self.refreshOwnedLocked(); self.signalPendingLocked()
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
                            if self.lock.withLock({ self.firstError == nil }) {
                                do { try self.beforeLogWrite?(); try log.write(contentsOf: bytes) }
                                catch { self.record(error) }
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
                        let expired = lock.withLock { () -> Bool in
                            refreshOwnedLocked()
                            if stopping { signalPendingLocked() }
                            return stopTime.map { groups.now() - $0 >= 10 } ?? false
                        }
                        if expired { lock.withLock { teardownFailed = true }; break }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    let leaderExited = groups.now()
                    while true {
                        let outstanding = lock.withLock { () -> Bool in
                            refreshOwnedLocked()
                            if stopping { signalPendingLocked() }
                            return registryError != nil || owned.values.contains { groups.identity($0.pid) == $0 }
                        }
                        let pipesDone = pipes.wait(timeout: .now()) == .success
                        if pipesDone && !outstanding { break }
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
    static func reconcileOrphan(in directory: URL) throws {
        let file = directory.appendingPathComponent("process.json")
        var targets = (try RequestProcessIdentity.observe(in: directory)).identities
        if FileManager.default.fileExists(atPath: file.path) {
            let identity: WorkerIdentity
            do { identity = try JSONDecoder().decode(WorkerIdentity.self, from: BoundedCatalogReader(root: directory).read("process.json", limit: CatalogLimits.headBytes).bytes) }
            catch { throw ShaderRequestError.unavailable("Worker identity is unreadable. Repair the journal marker or detach the checkout while retaining its evidence.") }
            guard identity.pid > 1, RequestPaths.canonical(URL(fileURLWithPath: identity.directory)) == RequestPaths.canonical(directory) else {
                throw ShaderRequestError.unavailable("Worker identity does not belong to this request journal.")
            }
            if let birth = identity.birth {
                if birth.isCurrent { targets += RequestProcessIdentity.group(identity.pid) }
            } else if let birth = RequestProcessIdentity(pid: identity.pid) {
                let task = Process(), output = Pipe()
                task.executableURL = URL(fileURLWithPath: "/bin/ps"); task.arguments = ["-p", String(identity.pid), "-o", "command="]
                task.standardOutput = output; try task.run()
                let command = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); task.waitUntilExit()
                if birth.isCurrent, command.contains(identity.script), command.contains(identity.directory) { targets += RequestProcessIdentity.group(identity.pid) }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var termSent: Set<RequestProcessIdentity> = [], killSent: Set<RequestProcessIdentity> = []
        while true {
            let observation = try RequestProcessIdentity.observe(in: directory, known: targets)
            targets = Array(Set((targets + observation.identities).filter(\.isCurrent)))
            let signal = ProcessInfo.processInfo.systemUptime >= deadline - 5 ? SIGKILL : SIGTERM
            let pending = RequestProcessIdentity.shutdownTargets(targets, sessions: observation.sessions, signal: signal).filter { identity in
                signal == SIGTERM ? termSent.insert(identity).inserted : killSent.insert(identity).inserted
            }
            RequestProcessIdentity.signal(pending, signal)
            if observation.uncertainty == nil, !targets.contains(where: \.isCurrent) {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("children.json"))
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("supervision.json")); return
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw RequestWorkerTeardownError(cause: observation.uncertainty) }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }
}
#endif
