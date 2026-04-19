# MeetMate

Local-first macOS meeting assistant. Real-time transcription, live cheatsheet, polished transcript, reply suggestions — all on-device, no cloud, no API keys.

## Stack

- **UI:** SwiftUI (macOS 14+)
- **Speech-to-text:** [WhisperKit](https://github.com/argmaxinc/WhisperKit) — `openai_whisper-large-v3`
- **LLM:** [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) — `mlx-community/Qwen3-14B-4bit`
- **Audio capture:** AVAudioEngine (mic) + ScreenCaptureKit `SCStream` (system audio)
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
