# Setup

## Prerequisites

- macOS 14 (Sonoma) or newer. macOS is the active target; iOS and iPadOS are deferred.
- Xcode 26 or newer. CI builds with 26.6, and I built from a fresh clone with 27.2.
- The Metal toolchain, once: `xcodebuild -downloadComponent MetalToolchain` (about 840 MB). Xcode 26+ ships it as a separate download, and the MLX package compiles Metal kernels. Without it the build stops with `cannot execute tool 'metal' due to missing Metal Toolchain`.
- For real meetings: an Azure subscription with **Azure OpenAI** (a chat deployment, ideally a second mini deployment) and **Azure AI Speech**. One region for both is simplest.
- Network access during meetings. Cloud is the default for STT and polish.
- About 6 to 11 GB of free disk for the local models (see "Local models" below).

## Try it without Azure

```bash
git clone https://github.com/Mingz6/MeetMate.git
cd MeetMate
xcodebuild -project MeetMate.xcodeproj -scheme MeetMate -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Debug/MeetMate.app --args --demo
```

Swift packages (WhisperKit, mlx-swift-examples) resolve on the first build, pinned by the committed `Package.resolved`. `--demo` plays a made-up meeting and needs no keys, permissions or model downloads.

## Open the project

```bash
open MeetMate.xcodeproj
```

## Capabilities

`MeetMate.entitlements` enables App Sandbox, audio input, camera, outbound network and user-selected files. `Info.plist` carries the microphone, camera and Documents folder usage descriptions.

## Signing

In Xcode, Signing & Capabilities: choose your own team (a free personal team works) and change the bundle identifier `dev.mingz.MeetMate` if it clashes. The project file still names the original author's team, so you must change it to run on a device or a signed build.

## First run

1. Press Run in Xcode.
2. Click Record. macOS asks for microphone access. Allow it.
3. For system audio, macOS asks for screen recording. Allow it, then restart the app.
4. Open Settings and enter your **Azure OpenAI** endpoint (`https://{resource}.openai.azure.com/`), primary deployment name, optional mini deployment name and key. Enter the **Azure AI Speech** region (for example `canadacentral`) and key. Everything is saved to the Keychain.
5. Set your name under Identity. The reply suggestion fires when the transcript contains it. The default is the author's first name.
6. The meeting saves under `MeetMate/Sessions/{yyyy-MM-dd-HHmm}/` in the app's Documents folder: `~/Library/Containers/dev.mingz.MeetMate/Data/Documents/` for a signed build, `~/Documents/` for an unsigned one. Turn off "Save this meeting" before recording to skip it.
7. If the network drops, the status bar switches to record-only mode. Audio and the raw transcript keep saving, and polish jobs replay when the cloud returns.

## Local models

The app loads WhisperKit (`large-v3` on macOS, about 3 GB) and an MLX model at every launch, with or without Azure keys. The MLX model is picked by RAM: Qwen3 14B (about 8 GB) at 32 GB or more, Llama 3.1 8B (about 4.5 GB) at 16 GB or more, Qwen3 4B (about 2.5 GB) below that. Settings, Local LLM lets you pick another one.

The first launch downloads them, which takes 5 to 10 minutes. A failed local load is only reported when no Azure keys are set.

## Build and test from the command line

```bash
# build
xcodebuild -project MeetMate.xcodeproj -scheme MeetMate -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

# unit tests (the UI tests need a GUI session)
xcodebuild -project MeetMate.xcodeproj -scheme MeetMate -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO -skip-testing:MeetMateUITests test
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cannot execute tool 'metal'` during the build | Run `xcodebuild -downloadComponent MetalToolchain` once. |
| `nullptr == Tap()` precondition crash on Stop then Start | Fixed in `MicrophoneCapture` (idempotent install and remove). If it returns, check that the `tapInstalled` flag is honored. |
| `audioanalyticsd` precondition error in the console | Sandbox noise from CoreAudio. Ignore. |
| `throwing -10877` in the console | `kAudioUnitErr_InvalidProperty`. CoreAudio probe noise. Ignore. |
| First launch hangs for minutes | The local models are downloading. |
| Azure 401 Unauthorized | Check the key and endpoint in Settings. AI Speech wants a region, not an endpoint. |
| Polished pane reads the same as the live pane | The polish prompt fell back to drop-only mode. Check that `TranscriptPolisher.polishOnce` keeps the editor-rewrite prompt. |
| Cost log shows 0 for a custom deployment name | Map it to a priced model: `defaults write dev.mingz.MeetMate deploymentModelMap -dict my-deployment gpt-5.4` (lowercase name). |

## Free Apple ID expiry

Apps signed with a free Apple ID expire after 7 days. Run again from Xcode to re-sign, or join the Developer Program.
