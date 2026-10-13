import Foundation
import Network
import dnssd

nonisolated public struct LocalMac: Identifiable, Sendable {
    public let id: String
    public let name: String
    let endpoint: NWEndpoint
    let interface: NWInterface
    let version: Int
}

nonisolated struct ResolvedMac: Sendable {
    let address: String
    let port: UInt16
}

/// Force both SRV and address lookup through mDNS, and validate before opening a socket.
nonisolated final class LocalResolver: @unchecked Sendable {
    static let resolutionFlags = DNSServiceFlags(kDNSServiceFlagsForceMulticast)
    private let queue = DispatchQueue(label: "Holodeck.multicast-resolver")
    private var service: DNSServiceRef?
    private var address: DNSServiceRef?
    private var continuation: CheckedContinuation<ResolvedMac, Error>?
    private var port: UInt16 = 0

    func resolve(_ mac: LocalMac) async throws -> ResolvedMac {
        try await withLocalTimeout { [self] in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async { [self] in
                        self.continuation = continuation
                        guard case .service(let name, let type, let domain, _) = mac.endpoint,
                              type == LocalProtocol.serviceType, domain == "local." else {
                            finish(.failure(LocalCatalogError.protocolViolation)); return
                        }
                        let error = DNSServiceResolve(&service, Self.resolutionFlags,
                            UInt32(mac.interface.index), name, type, domain, { _, _, interface, error, _, host, port, _, _, context in
                                guard let context else { return }
                                let resolver = Unmanaged<LocalResolver>.fromOpaque(context).takeUnretainedValue()
                                resolver.resolved(interface: interface, error: error, host: host, port: port)
                            }, Unmanaged.passUnretained(self).toOpaque())
                        guard error == kDNSServiceErr_NoError, let service else { finish(.failure(Self.failure(error))); return }
                        let scheduled = DNSServiceSetDispatchQueue(service, queue)
                        if scheduled != kDNSServiceErr_NoError { finish(.failure(Self.failure(scheduled))) }
                    }
                }
            } onCancel: { self.queue.async { self.finish(.failure(CancellationError())) } }
        }
    }

    private func resolved(interface: UInt32, error: DNSServiceErrorType, host: UnsafePointer<CChar>?, port: UInt16) {
        guard error == kDNSServiceErr_NoError, let host,
              String(cString: host).lowercased().hasSuffix(".local.") || String(cString: host).lowercased().hasSuffix(".local") else {
            finish(.failure(Self.failure(error))); return
        }
        self.port = UInt16(bigEndian: port)
        guard self.port > 0 else { finish(.failure(LocalCatalogError.protocolViolation)); return }
        let error = DNSServiceGetAddrInfo(&address, Self.resolutionFlags, interface,
            DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6), host, { _, _, interface, error, _, address, _, context in
                guard let context else { return }
                let resolver = Unmanaged<LocalResolver>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError, let address else { resolver.finish(.failure(LocalResolver.failure(error))); return }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return }
                var text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard LocalProtocol.isLocalAddress(text) else { return }
                if address.pointee.sa_family == AF_INET6, !text.contains("%"), text.lowercased().hasPrefix("fe80:") { text += "%\(interface)" }
                resolver.finish(.success(ResolvedMac(address: text, port: resolver.port)))
            }, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let address else { finish(.failure(Self.failure(error))); return }
        let scheduled = DNSServiceSetDispatchQueue(address, queue)
        if scheduled != kDNSServiceErr_NoError { finish(.failure(Self.failure(scheduled))) }
    }

    static func failure(_ code: DNSServiceErrorType) -> LocalCatalogError {
        code == kDNSServiceErr_PolicyDenied ? .permissionDenied : .disconnected
    }

    private func finish(_ result: Result<ResolvedMac, Error>) {
        let continuation = continuation; self.continuation = nil
        if let service { DNSServiceRefDeallocate(service); self.service = nil }
        if let address { DNSServiceRefDeallocate(address); self.address = nil }
        continuation?.resume(with: result)
    }
}
