import Foundation
import Network
import dnssd

nonisolated public struct LocalMac: Identifiable, Sendable {
    public let id: String
    public let name: String
    let endpoint: NWEndpoint
    let interface: NWInterface?
    let version: Int
}

nonisolated struct ResolvedMac: Sendable {
    let address: String
    let port: UInt16
}

/// Force both SRV and address lookup through mDNS, and validate before opening a socket.
nonisolated struct LocalDNSServiceAPI: @unchecked Sendable {
    var resolve: (inout DNSServiceRef?, UInt32, String, String, String, DNSServiceResolveReply?, UnsafeMutableRawPointer) -> DNSServiceErrorType
    var getAddress: (inout DNSServiceRef?, UInt32, String, DNSServiceGetAddrInfoReply?, UnsafeMutableRawPointer) -> DNSServiceErrorType
    var schedule: (DNSServiceRef, DispatchQueue) -> DNSServiceErrorType
    var deallocate: (DNSServiceRef) -> Void

    static let live = Self(resolve: { ref, interface, name, type, domain, callback, context in
        DNSServiceResolve(&ref, LocalResolver.resolutionFlags, interface, name, type, domain, callback, context)
    }, getAddress: { ref, interface, host, callback, context in
        DNSServiceGetAddrInfo(&ref, LocalResolver.resolutionFlags, interface,
            DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6), host, callback, context)
    }, schedule: DNSServiceSetDispatchQueue, deallocate: DNSServiceRefDeallocate)
}

nonisolated final class LocalResolver: @unchecked Sendable {
    static let resolutionFlags = DNSServiceFlags(kDNSServiceFlagsForceMulticast)
    private let queue = DispatchQueue(label: "Holodeck.multicast-resolver")
    private var service: DNSServiceRef?
    private var address: DNSServiceRef?
    private var continuation: CheckedContinuation<ResolvedMac, Error>?
    private var port: UInt16 = 0
    private enum Phase { case idle, service, address, finished }
    private var phase = Phase.idle
    private let api: LocalDNSServiceAPI

    init(api: LocalDNSServiceAPI = .live) { self.api = api }

    func resolve(_ mac: LocalMac) async throws -> ResolvedMac {
        try Task.checkCancellation()
        return try await withLocalTimeout { [self] in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async { [self] in
                        guard phase == .idle else { continuation.resume(throwing: CancellationError()); return }
                        self.continuation = continuation
                        guard case .service(let name, let type, let domain, _) = mac.endpoint,
                              type == LocalProtocol.serviceType, domain == "local." else {
                            finish(.failure(LocalCatalogError.protocolViolation)); return
                        }
                        phase = .service
                        let error = api.resolve(&service,
                            UInt32(mac.interface?.index ?? 0), name, type, domain, { _, _, interface, error, _, host, port, _, _, context in
                                guard let context else { return }
                                let resolver = Unmanaged<LocalResolver>.fromOpaque(context).takeUnretainedValue()
                                resolver.resolved(interface: interface, error: error, host: host, port: port)
                            }, Unmanaged.passUnretained(self).toOpaque())
                        guard error == kDNSServiceErr_NoError, let service else { finish(.failure(Self.failure(error))); return }
                        let scheduled = api.schedule(service, queue)
                        if scheduled != kDNSServiceErr_NoError { finish(.failure(Self.failure(scheduled))) }
                    }
                }
            } onCancel: { self.queue.async { self.finish(.failure(CancellationError())) } }
        }
    }

    private func resolved(interface: UInt32, error: DNSServiceErrorType, host: UnsafePointer<CChar>?, port: UInt16) {
        guard phase == .service else { return }
        guard error == kDNSServiceErr_NoError, let host,
              String(cString: host).lowercased().hasSuffix(".local.") || String(cString: host).lowercased().hasSuffix(".local") else {
            finish(.failure(Self.failure(error))); return
        }
        self.port = UInt16(bigEndian: port)
        guard self.port > 0 else { finish(.failure(LocalCatalogError.protocolViolation)); return }
        // Copy the callback-owned hostname before disposing its lookup.
        let hostname = String(cString: host)
        phase = .address
        if let service { api.deallocate(service); self.service = nil }
        let error = api.getAddress(&address, interface, hostname, { _, _, interface, error, _, address, _, context in
                guard let context else { return }
                let resolver = Unmanaged<LocalResolver>.fromOpaque(context).takeUnretainedValue()
                guard resolver.phase == .address else { return }
                guard error == kDNSServiceErr_NoError, let address else { resolver.finish(.failure(LocalResolver.failure(error))); return }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return }
                var text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard LocalProtocol.isLocalAddress(text) else { return }
                if address.pointee.sa_family == AF_INET6, !text.contains("%"), text.lowercased().hasPrefix("fe80:") { text += "%\(interface)" }
                resolver.finish(.success(ResolvedMac(address: text, port: resolver.port)))
            }, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let address else { finish(.failure(Self.failure(error))); return }
        let scheduled = api.schedule(address, queue)
        if scheduled != kDNSServiceErr_NoError { finish(.failure(Self.failure(scheduled))) }
    }

    static func failure(_ code: DNSServiceErrorType) -> LocalCatalogError {
        code == kDNSServiceErr_PolicyDenied ? .permissionDenied : .disconnected
    }

    private func finish(_ result: Result<ResolvedMac, Error>) {
        guard phase != .finished else { return }
        phase = .finished
        let continuation = continuation; self.continuation = nil
        if let service { api.deallocate(service); self.service = nil }
        if let address { api.deallocate(address); self.address = nil }
        continuation?.resume(with: result)
    }
}
