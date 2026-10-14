import Foundation
import Network
import Security
import CryptoKit

nonisolated public enum LocalProtocol {
    public static let version = 1
    public static let serviceType = "_holodeck._tcp"
    public static let maximumHeader = 65_536
    public static let maximumPayload = 8_388_608
    static func tcpOptions() -> NWProtocolTCP.Options {
        let options = NWProtocolTCP.Options()
        options.enableKeepalive = true
        options.keepaliveIdle = 30
        options.keepaliveInterval = 10
        options.keepaliveCount = 3
        return options
    }
    static func chooseMacID(available: [String], remembered: String?) -> String? {
        if let remembered { return available.contains(remembered) ? remembered : nil }
        return available.count == 1 ? available.first : nil
    }
    static func isPermissionDenied(_ error: NWError) -> Bool {
        switch error {
        case .dns(let code): code == -65570 // kDNSServiceErr_PolicyDenied
        case .posix(let code): code == .EPERM || code == .EACCES
        default: false
        }
    }

    /// Only local unicast destinations; multicast is reserved for discovery.
    public static func isLocalAddress(_ address: String, allowLoopback: Bool = false) -> Bool {
        let address = address.split(separator: "%")[0].lowercased()
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, String(address), &v4) == 1 {
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
                (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254) ||
                (allowLoopback && bytes[0] == 127)
        }
        if inet_pton(AF_INET6, String(address), &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) ||
                (allowLoopback && bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
        }
        return false
    }
}

nonisolated struct LocalMessage: Codable, Sendable {
    var version = LocalProtocol.version
    var operation: String
    var length = 0
    var deviceID: String?
    var name: String?
    var token: String?
    var serverID: String?
    var request: CatalogRequest?
    var limit: Int?
    var error: String?
    var capabilities: [String]?
    var requestMessage: String?
}

nonisolated struct LocalPacket: Sendable {
    var message: LocalMessage
    var payload = Data()
}

nonisolated enum LocalSecrets {
    static let service = "me.haroldmartin.Holodeck.local-network"
    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }
    static func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            #if os(tvOS)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    static func failure(_ status: OSStatus) -> LocalCatalogError {
        .invalidFile("Keychain", (SecCopyErrorMessageString(status, nil) as String?) ?? "Unable to store local network identity.")
    }
    static func remove(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LocalCatalogError.protocolViolation }
        return Data(bytes).base64EncodedString()
    }
}

nonisolated final class LocalTrust: @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var mismatch = false
    var fingerprint: String? { lock.withLock { key } }
    var identityChanged: Bool { lock.withLock { mismatch } }
    static func disableCertificateFetching(_ trust: SecTrust) {
        SecTrustSetNetworkFetchAllowed(trust, false)
    }

    func options(expected: String?) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { [self] _, trust, complete in
            let value = sec_trust_copy_ref(trust).takeRetainedValue()
            Self.disableCertificateFetching(value)
            guard let certificate = (SecTrustCopyCertificateChain(value) as? [SecCertificate])?.first,
                  let publicKey = SecCertificateCopyKey(certificate),
                  let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { complete(false); return }
            let pin = CatalogHash.sha256(bytes)
            lock.withLock { key = pin; mismatch = expected != nil && expected != pin }
            guard expected == nil || expected == pin else { complete(false); return }
            SecTrustSetPolicies(value, SecPolicyCreateBasicX509())
            SecTrustSetAnchorCertificates(value, [certificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(value, true)
            complete(SecTrustEvaluateWithError(value, nil))
        }, DispatchQueue(label: "Holodeck.local-trust"))
        return options
    }
}

/// Serializes client exchanges; the server uses receive/send in one sequential loop.
protocol LocalRequestConnection: AnyObject, Sendable {
    func start() async throws
    func exchange(_ packet: LocalPacket) async throws -> LocalPacket
    func pairingCode() async throws -> String
    func cancel()
}

actor LocalConnection: LocalRequestConnection {
    nonisolated let connection: NWConnection
    private nonisolated let onClosed: @Sendable () -> Void
    private var tail: Task<Void, Never>?
    init(_ connection: NWConnection, onClosed: @escaping @Sendable () -> Void = {}) {
        self.connection = connection; self.onClosed = onClosed
    }
    nonisolated func cancel() { connection.cancel() }

    func start() async throws {
        let connection = connection
        let onClosed = onClosed
        try await withLocalTimeout {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let completion = ConnectionReady(continuation)
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: completion.finish(.success(()))
                        case .failed(let error): completion.finish(.failure(error)); onClosed()
                        case .cancelled: completion.finish(.failure(CancellationError())); onClosed()
                        case .waiting(let error): completion.finish(.failure(error)); connection.cancel()
                        default: break
                        }
                    }
                    connection.start(queue: DispatchQueue(label: "Holodeck.local-connection"))
                }
            } onCancel: { connection.cancel() }
        }
    }

    func exchange(_ packet: LocalPacket) async throws -> LocalPacket {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            try Task.checkCancellation()
            return try await withLocalTimeout { [self] in
                try await send(packet)
                return try await receive()
            }
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel(); self.cancel() }
    }

    func send(_ packet: LocalPacket) async throws {
        var message = packet.message; message.length = packet.payload.count
        guard message.length <= LocalProtocol.maximumPayload else { throw CatalogError.oversizedResponse }
        let header = try JSONEncoder().encode(message)
        guard header.count <= LocalProtocol.maximumHeader else { throw LocalCatalogError.protocolViolation }
        var length = UInt32(header.count).bigEndian
        let bytes = withUnsafeBytes(of: &length) { Data($0) } + header + packet.payload
        let connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } onCancel: { connection.cancel() }
    }

    func receive(idleAllowed: Bool = false) async throws -> LocalPacket {
        let first = idleAllowed ? try await read(1) : Data()
        return try await withLocalTimeout { [self] in try await receiveBody(prefix: first) }
    }
    private func receiveBody(prefix first: Data) async throws -> LocalPacket {
        let prefix = first + (try await read(4 - first.count))
        let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= LocalProtocol.maximumHeader else { throw LocalCatalogError.protocolViolation }
        let message = try JSONDecoder().decode(LocalMessage.self, from: await read(Int(length)))
        guard message.version == LocalProtocol.version else { throw LocalCatalogError.incompatible }
        guard (0...LocalProtocol.maximumPayload).contains(message.length) else { throw CatalogError.oversizedResponse }
        return LocalPacket(message: message, payload: try await read(message.length))
    }

    private func read(_ count: Int) async throws -> Data {
        let connection = connection
        var result = Data()
        while result.count < count {
            try Task.checkCancellation()
            let remaining = min(65_536, count - result.count)
            let chunk: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: complete ? LocalCatalogError.disconnected : LocalCatalogError.protocolViolation) }
                    }
                }
            } onCancel: { connection.cancel() }
            result.append(chunk)
        }
        return result
    }

    func pairingCode() throws -> String {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            throw LocalCatalogError.protocolViolation
        }
        let label = "holodeck-pairing-v1"
        guard let secret = label.withCString({ sec_protocol_metadata_create_secret(tls.securityProtocolMetadata, label.utf8.count, $0, 32) }) else {
            throw LocalCatalogError.protocolViolation
        }
        let data = Data(secret as DispatchData)
        let number = SHA256.hash(data: data).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06u", number)
    }
}

nonisolated private final class ConnectionReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { let value = self.continuation; self.continuation = nil; return value }
        continuation?.resume(with: result)
    }
}

nonisolated func withLocalTimeout<T: Sendable>(clock: any Clock<Duration> = ContinuousClock(),
    _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask { try await clock.sleep(for: .seconds(30)); throw LocalCatalogError.timeout }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
