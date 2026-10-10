import XCTest
import Clocks
import CoreGraphics
@testable import HolodeckCore

final class PreviewRecoveryTests: XCTestCase {
    func testRetryWaitUsesCooldownAndCancellationAndRejectsPermanentFailures() async throws {
        let box = CatalogTestBox()
        let service = CatalogService(network: box.network, storage: .disabled, clock: box.clock)
        let preview = TestCatalog.shaders[0].preview!
        do { _ = try await service.preview(preview); XCTFail() } catch {}
        let waiting = Task { try await service.waitForPreviewRetry(preview) }
        try await waitForRetrySleeper(in: service)
        await box.clock.advance(by: .seconds(29))
        let sleepers = await service.previewRetryWaiterCount
        XCTAssertEqual(sleepers, 1)
        do { _ = try await service.preview(preview); XCTFail() } catch {}
        XCTAssertEqual(box.urls.count, 1)
        await box.clock.advance(by: .seconds(1))
        let retry = try await waiting.value
        XCTAssertTrue(retry)
        do { _ = try await service.preview(preview); XCTFail() } catch {}
        XCTAssertEqual(box.urls.count, 2)
        let cancelled = Task { try await service.waitForPreviewRetry(preview) }
        try await waitForRetrySleeper(in: service)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail() } catch is CancellationError {} catch { XCTFail("\(error)") }
        await box.clock.advance(by: .seconds(60))
        box.setResponses(["/previews/plasma.png": Data("invalid".utf8)])
        do { _ = try await service.preview(preview); XCTFail() } catch {}
        let permanent = try await service.waitForPreviewRetry(preview)
        XCTAssertFalse(permanent)
        let revised = ShaderPreview(path: preview.path, hash: preview.hash, publicationRevision: String(repeating: "c", count: 40))
        let fresh = try await service.waitForPreviewRetry(revised)
        XCTAssertTrue(fresh)
    }

    private func waitForRetrySleeper(in service: CatalogService) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while await service.previewRetryWaiterCount != 1 {
            guard ContinuousClock.now < deadline else { XCTFail("Retry did not enter cooldown"); throw CatalogError.invalidResponse }
            await Task.yield()
        }
    }

    func testTransientCooldownBackoffAndSuccessReset() async throws {
        let box = CatalogTestBox()
        let service = CatalogService(network: box.network, storage: .disabled, clock: box.clock)
        let preview = TestCatalog.shaders[0].preview!
        for (attempt, delay) in [30, 60, 120, 240, 300, 300].enumerated() {
            do { _ = try await service.preview(preview); XCTFail("Offline request must fail") } catch {}
            XCTAssertEqual(box.urls.count, attempt + 1)
            await box.clock.advance(by: .seconds(delay - 1))
            do { _ = try await service.preview(preview); XCTFail("Cooldown must fail") } catch {}
            XCTAssertEqual(box.urls.count, attempt + 1)
            await box.clock.advance(by: .seconds(1))
        }
        box.setResponses(["/previews/plasma.png": try TestCatalog.preview(named: "preview-\(preview.hash).png")])
        _ = try await service.preview(preview)
        XCTAssertEqual(box.urls.count, 7)
        let failures = await service.previewFailureCount
        XCTAssertEqual(failures, 0)
        await service.trimPreviewCaches()
        box.setResponses([:])
        do { _ = try await service.preview(preview) } catch {}
        await box.clock.advance(by: .seconds(30))
        do { _ = try await service.preview(preview) } catch {}
        XCTAssertEqual(box.urls.count, 9, "Success resets the next cooldown to 30 seconds")
    }

    func testValidationAndDecodeFailuresWaitForNewPublicationAndAreBounded() async throws {
        let box = CatalogTestBox()
        let service = CatalogService(network: box.network, storage: .disabled, clock: box.clock)
        let preview = TestCatalog.shaders[0].preview!
        box.setResponses(["/previews/plasma.png": Data("invalid".utf8)])
        do { _ = try await service.previewImage(preview, maxPixelSize: 64); XCTFail() } catch {}
        await box.clock.advance(by: .seconds(3600))
        do { _ = try await service.previewImage(preview, maxPixelSize: 128); XCTFail() } catch {}
        XCTAssertEqual(box.urls.count, 1)
        let revised = ShaderPreview(path: preview.path, hash: preview.hash, publicationRevision: String(repeating: "c", count: 40))
        box.setResponses(["/previews/plasma.png": try TestCatalog.preview(named: "preview-\(preview.hash).png")])
        _ = try await service.previewImage(revised, maxPixelSize: 64)
        _ = try await service.previewImage(preview, maxPixelSize: 64)
        XCTAssertEqual(box.urls.count, 2, "Positive images remain reusable across publications")
        let badPNG = Data([137, 80, 78, 71, 13, 10, 26, 10, 0])
        box.setResponses(["/previews/bad.png": badPNG])
        let bad = ShaderPreview(path: "previews/bad.png", hash: CatalogHash.sha256(badPNG), publicationRevision: revised.publicationRevision)
        do { _ = try await service.previewImage(bad, maxPixelSize: 64); XCTFail() } catch {}
        await service.trimPreviewCaches()
        do { _ = try await service.previewImage(bad, maxPixelSize: 128); XCTFail() } catch {}
        XCTAssertEqual(box.urls.count, 3, "Pressure trimming retains decode failure suppression")
        for number in 0..<501 {
            let unique = ShaderPreview(path: "previews/bad-\(number).png", hash: bad.hash, publicationRevision: revised.publicationRevision)
            do { _ = try await service.preview(unique) } catch {}
        }
        let count = await service.previewFailureCount
        XCTAssertEqual(count, 500)
    }

    func testCanceledNetworkFailureCreatesNoRetryRecord() async throws {
        for urlCancellation in [false, true] {
            let counter = CancellationCounter()
            let service = CatalogService(network: CatalogNetwork { _, _ in
                await counter.record()
                if urlCancellation { throw URLError(.cancelled) }
                throw CancellationError()
            }, storage: .disabled)
            for _ in 0..<2 { do { _ = try await service.preview(TestCatalog.shaders[0].preview!) } catch {} }
            let count = await counter.count
            let failures = await service.previewFailureCount
            XCTAssertEqual(count, 2)
            XCTAssertEqual(failures, 0)
            let canceled = Task { try await service.preview(TestCatalog.shaders[1].preview!) }
            canceled.cancel()
            do { _ = try await canceled.value; XCTFail() } catch is CancellationError {} catch { XCTFail("\(error)") }
        }
    }

    func testAspectFillAtOneAndTwoTimesIncludingFocusMargin() async throws {
        let service = CatalogService.offline(storage: TestCatalog.storage)
        let preview = TestCatalog.shaders[0].preview!
        for scale in [1.0, 2.0] {
            let target = CGSize(width: 320 * scale * 1.045, height: 232 * scale * 1.045)
            let image = try await service.previewImage(preview, targetPixelSize: target)
            XCTAssertGreaterThanOrEqual(image.width, Int(ceil(target.width)))
            XCTAssertGreaterThanOrEqual(image.height, Int(ceil(target.height)))
            XCTAssertEqual(image.width % 64, 0)
            XCTAssertLessThanOrEqual(max(image.width, image.height), 2048)
        }
        let capped = try await service.previewImage(preview, targetPixelSize: CGSize(width: 4096, height: 4096))
        XCTAssertLessThanOrEqual(max(capped.width, capped.height), 2048)
    }

    func testDestinationBucketsReuseDecodedImagesAndRejectInvalidSizes() async throws {
        let service = CatalogService.offline(storage: TestCatalog.storage)
        let preview = TestCatalog.shaders[0].preview!
        let first = try await service.previewImage(preview, targetPixelSize: CGSize(width: 320.1, height: 232))
        let equivalent = try await service.previewImage(preview, targetPixelSize: CGSize(width: 320.9, height: 232.9))
        XCTAssertTrue(first === equivalent)
        for invalid in [CGSize.zero, CGSize(width: -1, height: 1), CGSize(width: CGFloat.infinity, height: 1), CGSize(width: 1, height: CGFloat.nan)] {
            do { _ = try await service.previewImage(preview, targetPixelSize: invalid); XCTFail("Invalid size must fail") } catch {}
        }
    }

    func testDecoderIsBoundedResponsiveAndTrimDoesNotRepopulateCaches() async throws {
        let box = CatalogTestBox()
        let preview = TestCatalog.shaders[0].preview!
        try box.storage.write("snapshot.json", TestCatalog.data)
        try box.storage.write("preview-\(preview.hash).png", TestCatalog.preview(named: "preview-\(preview.hash).png"))
        let service = CatalogService.offline(storage: box.storage)
        let gate = DecodeGate(started: expectation(description: "Two decodes running"))
        gate.started.expectedFulfillmentCount = 2
        await service.setBeforePreviewDecode { gate.enter() }
        let tasks = [640, 704, 768].map { size in Task { try await service.previewImage(preview, maxPixelSize: size) } }
        await fulfillment(of: [gate.started], timeout: 5)
        let responsive = expectation(description: "Catalog actor remains responsive during decoding")
        let catalogTask = Task {
            let catalog = await service.current()
            XCTAssertEqual(catalog?.shaders.count, 8)
            await service.trimPreviewCaches()
            responsive.fulfill()
        }
        await fulfillment(of: [responsive], timeout: 2)
        XCTAssertEqual(gate.count, 2)
        gate.releaseAll()
        await catalogTask.value
        for task in tasks { _ = try await task.value }
        XCTAssertEqual(gate.maximum, 2)
        let costs = await service.previewCacheCosts
        XCTAssertEqual(costs.encoded, 0)
        XCTAssertEqual(costs.decoded, 0)
        await service.setBeforePreviewDecode(nil)
        let reloaded = try await service.previewImage(preview, maxPixelSize: 640)
        let populated = await service.previewCacheCosts
        XCTAssertGreaterThan(populated.encoded, 0)
        XCTAssertGreaterThan(populated.decoded, 0)
        XCTAssertLessThanOrEqual(populated.encoded, 16_777_216)
        XCTAssertLessThanOrEqual(populated.decoded, 33_554_432)
        XCTAssertEqual(reloaded.width, 640)
        XCTAssertEqual(box.storageReads.filter { $0.hasPrefix("preview-") }.count, 2)
    }

    func testTrimDuringDownloadServesCallerWithoutCaching() async throws {
        let gate = PreviewRequestGate()
        let preview = TestCatalog.shaders[0].preview!
        let service = CatalogService(network: CatalogNetwork { url, _ in await gate.image(url.lastPathComponent) }, storage: .disabled)
        let task = Task { try await service.previewImage(preview, maxPixelSize: 640) }
        await gate.waitForRequest("plasma.png")
        await service.trimPreviewCaches()
        await gate.complete("plasma.png", data: try TestCatalog.preview(named: "preview-\(preview.hash).png"))
        _ = try await task.value
        let costs = await service.previewCacheCosts
        XCTAssertEqual(costs.encoded, 0)
        XCTAssertEqual(costs.decoded, 0)
    }
}

private actor CancellationCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

nonisolated private final class DecodeGate: @unchecked Sendable {
    let started: XCTestExpectation
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = 0
    private var active = 0
    private var peak = 0
    var count: Int { lock.withLock { entered } }
    var maximum: Int { lock.withLock { peak } }
    init(started: XCTestExpectation) { self.started = started }
    func enter() {
        let firstTwo = lock.withLock {
            entered += 1; active += 1; peak = max(peak, active)
            return entered <= 2
        }
        if firstTwo { started.fulfill() }
        semaphore.wait()
        lock.withLock { active -= 1 }
    }
    func releaseAll() { for _ in 0..<3 { semaphore.signal() } }
}
