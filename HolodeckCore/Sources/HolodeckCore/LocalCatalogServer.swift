#if os(macOS)
import Foundation
import Network
import Security
import CryptoKit
import X509
import SystemConfiguration
import Clocks

nonisolated public struct TVApproval: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let code: String
}
nonisolated public struct ApprovedTV: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    let tokenHash: String
}
nonisolated public struct LocalServerState: Sendable {
    public var message = "Choose a shader folder to start sharing."
    public var pending: [TVApproval] = []
    public var approved: [ApprovedTV] = []
    public init() {}
}

/// Trusted with the TV approvals, independently of potentially unreadable request files.
nonisolated struct RequestRevocationIntent: Codable, Sendable, Equatable {
    let operationID: UUID
    let deviceID: String
}
/// Held by authenticated calls across actor hops. Revocation invalidates the old
/// approval even if its queued call reaches the request actor after replay finishes.
nonisolated final class TrustedRequestAuthorization: @unchecked Sendable {
    let coordinator: UUID
    let deviceID: String
    private let lock = NSLock()
    private var current = true
    init(coordinator: UUID, deviceID: String) { self.coordinator = coordinator; self.deviceID = deviceID }
    var isCurrent: Bool { lock.withLock { current } }
    func invalidate() { lock.withLock { current = false } }
}
nonisolated struct TrustedRevocationRevision: Sendable {
    let coordinator: UUID
    let sequence: UInt64
}
nonisolated struct TrustedTVApprovals: Codable, Sendable {
    var formatVersion = 1
    var approvals: [ApprovedTV] = []
    var revocations: [RequestRevocationIntent] = []
    static func decode(_ bytes: Data) throws -> Self {
        if let legacy = try? JSONDecoder().decode([ApprovedTV].self, from: bytes) { return .init(approvals: legacy) }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.formatVersion == 1, Set(value.revocations.map(\.deviceID)).count == value.revocations.count,
              Set(value.revocations.map(\.operationID)).count == value.revocations.count else { throw LocalCatalogError.invalidFile("TV approvals", "Invalid revocation envelope") }
        try value.validate(); return value
    }
    private func validate() throws {
        guard try JSONEncoder().encode(revocations).count <= 65536 else {
            throw LocalCatalogError.invalidFile("TV approvals", "Pending revocations exceed 64 KiB. Retry request recovery before revoking more TVs.")
        }
    }
    func encoded() throws -> Data {
        try validate()
        return try JSONEncoder().encode(self)
    }
}

public actor LocalCatalogServer {
    private static let productionNamespace = "mac-library"
    private var requests: ShaderRequestService?
    public func setRequestService(_ service: ShaderRequestService) async {
        do {
            let lease = try await acquireTrustedMutation(cancellable: false)
            if requests !== service {
                requestAuthorizations.values.forEach { $0.invalidate() }; requestAuthorizations.removeAll()
                coordinatorID = UUID(); requests = service
                await service.registerRevocationCoordinator(id: coordinatorID) { [weak self] in
                    guard let self else { throw ShaderRequestError.unavailable("The trusted TV revocation coordinator is unavailable.") }
                    try await self.replayRevocations()
                }
            }
            releaseTrustedMutation(lease)
            try await replayRevocations()
        } catch {
            // The drain already published the exact inspection/intent failure.
            // Do not turn a failed device replay into an unknown global approval state.
        }
    }
    private let catalog: DirectoryCatalog
    private let allowLoopback: Bool
    private let secretNamespace: String
    private let advertise: Bool
    private var listener: NWListener?
    private var listenerID: UUID?
    private var sessions: [UUID: LocalConnection] = [:]
    private let readAsset: @Sendable (CatalogRequest, Int, UUID) async throws -> Data
    private let clock: AnyClock<Duration>
    private var deadlines: [UUID: AnyClock<Duration>.Instant] = [:]
    private var deadlineTasks: [UUID: Task<Void, Never>] = [:]
    private var closing: Set<UUID> = []
    private struct Pending { let deviceID: String; let approval: TVApproval }
    private var pending: [UUID: Pending] = [:]
    private var issued: [UUID: String] = [:]
    private var declined: Set<UUID> = []
    private var authenticated: [UUID: ApprovedTV] = [:]
    private var approved: [String: ApprovedTV] = [:]
    private var revocations: [RequestRevocationIntent] = []
    private var approvalsLoaded = false
    private var coordinatorID = UUID()
    private var requestAuthorizations: [String: TrustedRequestAuthorization] = [:]
    private(set) var trustedEncodingCount = 0
    private var trustedSequence: UInt64 = 0
    private var trustedRevision: TrustedRevocationRevision { .init(coordinator: coordinatorID, sequence: trustedSequence) }
    private var trustedMutation: UUID?
    private var trustedWaiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var replayTask: Task<Void, Never>?
    private var replayWaiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]
    private var replayAllWaiters: [CheckedContinuation<Void, Error>] = []
    private struct ReplayFailure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
        init(_ error: Error) { message = RequestRecoveryStore.Entry.bounded(error.localizedDescription, bytes: 8192) }
    }
    private let beforeTrustedCommit: @Sendable (RequestRevocationIntent) async throws -> Void
    private let beforeRevocationReplay: @Sendable (RequestRevocationIntent) async throws -> Void
    private let readApprovals: @Sendable () throws -> Data?
    private let writeApprovals: @Sendable (Data) throws -> Void
    private var state = LocalServerState()
    private var observers: [UUID: AsyncStream<LocalServerState>.Continuation] = [:]
    private var identity: LocalServerIdentity?

    public init(catalog: DirectoryCatalog) {
        self.catalog = catalog; self.allowLoopback = false; self.secretNamespace = Self.productionNamespace; self.advertise = true
        readApprovals = { try LocalSecrets.read(Self.productionNamespace + "-approved-tvs") }
        writeApprovals = { try LocalSecrets.write($0, account: Self.productionNamespace + "-approved-tvs") }
        clock = AnyClock(ContinuousClock())
        beforeTrustedCommit = { _ in }; beforeRevocationReplay = { _ in }
        readAsset = { try await catalog.get($0, limit: $1, pinFor: $2) }
    }
    init(catalog: DirectoryCatalog, testingNamespace: String, advertise: Bool = false,
         clock: any Clock<Duration> = ContinuousClock(),
         readAsset: (@Sendable (CatalogRequest, Int, UUID) async throws -> Data)? = nil,
         readApprovals: (@Sendable () throws -> Data?)? = nil,
         writeApprovals: (@Sendable (Data) throws -> Void)? = nil,
         beforeTrustedCommit: @escaping @Sendable (RequestRevocationIntent) async throws -> Void = { _ in },
         beforeRevocationReplay: @escaping @Sendable (RequestRevocationIntent) async throws -> Void = { _ in }) {
        precondition(testingNamespace != Self.productionNamespace)
        self.catalog = catalog; self.allowLoopback = !advertise; self.secretNamespace = testingNamespace; self.advertise = advertise
        self.clock = AnyClock(clock)
        self.beforeTrustedCommit = beforeTrustedCommit; self.beforeRevocationReplay = beforeRevocationReplay
        self.readApprovals = readApprovals ?? { try LocalSecrets.read(testingNamespace + "-approved-tvs") }
        self.writeApprovals = writeApprovals ?? { try LocalSecrets.write($0, account: testingNamespace + "-approved-tvs") }
        self.readAsset = readAsset ?? { try await catalog.get($0, limit: $1, pinFor: $2) }
    }
    #if DEBUG
    public static func testing(catalog: DirectoryCatalog, namespace: String, advertise: Bool = false) -> LocalCatalogServer {
        LocalCatalogServer(catalog: catalog, testingNamespace: "ui-" + namespace, advertise: advertise)
    }
    public static func removeTestingSecrets(namespace: String) throws {
        try LocalSecrets.remove("ui-" + namespace + "-tls-identity")
        try LocalSecrets.remove("ui-" + namespace + "-approved-tvs")
    }
    #endif
    var listeningPort: UInt16? { listener?.port?.rawValue }
    var serverID: String? { identity?.id }
    var currentState: LocalServerState { state }
    var sessionCount: Int { sessions.count }
    var trustedMutationWaiterCount: Int { trustedWaiters.count }

    public func updates() -> AsyncStream<LocalServerState> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation; continuation.yield(state)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish(_ message: String? = nil) {
        if let message { state.message = message }
        state.pending = pending.values.map(\.approval).sorted { $0.name < $1.name }
        state.approved = approved.values.sorted { $0.name < $1.name }
        for observer in observers.values { observer.yield(state) }
    }

    public func start() throws {
        guard listener == nil else { return }
        if identity == nil {
            identity = try LocalServerIdentity.load(account: secretNamespace + "-tls-identity")
            try loadApprovals()
        }
        guard let identity else { throw LocalCatalogError.protocolViolation }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, sec_identity_create(identity.value)!)
        let parameters = NWParameters(tls: options, tcp: LocalProtocol.tcpOptions())
        if allowLoopback { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        let listener = try NWListener(using: parameters, on: .any)
        let name = String(((SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName).prefix(100))
        if advertise {
            listener.service = NWListener.Service(name: "Holodeck \(identity.id)", type: LocalProtocol.serviceType, domain: "local.",
                txtRecord: NWTXTRecord(["id": identity.id, "name": name, "version": String(LocalProtocol.version)]).data)
        }
        let listenerID = UUID()
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection, listenerID: listenerID) } }
        listener.stateUpdateHandler = { [weak self] status in Task { await self?.listenerState(status, id: listenerID) } }
        self.listener = listener; self.listenerID = listenerID
        listener.start(queue: DispatchQueue(label: "Holodeck.shader-server"))
        publish("Starting local sharing…")
    }

    public func stop() {
        requestAuthorizations.values.forEach { $0.invalidate() }; requestAuthorizations.removeAll()
        listenerID = nil; listener?.cancel(); listener = nil
        for id in sessions.keys { cancelSession(id) }
        publish("Local sharing is stopped.")
    }
    func clearTestSecrets() throws {
        precondition(secretNamespace != Self.productionNamespace)
        stop()
        try LocalServerIdentity.remove(account: secretNamespace + "-tls-identity")
        try LocalSecrets.remove(secretNamespace + "-approved-tvs")
    }

    private func listenerState(_ value: NWListener.State, id: UUID) {
        guard listenerID == id else { return }
        switch value {
        case .ready: publish("Serving shaders on the local network.")
        case .failed(let error):
            listenerID = nil; listener?.cancel(); listener = nil
            publishFailure(error)
        case .waiting(let error): publishFailure(error)
        default: break
        }
    }
    private func publishFailure(_ error: NWError) {
            if LocalProtocol.isPermissionDenied(error) { publish(LocalCatalogError.permissionDenied.localizedDescription) }
            else { publish("Local sharing failed: \(error.localizedDescription)") }
    }

    public func approve(_ id: UUID) async throws {
        let lease = try await acquireTrustedMutation()
        defer { releaseTrustedMutation(lease) }
        try loadApprovals()
        guard let request = pending[id], sessions[id] != nil, !closing.contains(id) else { return }
        guard let deadline = deadlines[id], clock.now < deadline else { cancelSession(id); publish(); return }
        let token = try LocalSecrets.token()
        let record = ApprovedTV(id: request.deviceID, name: request.approval.name, tokenHash: CatalogHash.sha256(Data(token.utf8)))
        var candidate = approved; candidate[record.id] = record
        try persist(candidate)
        requestAuthorizations.removeValue(forKey: record.id)?.invalidate()
        approved = candidate; issued[id] = token; pending[id] = nil; authenticated[id] = record
        deadlineTasks.removeValue(forKey: id)?.cancel(); deadlines[id] = nil
        publish()
    }
    public func decline(_ id: UUID) { pending[id] = nil; declined.insert(id); publish() }
    /// Only the short trusted transition holds this lease, never journal replay or process settlement.
    private func acquireTrustedMutation(cancellable: Bool = true) async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            while trustedMutation != nil {
                if cancellable { try Task.checkCancellation() }
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in trustedWaiters.append((id, c)) }
            }
            if cancellable { try Task.checkCancellation() }
            trustedMutation = id; return id
        } onCancel: {
            if cancellable { Task { await self.cancelTrustedWaiter(id) } }
        }
    }
    private func cancelTrustedWaiter(_ id: UUID) {
        let cancelled = trustedWaiters.filter { $0.0 == id }; trustedWaiters.removeAll { $0.0 == id }
        cancelled.forEach { $0.1.resume(throwing: CancellationError()) }
    }
    private func releaseTrustedMutation(_ id: UUID) {
        guard trustedMutation == id else { return }
        trustedMutation = nil
        let waiting = trustedWaiters; trustedWaiters.removeAll()
        waiting.forEach { $0.1.resume() }
    }
    public func revoke(_ id: String) async throws {
        let lease = try await acquireTrustedMutation()
        let intent: RequestRevocationIntent
        do {
            try loadApprovals()
            let existing = revocations.first { $0.deviceID == id }
            guard approved[id] != nil || existing != nil else { releaseTrustedMutation(lease); return }
            intent = existing ?? RequestRevocationIntent(operationID: UUID(), deviceID: id)
            if approved[id] != nil {
                var candidate = approved; candidate[id] = nil
                let intents = existing == nil ? revocations + [intent] : revocations
                // All trusted mutations hold the lease, so these validated bytes remain current across reservation.
                let bytes = try approvalBytes(candidate, revocations: intents)
                try await requests?.reserveRevocation(intent, revision: trustedRevision)
                do {
                    try await beforeTrustedCommit(intent)
                    try Task.checkCancellation()
                    try writeApprovals(bytes)
                } catch {
                    await requests?.cancelRevocationReservation(intent, revision: trustedRevision)
                    throw error
                }
                // No cancellation after publication: the trusted intent must reach the service before handoff.
                requestAuthorizations.removeValue(forKey: id)?.invalidate()
                approved = candidate; revocations = intents; trustedSequence &+= 1
                for (session, record) in authenticated where record.id == id { cancelSession(session) }
                publish()
                try await requests?.commitTrustedRevocation(intent, revision: trustedRevision)
            }
        } catch { releaseTrustedMutation(lease); throw error }
        releaseTrustedMutation(lease)
        try await replayRevocations(target: intent.operationID)
    }
    private func loadApprovals() throws {
        guard !approvalsLoaded else { return }
        let envelope = try readApprovals().map(TrustedTVApprovals.decode) ?? TrustedTVApprovals()
        approved = Dictionary(envelope.approvals.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        revocations = envelope.revocations; approvalsLoaded = true; publish()
    }
    private func replayRevocations(target: UUID? = nil) async throws {
        guard requests != nil else { return } // Keep durable intent for a subsequently registered request service.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            if let target {
                guard revocations.contains(where: { $0.operationID == target }) else { c.resume(); return }
                replayWaiters[target, default: []].append(c)
            } else { replayAllWaiters.append(c) }
            if replayTask == nil { replayTask = Task { await self.drainRevocations() } }
        }
    }
    private func drainRevocations() async {
        var attempted: Set<UUID> = [], failures: [UUID: ReplayFailure] = [:]
        var owner = coordinatorID
        while true {
            let lease = try! await acquireTrustedMutation(cancellable: false)
            let intent: RequestRevocationIntent
            let service = requests, revision = trustedRevision
            if owner != coordinatorID { owner = coordinatorID; attempted.removeAll(); failures.removeAll() }
            do {
                try loadApprovals()
                try await requests?.loadTrustedRevocations(revocations, revision: trustedRevision)
                guard let next = revocations.first(where: { !attempted.contains($0.operationID) }) else {
                    await requests?.revocationReplaySucceeded(revision: trustedRevision)
                    finishReplay(failures: failures)
                    releaseTrustedMutation(lease); return
                }
                intent = next; attempted.insert(intent.operationID)
            } catch {
                await requests?.revocationReplayFailed(error, revision: trustedRevision)
                finishReplay(failures: failures, unexpected: ReplayFailure(error))
                releaseTrustedMutation(lease); return
            }
            releaseTrustedMutation(lease)
            do {
                try await beforeRevocationReplay(intent)
                guard owner == coordinatorID else { continue }
                try await service?.applyTrustedRevocation(intent, revision: revision)
                let acknowledgement = try! await acquireTrustedMutation(cancellable: false)
                guard owner == coordinatorID, requests === service else { releaseTrustedMutation(acknowledgement); continue }
                do {
                    // Approvals can change during replay. Preserve the current tokens and remove only this intent.
                    let remaining = revocations.filter { $0.operationID != intent.operationID }
                    try persist(approved, revocations: remaining)
                    revocations = remaining
                    try await requests?.acknowledgeTrustedRevocation(intent, revision: trustedRevision)
                    let completed = replayWaiters.removeValue(forKey: intent.operationID) ?? []
                    completed.forEach { $0.resume() }
                } catch { releaseTrustedMutation(acknowledgement); throw error }
                releaseTrustedMutation(acknowledgement)
            } catch {
                guard owner == coordinatorID else { continue }
                failures[intent.operationID] = ReplayFailure(error)
                await service?.revocationReplayFailed(error, intent: intent, revision: revision)
            }
        }
    }
    private func finishReplay(failures: [UUID: ReplayFailure], unexpected: ReplayFailure? = nil) {
        replayTask = nil
        let waiting = replayWaiters; replayWaiters.removeAll()
        for (id, values) in waiting {
            let failure = unexpected ?? failures[id]
            for value in values {
                if let failure { value.resume(throwing: failure) } else { value.resume() }
            }
        }
        let all = replayAllWaiters; replayAllWaiters.removeAll()
        let failure = unexpected ?? failures.sorted { $0.key.uuidString < $1.key.uuidString }.first?.value
        for value in all {
            if let failure { value.resume(throwing: failure) } else { value.resume() }
        }
    }
    private func approvalBytes(_ records: [String: ApprovedTV], revocations pending: [RequestRevocationIntent]) throws -> Data {
        trustedEncodingCount += 1
        return try TrustedTVApprovals(approvals: Array(records.values), revocations: pending).encoded()
    }
    private func persist(_ records: [String: ApprovedTV], revocations pending: [RequestRevocationIntent]? = nil) throws {
        try writeApprovals(approvalBytes(records, revocations: pending ?? revocations))
        trustedSequence &+= 1
    }
    func requestAuthorization(for deviceID: String) throws -> TrustedRequestAuthorization {
        guard approved[deviceID] != nil else { throw ShaderRequestError.unavailable("TV access was revoked") }
        if let value = requestAuthorizations[deviceID] { return value }
        let value = TrustedRequestAuthorization(coordinator: coordinatorID, deviceID: deviceID)
        requestAuthorizations[deviceID] = value; return value
    }
    private func authorized(_ id: UUID) -> Bool {
        guard !closing.contains(id), let record = authenticated[id] else { return false }
        return approved[record.id]?.tokenHash == record.tokenHash
    }

    private func accept(_ connection: NWConnection, listenerID: UUID) {
        guard self.listenerID == listenerID, sessions.count < 16, case .hostPort(let host, _) = connection.endpoint,
              LocalProtocol.isLocalAddress("\(host)", allowLoopback: allowLoopback) else { connection.cancel(); return }
        let id = UUID(), channel = LocalConnection(connection)
        sessions[id] = channel
        let deadline = clock.now.advanced(by: .seconds(300))
        deadlines[id] = deadline
        deadlineTasks[id] = Task { [weak self, clock] in
            do { try await clock.sleep(until: deadline) } catch { return }
            await self?.expire(id)
        }
        Task { [self] in
            do {
                try await channel.start()
                while !Task.isCancelled, !closing.contains(id) {
                    let request = try await channel.receive(idleAllowed: authorized(id))
                    let response = try await respond(request, id: id, channel: channel)
                    try await withLocalTimeout { try await channel.send(response) }
                }
            } catch { channel.cancel() }
            await finishSession(id)
        }
    }

    private func expire(_ id: UUID) {
        guard !authorized(id), let deadline = deadlines[id], clock.now >= deadline else { return }
        cancelSession(id); publish()
    }

    private func cancelSession(_ id: UUID) {
        guard let channel = sessions[id] else { return }
        closing.insert(id)
        deadlineTasks.removeValue(forKey: id)?.cancel()
        let deviceID = authenticated.removeValue(forKey: id)?.id
        pending[id] = nil; issued[id] = nil
        if let deviceID, !authenticated.values.contains(where: { $0.id == deviceID }) {
            requestAuthorizations.removeValue(forKey: deviceID)?.invalidate()
        }
        channel.cancel()
    }

    /// Only the connection loop finalizes, after its last catalog read has drained.
    private func finishSession(_ id: UUID) async {
        cancelSession(id)
        await catalog.release(id)
        sessions[id] = nil; deadlines[id] = nil; declined.remove(id); closing.remove(id)
        publish()
    }

    private func respond(_ packet: LocalPacket, id: UUID, channel: LocalConnection) async throws -> LocalPacket {
        guard !closing.contains(id) else { throw LocalCatalogError.disconnected }
        if let deadline = deadlines[id], clock.now >= deadline {
            cancelSession(id); throw LocalCatalogError.timeout
        }
        let requestOperations = ["requestSubmit", "requestStatus", "requestAnswer", "requestActivated", "requestDelivery"]
        if requestOperations.contains(packet.message.operation) {
            guard authorized(id), let deviceID = authenticated[id]?.id else {
                return LocalPacket(message: LocalMessage(operation: "ok", error: "revoked"))
            }
            var reply = LocalMessage(operation: "ok")
            do {
                guard let requests else { throw ShaderRequestError.unavailable("Update the Mac app to enable requests.") }
                let control = try JSONDecoder().decode(ShaderRequestControl.self, from: packet.payload)
                let authorization = try requestAuthorization(for: deviceID)
                let value = try await requests.control(operation: packet.message.operation, payload: control, deviceID: deviceID, authorization: authorization)
                guard authorized(id) else { return LocalPacket(message: LocalMessage(operation: "ok", error: "revoked")) }
                return LocalPacket(message: reply, payload: try JSONEncoder().encode(value))
            } catch {
                reply.error = "requestError"; reply.requestMessage = error.localizedDescription
                return LocalPacket(message: reply)
            }
        }
        guard packet.payload.isEmpty else { throw LocalCatalogError.protocolViolation }
        let message = packet.message
        var response = LocalMessage(operation: "ok")
        switch message.operation {
        case "hello":
            response.serverID = identity?.id
            if requests != nil { response.capabilities = ["shaderRequests1"] }
        case "authenticate":
            guard let deviceID = message.deviceID, let token = message.token, token.count <= 100,
                  let record = approved[deviceID], record.tokenHash == CatalogHash.sha256(Data(token.utf8)) else {
                response.error = "revoked"; break
            }
            authenticated[id] = record
            deadlineTasks.removeValue(forKey: id)?.cancel(); deadlines[id] = nil
        case "pair":
            guard authenticated[id] == nil, pending[id] == nil, let deviceID = message.deviceID, UUID(uuidString: deviceID) != nil,
                  let name = message.name, !name.isEmpty, name.count <= 200 else { throw LocalCatalogError.protocolViolation }
            let code = try await channel.pairingCode()
            guard !closing.contains(id) else { throw LocalCatalogError.disconnected }
            pending[id] = Pending(deviceID: deviceID, approval: TVApproval(id: id, name: name, code: code))
            response.operation = "pending"; publish()
        case "pairStatus":
            if declined.contains(id) { response.error = "rejected" }
            else if let token = issued.removeValue(forKey: id), authorized(id) { response.token = token }
            else if pending[id] != nil { response.operation = "pending" }
            else { response.error = "rejected"; self.pending[id] = nil; publish() }
        case "asset":
            guard authorized(id) else { response.error = "revoked"; break }
            guard let request = message.request, let limit = message.limit,
                  (0...LocalProtocol.maximumPayload).contains(limit) else { throw LocalCatalogError.protocolViolation }
            do {
                let data = try await readAsset(request, limit, id)
                guard authorized(id) else { response.error = "revoked"; break }
                return LocalPacket(message: response, payload: data)
            } catch { response.error = "invalidAsset" }
        default: throw LocalCatalogError.protocolViolation
        }
        return LocalPacket(message: response)
    }
}

nonisolated private struct LocalServerIdentity {
    let id: String
    let value: SecIdentity
    private struct Saved: Codable { let id: String; let key: Data; let certificate: Data }
    static func remove(account: String) throws {
        try LocalSecrets.remove(account)
    }
    static func load(account: String) throws -> Self {
        let saved: Saved
        if let bytes = try LocalSecrets.read(account) { saved = try JSONDecoder().decode(Saved.self, from: bytes) }
        else {
            let key = P256.Signing.PrivateKey()
            let id = UUID().uuidString
            let name = try DistinguishedName { CommonName("Holodeck \(id)") }
            let certificate = try Certificate(version: .v3, serialNumber: .init(), publicKey: .init(key.publicKey),
                notValidBefore: Date().addingTimeInterval(-3600), notValidAfter: Date().addingTimeInterval(10 * 365 * 24 * 3600),
                issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions { Critical(BasicConstraints.notCertificateAuthority) }, issuerPrivateKey: .init(key))
            saved = Saved(id: id, key: key.x963Representation, certificate: Data(try certificate.serializeAsPEM().derBytes))
            try LocalSecrets.write(JSONEncoder().encode(saved), account: account)
        }
        guard let key = SecKeyCreateWithData(saved.key as CFData, [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 256] as CFDictionary, nil),
              let certificate = SecCertificateCreateWithData(nil, saved.certificate as CFData) else { throw LocalCatalogError.protocolViolation }
        guard let identity = SecIdentityCreate(nil, certificate, key) else { throw LocalCatalogError.protocolViolation }
        return Self(id: saved.id, value: identity)
    }
}
#endif
