# Local serving validation — 2026-10-13

The native Mac loader and LAN transport replace the production GitHub downloader. Shader and preview requests use `CatalogSource`; shipping Swift sources contain no URLSession downloader or public URLs. Bonjour resolution forces multicast DNS-SD, numeric destinations must be private or link-local on the discovered interface, and certificate verification disables network fetching.

## Automated checks

- Shared core: 106 tests executed, two opt-in performance tests skipped, zero failures. This run enabled real LAN Bonjour testing and supplied the local authoring repository.
- All 23 indexed authoring scenes loaded, assembled, compiled, rendered, and animated natively. Supplied preview bytes and SHA-256 hashes were checked. No authoring scripts ran.
- Directory tests cover assembly order, material helpers, collections, discovery metadata, attribution comments, canonical revisions, manual publication, bad-file rollback, persisted copied snapshots, path allowlists, and concurrent reload/download leases.
- Real TLS tests cover connection-derived matching codes, approval, rejection, credential persistence, revocation, and changed keys. Protocol tests cover bounds, malformed messages, interrupted transfers, cancellation, and serialized binary exchanges. Public-address rejection, multicast-only resolver flags, and disabled certificate fetching are asserted.
- Physical Apple TV: 37 unit tests and three UI regressions passed, including first-launch retry, offline error handling, and unchanged playback/focus during an updated catalog.
- Mac UI: four relevant tests passed, covering folder selection, manual reload, invalid-preview rollback, bookmark restoration after relaunch, cached-update retry, renderer error recovery, and collection filters without interrupting playback. Tests used isolated bundle IDs to avoid migrating the existing development app's sandbox container while changing its signing identity.
- Both app targets built successfully. Mac development signing uses a stable Apple Development identity so Keychain items remain accessible across builds. Swift Certificates is restricted to macOS.
- The final signed Mac app restored its configured authoring folder and playback, and reported **Serving shaders on the local network**. Its production identity and approvals use a stable namespace separate from development prototypes and isolated tests.

## Physical LAN check

An Apple TV 4K running tvOS 26.6 discovered the Mac's advertised service, resolved it locally, completed TLS pairing, showed the same six-digit code as the Mac settings view, and downloaded the real 23-scene authoring library after clicking **Approve**. The default scene played successfully. Relaunch restored cached playback and reauthenticated to the remembered Mac without another approval.

A second physical run stopped the Mac server after the remembered-host reconnect. The TV reported disconnection, then relaunched and played the cached default scene with the server unavailable. Both physical LAN UI runs passed.

The opt-in physical test uses real production transport and runtime Metal compilation, with isolated test Keychain credentials and disk storage. On this TV, its system profile picker had to be dismissed before Holodeck could become active. Discovery now starts from the foreground lifecycle; with no usable cache, the TV opens the picker to make connection and approval states visible.

## Remaining device checks

The router-level WAN-blocked test was skipped at the user's request. Physical permission denial/recovery, Mac sleep/wake, and minimum macOS 15 runtime checks remain manual release checks. Automated privacy/error mapping, revocation, TLS pinning, and offline-cache tests do not substitute for testing those OS and router behaviors.

Run instructions and test opt-ins are in [the local shader library workflow](shader-catalog-workflow.md).
