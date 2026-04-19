# MeetMate — Copilot Instructions

## Project Context
Local-first macOS meeting assistant. Captures mic + system audio, transcribes via WhisperKit, polishes the transcript and generates a rolling cheatsheet via on-device Qwen3-14B (MLX). Everything runs on-device — no cloud, no API keys, no telemetry.

## Tech Stack
- **Language**: Swift 5.9+
- **UI**: SwiftUI, macOS 14+ (Sonoma) — macOS only, not iOS/iPadOS
- **STT**: [WhisperKit](https://github.com/argmaxinc/WhisperKit) — `openai_whisper-large-v3`
- **LLM**: [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) — `mlx-community/Qwen3-14B-4bit` via `LLMModelFactory`
- **Audio**: AVAudioEngine (mic) + CoreAudio process tap / HAL aggregate device (system audio loopback)
- **Storage**: SwiftData
- **Build**: Xcode project (`MeetMate.xcodeproj`), no SwiftPM at root

## Project Structure
```
MeetMate/
├── MeetMateApp.swift                App entry
├── MeetMate.entitlements            Mic + audio-input + sandbox
├── Info.plist                       Mic + screen-capture usage strings
├── Audio/
│   ├── AudioCaptureService.swift    Merges mic + system audio
│   ├── MicrophoneCapture.swift      AVAudioEngine; idempotent tap install/remove
│   └── SystemAudioCapture.swift     CoreAudio HAL loopback
├── Transcription/
│   └── TranscriptionService.swift   Streaming sliding-window WhisperKit
├── Summarization/
│   ├── LLMService.swift             MLX Qwen3-14B-4bit loader + generate()
│   ├── TranscriptPolisher.swift     25s cycle → JSON {finalized, draft}
│   ├── CheatsheetGenerator.swift    Rolling topic / key points / questions / actions
│   └── ReplyGenerator.swift         Name-mention watcher
├── Models/Meeting.swift             SwiftData model
└── Views/                           MainView + 4 panes
docs/                                Architecture + setup notes
```

## Build & Run
```bash
xcodebuild -project MeetMate.xcodeproj -scheme MeetMate -configuration Debug -destination 'platform=macOS' build
```
Run from Xcode (⌘R) — needs mic + screen-recording permission grants in System Settings on first launch.

## Conventions
- SwiftUI views co-locate state via `@StateObject` / `@Published` services injected from `MainView.init`.
- Long-running services (`AudioCaptureService`, `TranscriptionService`, `LLMService`) are `ObservableObject`s with `@MainActor`-bound mutable state.
- Logs use `print("[<Component>] message")` — no logging framework.
- All file paths under the app sandbox: `~/Library/Containers/dev.mingz.MeetMate/Data/`.

## Key Patterns
- **Streaming Whisper sliding-window** (`TranscriptionService`): mirrors WhisperKit's `AudioStreamTranscriber` — confirmed/unconfirmed split, `clipTimestamps: [lastConfirmedSec - purgedDurationSec]`, `requiredForConfirmation: 2`, VAD-gated by RMS, 90s buffer with 30s retention. Don't replace with batch chunking — accuracy regresses badly.
- **Idempotent mic capture** (`MicrophoneCapture`): `tapInstalled` flag + early-exit if `engine.isRunning` + defensive `removeTap` before install. Prevents `nullptr == Tap()` precondition crash on start/stop/restart.
- **Qwen3 `/no_think`**: every LLM prompt ends with `/no_think` to skip Qwen3's `<think>` reasoning tokens. `LLMService.stripThinking()` is a belt-and-suspenders cleanup if any leak through.
- **JSON-from-LLM extraction**: prompts ask for `{...}` only; `parseResponse` slices first-`{` to last-`}` substring before `JSONSerialization` — survives stray prose.
- **Polisher contract**: `{"finalized": ["paragraph", ...], "draft": "trailing thought"}`. Cycle: 25s, min 6 segments. Prompt is editor-mode (allows light paraphrasing) — do NOT revert to "drop only" prompt; output becomes pass-through.

## Gotchas
- Model cache lives at `~/Library/Containers/dev.mingz.MeetMate/Data/Library/Caches/models/mlx-community/Qwen3-14B-4bit/`. Pre-download with `hf download mlx-community/Qwen3-14B-4bit --local-dir . --max-workers 8` from inside that dir to skip 15-minute first-run.
- App Sandbox is enabled — `audioanalyticsd` precondition errors in console are noise; ignore.
- WhisperKit segments arrive every 1.5s tick; the last 2 segments stay in `unconfirmedText` and re-decode each tick. Segments before that are immutable in `confirmedTranscript`.
- Hallucination blocklist in `TranscriptionService.applySegments` drops "Thank you", "you", ".", "-" — Whisper hallucinates these on silence.
- Don't add features that require network. The whole point is local-first.
