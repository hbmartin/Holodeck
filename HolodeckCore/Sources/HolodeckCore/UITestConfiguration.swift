#if DEBUG
import Foundation

/// Shared flag parsing; platform fixture installation stays in its app target.
nonisolated public struct UITestConfiguration: Sendable {
    public let arguments: [String]
    public let storageSuite: String?
    public let hasExplicitStorageSuite: Bool
    public let catalog: ValidatedCatalog?

    public init(arguments: [String] = ProcessInfo.processInfo.arguments,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                applicationID: String) {
        self.arguments = arguments
        hasExplicitStorageSuite = Self.value(for: "--ui-test-storage-suite", in: arguments) != nil
        let fixture = environment["HOLODECK_UI_TEST_CATALOG"]
        catalog = fixture.flatMap { try? JSONDecoder().decode(CatalogSnapshot.self, from: Data($0.utf8)).validated() }
        if fixture != nil || arguments.contains(where: { $0.hasPrefix("--ui-test-") }) {
            storageSuite = Self.value(for: "--ui-test-storage-suite", in: arguments)
                ?? applicationID + ".ui-tests." + UUID().uuidString
        } else { storageSuite = nil }
    }
    public func contains(_ flag: String) -> Bool { arguments.contains(flag) }
    public func value(for flag: String) -> String? { Self.value(for: flag, in: arguments) }
    public var fixtureCacheDirectory: URL? {
        storageSuite.map { suite in
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HolodeckUITests", isDirectory: true)
                .appendingPathComponent(CatalogHash.sha256(Data(suite.utf8)), isDirectory: true)
        }
    }
    public func makeUserDefaults(factory: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }) -> UserDefaults? {
        guard hasExplicitStorageSuite, !contains("--ui-test-cleanup-storage-suite"), let storageSuite else { return nil }
        return factory(storageSuite)
    }
    /// Platform fixture setup invokes cleanup before creating preferences or services.
    public func cleanupStorageSuite() {
        guard contains("--ui-test-cleanup-storage-suite"), hasExplicitStorageSuite, let storageSuite else { return }
        UserDefaults.standard.removePersistentDomain(forName: storageSuite)
        if let directory = fixtureCacheDirectory { try? FileManager.default.removeItem(at: directory) }
    }
    public func makeCatalogService() -> CatalogService {
        if contains("--ui-test-cleanup-storage-suite") { return .offline() }
        #if DEBUG
        if contains("--ui-test-pending-pairing") {
            return CatalogService(initialCatalog: catalog, storage: .disabled, enabled: false, usesLocalNetwork: true)
        }
        #endif
        if contains("--ui-test-local-network"), let directory = fixtureCacheDirectory {
            return CatalogService(source: LocalCatalogClient.shared.source, storage: .disk(at: directory), usesLocalNetwork: true)
        }
        if contains("--ui-test-disk-cache"), let catalog, let directory = fixtureCacheDirectory {
            let storage = CatalogStorage.disk(at: directory)
            if let data = try? JSONEncoder().encode(catalog.snapshot) { try? storage.write("snapshot.json", data) }
            return .offline(storage: storage)
        }
        if contains("--ui-test-empty-cache") {
            return CatalogService(source: CatalogSource { _, _ in throw CatalogError.invalidResponse }, storage: .disabled)
        }
        if let catalog, contains("--ui-test-download-catalog") || contains("--ui-test-fail-refresh") {
            let fixture = CatalogDownloadFixture(snapshot: catalog.snapshot,
                failFirst: contains("--ui-test-fail-catalog-once") || contains("--ui-test-fail-refresh"))
            return CatalogService(initialCatalog: contains("--ui-test-fail-refresh") ? catalog : nil,
                                  source: CatalogSource { url, _ in try await fixture.get(url) }, storage: .disabled)
        }
        return .offline(initialCatalog: catalog)
    }
    #if DEBUG
    public func makePendingPairingClient() -> LocalCatalogClient? {
        guard contains("--ui-test-pending-pairing"), let storageSuite else { return nil }
        let mac = LocalMac(id: UUID().uuidString, name: "Test Mac", endpoint: .service(name: "Test",
            type: LocalProtocol.serviceType, domain: "local.", interface: nil), interface: nil, version: LocalProtocol.version)
        let attempts = LocalDiscoverySequence()
        var dependencies = LocalClientDependencies()
        dependencies.usesSystemBrowser = false; dependencies.initialMacs = [mac]
        dependencies.readSecret = { _ in nil }; dependencies.writeSecret = { _, _ in }; dependencies.removeSecret = { _ in }
        dependencies.resolve = { _ in ResolvedMac(address: "192.168.1.2", port: 1234) }
        dependencies.transport = { mac, _, _, _ in
            let code = String(format: "%06llu", attempts.next())
            return LocalClientTransport(channel: PendingPairingTestChannel(id: mac.id, code: code),
                fingerprint: { "test-pin" }, identityChanged: { false })
        }
        return LocalCatalogClient(testingNamespace: "ui-" + storageSuite, dependencies: dependencies)
    }
    #endif
    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
              !arguments[index + 1].hasPrefix("--") else { return nil }
        return arguments[index + 1]
    }
}

private actor CatalogDownloadFixture {
    let snapshot: CatalogSnapshot
    var failFirst: Bool
    init(snapshot: CatalogSnapshot, failFirst: Bool) { self.snapshot = snapshot; self.failFirst = failFirst }
    func get(_ url: CatalogRequest) throws -> Data {
        if url.isHead {
            if failFirst { failFirst = false; throw CatalogError.invalidResponse }
            return Data("{\"revision\":\"\(snapshot.publicationRevision)\"}".utf8)
        }
        if url.lastPathComponent == "catalog.json" { return try JSONEncoder().encode(snapshot.manifest) }
        let id = String(url.lastPathComponent.split(separator: ".")[0])
        if let source = snapshot.sources[id], url.lastPathComponent.hasSuffix(".metal") { return Data(source.utf8) }
        throw CatalogError.invalidResponse
    }
}
#endif

#if DEBUG
/// Every new channel has a different code, exposing unintended pairing restarts.
private actor PendingPairingTestChannel: LocalRequestConnection {
    let id: String
    let code: String
    init(id: String, code: String) { self.id = id; self.code = code }
    func start() {}
    nonisolated func cancel() {}
    func pairingCode() -> String { code }
    func exchange(_ packet: LocalPacket) -> LocalPacket {
        var response = LocalMessage(operation: "pending")
        if packet.message.operation == "hello" { response.operation = "ok"; response.serverID = id }
        return LocalPacket(message: response)
    }
}
#endif
