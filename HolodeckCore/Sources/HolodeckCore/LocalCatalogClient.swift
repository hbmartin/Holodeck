import Foundation
import Network

nonisolated public struct LocalClientState: Sendable {
    public enum Status: Sendable, Equatable {
        case searching, chooseMac, connecting, awaitingApproval(String), connected(String)
        case disconnected, permissionDenied, rejected, incompatible, identityChanged, failed(String)
        public var message: String {
            switch self {
            case .searching: "Searching for Holodeck on your Mac…"
            case .chooseMac: "Choose a Mac to connect."
            case .connecting: "Connecting to your Mac…"
            case .awaitingApproval(let code): "Pairing code: \(code). Open Shader Library on your Mac and approve this TV."
            case .connected(let name): "Connected to \(name)"
            case .permissionDenied: LocalCatalogError.permissionDenied.localizedDescription
            case .disconnected: LocalCatalogError.disconnected.localizedDescription
            case .rejected: LocalCatalogError.rejected.localizedDescription
            case .incompatible: LocalCatalogError.incompatible.localizedDescription
            case .identityChanged: LocalCatalogError.identityChanged.localizedDescription
            case .failed(let message): message
            }
        }
    }
    public var status: Status = .searching
    public var macs: [LocalMac] = []
    public var generation: UInt64 = 0
    public init() {}
}

public actor LocalCatalogClient {
    public static let shared: LocalCatalogClient = {
        #if DEBUG
        let configuration = UITestConfiguration(applicationID: "me.haroldmartin.Holodeck")
        if configuration.contains("--ui-test-local-network"), let suite = configuration.storageSuite {
            return LocalCatalogClient(testingNamespace: "ui-" + suite)
        }
        #endif
        return LocalCatalogClient()
    }()
    #if DEBUG
    public static func removeTestingSecrets(namespace: String) throws {
        try LocalSecrets.remove("ui-" + namespace + "-identity")
        try LocalSecrets.remove("ui-" + namespace + "-pairing")
    }
    #endif
    private let secretNamespace: String
    private struct Pairing: Codable, Sendable { let id: String; let name: String; let pin: String; let token: String }
    private var browser: NWBrowser?
    private var state = LocalClientState()
    private var observers: [UUID: AsyncStream<LocalClientState>.Continuation] = [:]
    private var connection: LocalConnection?
    private var connecting: Task<Void, Never>?
    private var attemptID: UUID?
    private var pairing: Pairing?
    private var rememberedID: String?
    private var deviceID = ""
    private var deviceName = "Apple TV"
    private var loaded = false
    private var connectionID: String?
    private var connectionTag: UUID?
    private var repairID: String?

    public init() { secretNamespace = "tv" }
    init(testingNamespace: String) { precondition(testingNamespace != "tv"); secretNamespace = testingNamespace }
    func clearTestSecrets() throws {
        precondition(secretNamespace != "tv")
        stop()
        try LocalSecrets.remove(secretNamespace + "-identity")
        try LocalSecrets.remove(secretNamespace + "-pairing")
    }
    var currentState: LocalClientState { state }
    public nonisolated var source: CatalogSource { CatalogSource { [self] request, limit in try await fetch(request, limit: limit) } }

    public func updates() -> AsyncStream<LocalClientState> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation; continuation.yield(state)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish(_ status: LocalClientState.Status? = nil) {
        if let status { state.status = status }
        for observer in observers.values { observer.yield(state) }
    }

    public func start(deviceName: String = "Apple TV") {
        diagnose("Starting local discovery")
        self.deviceName = String(deviceName.prefix(200))
        guard browser == nil else { return }
        do {
            if !loaded {
                if let data = try LocalSecrets.read(secretNamespace + "-identity"), let id = String(data: data, encoding: .utf8) { deviceID = id }
                else { deviceID = UUID().uuidString; try LocalSecrets.write(Data(deviceID.utf8), account: secretNamespace + "-identity") }
                if let data = try LocalSecrets.read(secretNamespace + "-pairing") { pairing = try JSONDecoder().decode(Pairing.self, from: data) }
                rememberedID = pairing?.id
                loaded = true
            }
        } catch { publish(.failed(error.localizedDescription)); return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LocalProtocol.serviceType, domain: "local."), using: .tcp)
        browser.stateUpdateHandler = { [weak self] status in
            if case .waiting(let error) = status { Task { await self?.browserError(error) } }
            if case .failed(let error) = status { Task { await self?.browserError(error) } }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in Task { await self?.discovered(results) } }
        self.browser = browser
        browser.start(queue: DispatchQueue(label: "Holodeck.mac-discovery"))
        publish(.searching)
    }

    public func stop() {
        diagnose("Stopping local discovery")
        browser?.cancel(); browser = nil
        cancelConnection()
        state.macs = []; publish(.disconnected)
    }

    public func choose(_ id: String) {
        cancelConnection()
        rememberedID = id
        if pairing?.id != id || repairID == id { pairing = nil }
        repairID = nil
        attemptConnection(explicit: true)
    }

    public func changeMac() {
        cancelConnection()
        rememberedID = nil
        publish(.chooseMac)
    }

    public func retry() {
        if browser == nil { start(deviceName: deviceName) }
        if connection == nil { attemptConnection(explicit: true) }
    }

    private func cancelConnection() {
        attemptID = nil; connecting?.cancel(); connecting = nil
        connectionTag = nil; connection?.cancel(); connection = nil; connectionID = nil
    }

    private func browserError(_ error: NWError) {
        diagnose("Bonjour error: \(error)")
        if LocalProtocol.isPermissionDenied(error) { publish(.permissionDenied) }
        else { publish(.disconnected) }
    }

    private func discovered(_ results: Set<NWBrowser.Result>) {
        diagnose("Bonjour results: \(results.count)")
        var macs: [String: LocalMac] = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let id = txt["id"], UUID(uuidString: id) != nil,
                  let interface = result.interfaces.first,
                  case .service(_, let type, let domain, _) = result.endpoint,
                  type == LocalProtocol.serviceType, domain == "local." else { continue }
            macs[id] = LocalMac(id: id, name: txt["name"] ?? "Mac", endpoint: result.endpoint,
                               interface: interface, version: Int(txt["version"] ?? "0") ?? 0)
        }
        state.macs = macs.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let connectionID, !state.macs.contains(where: { $0.id == connectionID }) {
            cancelConnection(); publish(.disconnected)
        }
        if connection == nil, connecting == nil, state.status != .chooseMac { attemptConnection() }
        publish()
    }

    private func attemptConnection(explicit: Bool = false) {
        guard connection == nil, connecting == nil else { return }
        if !explicit, [.rejected, .identityChanged, .incompatible].contains(state.status) { return }
        let id = LocalProtocol.chooseMacID(available: state.macs.map(\.id), remembered: rememberedID)
        let mac = state.macs.first { $0.id == id }
        guard let mac else {
            publish(rememberedID == nil ? (state.macs.isEmpty ? .searching : .chooseMac) : .disconnected)
            return
        }
        rememberedID = mac.id
        guard mac.version == LocalProtocol.version else { publish(.incompatible); return }
        publish(.connecting)
        let attempt = UUID(); attemptID = attempt
        connecting = Task { [self] in
            do { try await connect(mac) }
            catch {
                diagnose("Connection failed: \(error)")
                if !Task.isCancelled, attemptID == attempt { handle(error) }
            }
            if attemptID == attempt { connecting = nil; attemptID = nil }
        }
    }

    private func closed(_ tag: UUID) {
        guard connectionTag == tag else { return }
        connection = nil; connectionID = nil; connectionTag = nil
        publish(.disconnected)
        if browser != nil { attemptConnection() }
    }

    private func connect(_ mac: LocalMac) async throws {
        diagnose("Resolving discovered Mac")
        let resolved = try await LocalResolver().resolve(mac)
        diagnose("Resolved a local destination")
        try Task.checkCancellation()
        let saved = pairing?.id == mac.id ? pairing : nil
        let trust = LocalTrust()
        let parameters = NWParameters(tls: trust.options(expected: saved?.pin), tcp: .init())
        parameters.requiredInterface = mac.interface
        let tag = UUID()
        let channel = LocalConnection(NWConnection(to: .hostPort(host: .init(resolved.address), port: .init(rawValue: resolved.port)!), using: parameters),
            onClosed: { [weak self] in Task { await self?.closed(tag) } })
        do {
            try await channel.start()
            diagnose("TLS connection ready")
            try Task.checkCancellation()
            let hello = try await channel.exchange(LocalPacket(message: .init(operation: "hello")))
            guard hello.message.serverID == mac.id else { throw LocalCatalogError.identityChanged }
            var request = LocalMessage(operation: saved == nil ? "pair" : "authenticate")
            request.deviceID = deviceID; request.name = deviceName; request.token = saved?.token
            if saved == nil { publish(.awaitingApproval(try await channel.pairingCode())) }
            // Approval is asynchronous on the server; poll this same TLS connection.
            var response = try await channel.exchange(LocalPacket(message: request))
            while response.message.operation == "pending" {
                try await Task.sleep(for: .seconds(1))
                response = try await channel.exchange(LocalPacket(message: .init(operation: "pairStatus")))
            }
            try check(response)
            guard let pin = trust.fingerprint, let token = response.message.token ?? saved?.token else { throw LocalCatalogError.protocolViolation }
            let approved = Pairing(id: mac.id, name: mac.name, pin: pin, token: token)
            try Task.checkCancellation()
            try LocalSecrets.write(JSONEncoder().encode(approved), account: secretNamespace + "-pairing")
            pairing = approved; connection = channel; connectionID = mac.id; connectionTag = tag
            state.generation &+= 1; publish(.connected(mac.name))
        } catch {
            channel.cancel()
            if trust.identityChanged { throw LocalCatalogError.identityChanged }
            throw error
        }
    }

    private func diagnose(_ message: String) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-local-network") { print("Holodeck LAN: \(message)") }
        #endif
    }

    private func fetch(_ request: CatalogRequest, limit: Int) async throws -> Data {
        guard let connection else {
            if browser != nil { attemptConnection() }
            throw LocalCatalogError.disconnected
        }
        do {
            var message = LocalMessage(operation: "asset"); message.request = request; message.limit = limit
            let response = try await connection.exchange(LocalPacket(message: message))
            try check(response)
            guard response.payload.count <= limit else { throw CatalogError.oversizedResponse }
            return response.payload
        } catch {
            if self.connection === connection {
                connectionTag = nil; connection.cancel(); self.connection = nil; connectionID = nil; handle(error)
            }
            throw error
        }
    }

    private func check(_ packet: LocalPacket) throws {
        switch packet.message.error {
        case nil: break
        case "revoked", "rejected": throw LocalCatalogError.rejected
        case "incompatible": throw LocalCatalogError.incompatible
        default: throw CatalogError.invalidResponse
        }
    }
    private func handle(_ error: Error) {
        switch error {
        case LocalCatalogError.rejected: pairing = nil; publish(.rejected)
        case LocalCatalogError.identityChanged: repairID = rememberedID; publish(.identityChanged)
        case LocalCatalogError.incompatible: publish(.incompatible)
        case LocalCatalogError.permissionDenied: publish(.permissionDenied)
        default: publish(.disconnected)
        }
    }
}
