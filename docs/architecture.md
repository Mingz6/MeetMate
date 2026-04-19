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
│ • Mic (AVAud)  │──▶│ • WhisperKit     │───▶│ • MLX Swift      │
│ • SystemAudio  │   │ • 16kHz chunks   │    │ • Qwen3-4B Q4    │
│   (SCKit, Mac) │   │ • Live segments  │    │ • Streaming      │
└────────────────┘   └──────────────────┘    └────────┬─────────┘
                                                      │
                              ┌───────────────────────┴────────┐
                              │                                │
                              ▼                                ▼
                  ┌──────────────────────┐         ┌──────────────────────┐
                  │ CheatsheetGenerator  │         │   ReplyGenerator     │
                  │ ──────────────       │         │ ─────────────        │
                  │ • Every 60s          │         │ • Watch for "Ming?"  │
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
         │ End of meeting: final summary → SwiftData + markdown    │
         │ file saved to ~/code/crna/meetings/{date}-{slug}.md     │
         └─────────────────────────────────────────────────────────┘
```

## Threading model

- **Main actor:** all UI + service coordinators
- **Background:** audio capture (AVAudioEngine has its own thread), WhisperKit inference (its own queue), MLX inference (its own queue)
- All cross-actor communication via `@Published` properties + Swift concurrency

## Data flow

1. `AudioCaptureService` produces `AVAudioPCMBuffer` chunks (mic + system mixed)
2. Buffers pushed into `TranscriptionService` ring buffer
3. Every 1-2s, full chunk fed to `WhisperKit.transcribe()` → text segment
4. Text appended to `liveTranscript` + saved as `TranscriptSegment` in SwiftData
5. `CheatsheetGenerator` polls `liveTranscript` every 60s, asks LLM for structured summary
6. `ReplyGenerator` polls `liveTranscript` every 2s, scans for user's name, triggers reply on match
7. UI binds to `@Published` state, redraws automatically
8. On stop: meeting + segments persisted, final summary written to disk

## Cross-platform divergence

| Concern | macOS | iPadOS |
|---------|-------|--------|
| System audio | ScreenCaptureKit | not implemented (mic only) |
| Window | floating + click-through | regular window or Slide Over |
| Background | always allowed | requires audio session config |
| Settings | separate Settings scene | inside MainView as sheet |
