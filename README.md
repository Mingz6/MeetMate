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
