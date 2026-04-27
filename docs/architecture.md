# Architecture

```
                 ┌─────────────────────────────────────────────┐
                 │              MeetMateApp (SwiftUI)          │
                 └────────────┬────────────────────────────────┘
                              │
                  ┌───────────┴───────────┐
                  │     MainView          │
                  │  Start / Stop button  │
                  └───────────┬───────────┘
                              │
        ┌─────────────────────┼─────────────────────────┐
        │                     │                         │
        ▼                     ▼                         ▼
┌────────────────┐   ┌──────────────────┐    ┌──────────────────┐
│ AudioCapture   │   │ TranscriptionSvc │    │   LLMService     │
│ ───────────    │   │ ─────────────    │    │ ─────────────    │
│ • Mic (AVAud)  │──▶│ • Azure Speech   │───▶│ • Azure OpenAI   │
│ • SystemAudio  │   │   (cloud primary)│    │   primary path   │
│   (SCKit, Mac) │   │ • WhisperKit     │    │ • MLX Qwen3-4B   │
│                │   │   (offline fb)   │    │   opt-in offline │
└────────────────┘   └──────────────────┘    │                  │
                                       └────────┬─────────┘
                                                      │
                              ┌───────────────────────┴────────┐
                              │                                │
                              ▼                                ▼
                  ┌──────────────────────┐         ┌──────────────────────┐
                  │ CheatsheetGenerator  │         │   ReplyGenerator     │
                  │ ──────────────       │         │ ─────────────        │
                  │ • Every 30s          │         │ • Watch for "Ming?"  │
                  │ • Topic, points,     │         │ • On trigger, gen    │
                  │   actions            │         │   2-3 sentence reply │
                  └──────────┬───────────┘         └──────────┬───────────┘
                             │                                │
                             └─────────────┬──────────────────┘
                                           ▼
                              ┌────────────────────────┐
                              │      CheatsheetView    │
                              │  (floating window on   │
                              │   Mac, side panel on   │
                              │   iPad)                │
                              └────────────────────────┘

         ┌─────────────────────────────────────────────────────────┐
         │ During meeting (save-by-default): audio + transcript + polish    │
         │ + cheatsheet flushed continuously to                              │
         │ ~/Library/Containers/dev.mingz.MeetMate/Data/Documents/Sessions/  │
         │ {YYYY-MM-DD-HHmm}/. Pre-record toggle can opt out per meeting.    │
         │ SwiftData Meeting row points at the session folder.               │
         └─────────────────────────────────────────────────────────┘
```

## Threading model

- **Main actor:** all UI + service coordinators
- **Background:** audio capture (AVAudioEngine has its own thread), WhisperKit inference (its own queue), MLX inference (its own queue)
- All cross-actor communication via `@Published` properties + Swift concurrency

## Data flow

1. `AudioCaptureService` produces `AVAudioPCMBuffer` chunks (mic + system mixed)
2. Buffers pushed into `TranscriptionService` ring buffer **and** written incrementally to `Sessions/{id}/audio.m4a`
3. Every 1-2s, full chunk fed to `WhisperKit.transcribe()` → text segment
4. Confirmed segments appended to `liveTranscript` + `transcript.jsonl` (flushed every N seconds) + saved as `TranscriptSegment` in SwiftData
5. `TranscriptPolisher` calls the configured `LLMProvider` (cloud by default, local MLX if user opted in) → polished paragraphs appended to `polished.md` and `paragraphs.jsonl`
6. `CheatsheetGenerator` polls `liveTranscript` every 30s, asks LLM for structured summary → `cheatsheet.md` snapshot per cycle
7. `ReplyGenerator` polls `liveTranscript` every 2s, scans for user's name, triggers reply on match
8. **Cloud unreachable** → reachability detector flips to `recordingOnly` mode: audio + raw transcript still saving, polish/cheatsheet jobs queued to disk and replayed when network returns
9. UI binds to `@Published` state, redraws automatically
10. **Save-by-default**: meeting persists to disk during recording, not just on stop. Pre-record toggle lets user opt out (writes to temp folder, deleted on stop).

## Cross-platform support

One codebase, three targets. **macOS is the active target**; iPadOS and iOS are design constraints today and a polish phase later. Every design decision must stay portable — no macOS-only data models, no Swift packages that won't compile on iOS.

| Concern | macOS (active) | iPadOS (port phase) | iOS (port phase) |
|---|---|---|---|
| Status | ✅ shipping | 🔜 mic-only RecordView ships, polish queued | 🔜 mic-only RecordView ships, polish queued |
| System audio | ScreenCaptureKit | not available (mic only) | not available (mic only) |
| Window | floating + click-through | regular window or Slide Over | full-screen |
| Background recording | always allowed | requires `.playAndRecord` audio session | requires `.playAndRecord` + Background Modes capability |
| Settings | separate Settings scene | sheet inside MainView | sheet inside MainView |
| Cloud STT + LLM (Azure) | full | full | full |
| Local WhisperKit + MLX (opt-in) | full | M-series only | A17 Pro+ only |
