# Holodeck quickstart

Set up your Mac once, approve your Apple TV, and play scenes from your local shader library.

## Before you start

- An Apple silicon Mac running macOS 15 or later, with the Mac app installed.
- An Apple TV running tvOS 26 or later, with Holodeck installed.
- Both devices on the same local network, with local-network access allowed for Holodeck.

If you need to build and install the apps, see [developer setup](local-shader-serving.md#developer-setup-and-testing).

## 1. Get your shader folder

Get [HolodeckShaders](https://github.com/hbmartin/HolodeckShaders): on its **main** branch, choose **Code → Download ZIP** and unzip it on your Mac. An existing local copy also works.

Choose the folder containing these items:

```text
HolodeckShaders-main/
├── index.json
├── shared/
└── shaders/
```

The Mac generates previews in its own cache. Generated previews are not committed to the shader repository.

Downloading the folder may need internet on your Mac. Transfers between the apps use your local network.

## 2. Configure the Mac

1. Open the Mac app's **Settings → Shader Library**, available through the **Shader Library** toolbar button.
2. Click **Choose Folder…** and select the folder containing `index.json`, `shared/`, and `shaders/`.
3. Allow local-network access if macOS asks.
4. Wait for **Serving shaders on the local network.** Your scenes should also appear in the Mac viewer.

Keep the Mac awake and the app running while the TV downloads. Closing its viewer window keeps sharing active. The app remembers your folder.

## 3. Approve your TV and play

1. Open Holodeck on Apple TV and allow local-network access if asked.
2. One available Mac connects automatically; with several, choose yours.
3. Compare the six-digit code on the TV with the request in the Mac's **Settings → Shader Library**.
4. When the codes match, click **Approve** on the Mac. If they do not match, click **Decline**.
5. Wait for the library to download and the default scene to play. The approval is saved for future connections.

Press **Select**, choose **Gallery**, to open the scene picker, browse with directional controls, and press **Select** to play. **Back** closes the picker while a scene is playing.

## Publish changes and manage access

After editing files, click **Reload Shaders** on Mac. The folder also reloads at startup. Edits stay unpublished until reload; errors name the offending file and preserve the previous library.

On TV, open the picker and choose **Check for Scene Updates**. Automatic checks run at launch, foreground return, and reconnection. Updated source takes effect when you select the scene or on a subsequent launch; current playback continues during updates.

Use **Change Mac** in the TV picker to switch hosts and approve the new connection. To stop downloads, click **Revoke** under the Mac's **Approved TVs**. Cached scenes remain playable.

## When the Mac is unavailable

Cached scenes play while the Mac app is closed or the Mac is asleep. New downloads need the Mac. Missing previews use color gradients. A remembered Mac stays selected until you choose another. If it is unavailable and other Macs appear, the TV opens the chooser after five seconds. Brief interruptions, such as Control Center, preserve pairing and the connection.

With no usable cache, the TV needs the configured Mac app and approval if it has not paired yet. tvOS can evict caches; an available Mac lets it download again.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| Searching or disconnected | Wake the Mac, open its app, and check the serving status. Use the same network; guest-network/device isolation can prevent discovery. Try **Change Mac → Search Again**. |
| Local-network permission denied | Allow Holodeck local-network access in that device's system Settings, then return to the app and retry. |
| Waiting for approval | Compare both codes in the Mac's **Shader Library**, then click **Approve** when they match. |
| Folder/reload error | Choose the folder containing `index.json`, fix the named missing/invalid file, then click **Reload Shaders**. |
| Incompatible versions | Update both the Mac and TV apps to compatible versions. |
| The Mac's identity changed | Use **Change Mac**, choose your Mac again, and compare the new codes before approving. |
| Access declined or revoked | Use **Check for Scene Updates** and approve its matching code on Mac to restore downloads. |

For authoring requirements, see [the workflow guide](shader-catalog-workflow.md). For how discovery, pairing, and downloads work, see [the technical reference](local-shader-serving.md).

## Request a shader change

Choose **Input** from Select during playback. Enter a change or describe a new scene, then Submit. The TV captures the scene as it looked when Input opened. A clarification may ask you to choose an answer or enter more detail. The completion message says whether the output is new or edited and discloses any runtime approximations.

First enable **Codex Shader Requests** in Mac Settings. Select an explicit model and verify setup. Codex must be logged in; Git must have credentials and identity; Python 3 and Xcode's macOS/tvOS Metal compilers must work. The selected checkout must be clean, with its existing work on `origin/main` and the native shader-tool/preview migration completed. Requests are disabled until this setup succeeds. The app manages that checkout and pushes verified results directly to main.

Manual requests show progress over playback and finish after the TV plays the result. Gallery and Input are locked while the Mac is connected. If the Mac disconnects, cached Gallery browsing becomes available; reconnecting restores the request lock. Backgrounding the TV leaves the Mac working and defers delivery. Keep the Mac awake for execution.

Open **HolodeckMac → Shader Requests** to inspect queued/running jobs, logs, commits and visual evidence. You can cancel queued work there. There is no TV cancellation or history browser. Finished records remain until you delete them.

The TV also requests performance improvements for sustained slow playback. Those requests allow browsing. If the resulting scene is still slow, Retry schedules another improvement with manual priority; Dismiss suppresses automatic requests for that scene until the next TV launch.
