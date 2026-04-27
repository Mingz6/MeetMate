# Setup Guide

## Prerequisites

- macOS 14+ (Sonoma) is the active target. iPadOS 17+ / iOS 17+ are supported but get polished after macOS lands.
- Xcode 15+
- An Azure subscription with **Azure OpenAI** (chat deployment) and **Azure AI Speech** (one resource group, one region works for both)
- Network access during meetings (cloud is the default for STT + polish)
- Optional: ~12 GB free disk if you want the local WhisperKit + MLX offline mode

## Open the project

```bash
cd ~/code/personal/MeetMate
open MeetMate.xcodeproj
```

Swift Package dependencies (WhisperKit, mlx-swift-examples) resolve automatically on first open.

## Capabilities (already configured)

`MeetMate.entitlements` enables:

- App Sandbox
- Audio Input
- Microphone
- User-selected file (read/write) — for SwiftData

`Info.plist` ships with `NSMicrophoneUsageDescription` and `NSSystemAdministrationUsageDescription`.

## Sign with your Apple ID

In Xcode → Signing & Capabilities:

- Team: your personal team (free works)
- Bundle Identifier: `dev.mingz.MeetMate` — change if conflict

## First run (macOS)

1. ⌘R in Xcode.
2. macOS prompts for microphone permission — allow.
3. macOS prompts for screen recording (needed for system audio loopback) — allow, then restart the app.
4. Open Settings → paste your **Azure OpenAI** endpoint + deployment name + API key, and your **Azure AI Speech** key + region. All stored in Keychain.
5. Click **Record**. STT streams to Azure AI Speech; polish/cheatsheet/reply call Azure OpenAI. By default the meeting saves to `~/Library/Containers/dev.mingz.MeetMate/Data/Documents/Sessions/{timestamp}/`. Toggle "Save this meeting" off before recording to skip the save.
6. If the network drops, the app flips to **record-only** mode — audio + raw transcript keep saving, polish jobs queue and replay when back online.

## First run (iPadOS / iOS)

Deferred until the macOS experience is solid. Mic-only RecordView already ships and works for capture, but the polish/cheatsheet pipeline is being designed and tested on macOS first. Same Azure keys will apply when the iOS polish phase lands.

### Offline mode (optional, opt-in)

If you want STT and polish to work fully without network, enable **Settings → Use local models**. WhisperKit downloads ~3 GB; MLX Qwen3-4B downloads ~2.5 GB. First polish call triggers the download (~5–10 min). Local mode is slower and runs the machine hot — prefer cloud for long meetings.

## Build from CLI

```bash
xcodebuild -project MeetMate.xcodeproj -scheme MeetMate -configuration Debug -destination 'platform=macOS' build
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `nullptr == Tap()` precondition crash on Stop+Start | Already fixed in `MicrophoneCapture` (idempotent install/remove). If it returns, check that `tapInstalled` flag is honored. |
| `audioanalyticsd` precondition error in console | Sandbox noise from CoreAudio. Ignore. |
| `throwing -10877` in console | `kAudioUnitErr_InvalidProperty`. CoreAudio probe noise. Ignore. |
| First local Qwen call hangs ~5–10 min | Model is downloading. Only relevant if you enabled local-models offline mode. |
| Azure 401 Unauthorized | Check key + endpoint in Settings. Azure OpenAI endpoint format: `https://{resource}.openai.azure.com/`. AI Speech needs region (e.g. `canadacentral`) not endpoint. |
| Polished pane reads identical to live pane | Polish prompt collapsed back to "drop only" mode. Check `TranscriptPolisher.polishOnce` keeps the editor-rewrite prompt. |

## Free-Apple-ID expiry

Apps signed with a free Apple ID expire after 7 days. To extend, hit Run in Xcode again to re-sign. Or pay $99/yr for the Developer Program.
