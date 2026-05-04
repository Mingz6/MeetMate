# MeetMate

Cloud-first meeting assistant for Apple platforms. Real-time transcription, live cheatsheet, polished transcript, reply suggestions — powered by Azure with on-device fallbacks when offline.

**Status:** macOS is the active target. iPadOS and iOS are kept as design constraints (one codebase, narrow platform divergence) and will be polished as a follow-up phase once the macOS experience is solid.

## Stack

- **UI:** SwiftUI (macOS 14+, iPadOS 17+, iOS 17+)
- **Speech-to-text (primary):** Azure AI Speech — live continuous recognition + batch transcription
- **Speech-to-text (offline fallback):** [WhisperKit](https://github.com/argmaxinc/WhisperKit)
- **LLM (primary):** Azure OpenAI — polish, cheatsheet, reply
- **LLM (offline fallback, opt-in):** [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) — `mlx-community/Qwen3-4B-4bit`
- **Audio capture:** AVAudioEngine (mic, all platforms) + ScreenCaptureKit (system audio, macOS only)
- **Storage:** SwiftData + session folder on disk

## Operating modes

1. **Cloud (default)** — STT + LLM both go to Azure. One resource, one auth, one bill.
2. **Record-only** — no network or 3 consecutive cloud failures → keep capturing audio + raw transcript to disk; polish/cheatsheet jobs queue and replay when back online.
3. **Local fallback (opt-in)** — user enables on-device WhisperKit + MLX Qwen3 in Settings. Slower, runs the machine hot, but works fully offline.

## Project Structure

```
MeetMate/
├── MeetMateApp.swift           App entry
├── MeetMate.entitlements       Sandbox + mic + audio input
├── Audio/                      Mic + system audio capture
├── Transcription/              Azure Speech client + WhisperKit fallback
├── Summarization/              Azure OpenAI client, polisher, cheatsheet, reply
├── Models/Meeting.swift        SwiftData
└── Views/                      MainView + 4 panes
docs/                           Architecture, setup, roadmap
```

See [.github/copilot-instructions.md](.github/copilot-instructions.md) for the architecture brief Copilot uses on this repo.

## Build & Run

```bash
xcodebuild -project MeetMate.xcodeproj -scheme MeetMate -configuration Debug -destination 'platform=macOS' build
```

Or open `MeetMate.xcodeproj` in Xcode and ⌘R.

First launch will prompt for microphone + screen recording permissions. Grant both, then paste your Azure OpenAI + Azure AI Speech keys in Settings (stored in Keychain). Full steps in [docs/setup.md](docs/setup.md).

## Documentation

- [docs/ROADMAP.md](docs/ROADMAP.md) — single source of truth for forward work
- [docs/architecture.md](docs/architecture.md) — system diagram and data flow
- [docs/setup.md](docs/setup.md) — local dev setup

## Privacy

When cloud mode is active:
- **Audio** is streamed to Azure AI Speech for transcription. Microsoft retains no data beyond the session. See [Azure Speech data privacy](https://learn.microsoft.com/azure/ai-services/speech-service/speech-services-data-security-privacy).
- **Speaker diarization** (batch re-transcription) sends the full audio file to Azure's Fast Transcription API. Audio is processed in-region and not stored after the response.
- **Transcript + screen frames** are sent to Azure OpenAI for polishing, cheatsheet, and vision analysis. Data is not used for model training on Azure OpenAI resources.
- **No telemetry** is sent anywhere. No analytics SDK is bundled.
- **Local fallback mode** keeps everything on-device — nothing leaves the machine.

All credentials are stored in Keychain. Session data lives in `~/Documents/MeetMate/Sessions/`.

## License

[MIT](LICENSE).
