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
    private let standaloneCoordinator: UUID
    var coordinator: UUID { owner?.authority ?? standaloneCoordinator }
    let deviceID: String
    private let lock = NSLock()
    private var current = true
    private let owner: TrustedOwnerPermit?
    init(coordinator: UUID, deviceID: String, owner: TrustedOwnerPermit? = nil) {
        self.standaloneCoordinator = coordinator; self.deviceID = deviceID; self.owner = owner
    }
    var isCurrent: Bool { lock.withLock { current } && (owner?.isCurrent ?? true) }
    func invalidate() { lock.withLock { current = false } }
}
nonisolated struct TrustedRevocationRevision: Sendable, Equatable {
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
    nonisolated static let productionNamespace = "mac-library"
    public func setRequestService(_ service: ShaderRequestService) async {
        do {
            guard try await registerTrustedBinding(service: service) else { return }
            try await trusted.replay()
        } catch is CancellationError { }
        catch {
            let detail = BoundedDiagnostics.bounded(error.localizedDescription, bytes: 8192)
            // The authority publishes an intent/write failure while it still owns
            // the transition. Only preparation errors need a local publication.
            if trustedDiagnostic?.contains(detail) != true { trustedDiagnostic = detail; publish() }
        }
    }
    private let instanceID = UUID()
    private let trusted: TrustedApprovalsCoordinator
    private var binding: TrustedApprovalsCoordinator.Binding?
    private enum RegistrationState: Equatable { case idle, pending(UUID), superseded }
    private var registrationState: RegistrationState = .idle
    private var registrationEligibility = TrustedOwnerLifetime()
    private weak var proposedService: ShaderRequestService?
    private var serviceOwner: RequestServiceOwnerLease?
    private var ownerServiceID: UUID?
    private var retired = false
    private var startGeneration: UInt64 = 0
    private var lifetimeRevision: UInt64 = 0
    private var registrationTicket: (id: UUID, ticket: TrustedApprovalsCoordinator.Registration)?
    private func trustedOwner(service: ShaderRequestService?) -> TrustedApprovalsCoordinator.Owner {
        let revision = lifetimeRevision
        return .init(serverID: instanceID, service: service,
              changed: { [weak self] in await self?.acceptTrustedSnapshot($0, binding: $1, lifetime: revision) },
              retired: { [weak self] in await self?.retireTrustedBinding() }, beforeReplay: beforeRevocationReplay, eligibility: registrationEligibility)
    }
    private func registerTrustedBinding(service: ShaderRequestService?, onlyIfVacant: Bool = false) async throws -> Bool {
        if !registrationEligibility.isCurrent { registrationEligibility = .init() }
        let attempt = UUID(), previous = registrationState, revision = lifetimeRevision
        registrationState = .pending(attempt); proposedService = service
        let registration: TrustedApprovalsCoordinator.Registration
        do { registration = try await trusted.register(trustedOwner(service: service), onlyIfVacant: onlyIfVacant) }
        catch {
            if registrationState == .pending(attempt) { registrationState = previous }
            throw error
        }
        guard revision == lifetimeRevision else { registration.completion.cancel(); throw CancellationError() }
        registrationTicket = (attempt, registration)
        defer { if registrationTicket?.id == attempt { registrationTicket = nil } }
        do {
            let result = try await registration.value()
            guard revision == lifetimeRevision else { throw CancellationError() }
            switch result {
            case .accepted:
                if registrationState == .pending(attempt) { registrationState = .idle }
                return true
            case .superseded:
                if registrationState == .pending(attempt) { registrationState = .superseded }
                return false
            }
        } catch {
            if registrationState == .pending(attempt) { registrationState = .idle }
            throw error
        }
    }
    private func ensureBinding(explicitStart: Bool = false) async throws -> TrustedOwnerPermit {
        if let binding, binding.permit.isCurrent { return binding.permit }
        guard !retired, registrationState == .idle else {
            throw ShaderRequestError.unavailable("Catalog server handoff is pending or this server was replaced. Use its accepted replacement.")
        }
        guard try await registerTrustedBinding(service: proposedService, onlyIfVacant: !explicitStart), let binding, binding.permit.isCurrent else {
            throw ShaderRequestError.unavailable("Catalog server handoff was superseded.")
        }
        return binding.permit
    }
    private func acceptTrustedSnapshot(_ snapshot: TrustedApprovalsCoordinator.Snapshot, binding: TrustedApprovalsCoordinator.Binding, lifetime revision: UInt64) {
        guard revision == lifetimeRevision else {
            binding.permit.invalidate(); binding.permit.lifetime.invalidate()
            let trusted = trusted
            Task { await trusted.releaseBinding(binding.permit) }
            return
        }
        guard binding.permit.serverID == instanceID, binding.permit.isCurrent else { return }
        let changedOwner = self.binding?.permit !== binding.permit
        for (device, authorization) in requestAuthorizations where changedOwner || approved[device]?.tokenHash != snapshot.approvals[device]?.tokenHash {
            authorization.invalidate(); requestAuthorizations[device] = nil
        }
        if ownerServiceID != binding.service?.runtimeID {
            serviceOwner?.release(); serviceOwner = binding.service?.retainOwner(); ownerServiceID = binding.service?.runtimeID
        }
        approved = snapshot.approvals; self.binding = binding; retired = false
        for (session, record) in authenticated where approved[record.id]?.tokenHash != record.tokenHash { cancelSession(session) }
        trustedDiagnostic = snapshot.diagnostic
        publish()
    }
    private func retireTrustedBinding() {
        retired = true; serviceOwner?.release(); serviceOwner = nil; ownerServiceID = nil
        stop(); publish("This catalog server was replaced.")
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
    private var approvalEligibility: [UUID: TrustedApprovalEligibility] = [:]
    private var declined: Set<UUID> = []
    private var authenticated: [UUID: ApprovedTV] = [:]
    private var approved: [String: ApprovedTV] = [:]
    private var requestAuthorizations: [String: TrustedRequestAuthorization] = [:]
    var trustedEncodingCount: Int { get async { await trusted.observation.encodings } }
    private let beforeTrustedCommit: @Sendable (RequestRevocationIntent) async throws -> Void
    private let beforeRevocationReplay: @Sendable (RequestRevocationIntent) async throws -> Void
    private var state = LocalServerState()
    private var transportMessage = LocalServerState().message
    private var trustedDiagnostic: String?
    private var observers: [UUID: AsyncStream<LocalServerState>.Continuation] = [:]
    private var identity: LocalServerIdentity?

    public init(catalog: DirectoryCatalog) {
        self.catalog = catalog; self.allowLoopback = false; self.secretNamespace = Self.productionNamespace; self.advertise = true
        trusted = .keychain(namespace: Self.productionNamespace)
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
         beforeRevocationReplay: @escaping @Sendable (RequestRevocationIntent) async throws -> Void = { _ in },
         trustedApprovals: TrustedApprovalsCoordinator? = nil) {
        precondition(testingNamespace != Self.productionNamespace)
        self.catalog = catalog; self.allowLoopback = !advertise; self.secretNamespace = testingNamespace; self.advertise = advertise
        self.clock = AnyClock(clock)
        self.beforeTrustedCommit = beforeTrustedCommit; self.beforeRevocationReplay = beforeRevocationReplay
        if let trustedApprovals { self.trusted = trustedApprovals }
        else if readApprovals != nil || writeApprovals != nil {
            let account = TrustedApprovalsCoordinator.approvalsAccount(testingNamespace)
            self.trusted = TrustedApprovalsCoordinator(read: readApprovals ?? { try LocalSecrets.read(account) },
                write: writeApprovals ?? { try LocalSecrets.write($0, account: account) })
        } else { self.trusted = .keychain(namespace: testingNamespace) }
        self.readAsset = readAsset ?? { try await catalog.get($0, limit: $1, pinFor: $2) }
    }
    #if DEBUG
    public static func testing(catalog: DirectoryCatalog, namespace: String, advertise: Bool = false) -> LocalCatalogServer {
        LocalCatalogServer(catalog: catalog, testingNamespace: "ui-" + namespace, advertise: advertise)
    }
    public static func removeTestingSecrets(namespace: String) throws {
        try LocalSecrets.remove("ui-" + namespace + "-tls-identity")
        try LocalSecrets.remove(TrustedApprovalsCoordinator.approvalsAccount("ui-" + namespace))
    }
    #endif
    var listeningPort: UInt16? { listener?.port?.rawValue }
    var serverID: String? { identity?.id }
    var currentState: LocalServerState { state }
    var sessionCount: Int { sessions.count }
    var trustedMutationWaiterCount: Int { get async { await trusted.observation.mutationWaiters } }

    public func updates() -> AsyncStream<LocalServerState> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation; continuation.yield(state)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish(_ message: String? = nil) {
        if let message { transportMessage = message }
        state.message = trustedDiagnostic ?? transportMessage
        state.pending = pending.values.map(\.approval).sorted { $0.name < $1.name }
        state.approved = approved.values.sorted { $0.name < $1.name }
        for observer in observers.values { observer.yield(state) }
    }

    public func start() async throws {
        if listener != nil, binding?.permit.isCurrent == true { return }
        startGeneration &+= 1; let generation = startGeneration
        _ = try await ensureBinding(explicitStart: true)
        try Task.checkCancellation()
        guard generation == startGeneration else { throw CancellationError() }
        guard listener == nil else { return }
        if identity == nil {
            identity = try LocalServerIdentity.load(account: secretNamespace + "-tls-identity")
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
        startGeneration &+= 1
        requestAuthorizations.values.forEach { $0.invalidate() }; requestAuthorizations.removeAll()
        listenerID = nil; listener?.cancel(); listener = nil
        for id in sessions.keys { cancelSession(id) }
        publish("Local sharing is stopped.")
    }
    public func shutdown() async {
        lifetimeRevision &+= 1; registrationEligibility.invalidate()
        registrationTicket?.ticket.completion.cancel(); registrationTicket = nil
        let prior = binding
        prior?.permit.invalidate(); prior?.permit.lifetime.invalidate()
        binding = nil; retired = true; proposedService = nil
        serviceOwner?.release(); serviceOwner = nil; ownerServiceID = nil
        stop()
        let eligibility = registrationEligibility, serverID = instanceID, trusted = trusted
        Task { await trusted.withdraw(serverID: serverID, eligibility: eligibility) }
    }
    deinit {
        let trusted = trusted, permit = binding?.permit, eligibility = registrationEligibility, serverID = instanceID
        eligibility.invalidate()
        permit?.invalidate(); permit?.lifetime.invalidate()
        Task { await trusted.withdraw(serverID: serverID, eligibility: eligibility) }
    }
    func clearTestSecrets() async throws {
        precondition(secretNamespace != Self.productionNamespace)
        await shutdown()
        await trusted.withdraw(serverID: instanceID, eligibility: registrationEligibility)
        try LocalServerIdentity.remove(account: secretNamespace + "-tls-identity")
        try LocalSecrets.remove(TrustedApprovalsCoordinator.approvalsAccount(secretNamespace))
        await trusted.discardTestingCacheIfIdle()
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
        let permit = try await ensureBinding()
        let proposal = try await trusted.approve(permit) { [weak self] in try await self?.approvalProposal(id) }
        guard let proposal else { return }
        guard proposal.eligibility.canIssue, pending[id] != nil, sessions[id] != nil, !closing.contains(id), permit.lifetime.isCurrent else {
            cancelSession(id); throw CommittedApprovalDeliveryError()
        }
        issued[id] = proposal.token; pending[id] = nil; authenticated[id] = proposal.record
        deadlineTasks.removeValue(forKey: id)?.cancel(); deadlines[id] = nil
        publish()
    }
    private func approvalProposal(_ id: UUID) throws -> TrustedApprovalsCoordinator.Approval? {
        guard let request = pending[id], sessions[id] != nil, !closing.contains(id) else { return nil }
        guard let deadline = deadlines[id], clock.now < deadline else { cancelSession(id); publish(); return nil }
        let token = try LocalSecrets.token()
        guard let eligibility = approvalEligibility[id] else { return nil }
        try eligibility.check()
        return .init(record: ApprovedTV(id: request.deviceID, name: request.approval.name, tokenHash: CatalogHash.sha256(Data(token.utf8))), token: token, eligibility: eligibility)
    }
    public func decline(_ id: UUID) { approvalEligibility.removeValue(forKey: id)?.close(); pending[id] = nil; declined.insert(id); publish() }
    public func revoke(_ id: String) async throws {
        let permit = try await ensureBinding(), hook = beforeTrustedCommit
        try await trusted.revoke(id, permit: permit, beforeCommit: hook)
    }
    func requestAuthorization(for deviceID: String) throws -> TrustedRequestAuthorization {
        guard let binding, binding.permit.isCurrent else { throw ShaderRequestError.unavailable("Catalog server handoff is pending. Wait for its accepted binding.") }
        guard approved[deviceID] != nil else { throw ShaderRequestError.unavailable("TV access was revoked") }
        if let value = requestAuthorizations[deviceID], value.isCurrent { return value }
        let value = TrustedRequestAuthorization(coordinator: binding.permit.authority, deviceID: deviceID, owner: binding.permit)
        requestAuthorizations[deviceID] = value; return value
    }
    private enum SessionAuthorization { case permitted, credentialRejected, interrupted }
    private func sessionAuthorization(_ id: UUID) -> SessionAuthorization {
        guard !closing.contains(id), sessions[id] != nil, binding?.permit.isCurrent == true else { return .interrupted }
        guard let record = authenticated[id], approved[record.id]?.tokenHash == record.tokenHash else { return .credentialRejected }
        return .permitted
    }
    private func credentialAuthorized(_ id: UUID) throws -> Bool {
        switch sessionAuthorization(id) {
        case .permitted: return true
        case .credentialRejected: return false
        case .interrupted: throw LocalCatalogError.disconnected
        }
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
                    let request = try await channel.receive(idleAllowed: sessionAuthorization(id) == .permitted)
                    let response = try await respond(request, id: id, channel: channel)
                    try await withLocalTimeout { try await channel.send(response) }
                }
            } catch { channel.cancel() }
            await finishSession(id)
        }
    }

    private func expire(_ id: UUID) {
        guard sessionAuthorization(id) != .permitted, let deadline = deadlines[id], clock.now >= deadline else { return }
        cancelSession(id); publish()
    }

    private func cancelSession(_ id: UUID) {
        guard let channel = sessions[id] else { return }
        closing.insert(id)
        deadlineTasks.removeValue(forKey: id)?.cancel()
        let deviceID = authenticated.removeValue(forKey: id)?.id
        approvalEligibility.removeValue(forKey: id)?.close()
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
        guard !closing.contains(id), let servingPermit = binding?.permit, servingPermit.isCurrent else { throw LocalCatalogError.disconnected }
        if let deadline = deadlines[id], clock.now >= deadline {
            cancelSession(id); throw LocalCatalogError.timeout
        }
        let requestOperations = ["requestSubmit", "requestStatus", "requestAnswer", "requestActivated", "requestDelivery"]
        if requestOperations.contains(packet.message.operation) {
            guard try credentialAuthorized(id), let deviceID = authenticated[id]?.id else {
                return LocalPacket(message: LocalMessage(operation: "ok", error: "revoked"))
            }
            var reply = LocalMessage(operation: "ok")
            do {
                guard let binding, binding.permit.isCurrent, let requests = binding.service else {
                    throw ShaderRequestError.unavailable("Catalog server handoff is pending or shader requests are unavailable. Wait for its accepted binding.")
                }
                let control = try JSONDecoder().decode(ShaderRequestControl.self, from: packet.payload)
                let authorization = try requestAuthorization(for: deviceID)
                let value = try await requests.control(operation: packet.message.operation, payload: control, deviceID: deviceID, authorization: authorization)
                guard servingPermit.isCurrent else { throw LocalCatalogError.disconnected }
                guard try credentialAuthorized(id) else { return LocalPacket(message: LocalMessage(operation: "ok", error: "revoked")) }
                return LocalPacket(message: reply, payload: try JSONEncoder().encode(value))
            } catch LocalCatalogError.disconnected { throw LocalCatalogError.disconnected }
            catch {
                guard servingPermit.isCurrent, !closing.contains(id) else { throw LocalCatalogError.disconnected }
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
            if binding?.service != nil { response.capabilities = ["shaderRequests1"] }
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
            guard let deadline = deadlines[id] else { throw LocalCatalogError.disconnected }
            let clock = clock
            approvalEligibility[id] = .init(withinDeadline: { clock.now < deadline })
            pending[id] = Pending(deviceID: deviceID, approval: TVApproval(id: id, name: name, code: code))
            response.operation = "pending"; publish()
        case "pairStatus":
            if declined.contains(id) { response.error = "rejected" }
            else if try credentialAuthorized(id), let token = issued.removeValue(forKey: id) { approvalEligibility[id] = nil; response.token = token }
            else if pending[id] != nil { response.operation = "pending" }
            else { response.error = "rejected"; self.pending[id] = nil; publish() }
        case "asset":
            guard try credentialAuthorized(id) else { response.error = "revoked"; break }
            guard let request = message.request, let limit = message.limit,
                  (0...LocalProtocol.maximumPayload).contains(limit) else { throw LocalCatalogError.protocolViolation }
            do {
                let data = try await readAsset(request, limit, id)
                guard servingPermit.isCurrent else { throw LocalCatalogError.disconnected }
                guard try credentialAuthorized(id) else { response.error = "revoked"; break }
                return LocalPacket(message: response, payload: data)
            } catch LocalCatalogError.disconnected { throw LocalCatalogError.disconnected }
            catch {
                guard servingPermit.isCurrent, !closing.contains(id) else { throw LocalCatalogError.disconnected }
                response.error = "invalidAsset"
            }
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
