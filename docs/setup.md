# Setup Guide

## Prerequisites

- macOS 14+ (Sonoma)
- Xcode 15+
- ~12 GB free disk for Whisper + Qwen models

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

## First run

1. ⌘R in Xcode.
2. macOS will prompt for microphone permission — allow.
3. macOS will prompt for screen recording (needed for system audio loopback) — allow, then restart the app.
4. WhisperKit auto-downloads `openai_whisper-large-v3` (~3 GB, 1–5 min).
5. Click **Record**. The first cheatsheet/polish call triggers the Qwen3 download (~8 GB, ~15 min). Pre-download instructions in the [README](../README.md#first-run-model-download) skip this wait.

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
| First Qwen call hangs ~15 min | Model is downloading. Pre-download via the README instructions. |
| Polished pane reads identical to live pane | Polish prompt collapsed back to "drop only" mode. Check `TranscriptPolisher.polishOnce` keeps the editor-rewrite prompt. |

## Free-Apple-ID expiry

Apps signed with a free Apple ID expire after 7 days. To extend, hit Run in Xcode again to re-sign. Or pay $99/yr for the Developer Program.
