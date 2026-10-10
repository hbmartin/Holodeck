#if DEBUG
import Foundation

/// Shared flag parsing; platform fixture installation stays in its app target.
nonisolated public struct UITestConfiguration: Sendable {
    public let arguments: [String]
    public let storageSuite: String?
    public let catalog: ValidatedCatalog?

    public init(arguments: [String] = ProcessInfo.processInfo.arguments,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                applicationID: String) {
        self.arguments = arguments
        let fixture = environment["HOLODECK_UI_TEST_CATALOG"]
        catalog = fixture.flatMap { try? JSONDecoder().decode(CatalogSnapshot.self, from: Data($0.utf8)).validated() }
        if fixture != nil || arguments.contains(where: { $0.hasPrefix("--ui-test-") }) {
            storageSuite = Self.value(for: "--ui-test-storage-suite", in: arguments)
                ?? applicationID + ".ui-tests." + UUID().uuidString
        } else { storageSuite = nil }
    }
    public func contains(_ flag: String) -> Bool { arguments.contains(flag) }
    public func value(for flag: String) -> String? { Self.value(for: flag, in: arguments) }
    public func makeCatalogService() -> CatalogService {
        if contains("--ui-test-empty-cache") {
            return CatalogService(network: CatalogNetwork { _, _ in throw CatalogError.invalidResponse }, storage: .disabled)
        }
        if let catalog, contains("--ui-test-download-catalog") || contains("--ui-test-fail-refresh") {
            let fixture = CatalogDownloadFixture(snapshot: catalog.snapshot,
                failFirst: contains("--ui-test-fail-catalog-once") || contains("--ui-test-fail-refresh"))
            return CatalogService(initialCatalog: contains("--ui-test-fail-refresh") ? catalog : nil,
                                  network: CatalogNetwork { url, _ in try await fixture.get(url) }, storage: .disabled)
        }
        return .offline(initialCatalog: catalog)
    }
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
    func get(_ url: URL) throws -> Data {
        if url.host == "api.github.com" {
            if failFirst { failFirst = false; throw CatalogError.invalidResponse }
            return Data("{\"object\":{\"sha\":\"\(snapshot.publicationRevision)\"}}".utf8)
        }
        if url.lastPathComponent == "catalog.json" { return try JSONEncoder().encode(snapshot.manifest) }
        let id = url.deletingPathExtension().lastPathComponent
        if let source = snapshot.sources[id], url.pathExtension == "metal" { return Data(source.utf8) }
        throw CatalogError.invalidResponse
    }
}
#endif
