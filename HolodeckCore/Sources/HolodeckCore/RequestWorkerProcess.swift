#if os(macOS)
import Foundation
import Darwin

nonisolated struct RequestWorkerTeardownError: LocalizedError, Sendable {
    var cause: String? = nil
    var errorDescription: String? { "Worker processes did not exit within ten seconds. Checkout recovery is required; process evidence was retained." + (cause.map { " Original error: " + $0 } ?? "") }
}

nonisolated struct RequestProcessIdentity: Codable, Sendable, Equatable {
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
    static func group(_ pid: Int32) -> [Self] {
        var pids = [Int32](repeating: 0, count: 8192)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<Int32>.size).compactMap { Self(pid: $0) }
    }
    static func registered(in directory: URL) throws -> [Self] {
        struct Entry: Decodable { let leader: RequestProcessIdentity; let members: [RequestProcessIdentity]; let unverified: Bool? }
        let marker = directory.appendingPathComponent("children.json")
        guard FileManager.default.fileExists(atPath: marker.path) else { return [] }
        let entries: [Entry]
        do { entries = try JSONDecoder().decode([Entry].self, from: BoundedCatalogReader(root: directory).read("children.json", limit: CatalogLimits.headBytes).bytes) }
        catch {
            if !FileManager.default.fileExists(atPath: marker.path) { return [] }
            throw error
        }
        guard entries.allSatisfy({ $0.leader.pid > 1 && $0.members.allSatisfy { $0.pid > 1 } }) else {
            throw ShaderRequestError.unavailable("Invalid validation process registry. Retain the journal and repair or detach this checkout.")
        }
        if entries.contains(where: { $0.unverified == true && kill(-$0.leader.pid, 0) == 0 }) {
            throw RequestWorkerTeardownError(cause: "Unverified validation descendants remain.")
        }
        return try entries.flatMap { entry in
            let known = entry.members.filter(\.isCurrent)
            if entry.leader.isCurrent { return known + group(entry.leader.pid) }
            // Observe an abandoned group only to detect missing evidence; never adopt or signal
            // fresh members after its leader has exited. A reused leader PID is unrelated.
            if Self(pid: entry.leader.pid) == nil,
               group(entry.leader.pid).contains(where: { !known.contains($0) }) {
                throw RequestWorkerTeardownError(cause: "Unverified validation descendants remain.")
            }
            return known
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
        var isAlive: @Sendable (Int32) -> Bool = { $0 > 1 && kill(-$0, 0) == 0 }
        var signal: @Sendable (Int32, Int32) -> Int32 = { kill(-$0, $1) }
        var schedule: @Sendable (DispatchWorkItem) -> Void = { DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: $0) }
    }
    static var bundledScript: URL? { Bundle.module.url(forResource: "shader_requests", withExtension: "py") }
    let process = Process()
    private let scriptOverride: URL?
    private let groups: GroupOperations
    private let input = Pipe(), output = Pipe(), error = Pipe()
    private let lock = NSLock(), drained = DispatchGroup()
    private var started = false, stopping = false, completed = false
    private var stopTime: Date?
    private var leader: RequestProcessIdentity?
    private var owned: [Int32: RequestProcessIdentity] = [:]
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
        if let leader, leader.isCurrent {
            for identity in RequestProcessIdentity.group(leader.pid) { owned[identity.pid] = identity }
        }
        if let journal {
            do { for identity in try RequestProcessIdentity.registered(in: journal) { owned[identity.pid] = identity } }
            catch { firstError = firstError ?? error; teardownFailed = true }
        }
    }
    func stop() {
        lock.withLock {
            guard !completed else { return }
            stopping = true; stopTime = stopTime ?? Date()
            guard started else { return }
            refreshOwnedLocked()
            RequestProcessIdentity.signal(Array(owned.values), SIGTERM)
            if escalation == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        guard !self.completed else { return }
                        self.refreshOwnedLocked()
                        RequestProcessIdentity.signal(Array(self.owned.values), SIGKILL)
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
                    process.arguments = [script.path, mode, directory.appendingPathComponent("configuration.json").path, directory.path]
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
                        leader = RequestProcessIdentity(pid: process.processIdentifier)
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
                            return stopTime.map { Date().timeIntervalSince($0) >= 10 } ?? false
                        }
                        if expired { lock.withLock { teardownFailed = true }; break }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    if pipes.wait(timeout: .now() + (lock.withLock { stopping } ? 0 : 5)) == .timedOut {
                        stop()
                        let remaining = lock.withLock { max(0, 10 - Date().timeIntervalSince(stopTime ?? Date())) }
                        if pipes.wait(timeout: .now() + remaining) == .timedOut { lock.withLock { teardownFailed = true } }
                    }
                    // Keep the journal if any registered descendant survives.
                    if lock.withLock({ refreshOwnedLocked(); return owned.values.contains(where: \.isCurrent) }) {
                        stop()
                        while lock.withLock({ owned.values.contains(where: \.isCurrent) && Date().timeIntervalSince(stopTime ?? Date()) < 10 }) {
                            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                        }
                    }
                    lock.withLock {
                        refreshOwnedLocked()
                        if owned.values.contains(where: \.isCurrent) { teardownFailed = true }
                    }
                    if lock.withLock({ teardownFailed }) { throw RequestWorkerTeardownError(cause: lock.withLock { firstError?.localizedDescription }) }
                    if let failure = lock.withLock({ firstError }) { throw failure }
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("process.json"))
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("children.json"))
                    if lock.withLock({ stopping }) { throw CancellationError() }
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
        var targets = try RequestProcessIdentity.registered(in: directory)
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
        for signal in [SIGTERM, SIGKILL] {
            RequestProcessIdentity.signal(targets, signal)
            let deadline = Date().addingTimeInterval(5)
            while targets.contains(where: \.isCurrent), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if !targets.contains(where: \.isCurrent) {
                // A leader may exit before a newly forked descendant was recorded.
                // In that case registered() retains the evidence instead of releasing the checkout.
                let remaining = try RequestProcessIdentity.registered(in: directory)
                if remaining.contains(where: \.isCurrent) { throw RequestWorkerTeardownError() }
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("children.json")); return
            }
        }
        throw RequestWorkerTeardownError()
    }
}
#endif
