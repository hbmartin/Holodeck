import Foundation
import Network
import Dependencies

nonisolated struct LocalClientTransport: Sendable {
    let channel: any LocalRequestConnection
    let fingerprint: @Sendable () -> String?
    let identityChanged: @Sendable () -> Bool
}

/// Internal seams let recovery tests control discovery, TLS, and persisted credentials.
nonisolated struct LocalClientDependencies: Sendable {
    var readSecret: @Sendable (String) throws -> Data? = LocalSecrets.read
    var writeSecret: @Sendable (Data, String) throws -> Void = { try LocalSecrets.write($0, account: $1) }
    var removeSecret: @Sendable (String) throws -> Void = LocalSecrets.remove
    var resolve: @Sendable (LocalMac) async throws -> ResolvedMac = { try await LocalResolver().resolve($0) }
    var transport: @Sendable (LocalMac, ResolvedMac, String?, @escaping @Sendable () -> Void) -> LocalClientTransport = { mac, resolved, pin, onClosed in
        let trust = LocalTrust()
        let parameters = NWParameters(tls: trust.options(expected: pin), tcp: LocalProtocol.tcpOptions())
        parameters.requiredInterface = mac.interface
        let channel = LocalConnection(NWConnection(to: .hostPort(host: .init(resolved.address),
            port: .init(rawValue: resolved.port)!), using: parameters), onClosed: onClosed)
        return LocalClientTransport(channel: channel, fingerprint: { trust.fingerprint }, identityChanged: { trust.identityChanged })
    }
    var usesSystemBrowser = true
    var initialMacs: [LocalMac] = []
}

nonisolated final class LocalDiscoverySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    func next() -> UInt64 { lock.withLock { sequence &+= 1; return sequence } }
}

extension DependencyValues {
    public var localCatalogClient: LocalCatalogClient {
        get { self[LocalCatalogClientKey.self] }
        set { self[LocalCatalogClientKey.self] = newValue }
    }
}

nonisolated public enum LocalCatalogClientKey: DependencyKey {
    public static let liveValue = LocalCatalogClient.shared
    public static let testValue: LocalCatalogClient = {
        var dependencies = LocalClientDependencies()
        dependencies.usesSystemBrowser = false
        dependencies.readSecret = { _ in nil }
        dependencies.writeSecret = { _, _ in }
        dependencies.removeSecret = { _ in }
        dependencies.resolve = { _ in throw LocalCatalogError.disconnected }
        return LocalCatalogClient(testingNamespace: "dependency-test", dependencies: dependencies)
    }()
}
