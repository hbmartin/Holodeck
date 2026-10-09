import XCTest
@testable import HolodeckCore

@MainActor
final class ViewerSessionTests: XCTestCase {
    private func session(_ policy: ViewerPolicy = .mac, saved: String? = "aurora") -> (ViewerSession, FakeRenderer, PreferenceRecorder) {
        let recorder = PreferenceRecorder(saved)
        let session = ViewerSession(catalogService: CatalogService(storage: TestCatalog.storage, enabled: false),
                                    preferences: recorder.preferences, policy: policy)
        let renderer = FakeRenderer()
        session.attach(renderer)
        return (session, renderer, recorder)
    }
    private func settled(_ session: ViewerSession) async {
        await session.selectionTask?.value
        await session.refreshTask?.value
    }
    private func changed(_ id: String = "plasma", metadataOnly: Bool = false) -> CatalogSnapshot {
        var snapshot = TestCatalog.snapshot
        snapshot.publicationRevision = String(repeating: "c", count: 40)
        let index = snapshot.manifest.shaders.firstIndex { $0.id == id }!
        snapshot.manifest.shaders[index].name = "Updated Scene"
        if !metadataOnly {
            snapshot.sources[id]! += "\n// updated source\n"
            snapshot.manifest.shaders[index].sourceSHA256 = CatalogHash.sha256(Data(snapshot.sources[id]!.utf8))
        }
        return snapshot
    }

    func testMacStartsDefaultAndDoesNotPersistSelectionWhileTVRestoresAndPersists() async {
        let (mac, macRenderer, macPrefs) = session()
        await settled(mac)
        XCTAssertEqual(mac.activeShader?.id, "plasma")
        XCTAssertEqual(macRenderer.activations, ["plasma"])
        await mac.select(TestCatalog.shaders[2]).value
        XCTAssertEqual(macPrefs.id, "aurora")
        XCTAssertEqual(macPrefs.writes, 0)
        let (tv, _, tvPrefs) = session(.tv)
        await settled(tv)
        XCTAssertEqual(tv.activeShader?.id, "aurora")
        await tv.select(TestCatalog.shaders[2]).value
        XCTAssertEqual(tvPrefs.id, "waves")
        XCTAssertEqual(tvPrefs.writes, 2)
    }

    func testLatestUserSelectionWinsAndCanceledSelectionDoesNotSave() async {
        let (session, renderer, prefs) = session(.tv, saved: nil)
        await settled(session)
        renderer.held = true
        let old = session.select(TestCatalog.shaders[1])
        await renderer.waitForRequest("aurora")
        let newest = session.select(TestCatalog.shaders[2])
        await renderer.waitForRequest("waves")
        renderer.finish("waves")
        await newest.value
        renderer.finish("aurora", failing: true)
        await old.value
        XCTAssertEqual(session.activeShader?.id, "waves")
        XCTAssertNil(session.failure)
        XCTAssertEqual(prefs.id, "waves")
        let canceled = session.select(TestCatalog.shaders[3])
        await renderer.waitForRequest("kaleidoscope")
        session.cancelPendingSelection()
        renderer.finish("kaleidoscope")
        await canceled.value
        XCTAssertEqual(session.activeShader?.id, "waves")
        XCTAssertEqual(prefs.writes, 2)
    }

    func testCancelBeforeTaskStartsDoesNotActivate() async {
        let (session, renderer, _) = session()
        await settled(session)
        let task = session.select(TestCatalog.shaders[1])
        session.cancelPendingSelection()
        await task.value
        XCTAssertEqual(renderer.activations, ["plasma"])
        XCTAssertNil(session.pendingSelection)
    }

    func testChangedSourceActivatesImmediatelyAndMetadataDoesNotRestart() async {
        let (mac, renderer, _) = session()
        await settled(mac)
        var metadata = changed(metadataOnly: true)
        let discovery = SceneDiscovery(tags: ["fluid"], moods: ["energetic"], motion: "steady")
        metadata.manifest.shaders[0].discovery = discovery
        metadata.manifest.collections = [CatalogCollection(id: "featured", name: "Featured", description: "Selected scenes.", shaderIDs: ["plasma"])]
        mac.applyCatalog(metadata)
        XCTAssertEqual(mac.activeShader?.title, "Updated Scene")
        XCTAssertEqual(mac.activeShader?.discovery, discovery)
        XCTAssertEqual(renderer.activations.count, 1)
        var revised = changed()
        revised.publicationRevision = String(repeating: "d", count: 40)
        mac.applyCatalog(revised)
        await settled(mac)
        XCTAssertEqual(renderer.activations.count, 2)
        XCTAssertEqual(mac.activeShader?.sourceHash, revised.shaders[0].sourceHash)
        let (tv, tvRenderer, _) = session(.tv, saved: nil)
        await settled(tv)
        tv.applyCatalog(revised)
        await settled(tv)
        XCTAssertEqual(tvRenderer.activations.count, 1)
        XCTAssertEqual(tv.activeShader?.title, "Plasma")
    }

    func testUserSelectionSupersedesAutomaticReplacement() async {
        let (session, renderer, _) = session()
        await settled(session)
        renderer.held = true
        session.applyCatalog(changed())
        let update = session.selectionTask!
        await renderer.waitForRequest("plasma")
        let user = session.select(TestCatalog.shaders[1])
        await renderer.waitForRequest("aurora")
        renderer.finish("aurora")
        await user.value
        renderer.finish("plasma")
        await update.value
        XCTAssertEqual(session.activeShader?.id, "aurora")
    }

    func testFailedReplacementRetainsPlaybackAndRetryRecovers() async throws {
        let (session, renderer, _) = session()
        await settled(session)
        renderer.failNext = true
        session.applyCatalog(changed())
        await settled(session)
        XCTAssertEqual(session.activeShader?.title, "Plasma")
        let failure = try XCTUnwrap(session.failure)
        session.retry(failure)
        await settled(session)
        XCTAssertEqual(session.activeShader?.title, "Updated Scene")
        XCTAssertNil(session.failure)
    }

    func testRemovedActiveSceneKeepsPlayingAndFilteringNeverSelects() async {
        let (session, renderer, _) = session()
        await settled(session)
        var snapshot = changed()
        snapshot.manifest.shaders.removeAll { $0.id == "plasma" }
        snapshot.manifest.defaultShaderID = "aurora"
        snapshot.sources.removeValue(forKey: "plasma")
        session.applyCatalog(snapshot)
        XCTAssertEqual(session.activeShader?.id, "plasma")
        XCTAssertEqual(renderer.activations.count, 1)
        XCTAssertTrue(SceneLibrary.filter(session.shaders, query: "no such scene", favoritesOnly: false, favorites: []).isEmpty)
        XCTAssertEqual(session.activeShader?.id, "plasma")
    }

    func testFirstActivationDoesNotRetryFailedInitialDownload() async {
        let counter = NetworkCounter()
        let service = CatalogService(network: CatalogNetwork { _, _ in
            await counter.record()
            throw CatalogError.invalidResponse
        }, storage: .disabled)
        let session = ViewerSession(catalogService: service, preferences: .inMemory(), policy: .tv)
        session.attach(FakeRenderer())
        await settled(session)
        let firstFailure = session.failure?.id
        session.setActive(true)
        await settled(session)
        let initialRequests = await counter.count
        XCTAssertEqual(initialRequests, 1)
        XCTAssertEqual(session.failure?.id, firstFailure)
        session.setActive(false)
        session.setActive(true)
        await settled(session)
        let resumedRequests = await counter.count
        XCTAssertEqual(resumedRequests, 2)
    }

    func testActivityPausesRendererAndOfflineFailurePreservesCatalog() async {
        let (session, renderer, _) = session()
        await settled(session)
        session.setActive(true)
        XCTAssertTrue(renderer.isActive)
        session.setActive(false)
        XCTAssertFalse(renderer.isActive)
        let failing = ViewerSession(catalogService: CatalogService(network: CatalogNetwork { _, _ in throw CatalogError.invalidResponse }, storage: TestCatalog.storage),
                                    preferences: .inMemory(), policy: .mac)
        let working = FakeRenderer()
        failing.attach(working)
        await settled(failing)
        XCTAssertEqual(failing.shaders.count, 8)
        XCTAssertEqual(failing.activeShader?.id, "plasma")
        XCTAssertNotNil(failing.failure)
    }
}

@MainActor
private final class PreferenceRecorder {
    var id: String?
    var writes = 0
    init(_ id: String?) { self.id = id }
    var preferences: ShaderPreferences {
        ShaderPreferences(lastShaderID: { self.id }, setLastShaderID: { self.id = $0; self.writes += 1 })
    }
}

@MainActor
private final class FakeRenderer: SceneRendering {
    var activeShader: ShaderDefinition?
    var activations: [String] = []
    var held = false
    var failNext = false
    var isActive = false
    private var generation = 0
    private var pending: [String: CheckedContinuation<Void, Error>] = [:]
    private var observers: [String: CheckedContinuation<Void, Never>] = [:]
    func select(_ shader: ShaderDefinition) async throws -> Bool {
        let request = generation
        if held {
            try await withCheckedThrowingContinuation { continuation in
                pending[shader.id] = continuation
                observers.removeValue(forKey: shader.id)?.resume()
            }
        }
        if failNext { failNext = false; throw CatalogError.invalidSource }
        guard request == generation else { return false }
        activeShader = shader
        activations.append(shader.id)
        return true
    }
    func cancelPendingSelection() { generation += 1 }
    func setActive(_ active: Bool) { isActive = active }
    func waitForRequest(_ id: String) async {
        if pending[id] != nil { return }
        await withCheckedContinuation { observers[id] = $0 }
    }
    func finish(_ id: String, failing: Bool = false) {
        let continuation = pending.removeValue(forKey: id)
        if failing { continuation?.resume(throwing: CatalogError.invalidSource) } else { continuation?.resume() }
    }
}

private actor NetworkCounter {
    private(set) var count = 0
    func record() { count += 1 }
}
