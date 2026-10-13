import XCTest
import Network
import dnssd
@testable import HolodeckCore

final class LocalResolverRecoveryTests: XCTestCase {
    private func mac() -> LocalMac {
        LocalMac(id: UUID().uuidString, name: "Test Mac", endpoint: .service(name: "Test",
            type: LocalProtocol.serviceType, domain: "local.", interface: nil), interface: nil, version: 1)
    }
    private func wait(_ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("DNS test did not advance"); throw LocalCatalogError.timeout }
            await Task.yield()
        }
    }
    func testRepeatedServiceCallbacksStartOneAddressLookupAndDisposeEveryHandle() async throws {
        for _ in 0..<20 {
            let driver = DNSRecoveryDriver(); let resolver = LocalResolver(api: driver.api)
            let mac = mac()
            let task = Task { try await resolver.resolve(mac) }
            try await wait { driver.isScheduled }
            driver.resolveTwice()
            try await wait { driver.addressStarts == 1 }
            driver.sendAddress()
            let result = try await task.value
            XCTAssertEqual(result.address, "192.168.1.2"); XCTAssertEqual(result.port, 1234)
            XCTAssertEqual(driver.addressStarts, 1)
            XCTAssertEqual(driver.disposed, [1, 2])
        }
    }
    func testAlreadyCanceledResolutionCreatesNoHandles() async throws {
        let driver = DNSRecoveryDriver(); let resolver = LocalResolver(api: driver.api); let mac = mac()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await resolver.resolve(mac)
        }
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        XCTAssertFalse(driver.isScheduled); XCTAssertEqual(driver.addressStarts, 0)
        XCTAssertTrue(driver.disposed.isEmpty)
    }
    func testCancellationAndAddressCompletionRaceFinishesOnceWithoutLeaking() async throws {
        for _ in 0..<20 {
            let driver = DNSRecoveryDriver(); let resolver = LocalResolver(api: driver.api); let mac = mac()
            let task = Task { try await resolver.resolve(mac) }
            try await wait { driver.isScheduled }; driver.resolveTwice()
            try await wait { driver.addressStarts == 1 }
            driver.sendAddress(); task.cancel()
            _ = await task.result
            XCTAssertEqual(driver.disposed.sorted(), [1, 2])
        }
    }
    func testKeepaliveConfigurationPreservesIdleSessionsAndDetectsDeadPeers() {
        let options = LocalProtocol.tcpOptions()
        XCTAssertTrue(options.enableKeepalive)
        XCTAssertEqual(options.keepaliveIdle, 30)
        XCTAssertEqual(options.keepaliveInterval, 10)
        XCTAssertEqual(options.keepaliveCount, 3)
    }
}

private nonisolated final class DNSRecoveryDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: DispatchQueue?
    private var resolveCallback: DNSServiceResolveReply?
    private var addressCallback: DNSServiceGetAddrInfoReply?
    private var context: UnsafeMutableRawPointer?
    private var disposedRefs: [Int] = []
    private var addresses = 0
    var isScheduled: Bool { lock.withLock { queue != nil } }
    var addressStarts: Int { lock.withLock { addresses } }
    var disposed: [Int] { lock.withLock { disposedRefs } }
    var api: LocalDNSServiceAPI {
        LocalDNSServiceAPI(resolve: { [self] ref, _, _, _, _, callback, context in
            lock.withLock { resolveCallback = callback; self.context = context }
            ref = OpaquePointer(bitPattern: 1); return DNSServiceErrorType(kDNSServiceErr_NoError)
        }, getAddress: { [self] ref, _, _, callback, _ in
            lock.withLock { addresses += 1; addressCallback = callback }
            ref = OpaquePointer(bitPattern: 2); return DNSServiceErrorType(kDNSServiceErr_NoError)
        }, schedule: { [self] _, queue in
            lock.withLock { self.queue = queue }; return DNSServiceErrorType(kDNSServiceErr_NoError)
        }, deallocate: { [self] ref in
            lock.withLock { disposedRefs.append(Int(bitPattern: ref)) }
        })
    }
    func resolveTwice() {
        lock.withLock { queue }?.async { [self] in
            guard let callback = lock.withLock({ resolveCallback }) else { return }
            "test.local.".withCString { host in
                for _ in 0..<2 {
                    callback(OpaquePointer(bitPattern: 1), 0, 1, DNSServiceErrorType(kDNSServiceErr_NoError), host, host,
                        UInt16(1234).bigEndian, 0, nil, context)
                }
            }
        }
    }
    func sendAddress() {
        lock.withLock { queue }?.async { [self] in
            guard !lock.withLock({ disposedRefs.contains(2) }), let callback = lock.withLock({ addressCallback }) else { return }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            _ = "192.168.1.2".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
            "test.local.".withCString { host in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        callback(OpaquePointer(bitPattern: 2), DNSServiceFlags(kDNSServiceFlagsAdd), 1,
                            DNSServiceErrorType(kDNSServiceErr_NoError), host, $0, 120, context)
                    }
                }
            }
        }
    }
}
