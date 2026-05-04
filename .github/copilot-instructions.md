# MeetMate — Copilot Instructions

## Project Context
Cloud-first macOS meeting assistant. Captures mic + system audio (+ optional webcam), transcribes via Azure AI Speech (live WebSocket) with local WhisperKit as offline fallback, polishes transcript and generates a rolling cheatsheet via Azure OpenAI (with optional local MLX Qwen3 fallback). Recordings, transcripts, and polish are saved to disk automatically.

## Tech Stack
- **Language**: Swift 5.9+
- **UI**: SwiftUI, macOS 14+ (Sonoma) — macOS primary, iPadOS/iOS deferred
- **STT (primary)**: Azure AI Speech — pure Swift WebSocket continuous recognition (`wss://{region}.stt.speech.microsoft.com`)
- **STT (fallback)**: [WhisperKit](https://github.com/argmaxinc/WhisperKit) — `openai_whisper-large-v3-turbo` for offline batch, sliding-window for live
- **LLM (primary)**: Azure OpenAI Chat Completions — per-task routing (mini deployment for polish/cheatsheet, primary for quality-sensitive tasks)
- **LLM (fallback)**: [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) — `mlx-community/Qwen3-4B-4bit` via `LLMModelFactory`
- **Audio**: AVAudioEngine (mic) + ScreenCaptureKit `SCStream` (system audio loopback)
- **Video**: ScreenCaptureKit (screen frames) + AVCaptureSession (webcam)
- **Storage**: SwiftData for Meeting model, file-based SessionStorage (`~/Documents/MeetMate/Sessions/`)
- **Build**: Xcode project (`MeetMate.xcodeproj`), SPM for packages

## Project Structure
```
MeetMate/
├── MeetMateApp.swift                App entry
├── MeetMate.entitlements            Sandbox: mic, camera, network, files
├── Info.plist                       Usage descriptions (mic, camera, documents)
├── Audio/
│   ├── AudioCaptureService.swift    Merges mic + system audio, levels
│   ├── MicrophoneCapture.swift      AVAudioEngine; idempotent tap install/remove
│   ├── SystemAudioCapture.swift     ScreenCaptureKit SCStream loopback
│   ├── FrameCaptureService.swift    Screen frame capture via SCStream (1-5fps)
│   └── WebcamCaptureService.swift   AVCaptureSession webcam frames
├── Cloud/
│   ├── AzureOpenAIProvider.swift    Azure OpenAI Chat Completions (task-routed)
│   ├── KeychainHelper.swift         Keychain CRUD for API credentials
│   ├── LLMProvider.swift            Protocol + LLMTask enum + LLMResult
│   ├── ReachabilityMonitor.swift    NWPathMonitor wrapper + failure tracking
│   └── ReplayQueue.swift            Disk-backed offline retry queue
├── Context/
│   ├── ContextService.swift         URL/PDF/text pre-meeting context
│   └── VocabularyExtractor.swift    Extract terms for phrase biasing
├── Models/
│   ├── Meeting.swift                SwiftData model
│   └── PolishedParagraph.swift      Stable ID + version + timestamps
├── Storage/
│   └── SessionStorage.swift         File-based session I/O (audio, frames, JSONL)
├── Summarization/
│   ├── LLMService.swift             Provider-routed service (cloud → local → recording-only)
│   ├── TranscriptPolisher.swift     25s live polish + re-polish + batch accept
│   ├── CheatsheetGenerator.swift    Rolling topic summary
│   ├── ReplyGenerator.swift         Name-mention reply suggestions
│   └── VisionService.swift          Screen frame + transcript → vision analysis
├── Transcription/
│   ├── AzureSpeechSTT.swift         WebSocket continuous recognition
│   ├── BatchReTranscriber.swift     Post-meeting re-transcription (cloud or local)
│   ├── STTProvider.swift            STT protocol
│   ├── TranscriptionService.swift   Orchestrates live STT + segment storage
│   └── VADGate.swift                RMS-based voice activity detection
└── Views/
    ├── MainView.swift               Main orchestrator view
    ├── SettingsView.swift            Credentials + preferences
    ├── PolishedTranscriptView.swift  Polished text with timestamps
    ├── CheatsheetView.swift          Topic summary display
    ├── TranscriptView.swift          Live raw transcript
    ├── ContextPane.swift             Pre-meeting context input
    ├── ProviderStatusBar.swift       Cloud/local/offline status + cost
    ├── STTStatusIndicator.swift      STT mode indicator
    ├── BatchReTranscriptionBanner.swift  "Improved transcript ready" UI
    └── RecordView.swift              iOS/iPadOS mic-only (deferred)
docs/                                 Architecture + setup + roadmap
```

## Build & Run
```bash
xcodebuild -project MeetMate.xcodeproj -scheme MeetMate -configuration Debug -destination 'platform=macOS' build
```
Run from Xcode (⌘R) — needs mic + camera + screen-recording permission grants in System Settings on first launch.

## Conventions
- SwiftUI views co-locate state via `@StateObject` / `@Published` services injected from `MainView.init`.
- Long-running services are `ObservableObject`s with `@MainActor`-bound mutable state.
- Session-token cancel pattern: increment `sessionToken` on start/stop, guard `token == sessionToken` after every `await`.
- Logs use `print("[<Component>] message")` — no logging framework.
- API credentials stored in macOS Keychain via `KeychainHelper`, never in UserDefaults.
- `LLMTask` enum routes calls: `.polish`/`.cheatsheet` → mini deployment, `.rePolish`/`.batchPolish`/`.vision`/`.reply` → primary deployment.

## Key Patterns
- **Azure Speech WebSocket STT** (`AzureSpeechSTT`): dual recognizers (mic + system), phrase list biasing, speaker diarization via `SpeakerId` in phrase results.
- **Streaming Whisper sliding-window** (`TranscriptionService`): offline fallback — confirmed/unconfirmed split, `clipTimestamps`, `requiredForConfirmation: 2`, VAD-gated by RMS, 90s buffer with 30s retention.
- **Idempotent mic capture** (`MicrophoneCapture`): `tapInstalled` flag + early-exit if `engine.isRunning` + defensive `removeTap` before install.
- **Qwen3 `/no_think`**: every local LLM prompt ends with `/no_think`. `LLMService.stripThinking()` cleans any leaked `<think>` tokens.
- **JSON-from-LLM extraction**: prompts ask for `{...}` only; `parseResponse` slices first-`{` to last-`}` before `JSONSerialization`.
- **Polisher contract**: `{"finalized": [{"id": "p_000123", "text": "...", "startSec": 12.3, "endSec": 18.7, "version": 1}], "draft": "..."}`. Stable IDs assigned by Swift, not LLM.
- **Replay queue**: offline polish/cheatsheet jobs written to disk, drained automatically when cloud comes back.
- **Batch re-transcription**: Fast Transcription API (cloud) or WhisperKit `transcribe(audioPath:)` (local) — runs on meeting stop, produces diarized transcript with accept/reject UI.

## Gotchas
- WhisperKit is pinned to `main` branch (no release tag) — fragile, update carefully.
- App Sandbox is enabled — `audioanalyticsd` precondition errors in console are noise; ignore.
- Model cache lives at `~/Library/Containers/dev.mingz.MeetMate/Data/Library/Caches/models/`.
- `ReachabilityMonitor` uses NWPathMonitor + a 3-failure circuit breaker — don't test cloud availability by making a real API call.
- `SessionStorage` writes to `~/Documents/MeetMate/Sessions/{YYYY-MM-DD-HHmm}/` — the path is derived from `Meeting.startedAt`, not configurable.
- Hallucination blocklist in `TranscriptionService.applySegments` drops "Thank you", "you", ".", "-" — Whisper hallucinates these on silence.
