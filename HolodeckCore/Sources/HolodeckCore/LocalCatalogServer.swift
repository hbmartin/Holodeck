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

public actor LocalCatalogServer {
    private static let productionNamespace = "mac-library"
    private var requests: ShaderRequestService?
    public func setRequestService(_ service: ShaderRequestService) { requests = service }
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
    private var state = LocalServerState()
    private var observers: [UUID: AsyncStream<LocalServerState>.Continuation] = [:]
    private var identity: LocalServerIdentity?

    public init(catalog: DirectoryCatalog) {
        self.catalog = catalog; self.allowLoopback = false; self.secretNamespace = Self.productionNamespace; self.advertise = true
        clock = AnyClock(ContinuousClock())
        readAsset = { try await catalog.get($0, limit: $1, pinFor: $2) }
    }
    init(catalog: DirectoryCatalog, testingNamespace: String, advertise: Bool = false,
         clock: any Clock<Duration> = ContinuousClock(),
         readAsset: (@Sendable (CatalogRequest, Int, UUID) async throws -> Data)? = nil) {
        precondition(testingNamespace != Self.productionNamespace)
        self.catalog = catalog; self.allowLoopback = !advertise; self.secretNamespace = testingNamespace; self.advertise = advertise
        self.clock = AnyClock(clock)
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
            if let data = try LocalSecrets.read(secretNamespace + "-approved-tvs") {
                let records = try JSONDecoder().decode([ApprovedTV].self, from: data)
                approved = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            }
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

    public func approve(_ id: UUID) throws {
        guard let request = pending[id], sessions[id] != nil, !closing.contains(id) else { return }
        guard let deadline = deadlines[id], clock.now < deadline else { cancelSession(id); publish(); return }
        let token = try LocalSecrets.token()
        let record = ApprovedTV(id: request.deviceID, name: request.approval.name, tokenHash: CatalogHash.sha256(Data(token.utf8)))
        var candidate = approved; candidate[record.id] = record
        try persist(candidate)
        approved = candidate; issued[id] = token; pending[id] = nil; authenticated[id] = record
        deadlineTasks.removeValue(forKey: id)?.cancel(); deadlines[id] = nil
        publish()
    }
    public func decline(_ id: UUID) { pending[id] = nil; declined.insert(id); publish() }
    public func revoke(_ id: String) async throws {
        var candidate = approved; candidate[id] = nil
        try persist(candidate); approved = candidate
        for (session, record) in authenticated where record.id == id {
            cancelSession(session)
        }
        try await requests?.revoke(id)
        publish()
    }
    private func persist(_ records: [String: ApprovedTV]) throws {
        try LocalSecrets.write(JSONEncoder().encode(Array(records.values)), account: secretNamespace + "-approved-tvs")
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
        pending[id] = nil; issued[id] = nil; authenticated[id] = nil
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
                let value = try await requests.control(operation: packet.message.operation, payload: control, deviceID: deviceID)
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
