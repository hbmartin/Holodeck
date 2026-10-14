import AppKit
import HolodeckCore
import Observation

@MainActor @Observable
final class MacRequestsModel {
    var configuration: ShaderRequestConfiguration
    var jobs: [ShaderRequestStatus] = []
    var checking = false
    var message = "Configure Codex and enable requests."
    var error: String?
    var onPublication: (@MainActor () -> Void)?
    let service: ShaderRequestService
    let directory: URL
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var revision: String?

    init(catalog: DirectoryCatalog, defaults: UserDefaults?, namespace: String?) {
        self.defaults = defaults
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(namespace.map { "Holodeck/Requests-tests-\($0)" } ?? "Holodeck/Requests")
        service = ShaderRequestService(catalog: catalog, directory: directory)
        configuration = ((try? Data(contentsOf: directory.appendingPathComponent("preferences.json"))) ?? defaults?.data(forKey: "holodeck.requestConfiguration")).flatMap { try? JSONDecoder().decode(ShaderRequestConfiguration.self, from: $0) } ?? .init()
        configuration.shaderTool = Bundle.main.resourceURL?.appendingPathComponent("Tools/holodeck-shader-tool").path ?? ""
        #if DEBUG
        let fixture = UITestConfiguration(applicationID: "me.haroldmartin.HolodeckMac")
        if namespace != nil, fixture.hasExplicitStorageSuite, let journal = ProcessInfo.processInfo.environment["HOLODECK_UI_TEST_REQUEST_JOURNAL"],
           let bytes = journal.data(using: .utf8),
           let records = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? bytes.write(to: directory.appendingPathComponent("journal.json"), options: .atomic)
            for record in records {
                if let status = record["status"] as? [String: Any], let id = status["id"] as? String, UUID(uuidString: id) != nil {
                    try? FileManager.default.createDirectory(at: directory.appendingPathComponent(id), withIntermediateDirectories: true)
                }
            }
        }
        #endif
        let service = service, config = configuration
        observation = Task { [weak self] in
            do { try await service.start(configuration: config) }
            catch { self?.error = error.localizedDescription }
            for await jobs in await service.updates() {
                guard let self else { break }
                self.jobs = jobs
                let current = await catalog.publicationRevisionValue()
                if let current, current != self.revision { self.revision = current; self.onPublication?() }
            }
        }
    }
    isolated deinit { observation?.cancel() }
    var hasUnfinishedJobs: Bool { jobs.contains { !$0.stage.terminal } }
    func setRepository(_ url: URL) {
        guard !configuration.enabled, !hasUnfinishedJobs else { return }
        configuration.repository = url.path; save()
    }
    private func save() { defaults?.set(try? JSONEncoder().encode(configuration), forKey: "holodeck.requestConfiguration") }
    func verify() {
        guard !checking else { return }
        checking = true; error = nil; message = "Checking tools, Git access, model and image review…"
        let candidate = configuration
        Task {
            defer { checking = false }
            do {
                try await service.verify(configuration: candidate)
                configuration = await service.configurationValue()
                save(); message = "Ready for shader requests"
            } catch { self.error = error.localizedDescription; message = "Setup needs attention" }
        }
    }
    func disable() {
        Task {
            do { try await service.disable(); configuration.enabled = false; save(); message = "Requests disabled" }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancel(_ id: UUID) { Task { do { try await service.cancelQueued(id) } catch { self.error = error.localizedDescription } } }
    func delete(_ id: UUID) { Task { do { try await service.deleteFinished(id) } catch { self.error = error.localizedDescription } } }
    func openArtifacts(_ id: UUID) { NSWorkspace.shared.open(directory.appendingPathComponent(id.uuidString)) }
    func logs(_ id: UUID) -> String {
        let file = directory.appendingPathComponent(id.uuidString).appendingPathComponent("worker.log")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "Logs appear when the worker starts." }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > 80_000 ? end - 80_000 : 0)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        } catch { return error.localizedDescription }
    }
    func frames(_ id: UUID) -> [URL] {
        let root = directory.appendingPathComponent(id.uuidString).appendingPathComponent("evidence")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "png" }.sorted { $0.path < $1.path }
    }
}
