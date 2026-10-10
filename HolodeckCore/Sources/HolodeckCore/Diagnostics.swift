import OSLog

nonisolated enum Diagnostics {
    static let catalog = Logger(subsystem: "me.haroldmartin.Holodeck", category: "Catalog")
    static let selection = Logger(subsystem: "me.haroldmartin.Holodeck", category: "Selection")
}
