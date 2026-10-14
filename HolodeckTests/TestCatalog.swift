import Foundation
@testable import Holodeck
@testable import HolodeckCore

/// Recorded repository content belongs to test bundles only, never Holodeck.app.
nonisolated enum TestCatalog {
    static let data: Data = {
        let url = Bundle(for: HolodeckTests.self).url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport")!
        return try! Data(contentsOf: url)
    }()
    static let snapshot: CatalogSnapshot = {
        let value = try! JSONDecoder().decode(CatalogSnapshot.self, from: data)
        return value
    }()
    static let catalog = try! snapshot.validated()
    static let localCatalog: ValidatedCatalog = {
        let bytes = try! CatalogPublication.encodedManifest(snapshot.manifest), revision = CatalogHash.sha256(bytes)
        return try! CatalogPublication.finish(CatalogPublication.builder(bytes, revision: revision, kind: .localPublication),
            sources: snapshot.sources.mapValues { Data($0.utf8) }, revision: revision)
    }()
    static var shaders: [ShaderDefinition] { catalog.shaders }
    static var initialShader: ShaderDefinition { catalog.initialShader }
    static let storage = CatalogStorage(read: { name in
        if name == "snapshot.json" { return data }
        return try? preview(named: name)
    }, write: { _, _ in }, remove: { _ in })
    static func preview(named name: String) throws -> Data {
        guard let url = Bundle(for: HolodeckTests.self).url(forResource: name, withExtension: nil, subdirectory: "TestSupport") else { throw CatalogError.invalidPreview }
        return try Data(contentsOf: url)
    }
}
