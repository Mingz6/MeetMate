# MeetMate

Local-first macOS meeting assistant. Real-time transcription, live cheatsheet, polished transcript, reply suggestions — all on-device, no cloud, no API keys.

## Stack

- **UI:** SwiftUI (macOS 14+)
- **Speech-to-text:** [WhisperKit](https://github.com/argmaxinc/WhisperKit) — `openai_whisper-large-v3`
- **LLM:** [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) — `mlx-community/Qwen3-14B-4bit`
- **Audio capture:** AVAudioEngine (mic) + CoreAudio HAL aggregate device (system audio)
- **Storage:** SwiftData

## Project Structure

```
MeetMate/
├── MeetMateApp.swift           App entry
├── MeetMate.entitlements       Sandbox + mic + audio input
├── Audio/                      Mic + system audio capture
├── Transcription/              WhisperKit streaming sliding window
├── Summarization/              MLX LLM, polisher, cheatsheet, reply
├── Models/Meeting.swift        SwiftData
└── Views/                      MainView + 4 panes
docs/                           Architecture + setup
```

See [.github/copilot-instructions.md](.github/copilot-instructions.md) for the full architecture brief Copilot uses on this repo.

## Build & Run

```bash
xcodebuild -project MeetMate.xcodeproj -scheme MeetMate -configuration Debug -destination 'platform=macOS' build
```

Or open `MeetMate.xcodeproj` in Xcode and ⌘R.

First launch will prompt for microphone + screen recording permissions. Grant both.

## First-Run Model Download

WhisperKit downloads `openai_whisper-large-v3` (~3 GB) automatically on first launch. The MLX Qwen3-14B-4bit model (~8 GB) downloads on first LLM use.

To pre-download Qwen and skip the 15-minute wait:

```bash
mkdir -p ~/Library/Containers/dev.mingz.MeetMate/Data/Library/Caches/models/mlx-community/Qwen3-14B-4bit
cd ~/Library/Containers/dev.mingz.MeetMate/Data/Library/Caches/models/mlx-community/Qwen3-14B-4bit
hf download mlx-community/Qwen3-14B-4bit --local-dir . --max-workers 8
```

## Documentation

- [docs/architecture.md](docs/architecture.md) — system diagram and data flow
- [docs/setup.md](docs/setup.md) — local dev setup
- [docs/phase-0-checklist.md](docs/phase-0-checklist.md) — original validation checklist (historical)

## License

[MIT](LICENSE).
# MeetMate

Local-first meeting assistant for macOS and iPadOS. Real-time transcription, live cheatsheet, reply suggestions, post-meeting summaries. All on-device, no cloud, no paid services.

**Status:** scaffolded, not yet implemented. See [../meeting-assistant-plan.md](../meeting-assistant-plan.md) for the build plan.

## Stack

- **UI:** SwiftUI (macOS 14+ / iPadOS 17+)
- **Speech-to-text:** [WhisperKit](https://github.com/argmaxinc/WhisperKit)
- **LLM:** [MLX Swift](https://github.com/ml-explore/mlx-swift-examples) running Qwen3 4B
- **Audio capture:** ScreenCaptureKit (macOS system audio) + AVAudioEngine (mic)
- **Storage:** SwiftData

## Project Structure

```
MeetMate/
├── MeetMateApp.swift           App entry point
├── Audio/                      Audio capture (mic + system audio)
│   ├── AudioCaptureService.swift
│   ├── MicrophoneCapture.swift
│   └── SystemAudioCapture.swift     macOS only
├── Transcription/              WhisperKit integration
│   ├── TranscriptionService.swift
│   └── TranscriptBuffer.swift
├── Summarization/              MLX LLM integration
│   ├── LLMService.swift
│   ├── CheatsheetGenerator.swift
│   └── ReplyGenerator.swift
├── Storage/                    SwiftData models + meeting archive
│   └── MeetingStore.swift
├── Models/                     Data models (Meeting, Transcript, Cheatsheet)
├── Views/                      SwiftUI views
│   ├── MainView.swift
│   ├── CheatsheetView.swift
│   ├── TranscriptView.swift
│   └── SettingsView.swift
└── Resources/
    └── Assets.xcassets
```

## Setup (after Xcode is installed)

1. Open `MeetMate.xcodeproj` in Xcode (TODO: create via Xcode wizard, see [docs/setup.md](docs/setup.md))
2. Add Swift Package dependencies:
   - `https://github.com/argmaxinc/WhisperKit`
   - `https://github.com/ml-explore/mlx-swift-examples`
3. Sign with your Apple ID (free) under Signing & Capabilities
4. Build and run on Mac or iPad

## Phase 0 Validation

Before writing app code, confirm the building blocks work:

```bash
# Clone and run reference demos
cd ~/code/oss
git clone https://github.com/argmaxinc/WhisperKit
git clone https://github.com/ml-explore/mlx-swift-examples
```

Open each in Xcode, run the demo on Mac and iPad, benchmark performance. See [docs/phase-0-checklist.md](docs/phase-0-checklist.md).

## License

Personal use. MIT for any open-source pieces.
