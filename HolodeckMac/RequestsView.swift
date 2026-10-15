import SwiftUI
import AppKit
import HolodeckCore

struct RequestsView: View {
    @Bindable var model: MacRequestsModel
    @State private var selected: UUID?
    var body: some View {
        NavigationSplitView {
            List(model.jobs, selection: $selected) { job in
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.request.prompt).lineLimit(2)
                    Text("\(job.stage.title) · \(job.request.context.name)").font(.caption).foregroundStyle(.secondary)
                    Text(job.request.purpose == .creative ? "Manual request" : job.request.origin == .manual ? "Performance retry" : "Automatic optimization")
                        .font(.caption2).foregroundStyle(.secondary)
                }.tag(job.id).accessibilityIdentifier("shader-request-\(job.id.uuidString)")
            }.navigationTitle("Requests").accessibilityIdentifier("shader-requests-list")
        } detail: {
            if let job = model.jobs.first(where: { $0.id == selected }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(job.request.prompt).font(.title2).textSelection(.enabled)
                        Text(job.message).accessibilityIdentifier("shader-request-stage")
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            Text("\(job.stage.title) · \(Int((job.stage.terminal ? job.updatedAt : timeline.date).timeIntervalSince(job.createdAt))) seconds")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Context: \(job.request.context.name) (\(job.request.context.shaderID))").textSelection(.enabled)
                        if let result = job.result {
                            Text(result.changed ? "\(result.outputKind == .new ? "Created" : "Edited") \(result.shaderID)" : "Already matches: \(result.shaderID)")
                            ForEach(result.approximations, id: \.self) { Text($0) }
                            if let commit = result.commitSHA { Text("Commit: \(commit)").font(.caption.monospaced()).textSelection(.enabled) }
                        }
                        if let clarification = job.clarification { Text(clarification.question).bold() }
                        HStack {
                            Button("Open Logs and Evidence") { model.openArtifacts(job.id) }
                            if job.stage == .queued { Button("Cancel Queued Request") { model.cancel(job.id) } }
                            if job.stage.terminal { Button("Delete Record", role: .destructive) { model.delete(job.id) } }
                        }
                        TimelineView(.periodic(from: .now, by: 2)) { _ in
                            DisclosureGroup("Worker Log") {
                                ScrollView { Text(model.logs(job.id)).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                    .frame(maxHeight: 240)
                            }
                        }
                        TimelineView(.periodic(from: .now, by: 2)) { _ in
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top) {
                                ForEach(model.frames(job.id), id: \.path) { file in
                                    VStack(alignment: .leading) {
                                        if let image = NSImage(contentsOf: file) { Image(nsImage: image).resizable().scaledToFit().frame(width: 320) }
                                        Text("\(file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent) / \(file.deletingLastPathComponent().lastPathComponent) / \(file.lastPathComponent)").font(.caption)
                                    }
                                }
                            }
                        }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
            } else { ContentUnavailableView("Shader Requests", systemImage: "sparkles", description: Text("Choose a request to inspect its progress, logs and visual evidence.")) }
        }
        .overlay(alignment: .bottom) { if let error = model.error { Text(error).foregroundStyle(.red).padding() } }
        .frame(minWidth: 900, minHeight: 600)
    }
}

struct RequestSettingsView: View {
    @Bindable var model: MacRequestsModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Section("Codex Shader Requests") {
            Text("The app manages the selected checkout. Enable only with a clean repository; all paired TVs may request changes.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Codex executable", text: $model.configuration.codex).accessibilityIdentifier("request-codex-path")
            TextField("Python executable", text: $model.configuration.python)
            TextField("Model", text: $model.configuration.model).accessibilityIdentifier("request-model")
            Picker("Reasoning", selection: $model.configuration.reasoning) {
                ForEach(["low", "medium", "high", "xhigh"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            HStack {
                Button("Verify Setup and Enable") { model.verify() }.disabled(model.checking || model.hasUnfinishedJobs || model.configuration.repository.isEmpty || model.configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("enable-shader-requests")
                if model.configuration.enabled { Button("Disable Requests") { model.disable() }.disabled(model.hasUnfinishedJobs) }
                Button("Open Requests") { openWindow(id: "requests") }
                if model.checking { ProgressView().controlSize(.small) }
            }
            ForEach(model.recoveries) { recovery in
                CheckoutRecoveryView(model: model, recovery: recovery)
            }
            Text(model.configuration.enabled ? "Requests enabled" : model.message).accessibilityIdentifier("request-setup-status")
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("Requires Codex login, Git credentials and identity, Python 3, and Xcode Metal compilers. Implementation and independent image review share this model setting. Verify setup again to apply changed settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CheckoutRecoveryView: View {
    let model: MacRequestsModel
    let recovery: ShaderRequestRecoveryStatus
    @State private var repository: String
    @State private var python: String
    @State private var git: String
    @State private var confirmsDetach = false
    init(model: MacRequestsModel, recovery: ShaderRequestRecoveryStatus) {
        self.model = model; self.recovery = recovery
        _repository = State(initialValue: recovery.repository)
        _python = State(initialValue: recovery.python)
        _git = State(initialValue: recovery.git)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Checkout Recovery").bold()
            Text(recovery.message).textSelection(.enabled)
            TextField("Owned checkout folder", text: $repository).accessibilityIdentifier("recovery-repository")
            TextField("Python executable", text: $python).accessibilityIdentifier("recovery-python")
            TextField("Git executable", text: $git).accessibilityIdentifier("recovery-git")
            HStack {
                Button("Retry Cleanup") { model.retryCleanup(recovery.id, repository: repository, python: python, git: git) }
                    .disabled(model.checking || recovery.isRunning).accessibilityIdentifier("retry-checkout-cleanup")
                Button("Detach Checkout…", role: .destructive) { confirmsDetach = true }
                    .disabled(model.checking).accessibilityIdentifier("detach-checkout")
            }
        }.confirmationDialog("Detach this checkout and disable shader requests?", isPresented: $confirmsDetach) {
            Button("Detach and Keep Files", role: .destructive) { model.detach(recovery.id) }
        } message: { Text("Unpublished checkout files, patches, and logs will be retained. Verify setup before managing a checkout again.") }
    }
}
