import Foundation
@testable import HolodeckCore

/// Recorded repository content belongs to test bundles only, never Holodeck.app.
nonisolated enum TestCatalog {
    static let data: Data = {
        let url = Bundle.module.url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport")!
        return try! Data(contentsOf: url)
    }()
    static let snapshot: CatalogSnapshot = {
        let value = try! JSONDecoder().decode(CatalogSnapshot.self, from: data)
        return value
    }()
    static let catalog = try! snapshot.validated()
    static var shaders: [ShaderDefinition] { catalog.shaders }
    static var initialShader: ShaderDefinition { catalog.initialShader }
    static let storage = CatalogStorage(read: { name in
        if name == "snapshot.json" { return data }
        return try? preview(named: name)
    }, write: { _, _ in })
    static func preview(named name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "TestSupport") else { throw CatalogError.invalidPreview }
        return try Data(contentsOf: url)
    }
}
