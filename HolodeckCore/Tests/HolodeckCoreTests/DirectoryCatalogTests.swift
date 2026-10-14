#if os(macOS)
import Foundation
import XCTest
import Network
import Metal
import Clocks
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
        let catalog = try await store.reload(from: root).catalog
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
        let catalog = try await store.reload(from: root).catalog
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
        try JSONSerialization.data(withJSONObject: ["shaders": [entry.id], "defaultShaderID": entry.id]).write(to: root.appendingPathComponent("index.json"))
        let cache = base.appendingPathComponent("head/preview-cache")
        let previews = ShaderPreviewGenerator(directory: cache) { _ in
            try ShaderPNG.gradient(colors: entry.colors)
        }
        return (root, DirectoryCatalog(directory: base.appendingPathComponent("head"), previewGenerator: previews))
    }

    func testUnpublishedHeadIsAnInvalidResponse() async throws {
        let (_, store) = try fixture()
        do {
            _ = try await store.source.get(.head, 65_536)
            XCTFail("An unpublished catalog returned a head")
        } catch CatalogError.invalidResponse {}
    }

    func testAssemblyRevisionAndGeneratedPreviewAreStableWithoutGit() async throws {
        let (root, store) = try fixture()
        let first = try await store.reload(from: root).catalog
        XCTAssertEqual(first.shaders[0].source, "COMMON\nBODY\nFRAGMENT\n")
        XCTAssertEqual(first.publicationRevision.count, 64)
        let again = try await store.reload(from: root).catalog
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
        let loaded = try await store.reload(from: root).catalog
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
        let result = try await store.reload(from: root)
        XCTAssertTrue(result.previewWarnings.isEmpty, "All repository previews should render successfully")
        let loaded = result.catalog
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("index.json"))) as? [String: Any])
        XCTAssertEqual(loaded.shaders.map(\.id), index["shaders"] as? [String])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let compiler = ShaderCompiler(device: device)
        for shader in loaded.shaders {
            _ = try await compiler.pipeline(for: shader)
            let preview = try XCTUnwrap(shader.preview)
            let generated = try await store.get(.asset(revision: loaded.publicationRevision, path: preview.path), limit: 8_388_608)
            XCTAssertTrue(ShaderPNG.isValid(generated))
            XCTAssertEqual(preview.hash, CatalogHash.sha256(generated))
        }
    }

    func testEditsStayUnpublishedUntilManualReloadAndSourcesAreImmutable() async throws {
        let (root, store) = try fixture()
        let first = try await store.reload(from: root).catalog
        try Data("EDITED\n".utf8).write(to: root.appendingPathComponent("shaders/plasma/body.metal"))
        let before = try JSONDecoder().decode(CatalogHead.self, from: await store.source.get(.head, 65_536))
        XCTAssertEqual(before.revision, first.publicationRevision)
        let copied = try await store.source.get(.asset(revision: first.publicationRevision, path: "sources/plasma.metal"), 1_048_576)
        XCTAssertEqual(String(decoding: copied, as: UTF8.self), first.shaders[0].source)
        let second = try await store.reload(from: root).catalog
        XCTAssertNotEqual(second.publicationRevision, first.publicationRevision)
        XCTAssertEqual(second.shaders[0].source, "COMMON\nEDITED\nFRAGMENT\n")
    }

    func testInvalidReloadNamesFileAndRetainsCurrentSnapshot() async throws {
        let (root, store) = try fixture()
        let first = try await store.reload(from: root).catalog
        let metadata = root.appendingPathComponent("shaders/plasma/metadata.json")
        try Data("not JSON".utf8).write(to: metadata)
        do { _ = try await store.reload(from: root); XCTFail("Invalid metadata accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("shaders/plasma/metadata.json")) }
        let head = try JSONDecoder().decode(CatalogHead.self, from: await store.source.get(.head, 65_536))
        XCTAssertEqual(head.revision, first.publicationRevision)
        let restarted = DirectoryCatalog(directory: root.deletingLastPathComponent().appendingPathComponent("head"))
        let recovered = try await restarted.cached()
        XCTAssertEqual(recovered?.publicationRevision, first.publicationRevision)
    }

    func testAllowlistAndSourceBoundsRejectArbitraryFiles() async throws {
        let (root, store) = try fixture()
        let catalog = try await store.reload(from: root).catalog
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
        let first = try await store.reload(from: root).catalog, connection = UUID()
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

@MainActor
extension DirectoryCatalogTests {
    private func assertNoStages(_ directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(contents.contains { $0.lastPathComponent.hasPrefix("stage-") }, file: file, line: line)
    }

    func testRestartAndUnchangedReloadRepairMissingAndCorruptPublicationAssets() async throws {
        for path in ["sources/plasma.metal", "previews/plasma.png", "catalog.json"] {
            for missing in [false, true] {
                let (root, store) = try fixture()
                let first = try await store.reload(from: root).catalog
                let directory = root.deletingLastPathComponent().appendingPathComponent("head")
                let asset = directory.appendingPathComponent(first.publicationRevision).appendingPathComponent(path)
                let expected = try Data(contentsOf: asset)
                if missing { try FileManager.default.removeItem(at: asset) }
                else { try Data("CORRUPT".utf8).write(to: asset) }
                let restarted = DirectoryCatalog(directory: directory)
                do { _ = try await restarted.cached(); XCTFail("Damaged publication restored: \(path)") } catch {}
                let repaired = try await restarted.reload(from: root).catalog
                XCTAssertEqual(repaired.publicationRevision, first.publicationRevision)
                let served = try await restarted.get(.asset(revision: repaired.publicationRevision, path: path), limit: 8_388_608)
                XCTAssertEqual(served, expected)
                let restored = try await restarted.cached()
                XCTAssertEqual(restored?.publicationRevision, first.publicationRevision)
                try assertNoStages(directory)
            }
        }
    }

    func testOversizedPublicationAssetsAreRepairedWithinExistingBounds() async throws {
        for (path, limit) in [("sources/plasma.metal", 1_048_576), ("previews/plasma.png", 8_388_608), ("catalog.json", 2_097_152)] {
            let (root, store) = try fixture()
            let first = try await store.reload(from: root).catalog
            let directory = root.deletingLastPathComponent().appendingPathComponent("head")
            let asset = directory.appendingPathComponent(first.publicationRevision).appendingPathComponent(path)
            let expected = try Data(contentsOf: asset)
            try Data(repeating: 0, count: limit + 1).write(to: asset)
            _ = try await store.reload(from: root)
            let served = try await store.get(.asset(revision: first.publicationRevision, path: path), limit: limit)
            XCTAssertEqual(served, expected)
            try assertNoStages(directory)
        }
    }

    func testIntactPublicationIsReusedWithoutSwappingItsFiles() async throws {
        let (root, store) = try fixture()
        let first = try await store.reload(from: root).catalog
        let directory = root.deletingLastPathComponent().appendingPathComponent("head")
        let asset = directory.appendingPathComponent(first.publicationRevision).appendingPathComponent("sources/plasma.metal")
        let inode = try FileManager.default.attributesOfItem(atPath: asset.path)[.systemFileNumber] as? NSNumber
        var files = DirectoryCatalogFileOperations()
        files.swap = { _, _ in throw POSIXError(.EIO) }
        let restarted = DirectoryCatalog(directory: directory, files: files)
        let reused = try await restarted.reload(from: root).catalog
        XCTAssertEqual(reused.publicationRevision, first.publicationRevision)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: asset.path)[.systemFileNumber] as? NSNumber, inode)
        try assertNoStages(directory)
    }

    func testExistingManifestMustMatchCandidateEvenWhenAssetHashesAreValid() async throws {
        let (root, store) = try fixture()
        let first = try await store.reload(from: root).catalog
        let directory = root.deletingLastPathComponent().appendingPathComponent("head")
        let manifestURL = directory.appendingPathComponent(first.publicationRevision).appendingPathComponent("catalog.json")
        let expected = try Data(contentsOf: manifestURL)
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: expected) as? [String: Any])
        var entries = try XCTUnwrap(wire["shaders"] as? [[String: Any]])
        entries[0]["name"] = "Unexpected title"; wire["shaders"] = entries
        try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys]).write(to: manifestURL)
        let restarted = DirectoryCatalog(directory: directory)
        do { _ = try await restarted.cached(); XCTFail("Altered metadata restored under its original revision") }
        catch CatalogError.invalidManifest {}
        let repaired = try await restarted.reload(from: root).catalog
        XCTAssertEqual(repaired.publicationRevision, first.publicationRevision)
        let served = try await restarted.get(.asset(revision: repaired.publicationRevision, path: "catalog.json"), limit: 2_097_152)
        XCTAssertEqual(served, expected)
        try assertNoStages(directory)
    }

    func testSwapAndMarkerFailuresPreserveCurrentPublicationAndCleanupStages() async throws {
        for failure in ["swap", "marker"] {
            let (root, store) = try fixture()
            let first = try await store.reload(from: root).catalog
            let other = root.deletingLastPathComponent().appendingPathComponent("other-authoring")
            try FileManager.default.copyItem(at: root, to: other)
            try Data("SECOND\n".utf8).write(to: other.appendingPathComponent("shaders/plasma/body.metal"))
            let current = try await store.reload(from: other).catalog
            let directory = root.deletingLastPathComponent().appendingPathComponent("head")
            let marker = directory.appendingPathComponent("current.json")
            let markerBefore = try Data(contentsOf: marker)
            let damaged = directory.appendingPathComponent(first.publicationRevision).appendingPathComponent("sources/plasma.metal")
            try Data("CORRUPT".utf8).write(to: damaged)
            var files = DirectoryCatalogFileOperations()
            if failure == "swap" { files.swap = { _, _ in throw POSIXError(.ENOTSUP) } }
            else { files.writeMarker = { _, _ in throw POSIXError(.EIO) } }
            let restarted = DirectoryCatalog(directory: directory, files: files)
            _ = try await restarted.cached()
            do { _ = try await restarted.reload(from: root); XCTFail("Injected \(failure) failure ignored") }
            catch let error as POSIXError { XCTAssertEqual(error.code, failure == "swap" ? .ENOTSUP : .EIO) }
            let head = try JSONDecoder().decode(CatalogHead.self, from: await restarted.get(.head, limit: 65_536))
            XCTAssertEqual(head.revision, current.publicationRevision)
            XCTAssertEqual(try Data(contentsOf: marker), markerBefore)
            let active = try await restarted.get(.asset(revision: current.publicationRevision, path: "sources/plasma.metal"), limit: 1_048_576)
            XCTAssertEqual(String(decoding: active, as: UTF8.self), current.shaders[0].source)
            XCTAssertEqual(String(decoding: try Data(contentsOf: damaged), as: UTF8.self), failure == "swap" ? "CORRUPT" : first.shaders[0].source)
            do { _ = try await restarted.get(.asset(revision: first.publicationRevision, path: "sources/plasma.metal"), limit: 1_048_576); XCTFail("Failed publication became allowlisted") }
            catch CatalogError.invalidResponse {}
            try assertNoStages(directory)
        }
    }

    func testRepairedPublicationRemainsLeasedAcrossFurtherReloads() async throws {
        let (root, store) = try fixture()
        let first = try await store.reload(from: root).catalog
        let directory = root.deletingLastPathComponent().appendingPathComponent("head")
        let connection = UUID()
        _ = try await store.get(.head, limit: 65_536, pinFor: connection)
        try Data("CORRUPT".utf8).write(to: directory.appendingPathComponent(first.publicationRevision).appendingPathComponent("sources/plasma.metal"))
        _ = try await store.reload(from: root)
        for text in ["SECOND", "THIRD", "FOURTH"] {
            try Data(text.utf8).write(to: root.appendingPathComponent("shaders/plasma/body.metal"))
            _ = try await store.reload(from: root)
        }
        let repaired = try await store.get(.asset(revision: first.publicationRevision, path: "sources/plasma.metal"), limit: 1_048_576)
        XCTAssertEqual(String(decoding: repaired, as: UTF8.self), first.shaders[0].source)
        await store.release(connection)
        do { _ = try await store.get(.asset(revision: first.publicationRevision, path: "sources/plasma.metal"), limit: 1_048_576); XCTFail("Released repair retained") }
        catch CatalogError.invalidResponse {}
        try assertNoStages(directory)
    }

    private func waitForSessionCount(_ count: Int, server: LocalCatalogServer) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while await server.sessionCount != count {
            guard ContinuousClock.now < deadline else { XCTFail("Session cleanup timed out"); throw LocalCatalogError.timeout }
            await Task.yield()
        }
    }
    func testAbsoluteApprovalDeadlineReclaimsAllSlotsDespiteRepeatedHello() async throws {
        let (root, store) = try fixture(); _ = try await store.reload(from: root)
        let clock = TestClock()
        let server = LocalCatalogServer(catalog: store, testingNamespace: "test-" + UUID().uuidString, clock: clock)
        addTeardownBlock { try await server.clearTestSecrets() }
        try await server.start()
        var clients: [LocalConnection] = []
        for _ in 0..<16 { clients.append(try await tlsClient(server).0) }
        try await waitForSessionCount(16, server: server)
        do { _ = try await tlsClient(server); XCTFail("Seventeenth session accepted") } catch {}
        for _ in 0..<10 {
            _ = try await clients[0].exchange(LocalPacket(message: .init(operation: "hello")))
            await clock.advance(by: .seconds(29))
        }
        let count = await server.sessionCount
        XCTAssertEqual(count, 16)
        await clock.advance(by: .seconds(10))
        try await waitForSessionCount(0, server: server)
        let replacement = try await tlsClient(server).0
        let response = try await replacement.exchange(LocalPacket(message: .init(operation: "hello")))
        XCTAssertNotNil(response.message.serverID)
    }
    func testApprovedIdleSessionOutlivesDeadlineAndEveryClosureReleasesItsPublication() async throws {
        for mode in ["close", "revoke", "stop"] {
            let (root, store) = try fixture(); let first = try await store.reload(from: root).catalog
            let clock = TestClock()
            let server = LocalCatalogServer(catalog: store, testingNamespace: "test-" + UUID().uuidString, clock: clock)
            addTeardownBlock { try await server.clearTestSecrets() }
            try await server.start()
            let client = try await tlsClient(server).0
            let deviceID = UUID().uuidString
            var pair = LocalMessage(operation: "pair"); pair.deviceID = deviceID; pair.name = "Idle TV"
            _ = try await client.exchange(LocalPacket(message: pair))
            let pending = await server.currentState.pending.first
            try await server.approve(XCTUnwrap(pending).id)
            _ = try await client.exchange(LocalPacket(message: .init(operation: "pairStatus")))
            var asset = LocalMessage(operation: "asset"); asset.request = .head; asset.limit = 65_536
            _ = try await client.exchange(LocalPacket(message: asset))
            await clock.advance(by: .seconds(600))
            let count = await server.sessionCount
            XCTAssertEqual(count, 1, "Approved healthy idle connection expired")
            for body in ["SECOND", "THIRD", "FOURTH"] {
                try Data(body.utf8).write(to: root.appendingPathComponent("shaders/plasma/body.metal"))
                _ = try await store.reload(from: root)
            }
            _ = try await store.get(.asset(revision: first.publicationRevision, path: "sources/plasma.metal"), limit: 1_048_576)
            switch mode {
            case "revoke": try await server.revoke(deviceID)
            case "stop": await server.stop()
            default: client.cancel()
            }
            try await waitForSessionCount(0, server: server)
            do {
                _ = try await store.get(.asset(revision: first.publicationRevision, path: "sources/plasma.metal"), limit: 1_048_576)
                XCTFail("Closed connection retained its publication")
            } catch CatalogError.invalidResponse {}
        }
    }
    func testApprovalDeadlineRemovesPendingRequestWithoutPolling() async throws {
        let (root, store) = try fixture(); _ = try await store.reload(from: root)
        let clock = TestClock()
        let server = LocalCatalogServer(catalog: store, testingNamespace: "test-" + UUID().uuidString, clock: clock)
        addTeardownBlock { try await server.clearTestSecrets() }
        try await server.start()
        let client = try await tlsClient(server).0
        var pair = LocalMessage(operation: "pair"); pair.deviceID = UUID().uuidString; pair.name = "Absent TV"
        _ = try await client.exchange(LocalPacket(message: pair))
        let request = await server.currentState.pending.first
        let id = try XCTUnwrap(request).id
        await clock.advance(by: .seconds(300))
        try await waitForSessionCount(0, server: server)
        try await server.approve(id)
        let state = await server.currentState
        XCTAssertTrue(state.pending.isEmpty); XCTAssertTrue(state.approved.isEmpty)
    }

    func testClosureWaitsForLateCatalogReadBeforeReleasingItsLease() async throws {
        for mode in ["close", "revoke", "stop"] {
            let (root, store) = try fixture(); let first = try await store.reload(from: root).catalog
            let gate = RecoveryGate()
            let server = LocalCatalogServer(catalog: store, testingNamespace: "test-" + UUID().uuidString,
                readAsset: { request, limit, id in
                    try await gate.wait()
                    return try await store.get(request, limit: limit, pinFor: id)
                })
            addTeardownBlock { await gate.release(); try await server.clearTestSecrets() }
            try await server.start()
            let client = try await tlsClient(server).0
            let deviceID = UUID().uuidString
            var pair = LocalMessage(operation: "pair"); pair.deviceID = deviceID; pair.name = "Reading TV"
            _ = try await client.exchange(LocalPacket(message: pair))
            let pending = await server.currentState.pending.first
            try await server.approve(XCTUnwrap(pending).id)
            _ = try await client.exchange(LocalPacket(message: .init(operation: "pairStatus")))
            let request = Task {
                var asset = LocalMessage(operation: "asset"); asset.request = .head; asset.limit = 65_536
                return try await client.exchange(LocalPacket(message: asset))
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await gate.hasEntered) {
                guard ContinuousClock.now < deadline else { XCTFail("Catalog read did not start"); throw LocalCatalogError.timeout }
                await Task.yield()
            }
            switch mode {
            case "revoke": try await server.revoke(deviceID)
            case "stop": await server.stop()
            default: client.cancel()
            }
            let count = await server.sessionCount
            XCTAssertEqual(count, 1, "Read was finalized before draining")
            await gate.release()
            _ = await request.result
            try await waitForSessionCount(0, server: server)
            for body in ["SECOND", "THIRD", "FOURTH"] {
                try Data(body.utf8).write(to: root.appendingPathComponent("shaders/plasma/body.metal"))
                _ = try await store.reload(from: root)
            }
            do {
                _ = try await store.get(.asset(revision: first.publicationRevision, path: "sources/plasma.metal"), limit: 1_048_576)
                XCTFail("Late catalog read recreated an orphaned lease")
            } catch CatalogError.invalidResponse {}
        }
    }
}
#endif
