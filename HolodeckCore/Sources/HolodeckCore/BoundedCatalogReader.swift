import Foundation
import Darwin

nonisolated struct CatalogFileSizeError: Error, LocalizedError {
    let path: String
    let kind: String
    let actual: Int
    let limit: Int
    var localError: LocalCatalogError { .invalidFile(path, CatalogError.sizeLimit(kind: kind, actual: actual, limit: limit).localizedDescription) }
    var errorDescription: String? { localError.localizedDescription }
}

/// Pins the root and every directory component; a pathname is never checked and then reopened.
nonisolated final class BoundedCatalogReader {
    private let root: Int32
    init(root url: URL) throws {
        root = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw LocalCatalogError.invalidFile(url.lastPathComponent, "Cannot open folder without following symbolic links: \(String(cString: strerror(errno)))") }
    }
    deinit { close(root) }

    struct File {
        let bytes: Data
        let modified: Date
    }

    func read(_ path: String, limit: Int, afterMetadata: (() throws -> Void)? = nil) throws -> File {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard limit >= 0, limit < Int.max, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw LocalCatalogError.invalidFile(path, "Expected a relative file path inside the selected folder.")
        }
        var parent = dup(root)
        guard parent >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(parent) }
        for component in parts.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw failure(path) }
            close(parent); parent = next
        }
        let descriptor = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(path) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure(path) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw LocalCatalogError.invalidFile(path, "Expected a regular file; symbolic links and special files are not supported.")
        }
        guard info.st_size <= limit else { throw CatalogFileSizeError(path: path, kind: "File", actual: Int(info.st_size), limit: limit) }
        try afterMetadata?()
        var data = Data(), buffer = [UInt8](repeating: 0, count: min(65_536, limit + 1))
        while data.count <= limit {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, min($0.count, limit + 1 - data.count)) }
            if count < 0 { if errno == EINTR { continue }; throw failure(path) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= limit else { throw CatalogFileSizeError(path: path, kind: "File (observed bytes)", actual: data.count, limit: limit) }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return File(bytes: data, modified: modified)
    }

    private func failure(_ path: String) -> LocalCatalogError {
        .invalidFile(path, "Cannot read a regular file without following symbolic links: \(String(cString: strerror(errno)))")
    }
}
