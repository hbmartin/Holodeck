# Local shader library workflow

The Mac app owns publication. Apple TV discovers the Mac on the local network, pairs once with Mac approval, and downloads catalog sources and previews over TLS. Compatible shader changes require no app release.

For setup and everyday controls, follow the [user quickstart](quickstart.md). For component ownership, protocol messages, credentials, storage, and developer setup, see the [technical reference](local-shader-serving.md). This guide keeps the authoring and publication overview.

## Configure and pair

1. Open **HolodeckMac → Settings → Shader Library → Choose Folder** and select an authoring folder.
2. Wait for **Serving shaders on the local network**. Keep the Mac app running; its viewer window may be closed.
3. Open Holodeck on Apple TV on the same network and allow local-network access. One available Mac connects automatically; several show a chooser.
4. Compare the six-digit code on both devices, then click **Approve** in the Mac's Shader Library settings.
5. Use **Reload Shaders** on Mac after edits. Use **Check for Scene Updates** on TV for an immediate check.

A remembered Mac is never silently replaced by another server. Use **Change Mac** to switch or repair pairing after a changed host key. **Revoke** cancels that TV's active connection and prevents further downloads. Its previously cached scenes remain playable.

## Authoring format

```text
index.json                          # ordered shader IDs, defaultShaderID, optional collections
shared/common.metal
shared/material.metal               # required by shaders that declare material helpers
shared/fragment.metal
shaders/<id>/metadata.json           # id, name, category, description, colors, shared, discovery
shaders/<id>/body.metal
```

Only indexed shaders are loaded, in index order. Shared declarations must be `["common", "fragment"]` or `["common", "material", "fragment"]`. Sources concatenate common helpers, optional material helpers, body, and fragment wrapper without rewriting source bytes or attribution comments. Collections and supported metadata use the existing catalog schema. Discovery labels retain existing normalization and optional-field recovery.

The loader generates previews and ignores legacy `preview.png`/`preview.json` files in the authoring folder. Git, Python, repository scripts, commits, and Xcode tools are unnecessary for publication from the app. Update dates use the latest modification time of a shader's metadata, body, and declared helpers.

Preview generation uses the shared offscreen renderer at 1280×720 and three seconds with the sRGB target. Successful PNGs are cached in app-owned storage by assembled-source hash, settings, and renderer version. Cache hashes and decoded images are checked before reuse; corrupt entries are regenerated, and unused cache entries are pruned after successful reload. Source or helper changes regenerate affected previews; metadata-only changes reuse successful renders.

A failed shader compile, GPU render, or PNG encoding uses an opaque gradient from the two metadata colors and displays a per-shader warning in Settings. Fallbacks are retried on each reload; successful regeneration clears their warning. Missing source files, invalid metadata, or storage failures reject reload and preserve the previous publication. Reloads are serialized while the current immutable assets remain available to connected TVs during generation. `DirectoryCatalog.reload(from:)` returns a `CatalogReloadResult` containing the validated catalog and preview warnings. The catalog wire format is unchanged.

The selected directory is persisted with a read-only security-scoped bookmark. The Mac sandbox allows user-selected read access and incoming connections. The directory is read at startup and on explicit reload, with no watcher or background helper. Copying a complete candidate into app-owned storage keeps served bytes independent of subsequent edits. Validation failure names its file and leaves the previous publication available. The copied publication can also be restored when authoring access fails after restart.

## Revisions, transport, and trust

A local revision is the SHA-256 digest of sorted-key canonical catalog metadata and asset hashes, before adding `sourceRevision`. The manifest's `sourceRevision` and publication revision use that 64-character digest. Legacy 40-character revisions remain valid in TV disk snapshots. Per-shader and collection array order is significant.

The Mac advertises `_holodeck._tcp` in `local.` with protocol version, stable Mac UUID, and display name. TV uses `NWBrowser`, then resolves SRV and numeric addresses using `DNSServiceResolve` and `DNSServiceGetAddrInfo`, both with `kDNSServiceFlagsForceMulticast`. The SRV hostname must end in `.local`; sockets accept only private or link-local destinations on the discovered interface. Loopback is enabled only for integration tests. Public IPs, DNS names, multicast destinations, and globally routable IPv6 are rejected before connecting.

The Mac's TLS 1.3 identity is generated with Apple's Swift Certificates library and persisted in Keychain; that library is restricted to macOS. Certificate verification disables network fetching and pins the public key after approved pairing. The six-digit code derives from TLS exported key material for that connection. Approval issues a random 256-bit per-TV credential. TV persists its credential and host pin in Keychain; Mac persists only the credential hash and approval. A changed host key fails closed until the user explicitly repairs the pairing.

A frame contains a four-byte big-endian JSON-header length, the JSON control message, then an optional binary payload. Control messages include a protocol version and payload length. Operations are `hello`, `pair`, `pairStatus`, `authenticate`, and `asset`; catalog requests are a current revision lookup or an asset path at a fixed revision. No catalog assets are released before approval/authentication. Every asset belongs to a validated snapshot allowlist. A connection pins its current revision, and publications used by active transfers survive reloads.

| Bound | Maximum |
| --- | --- |
| JSON frame header / revision response | 64 KiB |
| Catalog manifest | 2 MiB |
| One assembled source | 1 MiB |
| All sources | 16 MiB |
| One preview / binary frame payload | 8 MiB |
| Active server connections | 16 |
| Transfer / connection timeout | 30 seconds |
| Pending approval | 5 minutes |

All TV asset paths, including previews, use an injected `CatalogSource`. `DirectoryCatalog` supplies the Mac viewer; `LocalCatalogClient` supplies TV. Production code has no URLSession downloader, GitHub URL, public DNS resolver, or public-network fallback.

## Playback and offline behavior

TV applies a verified disk cache before requesting updates. A full candidate manifest and every source are verified before an atomic `snapshot.json` write. A failed update preserves the prior cache. Preview hashes, disk caching, bounded memory caches, independent fetching, decoding, retry policy, and gradient fallback remain unchanged.

Ordinary launch and foreground checks retain a 15-minute monotonic throttle once a usable cache exists. Explicit checks and reconnection bypass it. Concurrent refreshes share one operation. Mac authoring changes do not become visible until startup or **Reload Shaders**.

TV playback retains its existing pipeline during catalog updates. Revised source compiles when selected or on subsequent launch. A removed active shader continues playing; a missing saved ID resolves to the new default next launch. Mac replaces changed active source after successful compilation. Selection failures retain working playback.

No usable TV cache means the user must configure and open the Mac app and approve the TV. Searching, local-network permission denial, awaiting approval, disconnection, incompatible version, and changed-key states have distinct messages. Revocation does not erase cached scenes.

## Validation

Run `swift test --package-path HolodeckCore`. Set `HOLODECK_AUTHORING_FIXTURE=/absolute/path/to/HolodeckShaders` to additionally load, compile, render, animate, and verify generated previews from a local authoring repository without supplied PNGs. Run both app schemes' tests with injected fixtures. The Mac UI includes a real folder-picker, manual-reload, invalid-file rollback, and bookmark-relaunch test.

Set `HOLODECK_LAN_TEST=1` for the shared-core test that advertises a real Bonjour service, resolves it using multicast-only DNS-SD on a private interface, compares the TLS pairing codes, approves the client, downloads a revision, and reconnects using its saved Keychain credential. Test identities and approvals use isolated namespaces and are removed afterward.

The opt-in TV UI test `testPhysicalLocalNetworkPairingAndRememberedPlayback` uses the real network client and disk cache. Enable it with `TEST_RUNNER_HOLODECK_PHYSICAL_LAN_TEST=1` when running `xcodebuild HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests test` against a physical Apple TV. Run an isolated debug Mac app with `--ui-test-storage-suite Holodeck.physical-mac-validation --ui-test-local-library --ui-test-local-network`, choose the authoring folder, and leave Shader Library settings open. Compare the code printed by the TV test with the Mac request and click **Approve**. The test checks rendered playback and a credential-based reconnect after relaunch, then removes its TV test credentials and cache. Remove the Mac test namespace afterward using its existing test cleanup launch argument.

Also set `TEST_RUNNER_HOLODECK_PHYSICAL_OFFLINE_TEST=1` to pause that test after reconnecting. When it prints the offline-check prompt, quit the Mac validation app. It verifies disconnection and cached playback after another TV relaunch.

Before release, verify physical Mac-to-Apple-TV discovery and matching pairing codes, local-network permission denial/recovery, revocation, host-key repair, sleep/wake, offline playback, and updates while playing. Block WAN access while retaining LAN/mDNS access to confirm the complete physical flow works without internet. Automated loopback TLS tests do not establish router or device privacy behavior.

Implementation: [directory loader](../HolodeckCore/Sources/HolodeckCore/DirectoryCatalog.swift), [LAN server](../HolodeckCore/Sources/HolodeckCore/LocalCatalogServer.swift), [TV client](../HolodeckCore/Sources/HolodeckCore/LocalCatalogClient.swift), [resolver](../HolodeckCore/Sources/HolodeckCore/LocalDiscovery.swift), [framing and trust](../HolodeckCore/Sources/HolodeckCore/LocalTransport.swift), and [cache service](../HolodeckCore/Sources/HolodeckCore/CatalogService.swift).
