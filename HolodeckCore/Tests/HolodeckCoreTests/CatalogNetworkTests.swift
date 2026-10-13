import Foundation
import Network
import XCTest
import dnssd
import Security
@testable import HolodeckCore

@MainActor
final class CatalogNetworkTests: XCTestCase {
    func testLocalPermissionDenialIsDistinctFromDisconnection() {
        XCTAssertTrue(LocalProtocol.isPermissionDenied(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
        XCTAssertTrue(LocalProtocol.isPermissionDenied(.posix(.EPERM)))
        XCTAssertFalse(LocalProtocol.isPermissionDenied(.posix(.ECONNREFUSED)))
        guard case .permissionDenied = LocalResolver.failure(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)) else { return XCTFail("Permission denial became a generic disconnect") }
    }
    func testResolutionAndCertificateValidationCannotUsePublicNetworking() throws {
        XCTAssertEqual(LocalResolver.resolutionFlags, DNSServiceFlags(kDNSServiceFlagsForceMulticast))
        let url = try XCTUnwrap(Bundle.module.url(forResource: "local-trust", withExtension: "der", subdirectory: "TestSupport"))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(contentsOf: url) as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let value = try XCTUnwrap(trust)
        LocalTrust.disableCertificateFetching(value)
        var allowed = DarwinBoolean(true)
        XCTAssertEqual(SecTrustGetNetworkFetchAllowed(value, &allowed), errSecSuccess)
        XCTAssertFalse(allowed.boolValue)
    }
    func testDiscoveryRemembersHostAndNeverSilentlyFailsOver() {
        XCTAssertNil(LocalProtocol.chooseMacID(available: [], remembered: nil))
        XCTAssertEqual(LocalProtocol.chooseMacID(available: ["one"], remembered: nil), "one")
        XCTAssertNil(LocalProtocol.chooseMacID(available: ["one", "two"], remembered: nil))
        XCTAssertEqual(LocalProtocol.chooseMacID(available: ["one", "two"], remembered: "two"), "two")
        XCTAssertNil(LocalProtocol.chooseMacID(available: ["one"], remembered: "two"))
    }
    private func pair() async throws -> (LocalConnection, LocalConnection) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "Loopback listener ready")
        let (stream, continuation) = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { continuation.yield($0) }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: DispatchQueue(label: "Holodeck.protocol-tests"))
        addTeardownBlock { listener.cancel(); continuation.finish() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let client = LocalConnection(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        async let started: Void = client.start()
        var iterator = stream.makeAsyncIterator()
        let incoming = await iterator.next()
        let server = LocalConnection(try XCTUnwrap(incoming))
        try await server.start()
        try await started
        addTeardownBlock { client.cancel(); server.cancel() }
        return (client, server)
    }

    func testLocalAddressPolicyRejectsPublicDNSNamesAndMappedAddresses() {
        for address in ["10.0.1.2", "172.16.0.2", "172.31.255.1", "192.168.1.2", "169.254.1.2", "fe80::123%en0", "fd00::123"] {
            XCTAssertTrue(LocalProtocol.isLocalAddress(address), address)
        }
        for address in ["8.8.8.8", "172.32.0.1", "100.64.0.1", "224.0.0.251", "127.0.0.1", "::1", "::ffff:192.168.0.1", "2001:4860:4860::8888", "github.com", "mac.local"] {
            XCTAssertFalse(LocalProtocol.isLocalAddress(address), address)
        }
        XCTAssertTrue(LocalProtocol.isLocalAddress("127.0.0.1", allowLoopback: true))
        XCTAssertTrue(LocalProtocol.isLocalAddress("::1", allowLoopback: true))
    }

    func testBinaryAssetsRoundTripWithoutMixingConcurrentRequests() async throws {
        let (client, server) = try await pair()
        let work = Task {
            for _ in 0..<12 { let packet = try await server.receive(); try await server.send(packet) }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in 0..<12 {
                group.addTask {
                    let bytes = Data(repeating: UInt8(value), count: 130_000)
                    let result = try await client.exchange(LocalPacket(message: .init(operation: "echo"), payload: bytes))
                    XCTAssertEqual(result.payload, bytes)
                }
            }
            try await group.waitForAll()
        }
        try await work.value
    }

    func testHeaderAndPayloadBoundsAreRejectedBeforeAllocation() async throws {
        for bytes in [Data([0, 1, 0, 1]), Data([0, 0, 0, 0])] {
            let (client, server) = try await pair()
            try await raw(bytes, on: client)
            do { _ = try await server.receive(); XCTFail("Invalid header accepted") }
            catch LocalCatalogError.protocolViolation {}
        }
        let (client, server) = try await pair()
        var message = LocalMessage(operation: "asset"); message.length = LocalProtocol.maximumPayload + 1
        try await raw(header(message), on: client)
        do { _ = try await server.receive(); XCTFail("Oversized payload accepted") }
        catch CatalogError.oversizedResponse {}
    }

    func testIncompatibleProtocolAndInterruptedTransferFail() async throws {
        let (client, server) = try await pair()
        var message = LocalMessage(operation: "hello"); message.version = 99
        try await raw(header(message), on: client)
        do { _ = try await server.receive(); XCTFail("Incompatible version accepted") }
        catch LocalCatalogError.incompatible {}
        let (second, receiving) = try await pair()
        try await raw(Data([0, 0]), on: second)
        second.cancel()
        do { _ = try await receiving.receive(); XCTFail("Truncated transfer accepted") } catch {}
    }

    func testCancelledReadCompletes() async throws {
        let (_, server) = try await pair()
        let task = Task { try await server.receive() }
        await Task.yield(); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled read accepted") } catch {}
    }

    private func header(_ message: LocalMessage) throws -> Data {
        let data = try JSONEncoder().encode(message)
        var size = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: &size) { Data($0) } + data
    }
    private func raw(_ bytes: Data, on channel: LocalConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.connection.send(content: bytes, completion: .contentProcessed {
                if let error = $0 { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
