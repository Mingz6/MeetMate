# MeetMate Roadmap

Tracked TODOs for features not yet shipped. Check off as they land.

## iOS / iPadOS polish (after proof-of-concept)

- [ ] **Waveform view during recording** — real-time amplitude bars driven off `AudioCaptureService.levels`. Swift Charts or custom `Canvas`.
- [ ] **Waveform during playback** — scrub bar with time cursor.
- [ ] **Trim start/end** — AVFoundation `AVAssetExportSession` with `timeRange`. Save as new recording or overwrite.
- [ ] **Rename meeting** — inline edit on the meeting row, persist via SwiftData.
- [ ] **Folders / favorites** — nested folder model on `Meeting`, star flag.
- [ ] **Search** — full-text search across transcripts using SwiftData `#Predicate` or an in-memory index.
- [ ] **Share-as-bundle** — one share sheet sends `.m4a` + `transcript.txt` + `summary.md` as a single file package (`.meetmate` UTI or just a zip).
- [ ] **Lock-screen controls** — `MPRemoteCommandCenter` for pause/resume, `MPNowPlayingInfoCenter` for artwork + elapsed time.
- [ ] **Background recording keep-alive** — confirm audio session `.playAndRecord` category survives backgrounding; test with screen lock.
- [ ] **Storage management** — per-meeting size display, bulk delete, "clear meetings older than X" setting.

## Cross-platform: sync + cloud

- [ ] **iCloud sync via CloudKit** — meetings recorded on iPhone appear on Mac. SwiftData has CloudKit integration out of the box; needs container ID setup + entitlement.
- [ ] **Audio file sync** — store `.m4a` in `NSUbiquitousContainer` or CloudKit asset, not just SwiftData metadata.
- [ ] **Conflict resolution** — if same meeting edited on two devices, last-write-wins with visible indicator.

## Cloud LLM fallback (BYOK)

For older iPhones (no MLX) and users who want faster summaries.

- [ ] **Settings: "Use cloud AI"** toggle, default OFF.
- [ ] **BYOK key input** — user pastes OpenAI or Anthropic key, stored in Keychain only (never UserDefaults).
- [ ] **Provider abstraction** — `LLMProvider` protocol, two impls: `MLXProvider` (current) + `CloudProvider` (OpenAI `gpt-4o-mini` or Anthropic `claude-haiku`).
- [ ] **Graceful degrade** — if device can't run MLX *and* no cloud key, show "polish unavailable" instead of crashing.
- [ ] **Privacy UX** — persistent badge in the UI when cloud is active ("Cloud AI ON — transcript sent to OpenAI"). No surprises.
- [ ] **STT stays local** — never send raw audio to cloud. Transcript only. Document this clearly.

## Model management

- [ ] **Model download UI** — show size, progress, allow cancel, WiFi-only option.
- [ ] **Model switch at runtime** — let user swap Whisper or LLM model without app restart.
- [ ] **"Delete model" button** — clear disk space without uninstalling app.

## Testing & quality

- [ ] **Unit tests for ModelTier picking** — lock the device-class logic so future changes don't regress low-end devices.
- [ ] **Snapshot tests for RecordView** — three pane states (live empty, polished, topics).
- [ ] **iPhone 12/13 perf baseline** — record 10-min meeting, measure battery drain + thermal state + transcription lag.

## Nice-to-have

- [ ] **Speaker diarization** — "Speaker 1 / Speaker 2" labels in transcript. WhisperKit doesn't do this; would need a separate model.
- [ ] **Multi-language** — detect language, switch Whisper model variants.
- [ ] **Meeting templates** — "standup", "1:1", "customer call" presets with custom cheatsheet prompts.
- [ ] **Calendar integration** — auto-title meetings from EventKit events happening now.
- [ ] **Export to Notion / Obsidian** — send summary as API call or file drop.

## Done

- [x] macOS mic + system audio capture (ScreenCaptureKit)
- [x] WhisperKit streaming sliding-window transcription
- [x] MLX Qwen3 polish + topic summary
- [x] iOS/iPadOS mic-only RecordView
- [x] Device-tier Whisper + LLM model selection
