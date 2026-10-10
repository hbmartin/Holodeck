import XCTest
@testable import HolodeckCore

@MainActor
final class ViewerSessionTests: XCTestCase {
    private func session(_ policy: ViewerPolicy = .mac, saved: String? = "aurora") -> (ViewerSession, FakeRenderer, PreferenceRecorder) {
        let recorder = PreferenceRecorder(saved)
        let session = ViewerSession(catalogService: CatalogService.offline(initialCatalog: TestCatalog.catalog, storage: TestCatalog.storage),
                                    preferences: recorder.preferences, policy: policy)
        let renderer = FakeRenderer()
        session.attach(renderer)
        return (session, renderer, recorder)
    }
    private func settled(_ session: ViewerSession) async {
        await session.refreshTask?.value
        await session.selectionTask?.value
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

    func testDismissedRecoveryErrorNeverReturnsAndSuccessfulSelectionClearsPreviousError() async throws {
        let (session, renderer, _) = session()
        renderer.failNext = true
        await settled(session)
        let startup = try XCTUnwrap(session.failure)
        session.dismissFailure(id: startup.id)
        await session.refresh().value
        XCTAssertNil(session.selectionFailure)
        XCTAssertTrue(session.requiresExplicitSelection)
        renderer.held = true
        let pending = session.select(TestCatalog.shaders[1])
        await renderer.waitForRequest("aurora")
        session.cancelPendingSelection(resumeStartup: true)
        renderer.finish("aurora")
        await pending.value
        XCTAssertNil(session.failure)
        renderer.held = false
        renderer.failNext = true
        await session.select(TestCatalog.shaders[1]).value
        let previous = try XCTUnwrap(session.failure)
        renderer.held = true
        let canceled = session.select(TestCatalog.shaders[2])
        XCTAssertNil(session.failure)
        await renderer.waitForRequest("waves")
        session.cancelPendingSelection()
        XCTAssertEqual(session.failure?.id, previous.id)
        renderer.finish("waves")
        await canceled.value
        renderer.held = false
        await session.select(TestCatalog.shaders[2]).value
        XCTAssertNil(session.selectionFailure)
        session.retry(previous)
        XCTAssertEqual(session.activeShader?.id, "waves")
        XCTAssertNil(session.pendingSelection)
    }

    func testLazyCacheRefreshWithoutRendererJoinsOnAttachmentAndNeverSignalsEmptyCache() async throws {
        let gate = PreviewRequestGate()
        let service = CatalogService(network: CatalogNetwork { _, _ in await gate.image("published") }, storage: TestCatalog.storage)
        let session = ViewerSession(catalogService: service, preferences: .inMemory(), policy: .mac)
        var checkedWithCache = false
        session.onEvent = { event in
            if case .catalogCacheChecked = event { checkedWithCache = session.hasCheckedCache && !session.shaders.isEmpty }
        }
        XCTAssertFalse(session.hasCheckedCache)
        let refresh = session.refresh()
        await gate.waitForRequest("published")
        XCTAssertEqual(session.shaders.count, 8)
        XCTAssertTrue(checkedWithCache)
        XCTAssertNil(session.activeShader)
        session.attach(FakeRenderer())
        await session.selectionTask?.value
        XCTAssertEqual(session.activeShader?.id, "plasma")
        let requests = await gate.requestCount
        XCTAssertEqual(requests, 1)
        await gate.complete("published", data: Data())
        await refresh.value
        session.onEvent = nil
    }

    func testRecoveryCatalogFailureKeepsBothOperationsAndRetriesDownload() async throws {
        let counter = NetworkCounter()
        let service = CatalogService(initialCatalog: TestCatalog.catalog, network: CatalogNetwork { _, _ in
            await counter.record(); throw CatalogError.invalidResponse
        }, storage: .disabled)
        let session = ViewerSession(catalogService: service, preferences: .inMemory(), policy: .mac)
        let renderer = FakeRenderer()
        renderer.failNext = true
        session.attach(renderer)
        await settled(session)
        let selection = try XCTUnwrap(session.selectionFailure)
        let download = try XCTUnwrap(session.catalogUpdateFailure)
        session.dismissFailure(id: selection.id)
        session.retry(download)
        await settled(session)
        XCTAssertNil(session.failure)
        XCTAssertEqual(renderer.selections.count, 1)
        let requests = await counter.count
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(session.requiresExplicitSelection)
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
        mac.applyCatalog(try! metadata.validated())
        XCTAssertEqual(mac.activeShader?.title, "Updated Scene")
        XCTAssertEqual(mac.activeShader?.discovery, discovery)
        XCTAssertEqual(renderer.activations.count, 1)
        var revised = changed()
        revised.publicationRevision = String(repeating: "d", count: 40)
        mac.applyCatalog(try! revised.validated())
        await settled(mac)
        XCTAssertEqual(renderer.activations.count, 2)
        XCTAssertEqual(mac.activeShader?.sourceHash, try! revised.validated().shaders[0].sourceHash)
        let (tv, tvRenderer, _) = session(.tv, saved: nil)
        await settled(tv)
        tv.applyCatalog(try! revised.validated())
        await settled(tv)
        XCTAssertEqual(tvRenderer.activations.count, 1)
        XCTAssertEqual(tv.activeShader?.title, "Plasma")
    }

    func testUserSelectionSupersedesAutomaticReplacement() async {
        let (session, renderer, _) = session()
        await settled(session)
        renderer.held = true
        session.applyCatalog(try! changed().validated())
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
        session.applyCatalog(try! changed().validated())
        await settled(session)
        XCTAssertEqual(session.activeShader?.title, "Plasma")
        let failure = try XCTUnwrap(session.failure)
        session.retry(failure)
        await settled(session)
        XCTAssertEqual(session.activeShader?.title, "Updated Scene")
        XCTAssertNil(session.failure)
    }

    func testSuccessfulAutomaticReplacementClearsOnlyItsOwnFailure() async throws {
        let (session, renderer, _) = session()
        await settled(session)
        renderer.failNext = true
        session.applyCatalog(try changed().validated())
        await settled(session)
        XCTAssertNotNil(session.selectionFailure)
        var newer = changed()
        newer.publicationRevision = String(repeating: "e", count: 40)
        session.applyCatalog(try newer.validated())
        await settled(session)
        XCTAssertNil(session.selectionFailure)
        XCTAssertEqual(session.activeShader?.title, "Updated Scene")
    }

    func testRemovedActiveSceneKeepsPlayingAndFilteringNeverSelects() async {
        let (session, renderer, _) = session()
        await settled(session)
        var snapshot = changed()
        snapshot.manifest.shaders.removeAll { $0.id == "plasma" }
        snapshot.manifest.defaultShaderID = "aurora"
        snapshot.sources.removeValue(forKey: "plasma")
        session.applyCatalog(try! snapshot.validated())
        XCTAssertEqual(session.activeShader?.id, "plasma")
        XCTAssertEqual(renderer.activations.count, 1)
        XCTAssertTrue(SceneLibrary.filter(session.shaders, query: "no such scene", favoritesOnly: false, favorites: []).isEmpty)
        XCTAssertEqual(session.activeShader?.id, "plasma")
    }

    func testFailedStartupRequiresExplicitRecoveryAcrossRefreshAndCancellation() async throws {
        let (session, renderer, prefs) = session(.tv)
        renderer.failNext = true
        await settled(session)
        XCTAssertNil(session.activeShader)
        XCTAssertTrue(session.requiresExplicitSelection)
        let failure = try XCTUnwrap(session.failure)
        session.applyCatalog(try changed("aurora").validated())
        XCTAssertEqual(session.failure?.id, failure.id)
        XCTAssertTrue(session.requiresExplicitSelection)
        XCTAssertEqual(session.startupShader?.title, "Updated Scene")
        renderer.held = true
        let selection = session.select(TestCatalog.shaders[2])
        await renderer.waitForRequest("waves")
        session.cancelPendingSelection(resumeStartup: true)
        renderer.finish("waves")
        await selection.value
        XCTAssertNil(session.pendingSelection)
        XCTAssertNil(session.activeShader)
        XCTAssertEqual(renderer.selections.count, 2, "Back must not retry the failed startup")
        XCTAssertEqual(prefs.id, "aurora")
        XCTAssertEqual(prefs.writes, 0)
        renderer.held = false
        await session.select(TestCatalog.shaders[2]).value
        XCTAssertFalse(session.requiresExplicitSelection)
        XCTAssertEqual(prefs.id, "waves")
    }

    func testRemovedStartupResumesLatestDefaultAfterUserCancellation() async throws {
        let (session, renderer, _) = session(.tv)
        renderer.held = true
        await renderer.waitForRequest("aurora")
        await session.refreshTask?.value
        let initial = session.selectionTask!
        var latest = changed()
        latest.manifest.shaders.removeAll { $0.id == "aurora" }
        latest.sources.removeValue(forKey: "aurora")
        session.applyCatalog(try latest.validated())
        let user = session.select(TestCatalog.shaders[2])
        await renderer.waitForRequest("waves")
        session.cancelPendingSelection(resumeStartup: true)
        await renderer.waitForRequest("plasma")
        XCTAssertEqual(renderer.selections.last?.source, latest.sources["plasma"])
        renderer.finish("aurora")
        renderer.finish("waves")
        renderer.finish("plasma")
        await initial.value
        await user.value
        await settled(session)
        XCTAssertEqual(session.activeShader?.source, latest.sources["plasma"])
    }

    func testExplicitStartupRetryUsesLatestDefinitionAndSavesOnlyOnSuccess() async throws {
        let (session, renderer, prefs) = session(.tv)
        renderer.failNext = true
        await settled(session)
        let failure = try XCTUnwrap(session.failure)
        let latest = changed("aurora")
        session.applyCatalog(try latest.validated())
        XCTAssertEqual(prefs.writes, 0)
        session.retry(failure)
        await settled(session)
        XCTAssertEqual(session.activeShader?.source, latest.sources["aurora"])
        XCTAssertNil(session.failure)
        XCTAssertFalse(session.requiresExplicitSelection)
        XCTAssertEqual(prefs.id, "aurora")
        XCTAssertEqual(prefs.writes, 1)
    }

    func testNewSessionReconcilesSharedCatalogAfterUnchangedThrottledAndFailedChecks() async throws {
        let latest = changed()
        let box = CatalogTestBox()
        try box.storage.write("snapshot.json", TestCatalog.data)
        var responses = ["/git/ref/heads/published": Data("{\"object\":{\"sha\":\"\(latest.publicationRevision)\"}}".utf8),
                         "/catalog.json": try JSONEncoder().encode(latest.manifest)]
        for entry in latest.manifest.shaders { responses["/\(entry.sourcePath)"] = Data(latest.sources[entry.id]!.utf8) }
        box.setResponses(responses)
        let service = CatalogService(network: box.network, storage: box.storage, clock: box.clock)
        _ = try await service.refresh()
        for scenario in 0..<3 {
            if scenario > 0 { await box.clock.advance(by: .seconds(900)) }
            if scenario == 2 { box.setResponses([:]) }
            let session = ViewerSession(catalogService: service, preferences: .inMemory(), policy: .tv)
            session.attach(FakeRenderer())
            await settled(session)
            XCTAssertEqual(session.catalog?.publicationRevision, latest.publicationRevision)
            XCTAssertEqual(session.activeShader?.title, "Updated Scene")
            if scenario == 2 { XCTAssertNotNil(session.catalogUpdateFailure); XCTAssertNil(session.failure) }
        }
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

    func testCachedStartupActivatesBeforeTheNetworkRefreshCompletes() async {
        let gate = PreviewRequestGate()
        let service = CatalogService(network: CatalogNetwork { _, _ in await gate.image("published") }, storage: TestCatalog.storage)
        let session = ViewerSession(catalogService: service, preferences: .inMemory(), policy: .tv)
        session.attach(FakeRenderer())
        await gate.waitForRequest("published")
        await session.selectionTask?.value
        XCTAssertEqual(session.activeShader?.id, "plasma")
        XCTAssertTrue(session.isRefreshing)
        await gate.complete("published", data: Data("{\"object\":{\"sha\":\"\(TestCatalog.catalog.publicationRevision)\"}}".utf8))
        await settled(session)
        XCTAssertFalse(session.isRefreshing)
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
        XCTAssertNil(failing.failure)
        XCTAssertNotNil(failing.catalogUpdateFailure)
    }

    func testSelectionWithoutRendererHasNoSideEffects() async {
        let session = ViewerSession(catalogService: .offline(initialCatalog: TestCatalog.catalog), preferences: .inMemory(), policy: .mac)
        let failure = ViewerSession.Failure(message: "Existing error", operation: .catalog)
        session.failure = failure
        var events = 0
        session.onEvent = { _ in events += 1 }
        await session.select(TestCatalog.initialShader).value
        XCTAssertNil(session.pendingSelection)
        XCTAssertNil(session.selectionTask)
        XCTAssertEqual(session.catalogUpdateFailure?.id, failure.id)
        XCTAssertEqual(events, 0)
        let renderer = FakeRenderer()
        session.attach(renderer)
        await settled(session)
        XCTAssertEqual(session.activeShader?.id, "plasma")
    }

    func testUserFailureSurvivesRefreshAndAutomaticSourceReplacement() async throws {
        for automaticFailure in [false, true] {
            let (session, renderer, _) = session()
            await settled(session)
            renderer.failNext = true
            await session.select(TestCatalog.shaders[1]).value
            let failure = try XCTUnwrap(session.failure)
            await session.refresh().value
            XCTAssertEqual(session.failure?.id, failure.id)
            renderer.failNext = automaticFailure
            session.applyCatalog(try changed().validated())
            await settled(session)
            XCTAssertEqual(session.failure?.id, failure.id)
            XCTAssertNil(session.pendingSelection)
            XCTAssertNotNil(session.activeShader)
        }
    }

    func testStaleDismissalAndRetryDoNotReplaceNewFailure() async throws {
        let (session, renderer, _) = session()
        await settled(session)
        renderer.failNext = true
        await session.select(TestCatalog.shaders[1]).value
        let old = try XCTUnwrap(session.failure)
        renderer.failNext = true
        await session.select(TestCatalog.shaders[2]).value
        let current = try XCTUnwrap(session.failure)
        session.dismissFailure(id: old.id)
        session.retry(old)
        XCTAssertEqual(session.failure?.id, current.id)
        XCTAssertNil(session.pendingSelection)
        session.dismissFailure(id: current.id)
        XCTAssertNil(session.failure)
    }

    func testRepeatedSelectionFailuresHaveDistinctAttemptIdentities() async throws {
        let (session, renderer, _) = session()
        await settled(session)
        renderer.failNext = true
        await session.select(TestCatalog.shaders[1]).value
        let first = try XCTUnwrap(session.selectionFailure)
        renderer.failNext = true
        await session.select(TestCatalog.shaders[1]).value
        let second = try XCTUnwrap(session.selectionFailure)
        XCTAssertEqual(second.message, first.message)
        XCTAssertNotEqual(second.id, first.id)
        session.dismissFailure(id: first.id)
        session.retry(first)
        XCTAssertEqual(session.selectionFailure?.id, second.id)
        XCTAssertNil(session.pendingSelection)
    }

    func testCachedUpdateRetryPreservesSelectionFailureAndClearsNotice() async throws {
        let box = CatalogTestBox()
        let service = CatalogService(initialCatalog: TestCatalog.catalog, network: box.network, storage: .disabled)
        let session = ViewerSession(catalogService: service, preferences: .inMemory(), policy: .mac)
        let renderer = FakeRenderer()
        session.attach(renderer)
        await settled(session)
        XCTAssertNil(session.failure)
        let notice = try XCTUnwrap(session.catalogUpdateFailure)
        renderer.failNext = true
        await session.select(TestCatalog.shaders[1]).value
        let failure = try XCTUnwrap(session.failure)
        box.setResponses(["/git/ref/heads/published": Data("{\"object\":{\"sha\":\"\(TestCatalog.catalog.publicationRevision)\"}}".utf8)])
        session.retry(notice)
        await settled(session)
        XCTAssertNil(session.catalogUpdateFailure)
        XCTAssertEqual(session.failure?.id, failure.id)
        XCTAssertEqual(session.activeShader?.id, "plasma")
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
    var selections: [ShaderDefinition] = []
    var held = false
    var failNext = false
    var isActive = false
    private var generation = 0
    private var pending: [String: CheckedContinuation<Void, Error>] = [:]
    private var observers: [String: CheckedContinuation<Void, Never>] = [:]
    func select(_ shader: ShaderDefinition) async throws -> Bool {
        selections.append(shader)
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
