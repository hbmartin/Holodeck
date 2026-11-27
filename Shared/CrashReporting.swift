import Foundation
import Sentry

@MainActor
enum CrashReporting {
    static func start() {
        let bundle = Bundle.main
        guard let dsn = bundle.object(forInfoDictionaryKey: "HolodeckSentryDSN") as? String,
              let endpoint = URLComponents(string: dsn),
              endpoint.scheme == "https", endpoint.host != nil, endpoint.user?.isEmpty == false,
              let identifier = bundle.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return }

        let environment = bundle.object(forInfoDictionaryKey: "HolodeckSentryEnvironment") as? String
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment.flatMap { $0.isEmpty ? nil : $0 } ?? "development"
            options.releaseName = "\(identifier)@\(version)+\(build)"
            options.dist = build
            options.sendDefaultPii = false
            options.sendClientReports = false
            options.enableAutoSessionTracking = false
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.enableSwizzling = false
            options.enableAppHangTracking = false
            #if os(tvOS)
            options.enableWatchdogTerminationTracking = false
            #endif
            options.tracesSampleRate = 0
            options.tracePropagationTargets = []
            options.beforeSend = scrubIdentifiers
        }
    }

    nonisolated static func scrubIdentifiers(_ event: Event) -> Event? {
        // Cocoa v9 otherwise supplies a persistent installation ID as the event user.
        event.user = nil
        event.serverName = nil
        if var context = event.context, var app = context["app"] {
            app.removeValue(forKey: "device_app_hash")
            context["app"] = app
            event.context = context
        }
        return event
    }
}
