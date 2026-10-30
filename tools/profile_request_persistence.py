"""Compare Release service metadata persistence with a reviewed baseline; disposable workers only."""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRIVER = r'''
import Foundation
import Darwin
@testable import HolodeckCore
nonisolated enum ProfileDelay {
 static let seconds = Double(CommandLine.arguments[5])! / 1000
 static func pause() { if seconds > 0 { Thread.sleep(forTimeInterval: seconds) } }
}
nonisolated final class BaselineHashCounter: @unchecked Sendable {
 static let lock = NSLock(); nonisolated(unsafe) private static var value = 0
 static var count: Int { lock.withLock { value } }
 static func reset() { lock.withLock { value = 0 } }
 static func hash(_ bytes: Data) -> String { lock.withLock { value += 1 }; return CatalogHash.sha256(bytes) }
}
actor LatencyCounter {
 var maximum: Double = 0
 func record(_ seconds: Double) { maximum = max(maximum, seconds) }
}
func responsiveness(_ read: @escaping @Sendable () async -> Void, counter: LatencyCounter) -> Task<Void, Never> {
 Task {
  while !Task.isCancelled {
   let began = ProcessInfo.processInfo.systemUptime; await read()
   await counter.record(ProcessInfo.processInfo.systemUptime - began)
   try? await Task.sleep(for: .milliseconds(2))
  }
 }
}
final class Counter: @unchecked Sendable {
 let lock=NSLock();var value=0
 func write(_ data:Data,_ file:URL)throws {lock.withLock{value+=1};try RequestJournalWriter.write(data,to:file)}
 var count:Int{lock.withLock{value}}
}
@main struct Profile {
 @MainActor static func main()async throws {
  let samples=Int(CommandLine.arguments[1])!,stages=Int(CommandLine.arguments[2])!,python=CommandLine.arguments[3]
  let rootURL=URL(fileURLWithPath:CommandLine.arguments[4]),fm=FileManager.default
  let fixture=try JSONDecoder().decode(CatalogSnapshot.self,from:Data(contentsOf:rootURL.appendingPathComponent("HolodeckCore/Tests/HolodeckCoreTests/TestSupport/CatalogFixture.json")))
  let shader=try fixture.validated().initialShader,png=try RequestScreenshot.encode(pixels:Data([0,0,0,255]),width:1,height:1,bytesPerRow:4)
  let context=ShaderRequestContext(shader:shader,screenshot:png,animationTime:1,width:1280,height:720)
  var results:[[String:Any]]=[]
  for iteration in 0..<samples {
   for baseline in iteration % 2 == 0 ? [true,false]:[false,true] {
    let root=fm.temporaryDirectory.appendingPathComponent("HolodeckPersistenceProfile-"+UUID().uuidString)
    try fm.createDirectory(at:root,withIntermediateDirectories:true)
    let script=root.appendingPathComponent("worker.py"),counter=Counter()
    try """
    import json
    for n in range(\(stages)):print(json.dumps(dict(event='stage',stage='implementing',message='stage '+str(n))),flush=True)
    print(json.dumps(dict(event='clarification',question='Choose',options=['A','B'])),flush=True)
    """.write(to:script,atomically:true,encoding:.utf8)
    let config=ShaderRequestConfiguration(repository:root.path,python:python,enabled:true)
    let request=ShaderRequest(prompt:"Persistence fixture",context:context),job=root.appendingPathComponent(request.id.uuidString)
    let began:TimeInterval, cpu:clock_t, replacements:Int, encodings:Int, reads:Int, hashes:Int, response:Double
    if baseline {
     BaselineHashCounter.reset()
     let service=BaselineShaderRequestService(catalog:DirectoryCatalog(directory:root.appendingPathComponent("catalog")),directory:root,workerScript:script,recoveryWriter:{try counter.write($0,$1)})
     await service.suspend();try await service.start(configuration:config)
     let latency = LatencyCounter()
     let responsivenessTask = responsiveness({ _ = await service.configurationValue() }, counter: latency)
     let before=await service.persistenceStatistics();began=ProcessInfo.processInfo.systemUptime;cpu=clock()
     _=try await service.control(operation:"requestSubmit",payload:.init(request:request),deviceID:"fixture")
     await service.resume()
     while (try? RequestWorkerOperation.read(in:job)?.phase) != .complete || fm.fileExists(atPath:root.appendingPathComponent("active.json").path) {
      guard ProcessInfo.processInfo.systemUptime-began<30 else {await service.suspend();throw CocoaError(.userCancelled)}
      try await Task.sleep(for:.milliseconds(2))
     }
     let after=await service.persistenceStatistics()
     replacements=["journal.json","recovery.json","detached-checkouts.json"].reduce(0){$0+(after[$1,default:0]-before[$1,default:0])}
     encodings=after["metadataEncodings",default:0]-before["metadataEncodings",default:0]
     reads=after["reads",default:0]-before["reads",default:0];hashes=after["hashes",default:0]-before["hashes",default:0]
     responsivenessTask.cancel();await responsivenessTask.value;response=await latency.maximum;await service.suspend()
    } else {
     let service=ShaderRequestService(catalog:DirectoryCatalog(directory:root.appendingPathComponent("catalog")),directory:root,workerScript:script,recoveryWriter:{try counter.write($0,$1)},beforePersistenceReplacement:{_ in ProfileDelay.pause()})
     await service.suspend();try await service.start(configuration:config)
     let latency = LatencyCounter()
     let responsivenessTask = responsiveness({ _ = await service.configurationValue() }, counter: latency)
     let before=await service.persistenceStatistics();began=ProcessInfo.processInfo.systemUptime;cpu=clock()
     _=try await service.control(operation:"requestSubmit",payload:.init(request:request),deviceID:"fixture")
     await service.resume()
     while (try? RequestWorkerOperation.read(in:job)?.phase) != .complete || fm.fileExists(atPath:root.appendingPathComponent("active.json").path) {
      guard ProcessInfo.processInfo.systemUptime-began<30 else {await service.suspend();throw CocoaError(.userCancelled)}
      try await Task.sleep(for:.milliseconds(2))
     }
     let after=await service.persistenceStatistics()
     replacements=["journal.json","recovery.json","detached-checkouts.json"].reduce(0){$0+(after[$1,default:0]-before[$1,default:0])}
     encodings=after["metadataEncodings",default:0]-before["metadataEncodings",default:0]
     reads=after["reads",default:0]-before["reads",default:0];hashes=after["hashes",default:0]-before["hashes",default:0]
     responsivenessTask.cancel();await responsivenessTask.value;response=await latency.maximum;await service.suspend()
    }
    let elapsed=ProcessInfo.processInfo.systemUptime-began,used=Double(clock()-cpu)/Double(CLOCKS_PER_SEC)
    results.append(["baseline":baseline,"iteration":iteration,"milliseconds":elapsed*1000,"cpu_seconds":used,"metadata_replacements":replacements,"metadata_fsyncs":replacements*2,"metadata_encodings":encodings,"persistence_reads":reads,"persistence_hashes":hashes,"maximum_actor_reply_ms":response*1000])
    try fm.removeItem(at:root)
   }
  }
  print(String(decoding:try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
 }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='650cfa2')
    parser.add_argument('--samples', type=int, default=5)
    parser.add_argument('--stages', type=int, default=200)
    parser.add_argument('--python', default='/usr/bin/python3')
    parser.add_argument('--slow-ms', type=float, default=0, help='Delay each metadata/payload replacement equally in both writers')
    args = parser.parse_args()
    if not 1 <= args.samples <= 100 or not 1 <= args.stages <= 10000 or not 0 <= args.slow_ms <= 1000:
        parser.error('samples must be 1..100, stages 1..10000, and slow-ms 0..1000')
    product = ROOT / 'HolodeckCore/.build/out/Products/Release'
    if not (product / 'libHolodeckCore.a').exists():
        parser.error('Build and test HolodeckCore in Release first')
    baseline_sha = subprocess.check_output(['git', 'rev-parse', '--verify', '--end-of-options', args.baseline + '^{commit}'], cwd=ROOT, text=True).strip()
    original = subprocess.check_output(['git', 'show', baseline_sha + ':HolodeckCore/Sources/HolodeckCore/ShaderRequestService.swift'], cwd=ROOT, text=True)
    actor = original[original.index('public actor ShaderRequestService {'):]
    actor = actor.replace('ShaderRequestService', 'BaselineShaderRequestService').replace('RequestPersistence', 'BaselineRequestPersistence')
    persistence = subprocess.check_output(['git', 'show', baseline_sha + ':HolodeckCore/Sources/HolodeckCore/RequestPersistence.swift'], cwd=ROOT, text=True).replace('RequestPersistence', 'BaselineRequestPersistence')
    # Instrument the reviewed writer without changing its read/write decisions.
    persistence = persistence.replace('private var encodings = 0', 'private var encodings = 0; private var reads = 0')
    persistence = persistence.replace('return .file(try BoundedCatalogReader', 'reads += 1; return .file(try BoundedCatalogReader')
    persistence = persistence.replace('CatalogHash.sha256(', 'BaselineHashCounter.hash(')
    persistence = persistence.replace('"encodings": encodings', '"encodings": encodings, "metadataEncodings": encodings, "reads": reads, "hashes": BaselineHashCounter.count')
    persistence = persistence.replace('private func replace(_ bytes: Data, at file: URL) throws {', 'private func replace(_ bytes: Data, at file: URL) throws { ProfileDelay.pause()')
    with tempfile.TemporaryDirectory(prefix='holodeck-persistence-profile-') as temporary:
        folder = Path(temporary)
        baseline = folder / 'baseline.swift'
        baseline.write_text('#if os(macOS)\nimport Foundation\nimport Darwin\n@testable import HolodeckCore\n' + actor + '\n' + persistence)
        driver = folder / 'profile.swift'; driver.write_text(DRIVER)
        executable = folder / 'profile'
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', '-target', 'arm64-apple-macos15.0', '-sdk', sdk, '-I', str(product), '-L', str(product), '-lHolodeckCore', str(baseline), str(driver), '-o', str(executable)], cwd=ROOT, check=True, timeout=120)
        result = subprocess.run([str(executable), str(args.samples), str(args.stages), args.python, str(ROOT), str(args.slow_ms)], cwd=ROOT, check=True, text=True, capture_output=True, timeout=args.samples*65+30)
        print(json.dumps(dict(baseline=baseline_sha, python=args.python, slowMilliseconds=args.slow_ms, stages=args.stages, metadataFiles=['journal.json','recovery.json','detached-checkouts.json'], fsyncAccounting='Each successful metadata replacement synchronizes the file and its parent directory; operation/process evidence writes are excluded equally. Encodings, reads and hash calls are instrumented in both reviewed and current writers; response latency samples configuration queries during work. Each injected replacement delay applies equally.', samples=json.loads(result.stdout)), indent=2))


if __name__ == '__main__':
    main()
