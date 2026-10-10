import Foundation
import Darwin

nonisolated enum AppPreferencesReader {
    enum ReadError: Error {
        case homeDirectoryUnavailable
        case missingFile(URL)
        case invalidDictionary(URL)
    }

    static func appURL() throws -> URL {
        // The app and UI runner use separate preferences domains. Xcode also redirects
        // the runner's home, so resolve the sandboxed app's path from the real user home.
        guard let directory = getpwuid(getuid())?.pointee.pw_dir else { throw ReadError.homeDirectoryUnavailable }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
            .appendingPathComponent("Library/Containers/me.haroldmartin.HolodeckMac/Data/Library/Preferences/me.haroldmartin.HolodeckMac.plist")
    }

    static func read(at url: URL, allowMissing: Bool = false) throws -> [String: Any] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            if allowMissing { return [:] }
            throw ReadError.missingFile(url)
        }
        guard let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { throw ReadError.invalidDictionary(url) }
        return values
    }
}
