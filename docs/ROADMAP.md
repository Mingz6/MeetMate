# MeetMate Roadmap

Single source of truth for forward work. Active sprint at the top, backlog below.

## Direction (April 2026)

Cloud-first for both **STT and LLM**, both on **Azure** (AI Speech + Azure OpenAI — one resource, one auth, one bill). Network required for live polish/cheatsheet/reply and live transcription. Local WhisperKit + local MLX stay as offline-mode fallbacks only, not the default. When cloud is unreachable, MeetMate keeps recording audio so nothing is lost — STT and polish replay when the network comes back.

**Phasing:** macOS first. Get it working perfectly there before polishing iPadOS/iOS. But every design decision has to stay portable — one codebase, no macOS-only data models, no APIs we can't swap on the iOS side. iPadOS/iOS targets exist today (mic-only RecordView ships) but are explicitly a follow-up phase, not parallel work.

## Active sprint (2026-Q2)

Captured from the 2026-04-22 paper-reading meeting where the live transcript almost got lost and the M3 Max throttled hard during polish.

### 1. Auto-save audio + transcript to disk

By default the meeting is saved (audio + transcript + polish + cheatsheet). User can opt out per meeting via a "Don't save" toggle before recording starts.

- [ ] Storage layout: `~/Library/Containers/dev.mingz.MeetMate/Data/Documents/Sessions/{YYYY-MM-DD-HHmm}/`
- [ ] Save raw mic + system audio incrementally as `.m4a` (not held in RAM)
- [ ] `transcript.jsonl` — confirmed Whisper segments + timestamps, flushed every N seconds
- [ ] `polished.md` — append-only after each polish cycle
- [ ] `cheatsheet.md` — snapshot per cycle
- [ ] On crash/quit, last-saved state survives — verify with `kill -9`
- [ ] "Show in Finder" button for the active session folder (macOS) / Files share sheet (iOS/iPadOS)
- [ ] Update SwiftData `Meeting` to point at the session folder path
- [ ] **Pre-record toggle**: "Save this meeting" — default ON. When OFF, write to a temp folder and delete on stop.

### 2. Cloud LLM as primary, audio-only fallback

Cloud is the new default. When the network is gone, MeetMate keeps capturing audio + raw transcript and skips polish. Polish replays from the saved transcript when back online.

- [ ] `LLMProvider` protocol — `AzureOpenAIProvider` (primary) + optional `LocalMLXProvider` (kept as opt-in nice-to-have for offline-by-choice users)
- [ ] Primary cloud provider: **Azure OpenAI** (same Azure resource as AI Speech). Protocol stays open for Anthropic/Gemini later if needed.
- [ ] Settings: Azure endpoint + deployment name + API key entry, store in **Keychain** (NOT UserDefaults)
- [ ] Per-task provider routing: polish vs cheatsheet vs reply vs re-polish can use different model tiers
- [ ] Streaming response support (SSE) so UI stays responsive
- [ ] **Reachability + failure handling** — 3 consecutive failures (timeout / 5xx / no network) → flip to `recordingOnly` mode, show banner: "Offline — audio + raw transcript still saving, polish paused"
- [ ] **Replay queue** — while offline, queue polish/cheatsheet jobs to disk; drain when back online against the saved transcript
- [ ] Manual "Pause cloud calls" toggle in UI for cost-sensitive moments
- [ ] Cost meter — approx tokens-in/out per session
- [ ] Privacy disclosure in onboarding + README — "Audio is streamed to Azure AI Speech for transcription. Transcript text is sent to Azure OpenAI for polishing. Local-only mode available in Settings (slower, requires model downloads)."
- [x] Update README — dropped "no cloud, no API keys" headline; reframed as cloud-first with offline fallbacks

### 3. Pre-meeting context input

- [ ] "Context" pane in MainView with text area + URL field
- [ ] URL fetch: download page, strip to readable text
- [ ] PDF drop support — extract text from a paper
- [ ] Inject context as system prompt prefix into polish + cheatsheet + reply
- [ ] Persist `context.md` in the session folder
- [ ] Token budget guard — truncate if too long, warn user

### 4. Video capture ("eyes")

- [ ] Extend ScreenCaptureKit `SCStream` with video output (already on the stream for audio)
- [ ] Sample frames at low rate (1 fps or every 5s) — control disk + LLM cost
- [ ] Save frames as JPEG in `Sessions/{id}/frames/` with timestamp filenames
- [ ] Optional webcam input via AVCaptureSession
- [ ] Vision LLM call — recent frame + transcript snippet → "what's on screen now" cheatsheet enrichment
- [ ] UI toggle: video off by default (privacy + cost)
- [ ] Storage cap — auto-prune frames older than N hours

### 5. Timestamps + stable paragraph IDs on polished transcript

Critical: this builds the contract that #6 re-polish will mutate. Get the IDs right the first time so #6 doesn't force a second contract migration.

- [ ] Pass Whisper segment timestamps through to the polish prompt
- [ ] Polish JSON contract: `{"finalized": [{"id": "p_000123", "text": "...", "startSec": 12.3, "endSec": 18.7, "version": 1}], "draft": "..."}`
- [ ] **Stable IDs assigned by Swift**, not the LLM (LLMs forget IDs across calls). Format `p_{6-digit zero-padded}`, monotonic per session, never reused.
- [ ] **Version field** ships in #5 even though it stays at 1 until #6. Avoids contract migration later.
- [ ] Persist `paragraphs.jsonl` (one paragraph per line, append-only) alongside `polished.md`
- [ ] Render `[mm:ss]` prefix in the polished pane
- [ ] Click a timestamp → seek the saved audio file (needs audio playback UI)
- [ ] Backfill: when polisher merges 6 segments into 2 paragraphs, take start of first + end of last

### 6. Retroactive re-polish

Depends on #5 (stable IDs + version field) and #2 (cloud LLM). Re-polish never invents IDs — only references existing ones.

- [ ] Trigger: every N cycles, take the last K finalized paragraphs by ID + new context, ask LLM to revise
- [ ] Polish JSON gains `revisions`: `[{"replaceIds": ["p_000003","p_000004"], "newText": "...", "reason": "speaker corrected themselves"}]`
- [ ] Append to `paragraphs.jsonl` as new versions (append-only, same `id`, bumped `version`)
- [ ] UI: strikethrough old + new text, accept/reject
- [ ] Edit trail view — click a paragraph to see all versions
- [ ] Test case: "I want to buy an apple. Well, banana is better." → "Speaker decided on banana over apple."
- [ ] Bound the re-polish window (last 5 paragraphs)
- [ ] Cloud-only — skip in `recordingOnly` mode

### 7. App icon

- [ ] Design icon — mic + brain or speech bubble + sparkle
- [ ] Full icon set: 16/32/64/128/256/512/1024 @1x and @2x
- [ ] Drop into `MeetMate/Assets.xcassets/AppIcon.appiconset/`
- [ ] Verify in Finder + Dock + ⌘-Tab + About panel
- [ ] Add to README screenshots

### 8. Transcription quality — Azure AI Speech, VAD, offline re-transcribe pass

The biggest accuracy gap today is STT, not the LLM. Live `large-v3` streaming on M3 Max throttles, hallucinates on silence, and butchers domain terms (e.g. "KV cache" → "KB cache"). Five layers fix this, all on a single provider.

**Provider choice: Azure AI Speech** — same vendor as the LLM (Azure OpenAI), one resource, one auth flow, one billing line. Native Swift SDK. Live streaming + batch transcription + phrase lists + diarization all included. Local WhisperKit stays as the offline-mode fallback only — no Whisper-on-cloud second provider needed.

#### 8a. Cloud STT (primary path) — Azure AI Speech

- [ ] `STTProvider` protocol — mirror `LLMProvider` shape
- [ ] Wire **Microsoft Cognitive Services Speech SDK** for Swift (`MicrosoftCognitiveServicesSpeech` xcframework)
- [ ] Use `SPXSpeechRecognizer` continuous recognition over WebSocket for live
- [ ] API key + region in Keychain alongside Azure OpenAI keys (same Azure resource)
- [ ] Stream audio chunks; receive partial + final results via delegate callbacks
- [ ] Built-in **speaker diarization** — enable `SpeakerDiarizationEnabled` to get speaker labels for free
- [ ] **Offline fallback**: cloud unreachable → fall back to local WhisperKit (already shipped). If user disabled local Whisper too, drop to `recordingOnly` (audio still saving).
- [ ] Cost meter — minutes of audio sent + tokens of LLM output
- [ ] Privacy disclosure: "Audio is streamed to Azure AI Speech for transcription. Disable cloud STT in Settings to keep audio on-device."

#### 8b. VAD gating

Azure AI Speech does its own VAD server-side, but client-side VAD still saves cost and bandwidth.

- [ ] Add Silero VAD via WhisperKit's `VoiceActivityDetector` (or standalone CoreML model)
- [ ] Gate audio chunks before streaming to Azure — silence never goes over the wire
- [ ] Cuts cloud STT cost (we don't pay to transcribe silence)
- [ ] Backstop for the local-WhisperKit offline path which lacks server-side VAD
- [ ] Configurable threshold + hangover time

#### 8c. Vocabulary biasing (phrase lists)

- [ ] Wire context from #3 (URL / PDF / text) into Azure Speech `PhraseListGrammar` (cloud) and Whisper `DecodingOptions.prefix` (local fallback)
- [ ] Extract candidate terms from the context: capitalized words, acronyms, names
- [ ] Names, paper titles, technical terms get spelled correctly after first mention
- [ ] Per-meeting editable vocabulary list — surface in UI before recording

#### 8d. Offline re-transcribe pass (the killer feature)

After the meeting ends, run a higher-quality batch transcription on the saved `audio.m4a` from #1. Same Azure Speech service, different endpoint — batch transcription gets full-context decoding instead of 1.5s sliding windows. Dramatic accuracy bump.

- [ ] On meeting stop, queue an offline re-transcribe job
- [ ] Use Azure Speech **batch transcription REST API** (upload audio to Azure Blob or use direct file submission)
- [ ] Inject the meeting's vocabulary list (#8c) as phrase list
- [ ] Enable diarization in batch mode — produces cleaner speaker labels than live
- [ ] Replace `transcript.jsonl` and `paragraphs.jsonl` with re-transcribed versions; keep originals as `.live.jsonl` for diffing
- [ ] Re-run polish + cheatsheet on the cleaned transcript
- [ ] UI: "Improved transcript ready" notification when done; one-click view diff
- [ ] Local fallback: if user disabled cloud, run local `large-v3-turbo` against the saved file (no streaming constraint)

#### 8e. Separate mic + system audio streams

- [ ] Stop mixing mic + ScreenCaptureKit into one mono stream before STT
- [ ] Send mic and system audio as **two separate Azure Speech recognizers** (or one stereo stream with channel routing)
- [ ] Tag segments by source: `[me]` vs `[remote]`
- [ ] Eliminates cross-talk degradation on overlapping speech
- [ ] Combines with Azure's diarization — mic stream gets per-speaker labels for the in-room people, system stream gets per-speaker labels for the Zoom side

## Execution order

1. **#1 auto-save** — foundation. Must survive crash/quit before we layer cloud calls on top. Also unlocks #8d (offline re-transcribe needs the saved audio file).
2. **#2 cloud LLM + audio-only fallback** — new default polish path. Ship reachability + replay queue here so #1's saved audio gets re-polished when back online.
3. **#8a + #8b cloud STT + VAD** — biggest accuracy win. Solves throttling and hallucinations in one shot. Do alongside or right after #2 since the provider/keychain/reachability scaffolding is identical.
4. **#7 icon** — quick win between heavy phases.
5. **#3 context input** — unlocks #8c (vocabulary biasing) the moment it ships.
6. **#8c + #8d** — vocabulary biasing + offline re-transcribe. Closes ~80% of the accuracy gap vs the offline voice-memo pipeline.
7. **#5 timestamps + stable IDs + version field** — ship the full contract upfront to avoid migration during #6.
8. **#6 re-polish** — pure consumer of #5's contract + #2's cloud calls.
9. **#8e separate streams** — do after STT cloud is stable; needs two-channel handling.
10. **#4 video** — biggest scope, lowest urgency, last.

## Backlog (cross-platform)

### iOS / iPadOS polish

- [ ] **Waveform during recording** — Swift Charts or custom `Canvas` driven off `AudioCaptureService.levels`
- [ ] **Waveform during playback** — scrub bar with time cursor
- [ ] **Trim start/end** — `AVAssetExportSession` with `timeRange`
- [ ] **Rename meeting** — inline edit, persist via SwiftData
- [ ] **Folders / favorites** — nested folder model on `Meeting`, star flag
- [ ] **Search** — full-text across transcripts via SwiftData `#Predicate`
- [ ] **Share-as-bundle** — `.m4a` + `transcript.txt` + `summary.md` as a single package
- [ ] **Lock-screen controls** — `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter`
- [ ] **Background recording keep-alive** — confirm `.playAndRecord` survives backgrounding
- [ ] **Storage management** — per-meeting size, bulk delete, "older than X" cleanup

### Sync

- [ ] **iCloud sync via CloudKit** — meetings recorded on iPhone appear on Mac. SwiftData has CloudKit integration; needs container ID + entitlement.
- [ ] **Audio file sync** — `.m4a` in CloudKit asset, not just SwiftData metadata
- [ ] **Conflict resolution** — last-write-wins with visible indicator

### Local model (nice-to-have, no longer the default path)

- [ ] **Model download UI** — size, progress, cancel, WiFi-only option
- [ ] **Runtime model swap** — change Whisper or LLM without restart
- [ ] **Delete model button** — reclaim disk

### Testing & quality

- [ ] **ModelTier picking unit tests** — lock device-class logic
- [ ] **RecordView snapshot tests** — three pane states
- [ ] **iPhone 12/13 perf baseline** — 10-min meeting, battery + thermal + lag

### Nice-to-have

- [ ] **Speaker diarization** — needs separate model (WhisperKit doesn't do this)
- [ ] **Multi-language** — detect + swap Whisper variants
- [ ] **Meeting templates** — standup / 1:1 / customer call presets
- [ ] **Calendar integration** — auto-title from EventKit
- [ ] **Export to Notion / Obsidian** — API or file drop

## Done

- [x] macOS mic + system audio capture (ScreenCaptureKit)
- [x] WhisperKit streaming sliding-window transcription
- [x] MLX Qwen3 polish + topic summary (now demoted to opt-in offline mode)
- [x] iOS/iPadOS mic-only RecordView
- [x] Device-tier Whisper + LLM model selection
