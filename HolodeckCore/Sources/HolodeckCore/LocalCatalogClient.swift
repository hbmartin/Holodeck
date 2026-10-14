import Foundation
import Network
import Clocks

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
    public var macChoiceID: UUID?
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
    private let dependencies: LocalClientDependencies
    private let clock: AnyClock<Duration>
    private struct Pairing: Codable, Sendable {
        let id: String; let name: String; let pin: String; var token: String?
    }
    private var browser: NWBrowser?
    private var browserID: UUID?
    private var browserReady = false
    private var discoverySequence: UInt64 = 0
    private var browserStateSequence: UInt64 = 0
    private var state = LocalClientState()
    private var observers: [UUID: AsyncStream<LocalClientState>.Continuation] = [:]
    private var connection: (any LocalRequestConnection)?
    private var connecting: Task<Void, Never>?
    private var attemptID: UUID?
    private var pairing: Pairing?
    private var rememberedID: String?
    private var deviceID = ""
    private var deviceName = "Apple TV"
    private var loaded = false
    private var connectionTag: UUID?
    private var repairID: String?
    private var recoveryID: UUID?
    private var recoveryTask: Task<Void, Never>?
    private var manualChoice = false
    private var choicePreviousStatus: LocalClientState.Status?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0

    public init() {
        secretNamespace = "tv"; dependencies = LocalClientDependencies(); clock = AnyClock(ContinuousClock())
    }
    init(testingNamespace: String, dependencies: LocalClientDependencies = LocalClientDependencies(),
         clock: any Clock<Duration> = ContinuousClock()) {
        precondition(testingNamespace != "tv")
        secretNamespace = testingNamespace; self.dependencies = dependencies; self.clock = AnyClock(clock)
    }
    func clearTestSecrets() throws {
        precondition(secretNamespace != "tv")
        stop()
        try dependencies.removeSecret(secretNamespace + "-identity")
        try dependencies.removeSecret(secretNamespace + "-pairing")
    }
    var currentState: LocalClientState { state }
    var currentBrowserID: UUID? { browserID }
    var observerCount: Int { observers.count }
    public nonisolated var source: CatalogSource {
        var source = CatalogSource(waitForAvailability: { [self] in try await waitForAvailability() }) {
            [self] request, limit in try await fetch(request, limit: limit)
        }
        source.isLocalPublication = true
        return source
    }

    public func updates() -> AsyncStream<LocalClientState> { makeUpdates(id: UUID()) }
    private func makeUpdates(id: UUID) -> AsyncStream<LocalClientState> {
        AsyncStream { continuation in
            observers[id] = continuation; continuation.yield(state)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.finish() }
    private func publish(_ status: LocalClientState.Status? = nil) {
        if let status { state.status = status }
        for observer in observers.values { observer.yield(state) }
    }

    /// Checks cancellation on the actor, so a queued obsolete lifecycle event cannot win.
    public func setForeground(_ foreground: Bool, deviceName: String = "Apple TV") {
        guard !Task.isCancelled else { return }
        if foreground { start(deviceName: deviceName) } else { stop() }
    }

    public func start(deviceName: String = "Apple TV") {
        diagnose("Starting local discovery")
        self.deviceName = String(deviceName.prefix(200))
        guard browserID == nil else { return }
        do {
            if !loaded {
                if let data = try dependencies.readSecret(secretNamespace + "-identity"),
                   let id = String(data: data, encoding: .utf8) { deviceID = id }
                else {
                    deviceID = UUID().uuidString
                    try dependencies.writeSecret(Data(deviceID.utf8), secretNamespace + "-identity")
                }
                if let data = try dependencies.readSecret(secretNamespace + "-pairing") {
                    pairing = try JSONDecoder().decode(Pairing.self, from: data)
                }
                rememberedID = pairing?.id; loaded = true
            }
        } catch { publish(.failed(error.localizedDescription)); return }
        let id = UUID(); browserID = id
        discoverySequence = 0; browserStateSequence = 0
        browserReady = !dependencies.usesSystemBrowser
        if dependencies.usesSystemBrowser {
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LocalProtocol.serviceType, domain: "local."), using: .tcp)
            let sequence = LocalDiscoverySequence()
            browser.stateUpdateHandler = { [weak self] status in
                let number = sequence.next()
                Task { await self?.browserState(status, id: id, sequence: number) }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let number = sequence.next()
                Task { await self?.discovered(results, id: id, sequence: number) }
            }
            self.browser = browser
            browser.start(queue: DispatchQueue(label: "Holodeck.mac-discovery"))
        }
        if connection == nil, connecting == nil { publish(.searching) }
        if !dependencies.usesSystemBrowser, !dependencies.initialMacs.isEmpty {
            discovered(dependencies.initialMacs, id: id, sequence: 1)
        }
    }

    public func stop() {
        diagnose("Stopping local discovery")
        browserID = nil; browserReady = false; browser?.cancel(); browser = nil
        cancelConnection(); resetRecovery(); manualChoice = false
        state.macs = []; publish(.disconnected)
    }

    public func choose(_ id: String) {
        cancelConnection(); resetRecovery(); manualChoice = false
        do {
            if pairing?.id != id || repairID == id {
                try dependencies.removeSecret(secretNamespace + "-pairing"); pairing = nil
            }
        } catch { publish(.failed(error.localizedDescription)); return }
        rememberedID = id; repairID = nil
        attemptConnection(explicit: true)
    }

    public func changeMac() {
        cancelReconnect()
        choicePreviousStatus = state.status
        resetRecovery(); manualChoice = true
        state.macChoiceID = UUID(); publish(.chooseMac)
    }

    public func cancelMacChoice() {
        guard manualChoice else { return }
        manualChoice = false
        if connection != nil {
            resetRecovery(); publish(.connected(pairing?.name ?? "Mac"))
        } else if connecting != nil {
            resetRecovery()
            if state.status == .chooseMac { publish(choicePreviousStatus ?? .connecting) }
        } else if let rememberedID, state.macs.contains(where: { $0.id == rememberedID }) {
            resetRecovery(); attemptConnection(explicit: true)
        } else {
            // Preserve this canceled episode until the remembered host returns.
            recoveryID = state.macChoiceID
            if rememberedID != nil { publish(.disconnected) }
        }
        choicePreviousStatus = nil
    }

    public func retry() {
        cancelReconnect()
        manualChoice = false; resetRecovery()
        if browserID == nil { start(deviceName: deviceName) }
        if connection == nil { attemptConnection(explicit: true) }
    }

    private func cancelConnection() {
        cancelReconnect()
        attemptID = nil; connecting?.cancel(); connecting = nil
        connectionTag = nil; connection?.cancel(); connection = nil
    }

    func browserState(_ value: NWBrowser.State, id: UUID, sequence: UInt64) {
        guard browserID == id, sequence > browserStateSequence else { return }
        browserStateSequence = sequence
        switch value {
        case .ready:
            browserReady = true
            if state.status == .permissionDenied, connection == nil, connecting == nil { publish(.searching) }
            if connection == nil, connecting == nil, state.status != .chooseMac { attemptConnection() }
        case .waiting(let error), .failed(let error):
            browserReady = false
            cancelReconnect()
            recoveryTask?.cancel(); recoveryTask = nil
            if case .failed = value { browserID = nil; browser?.cancel(); browser = nil }
            diagnose("Bonjour error: \(error)")
            if connection == nil, connecting == nil {
                publish(LocalProtocol.isPermissionDenied(error) ? .permissionDenied : .disconnected)
            }
        default: break
        }
    }

    private func discovered(_ results: Set<NWBrowser.Result>, id: UUID, sequence: UInt64) {
        var macs: [String: LocalMac] = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let id = txt["id"], UUID(uuidString: id) != nil,
                  let interface = result.interfaces.first,
                  case .service(_, let type, let domain, _) = result.endpoint,
                  type == LocalProtocol.serviceType, domain == "local." else { continue }
            macs[id] = LocalMac(id: id, name: txt["name"] ?? "Mac", endpoint: result.endpoint,
                               interface: interface, version: Int(txt["version"] ?? "0") ?? 0)
        }
        discovered(Array(macs.values), id: id, sequence: sequence)
    }

    func discovered(_ macs: [LocalMac], id: UUID, sequence: UInt64) {
        guard browserID == id, sequence > discoverySequence else { return }
        discoverySequence = sequence
        state.macs = macs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let rememberedID, !state.macs.contains(where: { $0.id == rememberedID }), connection == nil {
            cancelReconnect()
        }
        // Discovery is advisory; only the channel determines whether it is alive.
        if let rememberedID, state.macs.contains(where: { $0.id == rememberedID }), !manualChoice {
            let recovering = recoveryID != nil
            resetRecovery()
            if recovering, state.status == .chooseMac { publish(.searching) }
        }
        if connection == nil, connecting == nil, state.status != .chooseMac { attemptConnection() }
        updateRecovery(); publish()
    }

    private func resetRecovery() {
        recoveryTask?.cancel(); recoveryTask = nil; recoveryID = nil; state.macChoiceID = nil
    }
    private func updateRecovery() {
        guard browserReady, let browserID, connection == nil, connecting == nil, !manualChoice,
              let rememberedID, !state.macs.contains(where: { $0.id == rememberedID }), !state.macs.isEmpty else {
            recoveryTask?.cancel(); recoveryTask = nil
            return
        }
        guard state.macChoiceID == nil, recoveryTask == nil else { return }
        let episode = recoveryID ?? UUID(); recoveryID = episode
        let deadline = clock.now.advanced(by: .seconds(5))
        recoveryTask = Task { [weak self, clock] in
            do { try await clock.sleep(until: deadline) } catch { return }
            await self?.offerRecovery(episode, browserID: browserID)
        }
    }
    private func offerRecovery(_ episode: UUID, browserID: UUID) {
        guard self.browserID == browserID, browserReady, recoveryID == episode,
              connection == nil, connecting == nil, let rememberedID,
              !state.macs.contains(where: { $0.id == rememberedID }), !state.macs.isEmpty else { return }
        recoveryTask = nil; state.macChoiceID = episode; publish(.chooseMac)
    }

    private func attemptConnection(explicit: Bool = false) {
        guard browserReady, connection == nil, connecting == nil else { return }
        if !explicit, reconnectTask != nil { return }
        if !explicit {
            switch state.status {
            case .rejected, .identityChanged, .incompatible, .permissionDenied, .failed: return
            default: break
            }
        }
        let id = LocalProtocol.chooseMacID(available: state.macs.map(\.id), remembered: rememberedID)
        guard let mac = state.macs.first(where: { $0.id == id }) else {
            publish(rememberedID == nil ? (state.macs.isEmpty ? .searching : .chooseMac) : .disconnected)
            if state.status == .chooseMac, state.macChoiceID == nil { state.macChoiceID = UUID(); publish() }
            updateRecovery(); return
        }
        resetRecovery(); rememberedID = mac.id
        guard mac.version == LocalProtocol.version else { publish(.incompatible); return }
        publish(.connecting)
        let attempt = UUID(); attemptID = attempt
        connecting = Task { [self] in
            do { try await connect(mac, attempt: attempt) }
            catch {
                diagnose("Connection failed: \(error)")
                if !Task.isCancelled, attemptID == attempt { handle(connectionError(error)) }
            }
            if attemptID == attempt {
                connecting = nil; attemptID = nil
                updateRecovery(); scheduleReconnect(); publish()
            }
        }
    }

    private func closed(_ tag: UUID) {
        guard connectionTag == tag else { return }
        connection = nil; connectionTag = nil
        publish(.disconnected)
        updateRecovery(); scheduleReconnect()
    }

    private func cancelReconnect() {
        reconnectTask?.cancel(); reconnectTask = nil; reconnectAttempts = 0
    }
    private func scheduleReconnect() {
        guard browserReady, let browserID, connection == nil, connecting == nil, !manualChoice,
              state.status == .disconnected, let rememberedID,
              state.macs.contains(where: { $0.id == rememberedID }), reconnectTask == nil else { return }
        let delay = min(1 << min(reconnectAttempts, 5), 30)
        reconnectAttempts = min(reconnectAttempts + 1, 5)
        let deadline = clock.now.advanced(by: .seconds(delay))
        reconnectTask = Task { [weak self, clock] in
            do { try await clock.sleep(until: deadline) } catch { return }
            await self?.reconnect(browserID: browserID)
        }
    }
    private func reconnect(browserID: UUID) {
        guard !Task.isCancelled, self.browserID == browserID else { return }
        reconnectTask = nil
        attemptConnection()
    }
    private func connectionError(_ error: Error) -> Error {
        guard let error = error as? NWError else { return error }
        return LocalProtocol.isPermissionDenied(error) ? LocalCatalogError.permissionDenied : .disconnected
    }

    private func checkAttempt(_ id: UUID) throws {
        try Task.checkCancellation()
        guard attemptID == id else { throw CancellationError() }
    }
    private func connect(_ mac: LocalMac, attempt: UUID) async throws {
        let resolved = try await dependencies.resolve(mac)
        try checkAttempt(attempt)
        let saved = pairing?.id == mac.id ? pairing : nil
        let tag = UUID()
        let transport = dependencies.transport(mac, resolved, saved?.pin, { [weak self] in Task { await self?.closed(tag) } })
        let channel = transport.channel
        do {
            try await channel.start(); try checkAttempt(attempt)
            let hello = try await channel.exchange(LocalPacket(message: .init(operation: "hello")))
            try checkAttempt(attempt)
            guard hello.message.serverID == mac.id else { throw LocalCatalogError.identityChanged }
            var request = LocalMessage(operation: saved?.token == nil ? "pair" : "authenticate")
            request.deviceID = deviceID; request.name = deviceName; request.token = saved?.token
            if saved?.token == nil {
                let code = try await channel.pairingCode(); try checkAttempt(attempt)
                publish(.awaitingApproval(code))
            }
            var response = try await channel.exchange(LocalPacket(message: request))
            while response.message.operation == "pending" {
                try await clock.sleep(for: .seconds(1)); try checkAttempt(attempt)
                response = try await channel.exchange(LocalPacket(message: .init(operation: "pairStatus")))
            }
            try checkAttempt(attempt); try check(response)
            guard let pin = transport.fingerprint(), let token = response.message.token ?? saved?.token else {
                throw LocalCatalogError.protocolViolation
            }
            let approved = Pairing(id: mac.id, name: mac.name, pin: pin, token: token)
            try dependencies.writeSecret(JSONEncoder().encode(approved), secretNamespace + "-pairing")
            pairing = approved; connection = channel; connectionTag = tag
            cancelReconnect()
            state.generation &+= 1; publish(.connected(mac.name))
        } catch {
            channel.cancel()
            if transport.identityChanged() { throw LocalCatalogError.identityChanged }
            throw error
        }
    }

    private func diagnose(_ message: String) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-local-network") { print("Holodeck LAN: \(message)") }
        #endif
    }

    private func waitForSetup() async throws -> any LocalRequestConnection {
        let id = UUID(); let stream = makeUpdates(id: id)
        defer { removeObserver(id) }
        for await update in stream {
            try Task.checkCancellation()
            if let connection { return connection }
            switch update.status {
            case .connecting: continue
            case .awaitingApproval: throw LocalCatalogError.approvalRequired
            case .permissionDenied: throw LocalCatalogError.permissionDenied
            case .rejected: throw LocalCatalogError.rejected
            case .incompatible: throw LocalCatalogError.incompatible
            case .identityChanged: throw LocalCatalogError.identityChanged
            default: throw LocalCatalogError.disconnected
            }
        }
        throw CancellationError()
    }
    private func waitForAvailability() async throws {
        let id = UUID(); let stream = makeUpdates(id: id)
        defer { removeObserver(id) }
        for await _ in stream {
            try Task.checkCancellation()
            if connection != nil { return }
        }
        throw CancellationError()
    }

    private func fetch(_ request: CatalogRequest, limit: Int) async throws -> Data {
        try Task.checkCancellation()
        if connection == nil, browserID != nil, state.status != .chooseMac { attemptConnection() }
        let channel: any LocalRequestConnection
        if let connection { channel = connection }
        else { channel = try await withLocalTimeout(clock: clock) { [self] in try await waitForSetup() } }
        let response: LocalPacket
        do {
            var message = LocalMessage(operation: "asset"); message.request = request; message.limit = limit
            response = try await channel.exchange(LocalPacket(message: message))
            if response.message.error != "invalidAsset" { try check(response) }
        } catch {
            let failure = connectionError(error)
            if connection === channel {
                connectionTag = nil; channel.cancel(); connection = nil; handle(failure)
                updateRecovery(); scheduleReconnect()
            }
            throw failure
        }
        // The complete frame has been consumed; request validation does not invalidate the channel.
        guard response.payload.count <= limit else { throw CatalogError.oversizedResponse }
        if response.message.error == "invalidAsset" { throw CatalogError.invalidResponse }
        return response.payload
    }

    private func check(_ packet: LocalPacket) throws {
        switch packet.message.error {
        case nil: break
        case "revoked", "rejected": throw LocalCatalogError.rejected
        case "incompatible": throw LocalCatalogError.incompatible
        default: throw LocalCatalogError.protocolViolation
        }
    }
    private func handle(_ error: Error) {
        switch error {
        case LocalCatalogError.rejected:
            do {
                if var saved = pairing {
                    saved.token = nil; pairing = saved
                    try dependencies.writeSecret(JSONEncoder().encode(saved), secretNamespace + "-pairing")
                }
                publish(.rejected)
            } catch { publish(.failed(error.localizedDescription)) }
        case LocalCatalogError.identityChanged: repairID = rememberedID; publish(.identityChanged)
        case LocalCatalogError.incompatible: publish(.incompatible)
        case LocalCatalogError.permissionDenied: publish(.permissionDenied)
        case LocalCatalogError.invalidFile: publish(.failed(error.localizedDescription))
        default: publish(.disconnected)
        }
    }
}
