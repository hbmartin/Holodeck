import Foundation

/// Pure composition shared by local recovery owners; formatting stays with each origin.
nonisolated enum BoundedDiagnostics {
    static func bounded(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var prefix = Data(text.utf8.prefix(max(0, bytes)))
        while !prefix.isEmpty {
            if let value = String(data: prefix, encoding: .utf8) { return value }
            prefix.removeLast()
        }
        return ""
    }
    static func appending(_ detail: String, primary: String, secondary: [String]) -> [String] {
        let value = bounded(detail, bytes: 2048)
        guard bounded(detail, bytes: 8192) != primary, !secondary.contains(value) else { return secondary }
        return Array((secondary + [value]).suffix(8))
    }
}
