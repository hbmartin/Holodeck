#if os(macOS)
import Foundation
import XCTest
import Network
import Metal
@testable import HolodeckCore

@MainActor
final class DirectoryCatalogTests: XCTestCase {
    private func tlsClient(_ server: LocalCatalogServer, pin: String? = nil) async throws -> (LocalConnection, LocalTrust) {
        var port: UInt16?
        for _ in 0..<250 {
            port = await server.listeningPort
            if let port, port > 0 { break }
            port = nil
            try await Task.sleep(for: .milliseconds(20))
        }
        let trust = LocalTrust()
        let channel = LocalConnection(NWConnection(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(port))!,
            using: NWParameters(tls: trust.options(expected: pin), tcp: .init())))
        try await channel.start()
        addTeardownBlock { channel.cancel() }
        return (channel, trust)
    }

    func testTLSApprovalCredentialReconnectRevocationAndHostPin() async throws {
        let (root, store) = try fixture()
        let catalog = try await store.reload(from: root)
        let namespace = "test-" + UUID().uuidString
        let server = LocalCatalogServer(catalog: store, testingNamespace: namespace)
        addTeardownBlock { try await server.clearTestSecrets() }
        try await server.start()
        let (client, trust) = try await tlsClient(server)
        let hello = try await client.exchange(LocalPacket(message: .init(operation: "hello")))
        XCTAssertNotNil(hello.message.serverID)
        var asset = LocalMessage(operation: "asset"); asset.request = .head; asset.limit = 65_536
        let forbidden = try await client.exchange(LocalPacket(message: asset))
        XCTAssertEqual(forbidden.message.error, "revoked")
        XCTAssertTrue(forbidden.payload.isEmpty)
        let device = UUID().uuidString
        var pair = LocalMessage(operation: "pair"); pair.deviceID = device; pair.name = "Test Apple TV"
        let stream = await server.updates()
        let response = try await client.exchange(LocalPacket(message: pair))
        XCTAssertEqual(response.message.operation, "pending")
        var iterator = stream.makeAsyncIterator()
        var request: TVApproval?
        while let update = await iterator.next() { if let first = update.pending.first { request = first; break } }
        let approval = try XCTUnwrap(request)
        let code = try await client.pairingCode()
        XCTAssertEqual(approval.code, code)
        try await server.approve(approval.id)
        let approved = try await client.exchange(LocalPacket(message: .init(operation: "pairStatus")))
        let token = try XCTUnwrap(approved.message.token)
        let head = try await client.exchange(LocalPacket(message: asset))
        XCTAssertEqual(try JSONDecoder().decode(CatalogHead.self, from: head.payload).revision, catalog.publicationRevision)
        let pin = try XCTUnwrap(trust.fingerprint)
        client.cancel()
        // Restart the service to exercise persistent identity and approvals.
        await server.stop()
        let restarted = LocalCatalogServer(catalog: store, testingNamespace: namespace)
        addTeardownBlock { try await restarted.clearTestSecrets() }
        try await restarted.start()
        let (reconnected, sameTrust) = try await tlsClient(restarted, pin: pin)
        XCTAssertEqual(sameTrust.fingerprint, pin)
        var auth = LocalMessage(operation: "authenticate"); auth.deviceID = device; auth.token = token
        let authenticated = try await reconnected.exchange(LocalPacket(message: auth))
        XCTAssertNil(authenticated.message.error)
        let available = try await reconnected.exchange(LocalPacket(message: asset))
        XCTAssertFalse(available.payload.isEmpty)
        try await restarted.revoke(device)
        let (revoked, _) = try await tlsClient(restarted, pin: pin)
        let denial = try await revoked.exchange(LocalPacket(message: auth))
        XCTAssertEqual(denial.message.error, "revoked")
        do { _ = try await tlsClient(restarted, pin: String(repeating: "0", count: 64)); XCTFail("Changed public key accepted") }
        catch {}
    }

    func testDeclinedTVReceivesNoCredentialOrAssets() async throws {
        let (root, store) = try fixture()
        _ = try await store.reload(from: root)
        let server = LocalCatalogServer(catalog: store, testingNamespace: "test-" + UUID().uuidString)
        addTeardownBlock { try await server.clearTestSecrets() }
        try await server.start()
        let (client, _) = try await tlsClient(server)
        let stream = await server.updates()
        var pair = LocalMessage(operation: "pair"); pair.deviceID = UUID().uuidString; pair.name = "Declined TV"
        _ = try await client.exchange(LocalPacket(message: pair))
        var iterator = stream.makeAsyncIterator()
        while let update = await iterator.next() {
            if let request = update.pending.first { await server.decline(request.id); break }
        }
        let denial = try await client.exchange(LocalPacket(message: .init(operation: "pairStatus")))
        XCTAssertEqual(denial.message.error, "rejected"); XCTAssertNil(denial.message.token)
    }

    func testBonjourDiscoveryPairingAndRememberedClientReconnect() async throws {
        guard ProcessInfo.processInfo.environment["HOLODECK_LAN_TEST"] == "1" else {
            throw XCTSkip("Set HOLODECK_LAN_TEST=1 on a Mac with local-network access.")
        }
        let (root, store) = try fixture()
        let catalog = try await store.reload(from: root)
        let namespace = "test-lan-" + UUID().uuidString
        let server = LocalCatalogServer(catalog: store, testingNamespace: namespace, advertise: true)
        let client = LocalCatalogClient(testingNamespace: namespace)
        addTeardownBlock { try await server.clearTestSecrets(); try await client.clearTestSecrets() }
        try await server.start()
        let serverID = await server.serverID
        let id = try XCTUnwrap(serverID)
        await client.start(deviceName: "LAN test TV")
        let deadline = ContinuousClock().now.advanced(by: .seconds(35))
        var didChoose = false, didApprove = false
        while ContinuousClock().now < deadline {
            let state = await client.currentState
            if !didChoose, state.macs.contains(where: { $0.id == id }) {
                didChoose = true
                await client.choose(id)
            }
            if case .awaitingApproval(let code) = state.status,
               let request = await server.currentState.pending.first {
                XCTAssertEqual(code, request.code)
                try await server.approve(request.id); didApprove = true
            }
            if case .connected = state.status { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let state = await client.currentState
        guard case .connected = state.status else { return XCTFail("LAN connection failed: \(state.status.message); discovered \(state.macs.count) Macs; server: \(await server.currentState.message)") }
        XCTAssertTrue(didChoose); XCTAssertTrue(didApprove)
        let head = try JSONDecoder().decode(CatalogHead.self, from: await client.source.get(.head, 65_536))
        XCTAssertEqual(head.revision, catalog.publicationRevision)
        await client.stop()
        let remembered = LocalCatalogClient(testingNamespace: namespace)
        addTeardownBlock { try await remembered.clearTestSecrets() }
        await remembered.start(deviceName: "LAN test TV")
        let reconnectDeadline = ContinuousClock().now.advanced(by: .seconds(35))
        while ContinuousClock().now < reconnectDeadline {
            if case .connected = await remembered.currentState.status { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let reconnected = await remembered.currentState
        guard case .connected = reconnected.status else { return XCTFail("Remembered client failed: \(reconnected.status.message)") }
        let pending = await server.currentState.pending
        XCTAssertTrue(pending.isEmpty)
        let cachedHead = try JSONDecoder().decode(CatalogHead.self, from: await remembered.source.get(.head, 65_536))
        XCTAssertEqual(cachedHead.revision, head.revision)
    }

    func fixture() throws -> (URL, DirectoryCatalog) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("authoring")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        try Data("COMMON\n".utf8).write(to: root.appendingPathComponent("shared/common.metal"))
        try Data("FRAGMENT\n".utf8).write(to: root.appendingPathComponent("shared/fragment.metal"))
        let entry = TestCatalog.snapshot.manifest.shaders[0]
        let directory = root.appendingPathComponent("shaders/\(entry.id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        metadata["shared"] = ["common", "fragment"]
        try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent("metadata.json"))
        try Data("BODY\n".utf8).write(to: directory.appendingPathComponent("body.metal"))
        try TestCatalog.preview(named: "preview-\(entry.previewSHA256).png").write(to: directory.appendingPathComponent("preview.png"))
        try JSONSerialization.data(withJSONObject: ["shaders": [entry.id], "defaultShaderID": entry.id]).write(to: root.appendingPathComponent("index.json"))
        return (root, DirectoryCatalog(directory: base.appendingPathComponent("head")))
    }

    func testAssemblyRevisionAndProvidedPreviewAreStableWithoutGit() async throws {
        let (root, store) = try fixture()
        let first = try await store.reload(from: root)
        XCTAssertEqual(first.shaders[0].source, "COMMON\nBODY\nFRAGMENT\n")
        XCTAssertEqual(first.publicationRevision.count, 64)
        let again = try await store.reload(from: root)
        XCTAssertEqual(first.publicationRevision, again.publicationRevision)
        let image = try await store.source.get(.asset(revision: first.publicationRevision, path: first.shaders[0].preview!.path), 8_388_608)
        XCTAssertEqual(CatalogHash.sha256(image), first.shaders[0].preview!.hash)
        try first.snapshot.validate()
    }

    func testMaterialHelpersCollectionsDiscoveryAndAttributionArePreserved() async throws {
        let (root, store) = try fixture()
        let path = root.appendingPathComponent("shaders/plasma/metadata.json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        metadata["shared"] = ["common", "material", "fragment"]
        metadata["discovery"] = ["tags": [" Warm ", "warm"], "moods": ["Calm"], "motion": "Slow"]
        try JSONSerialization.data(withJSONObject: metadata).write(to: path)
        try Data("MATERIAL\n".utf8).write(to: root.appendingPathComponent("shared/material.metal"))
        try Data("// Source: author attribution\nBODY\n".utf8).write(to: root.appendingPathComponent("shaders/plasma/body.metal"))
        let collection = CatalogCollection(id: "curated", name: "Curated", description: "Ordered scenes.", shaderIDs: ["plasma"])
        let encodedCollection = try JSONSerialization.jsonObject(with: JSONEncoder().encode(collection))
        try JSONSerialization.data(withJSONObject: ["shaders": ["plasma"], "defaultShaderID": "plasma", "collections": [encodedCollection]])
            .write(to: root.appendingPathComponent("index.json"))
        let loaded = try await store.reload(from: root)
        XCTAssertEqual(loaded.shaders[0].source, "COMMON\nMATERIAL\n// Source: author attribution\nBODY\nFRAGMENT\n")
        XCTAssertEqual(loaded.snapshot.manifest.collections, [collection])
        XCTAssertEqual(loaded.shaders[0].discovery?.tags, ["warm"])
        XCTAssertEqual(loaded.shaders[0].discovery?.moods, ["calm"])
    }

    func testSuppliedAuthoringRepositoryLoadsAndCompilesNatively() async throws {
        guard let path = ProcessInfo.processInfo.environment["HOLODECK_AUTHORING_FIXTURE"] else {
            throw XCTSkip("Set HOLODECK_AUTHORING_FIXTURE to test a local authoring directory.")
        }
        let root = URL(fileURLWithPath: path), destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        let store = DirectoryCatalog(directory: destination)
        let loaded = try await store.reload(from: root)
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("index.json"))) as? [String: Any])
        XCTAssertEqual(loaded.shaders.map(\.id), index["shaders"] as? [String])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let compiler = ShaderCompiler(device: device)
        for shader in loaded.shaders {
            _ = try await compiler.pipeline(for: shader)
            let supplied = try Data(contentsOf: root.appendingPathComponent("shaders/\(shader.id)/preview.png"))
            XCTAssertEqual(shader.preview?.hash, CatalogHash.sha256(supplied))
        }
    }

    func testEditsStayUnpublishedUntilManualReloadAndSourcesAreImmutable() async throws {
        let (root, store) = try fixture()
        let first = try await store.reload(from: root)
        try Data("EDITED\n".utf8).write(to: root.appendingPathComponent("shaders/plasma/body.metal"))
        let before = try JSONDecoder().decode(CatalogHead.self, from: await store.source.get(.head, 65_536))
        XCTAssertEqual(before.revision, first.publicationRevision)
        let copied = try await store.source.get(.asset(revision: first.publicationRevision, path: "sources/plasma.metal"), 1_048_576)
        XCTAssertEqual(String(decoding: copied, as: UTF8.self), first.shaders[0].source)
        let second = try await store.reload(from: root)
        XCTAssertNotEqual(second.publicationRevision, first.publicationRevision)
        XCTAssertEqual(second.shaders[0].source, "COMMON\nEDITED\nFRAGMENT\n")
    }

    func testInvalidReloadNamesFileAndRetainsCurrentSnapshot() async throws {
        let (root, store) = try fixture()
        let first = try await store.reload(from: root)
        let preview = root.appendingPathComponent("shaders/plasma/preview.png")
        try Data("not a PNG".utf8).write(to: preview)
        do { _ = try await store.reload(from: root); XCTFail("Invalid preview accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("shaders/plasma/preview.png")) }
        let head = try JSONDecoder().decode(CatalogHead.self, from: await store.source.get(.head, 65_536))
        XCTAssertEqual(head.revision, first.publicationRevision)
        let restarted = DirectoryCatalog(directory: root.deletingLastPathComponent().appendingPathComponent("head"))
        let recovered = try await restarted.cached()
        XCTAssertEqual(recovered?.publicationRevision, first.publicationRevision)
    }

    func testAllowlistAndSourceBoundsRejectArbitraryFiles() async throws {
        let (root, store) = try fixture()
        let catalog = try await store.reload(from: root)
        for path in ["../index.json", "shaders/plasma/body.metal", "index.json", "/etc/passwd", "https://example.com/catalog.json", "https://example.com/preview.png"] {
            do { _ = try await store.source.get(.asset(revision: catalog.publicationRevision, path: path), 100); XCTFail(path) }
            catch CatalogError.invalidResponse {}
        }
        do { _ = try await store.source.get(.asset(revision: catalog.publicationRevision, path: "sources/plasma.metal"), 2); XCTFail("Bound ignored") }
        catch CatalogError.oversizedResponse {}
        try FileManager.default.removeItem(at: root.appendingPathComponent("shaders/plasma/body.metal"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("shaders/plasma/body.metal"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        do { _ = try await store.reload(from: root); XCTFail("Escaping symlink accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("body.metal")) }
    }

    func testConnectionPinsRetainOldAssetsAcrossSeveralReloads() async throws {
        let (root, store) = try fixture()
        let first = try await store.reload(from: root), connection = UUID()
        _ = try await store.get(.head, limit: 65_536, pinFor: connection)
        for text in ["SECOND", "THIRD", "FOURTH"] {
            try Data(text.utf8).write(to: root.appendingPathComponent("shaders/plasma/body.metal"))
            _ = try await store.reload(from: root)
        }
        let old = try await store.get(.asset(revision: first.publicationRevision, path: "sources/plasma.metal"), limit: 1_048_576)
        XCTAssertEqual(String(decoding: old, as: UTF8.self), first.shaders[0].source)
        await store.release(connection)
        do { _ = try await store.get(.asset(revision: first.publicationRevision, path: "sources/plasma.metal"), limit: 1_048_576); XCTFail("Unleased old revision retained") }
        catch CatalogError.invalidResponse {}
    }
}
#endif
