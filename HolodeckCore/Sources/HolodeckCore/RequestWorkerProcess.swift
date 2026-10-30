#if os(macOS)
import Foundation
import Darwin

nonisolated enum RequestWorkerDiagnostic {
    static func combined(_ causes: String?...) -> String? {
        let value = causes.compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "; ")
        return value.isEmpty ? nil : value
    }
}

nonisolated struct RequestWorkerTeardownError: LocalizedError, Sendable {
    var cause: String? = nil
    var errorDescription: String? { "Worker processes did not exit within ten seconds. Checkout recovery is required; process evidence was retained." + (cause.map { " Original error: " + $0 } ?? "") }
}

nonisolated struct RequestWorkerOwnershipError: LocalizedError, Sendable {
    var cause: String? = nil
    var errorDescription: String? { "Worker ownership cannot be verified. Registered commands were left untouched; repair the worker marker and retry recovery before reusing or detaching the checkout." + (cause.map { " Original error: " + $0 } ?? "") }
}

nonisolated struct RequestWorkerEvidenceError: LocalizedError, Sendable {
    let cause: String
    var errorDescription: String? { cause + " Repair the journal or detach while retaining its files and evidence." }
}

nonisolated final class RequestBootIdentityCache: @unchecked Sendable {
    private let lock = NSLock()
    private let read: @Sendable () -> String?
    private var cached: String?
    init(read: @escaping @Sendable () -> String?) { self.read = read }
    func value() -> String? {
        if let value = lock.withLock({cached}) { return value }
        guard let value = read() else { return nil }
        return lock.withLock { cached = cached ?? value;return cached }
    }
}

nonisolated struct RequestSettlementBudget: Codable, Sendable {
    var attemptID: UUID
    var bootID: String?
    var clock: String
    var startedAt: TimeInterval
    var deadline: TimeInterval
    private static let bootCache = RequestBootIdentityCache(read:readBootIdentity)
    static var bootIdentity: String? { bootCache.value() }
    private static func readBootIdentity() -> String? {
        var bytes = [CChar](repeating: 0, count: 128), count = 128
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0,
              let uuid = UUID(uuidString: String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) }, as:UTF8.self)) else { return nil }
        return uuid.uuidString.lowercased()
    }
    init(now: TimeInterval, boot: String? = Self.bootIdentity) {
        attemptID = UUID(); bootID = boot; clock = "darwin-uptime-raw"; startedAt = now; deadline = now + 10
    }
    var valid: Bool {
        clock == "darwin-uptime-raw" && (bootID == nil || UUID(uuidString:bootID!) != nil) &&
        startedAt.isFinite && deadline.isFinite && deadline >= startedAt && deadline - startedAt <= 10.001
    }
    func expired(at now: TimeInterval) -> Bool { now >= deadline }
    func escalated(at now: TimeInterval) -> Bool { now >= startedAt + 5 }
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
        let termination: RequestSettlementBudget?
    }
    struct Observation {
        var identities: [RequestProcessIdentity]
        var uncertainty: String?
        var evidenceErrors: [String] = []
        var evidenceError: String? { evidenceErrors.isEmpty ? nil : evidenceErrors.joined(separator:"; ") }
        mutating func addEvidenceError(_ message: String) {
            if !evidenceErrors.contains(message) { evidenceErrors.append(message) }
        }
        var observationFailure: String?
        var sessions: [RequestProcessIdentity: [RequestProcessIdentity]] = [:]
        var supervisors: Set<RequestProcessIdentity> = []
    }
    static func evidenceExists(_ file: URL) -> Bool {
        var info = stat()
        return lstat(file.path, &info) == 0 || errno != ENOENT
    }
    static func arguments(_ pid: Int32) throws -> [String] {
        var maximum: Int32 = 0, size = MemoryLayout<Int32>.size
        var maximumName: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&maximumName, 2, &maximum, &size, nil, 0) == 0,
              maximum > 0, maximum <= 1_048_576 else { throw RequestWorkerOwnershipError() }
        var bytes = [UInt8](repeating:0,count:Int(maximum)), name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        size = bytes.count
        guard sysctl(&name, 3, &bytes, &size, nil, 0) == 0, size >= 4 else { throw RequestWorkerOwnershipError() }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as:Int32.self) }
        guard count > 0 else { throw RequestWorkerOwnershipError() }
        let strings = bytes.prefix(size).dropFirst(4).split(separator:0).map { String(decoding:$0,as:UTF8.self) }
        guard strings.count >= Int(count) + 1 else { throw RequestWorkerOwnershipError() }
        return Array(strings.dropFirst().prefix(Int(count))) // executable path precedes argv; never inspect the environment.
    }
    static func observe(in directory: URL, known additional: [Self] = [],
                        group: @escaping (Int32) throws -> [Self] = checkedGroup,
                        identity: @escaping (Int32) -> Self? = { Self(pid:$0) }) throws -> Observation {
        struct Entry: Decodable { let leader: RequestProcessIdentity; var members: [RequestProcessIdentity] }
        var result = Observation(identities: [])
        let pass = RequestObservationPass(group:group,identity:identity)
        guard evidenceExists(directory) else {
            return Observation(identities:additional.filter { pass.current($0) })
        }
        let reader = try BoundedCatalogReader(root: directory)
        let supervision: Supervision?
        do {
            let file = directory.appendingPathComponent("supervision.json")
            if Self.evidenceExists(file) {
                let value = try JSONDecoder().decode(Supervision.self, from: reader.read("supervision.json", limit: CatalogLimits.headBytes).bytes)
                guard [1, 2, 3].contains(value.formatVersion), value.supervisor.pid > 1, (value.command?.pid ?? 2) > 1,
                      ["starting", "running", "draining", "settled", "failed", "cancelled"].contains(value.state),
                      value.formatVersion == 1 || (value.sessionID != nil && (value.revision ?? -1) >= 0 && value.clock == "darwin-uptime-raw" && value.pipeDrainComplete != nil && value.processesSettled != nil && value.deadline?.isFinite != false),
                      value.formatVersion != 3 || value.termination?.valid != false else {
                    throw RequestWorkerEvidenceError(cause: "Invalid supervision evidence.")
                }
                supervision = value
            } else { supervision = nil }
        } catch {
            supervision = nil
            if Self.evidenceExists(directory.appendingPathComponent("supervision.json")) {
                result.addEvidenceError("Supervision evidence is unreadable: " + error.localizedDescription)
            }
        }
        var entries: [Entry] = []
        do {
            if Self.evidenceExists(directory.appendingPathComponent("children.json")) {
                let values = try JSONDecoder().decode([Entry].self, from: reader.read("children.json", limit: CatalogLimits.headBytes).bytes)
                guard values.allSatisfy({ $0.leader.pid > 1 && $0.members.allSatisfy { $0.pid > 1 } }) else {
                    throw RequestWorkerEvidenceError(cause: "Invalid validation process identities.")
                }
                entries = values
            }
        } catch {
            if Self.evidenceExists(directory.appendingPathComponent("children.json")) {
                result.addEvidenceError("Validation process registry is unreadable: " + error.localizedDescription)
            }
        }
        if let supervision {
            result.supervisors.insert(supervision.supervisor)
            // Both files independently retain ownership, including a known command that
            // closed its pipes before its supervisor or registry disappeared.
            let members = [supervision.supervisor] + [supervision.command].compactMap { $0 }
            if let index = entries.firstIndex(where: { $0.leader == supervision.supervisor }) { entries[index].members += members }
            else { entries.append(Entry(leader: supervision.supervisor, members: members)) }
            if (supervision.recoveryRequired == true && supervision.failureKind == "pipeDrain") ||
                (supervision.formatVersion >= 2 && !pass.current(supervision.supervisor) && supervision.pipeDrainComplete != true) {
                result.addEvidenceError(supervision.failureKind == "pipeDrain" ? (supervision.failure ?? "Output pipe completion is unverified.") : "Output pipe completion is unverified.")
            }
        }
        for entry in entries {
            let known = Array(Set(entry.members + additional)).filter { pass.current($0) }
            result.identities += known // Never lose verified members when enumeration fails.
            do {
                let observed = try pass.anchor(entry.leader,known:known,label:"validation")
                result.identities += observed.identities
                result.uncertainty = observed.uncertainty ?? result.uncertainty
                if entry.leader == supervision?.supervisor, pass.current(entry.leader) {
                    result.sessions[entry.leader] = Array(Set(entry.members.filter { pass.current($0) } + (try pass.group(entry.leader.pid))))
                }
            } catch { result.observationFailure = error.localizedDescription }
        }
        result.identities = Array(Set(result.identities))
        return result
    }
    static func shutdownTargets(_ identities: [Self], sessions: [Self: [Self]], signal: Int32, allowOwnerRetirement: Bool = true,
                                identity: (Int32) -> Self? = { Self(pid:$0) }) -> [Self] {
        let currentSessions = sessions.filter { identity($0.key.pid) == $0.key }
        return identities.filter { identity in
            if let members = currentSessions[identity] {
                return signal == SIGTERM || (allowOwnerRetirement && !members.contains(where: { $0 != identity }))
            }
            if signal == SIGTERM, currentSessions.values.contains(where: { $0.contains(identity) }) { return false }
            return true
        }
    }
    static func signal(_ identities: [Self], _ signal: Int32, identity: (Int32) -> Self? = { Self(pid:$0) },
                       send: (Int32,Int32) -> Int32 = { kill($0,$1) }) {
        for value in identities where identity(value.pid) == value { _ = send(value.pid, signal) }
    }
}

/// One pass caches successful and failed enumeration and birth reads outside ownership locks.
nonisolated private final class RequestObservationPass {
    let identity: (Int32) -> RequestProcessIdentity?
    private let enumerate: (Int32) throws -> [RequestProcessIdentity]
    private var groups: [Int32: Result<[RequestProcessIdentity],Error>] = [:]
    private var births: [Int32: RequestProcessIdentity?] = [:]
    init(group: @escaping (Int32) throws -> [RequestProcessIdentity], identity: @escaping (Int32) -> RequestProcessIdentity?) {
        self.enumerate = group; self.identity = identity
    }
    func birth(_ pid: Int32) -> RequestProcessIdentity? {
        if let value = births[pid] { return value }
        let value = identity(pid); births.updateValue(value,forKey:pid); return value
    }
    func current(_ value: RequestProcessIdentity) -> Bool { birth(value.pid) == value }
    func group(_ pid: Int32) throws -> [RequestProcessIdentity] {
        if let value = groups[pid] { return try value.get() }
        let result = Result { try enumerate(pid) }; groups[pid] = result; return try result.get()
    }
    func anchor(_ leader: RequestProcessIdentity, known: [RequestProcessIdentity], label: String) throws -> RequestProcessIdentity.Observation {
        let currentBirth = birth(leader.pid), currentKnown = known.filter { current($0) }
        if currentBirth == leader {
            return .init(identities:Array(Set(currentKnown + [leader] + (try group(leader.pid)))))
        }
        let unfamiliar = try currentBirth == nil && group(leader.pid).contains { !currentKnown.contains($0) }
        return .init(identities:currentKnown,uncertainty:unfamiliar ? "Unverified " + label + " descendants remain." : nil)
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
    func receive(_ bytes: Data, continuation: AsyncThrowingStream<RequestWorkerEvent, Error>.Continuation, observe: (RequestWorkerEvent) -> Void) {
        pending.append(bytes)
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
            if let event = try? JSONDecoder().decode(RequestWorkerEvent.self, from: line) { observe(event); continuation.yield(event) }
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
        var boot: @Sendable () -> String? = { RequestSettlementBudget.bootIdentity }
        var arguments: @Sendable (Int32) throws -> [String] = { try RequestProcessIdentity.arguments($0) }
    }
    static let bootstrap = """
    import json,os,runpy,sys
    if sys.version_info < (3,9):
        print(json.dumps({'event':'failure','message':'The shader checker requires Python 3.9 or later; choose a supported interpreter.'}),flush=True)
        sys.exit(2)
    try: os.setsid()
    except PermissionError: pass
    if sys.stdin.readline() != sys.argv[1]+'\\n': sys.exit(125)
    sys.argv=sys.argv[2:]
    runpy.run_path(sys.argv[0],run_name='__main__')
    """
    static var bundledScript: URL? { Bundle.module.url(forResource: "shader_requests", withExtension: "py") }
    let process = Process()
    private let scriptOverride: URL?
    private let groups: GroupOperations
    private let input = Pipe(), output = Pipe(), error = Pipe()
    private let lock = NSLock(), drained = DispatchGroup()
    private let signalQueue = DispatchQueue(label:"Holodeck.worker-signals")
    private var ownershipGeneration: UInt64 = 0
    private var started = false, stopping = false, completed = false
    private var terminationBudget: RequestSettlementBudget?
    private var cancelRequested = false
    private var termSent: Set<RequestProcessIdentity> = [], killSent: Set<RequestProcessIdentity> = []
    private var registryError: Error?
    private var leader: RequestProcessIdentity?
    private var owned: [Int32: RequestProcessIdentity] = [:]
    private var supervisedSessions: [RequestProcessIdentity: [RequestProcessIdentity]] = [:]
    private var supervisorAnchors: Set<RequestProcessIdentity> = []
    private var journal: URL?
    private var workerConfiguration: ShaderRequestConfiguration?
    private var initiatingFailure: Error?
    private var parsedFailure: Error?
    private static func supervisionFailure(_ error: Error) -> Error {
        if error is RequestWorkerSupervisionError || error is RequestWorkerTeardownError || error is RequestWorkerEvidenceError || error is RequestWorkerOwnershipError || error is ShaderRequestError { return error }
        return RequestWorkerSupervisionError(message: error.localizedDescription, underlyingError: error, retryable: !(error is POSIXError || error is CocoaError))
    }
    var recordedFailure: Error? { lock.withLock { initiatingFailure ?? firstError.map(Self.supervisionFailure) ?? parsedFailure } }
    private var firstError: Error?
    private var logFailed = false
    private var nextObservation: TimeInterval = 0
    private var observationFailures = 0
    private var observationInFlight = false
    private var rootStopObserved = false
    private var gateReleased = false
    private var rootTermSentAt: TimeInterval?
    private var teardownFailed = false
    private var retainedRecoveryError: Error?
    private var signalPassPending = false
    private var nextSignalPass: TimeInterval = 0
    var beforeReplyWrite: (() -> Void)?
    var beforeBirthCapture: (() -> Void)?
    var beforeIdentityWrite: (() throws -> Void)?
    var beforeGateRelease: (() throws -> Void)?
    var beforeLogWrite: (() throws -> Void)?
    var beforeSignalPass: (() -> Void)?
    var afterObservationCommit: (([RequestProcessIdentity]) -> Void)?
    init(script: URL? = nil, groups: GroupOperations = .init()) { scriptOverride = script; self.groups = groups }
    var recoveryTarget: (directory: URL, configuration: ShaderRequestConfiguration)? {
        lock.withLock {
            guard let journal, let workerConfiguration else { return nil }
            return (journal, workerConfiguration)
        }
    }

    private func unavailableReply() -> Error {
        if let failure = initiatingFailure ?? firstError.map(Self.supervisionFailure) ?? parsedFailure { return failure }
        if cancelRequested { return CancellationError() }
        return RequestWorkerSupervisionError(message: "Worker stopped before accepting its reply. See its retained log.")
    }
    func reply(_ accepted: Bool, message: String? = nil) throws {
        struct Reply: Encodable { let ok: Bool; let message: String? }
        try lock.withLock { guard started, gateReleased, !stopping, process.isRunning else { throw unavailableReply() } }
        beforeReplyWrite?()
        try lock.withLock {
            guard started, gateReleased, !stopping, process.isRunning else { throw unavailableReply() }
            var bytes = try JSONEncoder().encode(Reply(ok: accepted, message: message)); bytes.append(10)
            try input.fileHandleForWriting.write(contentsOf: bytes)
        }
    }
    private func refreshOwned(force: Bool = false) {
        // Enumeration, evidence reads and birth queries run outside the state lock.
        // Cancellation, replies and log readers never wait for those observations.
        let snapshot: (RequestProcessIdentity?, URL?, [RequestProcessIdentity], Bool, UInt64, Set<RequestProcessIdentity>)? = lock.withLock {
            guard !completed, !observationInFlight, force || groups.now() >= nextObservation else { return nil }
            observationInFlight = true; nextObservation = groups.now() + 0.25
            return (leader,journal,Array(owned.values),stopping,ownershipGeneration,supervisorAnchors)
        }
        guard let (root,directory,known,stoppingAtSnapshot,generation,anchors) = snapshot else { return }
        let pass = RequestObservationPass(group:groups.group,identity:groups.identity)
        var observed = known.filter { pass.current($0) }
        var observation = RequestProcessIdentity.Observation(identities:[])
        var failure: Error?
        if let root {
            do {
                let result = try pass.anchor(root,known:observed,label:"worker")
                observed += result.identities; observation.uncertainty = result.uncertainty
            } catch { failure = error }
        }
        if let directory {
            do {
                let result = try RequestProcessIdentity.observe(in:directory,known:observed,group:pass.group,identity:pass.birth)
                observation.identities = result.identities; observation.sessions = result.sessions; observation.supervisors = result.supervisors
                observation.uncertainty = result.uncertainty ?? observation.uncertainty; observation.evidenceErrors = result.evidenceErrors
                if let detail = result.observationFailure { failure = RequestWorkerTeardownError(cause:detail) }
            } catch { failure = error }
        }
        let verified = Set((known + observed + observation.identities).filter { pass.current($0) })
        let currentAnchors = anchors.union(observation.supervisors).filter { pass.current($0) }
        let currentSessions = (failure == nil ? observation.sessions : [:]).filter { pass.current($0.key) }
        let shouldStop = lock.withLock { () -> Bool in
            observationInFlight = false
            guard !completed, journal == directory, leader == root, ownershipGeneration == generation else { return false }
            if Set(owned.values) != verified { nextSignalPass = 0 }
            owned = Dictionary(uniqueKeysWithValues:verified.map { ($0.pid,$0) })
            termSent.formIntersection(verified); killSent.formIntersection(verified)
            // Failed observations never delegate through a stale cached supervisor map.
            supervisedSessions = currentSessions; supervisorAnchors = currentAnchors
            if let failure {
                observationFailures += 1; registryError = failure
                if observationFailures >= 3 {
                    let detail = (failure as? RequestWorkerTeardownError)?.cause ?? failure.localizedDescription
                    firstError = firstError ?? RequestWorkerSupervisionError(message: "Repeated process observation failure: " + detail)
                    initiatingFailure = initiatingFailure ?? firstError.map(Self.supervisionFailure)
                    return true
                }
                return false
            }
            observationFailures = 0
            if stoppingAtSnapshot, !rootStopObserved { rootStopObserved = true;nextSignalPass = 0 }
            registryError = observation.uncertainty.map { RequestWorkerTeardownError(cause: $0) } ?? observation.evidenceError.map { RequestWorkerEvidenceError(cause: $0) }
            return false
        }
        afterObservationCommit?(lock.withLock { Array(owned.values) })
        if shouldStop { beginTeardown(cancelled: false) }
    }
    private func signalPending() {
        let enqueue = lock.withLock { () -> Bool in
            let now = groups.now()
            guard started,stopping,!completed,!signalPassPending,now >= nextSignalPass,
                  terminationBudget?.expired(at:now) != true else { return false }
            let rootRunning = process.isRunning
            let candidates = rootRunning ? leader.map{[$0]} ?? [] : Array(owned.values)
            let due = candidates.contains { identity in
                if !termSent.contains(identity) { return true }
                let escalate = rootRunning ? rootTermSentAt.map{now >= $0 + 5} == true : terminationBudget?.escalated(at:now) == true
                return escalate && !killSent.contains(identity)
            }
            guard due else { return false }
            signalPassPending = true;nextSignalPass = now + 0.25;return true
        }
        guard enqueue else { return }
        signalQueue.async { [self] in
            defer { lock.withLock{signalPassPending = false} }
            beforeSignalPass?()
            let snapshot = lock.withLock { () -> (RequestProcessIdentity?,[RequestProcessIdentity],[RequestProcessIdentity:[RequestProcessIdentity]],Bool,Bool,UInt64,Set<RequestProcessIdentity>)? in
                guard started,stopping,!completed,terminationBudget?.expired(at:groups.now()) != true else { return nil }
                return (leader,Array(owned.values),supervisedSessions,rootTermSentAt.map { groups.now() >= $0 + 5 } == true,
                        rootStopObserved || observationFailures >= 3,ownershipGeneration,supervisorAnchors)
            }
            guard let (root,identities,sessions,rootEscalated,rootReady,generation,anchors) = snapshot else { return }
            let rootLive = root.map { passBirth in groups.identity(passBirth.pid) == passBirth } == true
            let kill = rootLive ? rootEscalated : lock.withLock { terminationBudget?.escalated(at:groups.now()) == true }
            let signal = kill ? SIGKILL : SIGTERM
            let pass = RequestObservationPass(group:groups.group,identity:groups.identity)
            let targets: [RequestProcessIdentity]
            if let root, pass.current(root) {
                targets = rootReady || kill ? [root] : []
            } else if root == nil && process.isRunning {
                targets = [] // No verified worker root: never cancel commands underneath a running worker.
            } else {
                targets = RequestProcessIdentity.shutdownTargets(identities,sessions:sessions,signal:signal,
                    allowOwnerRetirement:rootReady,identity:pass.birth)
            }
            for identity in targets where groups.identity(identity.pid) == identity {
                if lock.withLock({ kill ? killSent.contains(identity) : termSent.contains(identity) }) { continue }
                if kill, anchors.contains(identity), identity != root {
                    // Retire owners only after a fresh, successful sole-member observation.
                    do { if try pass.group(identity.pid).contains(where: { $0 != identity }) { continue } }
                    catch { lock.withLock { registryError = error }; continue }
                }
                for value in [SIGTERM] + (kill ? [SIGKILL] : []) {
                    let reserved = lock.withLock { () -> Bool in
                        guard !completed,ownershipGeneration == generation,terminationBudget?.expired(at:groups.now()) != true else { return false }
                        if value == SIGTERM {
                            let inserted = termSent.insert(identity).inserted
                            if inserted, identity == root { rootTermSentAt = groups.now() }
                            return inserted
                        }
                        return killSent.insert(identity).inserted
                    }
                    if reserved,groups.identity(identity.pid) == identity,groups.signal(identity.pid,value) != 0,errno != ESRCH {
                        lock.withLock { registryError = RequestWorkerTeardownError(cause:"Cannot signal verified process: " + String(cString:strerror(errno))) }
                    }
                }
            }
        }
    }
    func stop() { beginTeardown(cancelled: true) }
    func shutdown() { beginTeardown(cancelled: false) }
    private func beginTeardown(cancelled: Bool) {
        let boot = groups.boot()
        lock.withLock {
            guard !completed else { return }
            cancelRequested = cancelRequested || cancelled
            if !stopping { nextObservation = 0;nextSignalPass = 0 }
            stopping = true; terminationBudget = terminationBudget ?? RequestSettlementBudget(now:groups.now(),boot:boot)
            guard started else { return }
            if !gateReleased { try? input.fileHandleForWriting.close() }

        }
        signalPending()
    }
    private func record(_ error: Error) {
        lock.withLock { firstError = firstError ?? error; initiatingFailure = initiatingFailure ?? Self.supervisionFailure(error) }
        beginTeardown(cancelled: false)
    }

    func run(mode: String, configuration: ShaderRequestConfiguration, directory: URL, operationID: UUID? = nil) -> AsyncThrowingStream<RequestWorkerEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { journal = directory; workerConfiguration = configuration }
            drained.enter()
            DispatchQueue(label: "Holodeck.request-worker").async { [self] in
                let pipes = DispatchGroup()
                var readers: [RequestPipeDrain] = []
                defer {
                    readers.forEach { $0.cancel() }
                    lock.withLock { completed = true; ownershipGeneration &+= 1 }
                    drained.leave()
                }
                do {
                    guard let script = scriptOverride ?? Self.bundledScript else { throw ShaderRequestError.unavailable("Bundled shader request worker is missing.") }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    if let operationID {
                        try RequestWorkerOperation.validateLaunch(id: operationID, configuration: configuration, in: directory)
                    } else {
                        try RequestJournalWriter.write(RequestWorkerOperation.encodedConfiguration(configuration, id: nil), to: directory.appendingPathComponent("configuration.json"))
                    }
                    process.executableURL = URL(fileURLWithPath: configuration.python)
                    let launchToken = UUID().uuidString
                    process.arguments = ["-I", "-c", Self.bootstrap, launchToken, script.path, mode, directory.appendingPathComponent("configuration.json").path, directory.path]
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
                            if parsesEvents { parser.receive(bytes, continuation: continuation) { event in
                                if let failure = event.failureError { self.lock.withLock { self.parsedFailure = self.parsedFailure ?? failure; self.initiatingFailure = self.initiatingFailure ?? failure } }
                            } }
                        })
                    }
                    try lock.withLock {
                        guard !stopping else { throw CancellationError() }
                        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw POSIXError(.EIO) }
                        do { try process.run() }
                        catch { throw ShaderRequestError.unavailable("Worker interpreter could not launch: " + error.localizedDescription) }
                        started = true
                    }
                    beforeBirthCapture?()
                    var birth: RequestProcessIdentity?
                    for observation in 0..<3 {
                        if !process.isRunning || lock.withLock({ stopping }) { break }
                        if let value = groups.identity(process.processIdentifier) { birth = value; break }
                        if observation < 2 { groups.wait(0.25) }
                    }
                    lock.withLock {
                        leader = birth; ownershipGeneration &+= 1
                        if let birth { owned[birth.pid] = birth }
                    }
                    guard let birth else {
                        if lock.withLock({ stopping }) { throw CancellationError() }
                        if !process.isRunning { throw startupExitError() }
                        throw RequestWorkerSupervisionError(message:"Worker birth identity could not be established; checkout execution was not released.")
                    }
                    try beforeIdentityWrite?()
                    try RequestJournalWriter.write(JSONEncoder().encode(WorkerIdentity(pid: birth.pid, script: script.path,
                        directory: directory.path, birth: birth)), to: directory.appendingPathComponent("process.json"))
                    try beforeGateRelease?()
                    if lock.withLock({ cancelRequested }) { throw CancellationError() }
                    guard groups.identity(birth.pid) == birth else {
                        if !process.isRunning { throw startupExitError() }
                        throw RequestWorkerOwnershipError()
                    }
                    try lock.withLock {
                        guard !stopping else { throw CancellationError() }
                        guard process.isRunning else { throw startupExitError() }
                        try input.fileHandleForWriting.write(contentsOf:Data((launchToken + "\n").utf8))
                        gateReleased = true
                    }
                    while process.isRunning {
                        refreshOwned()
                        signalPending()
                        let expired = lock.withLock { () -> Bool in
                            return terminationBudget?.expired(at:groups.now()) ?? false
                        }
                        if expired { lock.withLock { teardownFailed = true }; break }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    let leaderExited = groups.now()
                    lock.withLock { nextObservation = 0 }
                    while true {
                        refreshOwned()
                        signalPending()
                        let pipesDone = pipes.wait(timeout: .now()) == .success
                        if pipesDone, !process.isRunning, lock.withLock({ owned.isEmpty }) {
                            let pendingSignals = DispatchGroup(); pendingSignals.enter()
                            signalQueue.async { pendingSignals.leave() }
                            if pendingSignals.wait(timeout:.now() + 0.025) == .success {
                                refreshOwned(force: true)
                                if lock.withLock({ owned.isEmpty }) {
                                    if let failure = lock.withLock({ registryError as? RequestWorkerEvidenceError }) { throw failure }
                                    if lock.withLock({ registryError == nil }) { break }
                                }
                            }
                        }
                        // Permit short natural EOF/registry settlement without declaring cancellation.
                        if lock.withLock({ terminationBudget == nil }), groups.now() - leaderExited >= 0.1 {
                            beginTeardown(cancelled: false)
                        }
                        if lock.withLock({ terminationBudget?.expired(at:groups.now()) ?? false }) {
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
                    if process.terminationReason == .uncaughtSignal {
                        throw RequestWorkerSupervisionError(message: "Worker terminated by signal \(process.terminationStatus) after launch. See its retained log.")
                    }
                    if process.terminationStatus != 0 {
                        throw recordedFailure ?? RequestWorkerSupervisionError(message: "Worker exited \(process.terminationStatus) after launch without a failure event. See its retained log.")
                    }
                    continuation.finish()
                } catch {
                    // Diagnostic priority and recovery classification are independent.
                    // A worker's ordinary failure cannot certify damaged ownership evidence.
                    let caught = error
                    let original = recordedFailure
                    let detail = original.map { $0.localizedDescription }
                    let error: Error
                    switch caught {
                    case let failure as RequestWorkerEvidenceError:
                        error = RequestWorkerEvidenceError(cause: failure.cause + (detail.map { " Original worker error: " + $0 } ?? ""))
                    case let failure as RequestWorkerOwnershipError:
                        error = RequestWorkerOwnershipError(cause: RequestWorkerDiagnostic.combined(failure.cause, detail))
                    case let failure as RequestWorkerTeardownError:
                        error = RequestWorkerTeardownError(cause: RequestWorkerDiagnostic.combined(failure.cause, detail))
                    default: error = original ?? caught
                    }
                    if lock.withLock({ started && !gateReleased }) {
                        beginTeardown(cancelled: false)
                        while process.isRunning || pipes.wait(timeout:.now()) != .success {
                            refreshOwned(); signalPending()
                            if lock.withLock({ terminationBudget?.expired(at:groups.now()) == true }) {
                                lock.withLock { teardownFailed = true }; break
                            }
                            groups.wait(0.025)
                        }
                    }
                    if lock.withLock({ teardownFailed }) {
                        continuation.finish(throwing:RequestWorkerTeardownError(cause:error.localizedDescription)); return
                    }
                    if error is RequestWorkerEvidenceError || error is RequestWorkerOwnershipError { lock.withLock { retainedRecoveryError = error } }
                    if process.isRunning { shutdown() }
                    if error is CancellationError || error is RequestWorkerTeardownError || error is RequestWorkerEvidenceError ||
                       error is RequestWorkerOwnershipError || error is RequestWorkerSupervisionError || error is ShaderRequestError {
                        continuation.finish(throwing:error)
                    } else {
                        continuation.finish(throwing:RequestWorkerSupervisionError(message:error.localizedDescription,underlyingError:error,retryable:!(error is POSIXError || error is CocoaError)))
                    }
                }
            }
            continuation.onTermination = { [weak self] reason in if case .cancelled = reason { self?.stop() } }
        }
    }
    private func startupExitError() -> ShaderRequestError {
        let reason = process.terminationReason == .uncaughtSignal ? "signal" : "exit"
        return .unavailable("Worker interpreter exited before checkout execution was released (" + reason + " " + String(process.terminationStatus) + "). See retained worker-stderr.log and worker.log.")
    }
    func waitForExit() async throws {
        let finished: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in continuation.resume(returning: drained.wait(timeout: .now() + 11) == .success) }
        }
        guard finished, !lock.withLock({ teardownFailed }) else { stop(); throw RequestWorkerTeardownError(cause: lock.withLock { firstError?.localizedDescription }) }
        if let error = lock.withLock({ retainedRecoveryError }) { throw error }
    }
    private struct WorkerIdentity: Codable { let pid: Int32; let script: String; let directory: String; var birth: RequestProcessIdentity? }
    static func reconcileOrphan(in directory: URL, groups: GroupOperations = .init()) throws {
        let file = directory.appendingPathComponent("process.json")
        var root: RequestProcessIdentity?
        var markerError: String?
        if RequestProcessIdentity.evidenceExists(file) {
            do {
                let identity: WorkerIdentity
                do { identity = try JSONDecoder().decode(WorkerIdentity.self, from: BoundedCatalogReader(root: directory).read("process.json", limit: CatalogLimits.headBytes).bytes) }
                catch { throw ShaderRequestError.unavailable("Worker identity is unreadable. Repair the journal marker or detach the checkout while retaining its evidence.") }
                guard identity.pid > 1, identity.birth.map({ $0.pid == identity.pid }) != false, RequestPaths.canonical(URL(fileURLWithPath: identity.directory)) == RequestPaths.canonical(directory) else {
                    throw ShaderRequestError.unavailable("Worker identity does not belong to this request journal.")
                }
                if let birth = identity.birth {
                    root = birth // A retired birth still identifies the group whose unfamiliar members must remain unowned.
                } else if let birth = groups.identity(identity.pid) {
                    let arguments = try groups.arguments(identity.pid)
                    if groups.identity(birth.pid) == birth, arguments.contains(identity.script), arguments.contains(identity.directory) { root = birth }
                }
            } catch { markerError = error.localizedDescription }
        }
        var targets = root.map { [$0] } ?? []
        let budget = RequestSettlementBudget(now:groups.now(),boot:groups.boot())
        var termSent: Set<RequestProcessIdentity> = [], killSent: Set<RequestProcessIdentity> = []
        var uncertainty: String?, failures = 0
        var evidenceError = markerError
        var sessions: [RequestProcessIdentity: [RequestProcessIdentity]] = [:]
        var anchors: Set<RequestProcessIdentity> = []
        while true {
            uncertainty = nil
            do {
                let pass = RequestObservationPass(group:groups.group,identity:groups.identity)
                var rootFailure: Error?
                if let root {
                    do {
                        let result = try pass.anchor(root,known:targets,label:"worker")
                        targets += result.identities
                        if let detail = result.uncertainty { uncertainty = detail }
                    } catch { rootFailure = error }
                }
                let observation = try RequestProcessIdentity.observe(in:directory,known:targets,group:pass.group,identity:pass.birth)
                targets += observation.identities; sessions = observation.sessions; anchors.formUnion(observation.supervisors)
                if let rootFailure { throw rootFailure }
                if let detail = observation.observationFailure { throw RequestWorkerTeardownError(cause:detail) }
                uncertainty = observation.uncertainty ?? uncertainty
                let details = [markerError,observation.evidenceError].compactMap{$0}
                evidenceError = details.isEmpty ? nil : details.joined(separator:"; "); failures = 0
            } catch { failures += 1; uncertainty = error.localizedDescription }
            targets = Array(Set(targets.filter { groups.identity($0.pid) == $0 }))
            if root == nil, !targets.isEmpty { throw RequestWorkerOwnershipError() }
            let signal = budget.escalated(at:groups.now()) ? SIGKILL : SIGTERM
            let pending = budget.expired(at:groups.now()) ? [] : root.flatMap { groups.identity($0.pid) == $0 ? [$0] : nil } ?? RequestProcessIdentity.shutdownTargets(targets, sessions: sessions, signal: signal, allowOwnerRetirement: failures == 0, identity:groups.identity)
            let term = pending.filter { termSent.insert($0).inserted }
            RequestProcessIdentity.signal(term, SIGTERM, identity:groups.identity, send:groups.signal)
            if signal == SIGKILL {
                let killable = pending.filter { identity in
                    guard anchors.contains(identity), identity != root else { return true }
                    do { return try !groups.group(identity.pid).contains { $0 != identity } }
                    catch { uncertainty = error.localizedDescription; failures += 1; return false }
                }
                RequestProcessIdentity.signal(killable.filter { killSent.insert($0).inserted }, SIGKILL, identity:groups.identity, send:groups.signal)
            }
            if uncertainty == nil, !targets.contains(where: { groups.identity($0.pid) == $0 }) {
                // A second observation after signalling closes the final-fork window.
                do {
                    let final = try RequestProcessIdentity.observe(in: directory, known: targets, group: groups.group, identity:groups.identity)
                    let rootGroup = try root.flatMap { root -> [RequestProcessIdentity]? in
                        let current = groups.identity(root.pid)
                        return current == nil || current == root ? try groups.group(root.pid) : nil
                    } ?? []
                    if final.observationFailure == nil, final.uncertainty == nil, final.identities.isEmpty, rootGroup.isEmpty {
                        var details = [String]()
                        for detail in [evidenceError,final.evidenceError].compactMap({$0}) where !details.contains(detail) { details.append(detail) }
                        if !details.isEmpty { throw RequestWorkerEvidenceError(cause:details.joined(separator:"; ")) }
                        for name in ["process.json", "children.json", "supervision.json"] {
                            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                        }
                        return
                    }
                    targets += final.identities; uncertainty = final.observationFailure ?? final.uncertainty
                } catch let error as RequestWorkerEvidenceError { throw error }
                catch { failures += 1; uncertainty = error.localizedDescription }
            }
            guard !budget.expired(at:groups.now()) else { throw RequestWorkerTeardownError(cause: uncertainty) }
            // Retries are observation intervals, never sleeps inside an ownership lock.
            groups.wait(0.25)
        }
    }
}
#endif
