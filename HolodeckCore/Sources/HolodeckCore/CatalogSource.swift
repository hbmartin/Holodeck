import Foundation

/// Typed asset requests cannot contain a URL or an alternate download location.
nonisolated public enum CatalogRequest: Codable, Sendable, Equatable {
    case head
    case asset(revision: String, path: String)

    public var isHead: Bool { if case .head = self { true } else { false } }
    public var lastPathComponent: String {
        switch self { case .head: "head"; case .asset(_, let path): String(path.split(separator: "/").last ?? "") }
    }
}

nonisolated public struct CatalogHead: Codable, Sendable {
    public let revision: String
    public init(revision: String) { self.revision = revision }
}

nonisolated public struct CatalogSource: Sendable {
    public enum Kind: Sendable, Equatable { case standard, localPublication }
    public let kind: Kind
    /// Waits for source recovery without canceling its shared connection attempt.
    public var waitForAvailability: (@Sendable () async throws -> Void)?
    public var get: @Sendable (CatalogRequest, Int) async throws -> Data
    public init(kind: Kind, waitForAvailability: (@Sendable () async throws -> Void)? = nil,
                get: @escaping @Sendable (CatalogRequest, Int) async throws -> Data) {
        self.kind = kind; self.waitForAvailability = waitForAvailability; self.get = get
    }
    public func replacingGet(_ get: @escaping @Sendable (CatalogRequest, Int) async throws -> Data) -> Self {
        Self(kind: kind, waitForAvailability: waitForAvailability, get: get)
    }
    public static let unavailable = Self(kind: .standard) { _, _ in throw LocalCatalogError.disconnected }
}

nonisolated public enum LocalCatalogError: Error, LocalizedError, Sendable {
    case disconnected, permissionDenied, approvalRequired, rejected, incompatible, identityChanged
    case invalidFile(String, String), protocolViolation, timeout
    var isConnectivityFailure: Bool {
        switch self {
        case .disconnected, .permissionDenied, .approvalRequired, .rejected, .incompatible, .identityChanged, .timeout: true
        case .invalidFile, .protocolViolation: false
        }
    }
    public var errorDescription: String? {
        switch self {
        case .disconnected: "Open Holodeck on your Mac, configure its shader folder, and approve this TV. Cached scenes remain available."
        case .permissionDenied: "Allow Holodeck to access the local network in Settings."
        case .approvalRequired: "Approve this TV in the Mac app’s Shader Library settings."
        case .rejected: "This TV’s access was declined or revoked. Request approval again on your Mac."
        case .incompatible: "The Mac and TV use incompatible Holodeck versions. Update both apps."
        case .identityChanged: "The Mac’s identity has changed. Choose the Mac again to request approval."
        case .invalidFile(let path, let reason): "\(path): \(reason)"
        case .protocolViolation: "The Mac sent an invalid catalog response."
        case .timeout: "The Mac did not respond. Try again."
        }
    }
}
