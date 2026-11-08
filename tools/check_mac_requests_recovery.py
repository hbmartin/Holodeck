#!/usr/bin/env python3
"""Check MacRequestsModel's partial-recovery observation without desktop UI.

Run `swift test --package-path HolodeckCore` first. This compiles the actual Mac
model with the built Debug core into a disposable, explicitly isolated fixture.
No production preferences, Keychain entries, listeners or requests are used.
"""
import os
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DRIVER = r'''
import Foundation
@testable import HolodeckCore

@MainActor @main struct RecoveryCheck {
    static func require(_ condition: Bool, _ detail: String) throws {
        if !condition { throw ShaderRequestError.unavailable(detail) }
    }
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition() {
            try require(ContinuousClock.now < deadline, "Model recovery backstop")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func accepted(_ ticket: TrustedApprovalsCoordinator.Registration) async throws {
        guard case .accepted = try await ticket.value() else { throw ShaderRequestError.invalidRequest }
    }
    static func main() async {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOLODECK_UI_TEST_REQUEST_DIRECTORY"]!)
        var services: [ShaderRequestService] = []
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let preferences = root.appendingPathComponent("preferences.json")
            try Data("not JSON".utf8).write(to: preferences)
            let model = MacRequestsModel(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), defaults: nil, namespace: "headless-recovery")
            try require(model.directory.path == root.path, "Missing isolated model directory")
            try await model.initialized(); services.append(model.service); await model.service.suspend()
            let otherRoot = root.appendingPathComponent("other")
            let other = ShaderRequestService(catalog: DirectoryCatalog(directory: otherRoot.appendingPathComponent("catalog")), directory: otherRoot)
            services.append(other); await other.suspend(); try await other.initialize(configuration: .init(repository: otherRoot.path))
            let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
            let bytes = try TrustedTVApprovals(revocations: [intent]).encoded()
            let authority = TrustedApprovalsCoordinator(read: { bytes }, write: { _ in })
            func owner(_ service: ShaderRequestService) -> TrustedApprovalsCoordinator.Owner {
                .init(serverID: UUID(), service: service, changed: { _, _ in }, retired: {}, beforeReplay: { _ in throw POSIXError(.EIO) })
            }
            try await accepted(authority.register(owner(model.service))); try await accepted(authority.register(owner(other)))
            do { try await authority.replay(); throw ShaderRequestError.invalidRequest }
            catch { try require(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription), "Missing replay failure") }
            let folder = root.appendingPathComponent("accepted-folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let configuration = ShaderRequestConfiguration(repository: folder.path, model: "Recovered model", enabled: false)
            try JSONEncoder().encode(configuration).write(to: preferences, options: .atomic)
            model.retryReconciliation(); try await wait { !model.checking }
            try require(model.error?.contains("Partial recovery") == true, "Missing partial recovery result: " + (model.error ?? "none"))
            try await wait { model.configuration.repository == folder.path }
            try require(!model.configuration.enabled, "Recovery unexpectedly enabled requests")
            print("PASS: partial recovery preserves the accepted folder through localUpdates without desktop UI")
        } catch {
            for service in services { await service.suspend() }
            FileHandle.standardError.write(Data(("FAIL: " + error.localizedDescription + "\n").utf8)); exit(1)
        }
        for service in services { await service.suspend() }
    }
}
'''


def main():
    if platform.system() != "Darwin":
        raise SystemExit("This check compiles the macOS model and requires macOS.")
    products = ROOT / "HolodeckCore/.build/debug"
    objects = sorted(products.glob("*.o"))
    if not objects:
        raise SystemExit("Build Debug core tests first: swift test --package-path HolodeckCore")
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    includes = ROOT / "HolodeckCore/.build/checkouts/swift-crypto/Sources/CCryptoBoringSSL/include"
    with tempfile.TemporaryDirectory(prefix="holodeck-model-recovery-", dir="/private/tmp") as temporary:
        directory = Path(temporary)
        driver, executable = directory / "check.swift", directory / "check"
        driver.write_text(DRIVER)
        command = ["xcrun", "swiftc", "-D", "DEBUG", "-parse-as-library", "-swift-version", "6", "-target", platform.machine() + "-apple-macos15.0", "-sdk", sdk,
                   "-I", str(products), "-Xcc", "-fmodule-map-file=" + str(includes / "module.modulemap"), "-Xcc", "-I" + str(includes),
                   "-Xcc", "-isystem", "-Xcc", str(Path(sdk) / "usr/include/c++/v1"), str(driver), str(ROOT / "HolodeckMac/MacRequestsModel.swift"),
                   *map(str, objects), "-o", str(executable)]
        subprocess.run(command, cwd=ROOT, check=True, timeout=120)
        environment = dict(os.environ, HOLODECK_UI_TEST_REQUEST_DIRECTORY=str(directory / "requests"))
        subprocess.run([str(executable), "--ui-test-storage-suite", "headless-recovery"], cwd=ROOT, env=environment, check=True, timeout=30)


if __name__ == "__main__":
    main()
