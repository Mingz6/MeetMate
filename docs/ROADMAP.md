# MeetMate Roadmap

Single source of truth for forward work. Active sprint at the top, backlog below.

## Direction (April 2026)

Cloud-first for both **STT and LLM**, both on **Azure** (AI Speech + Azure OpenAI — one resource, one auth, one bill). Network required for live polish/cheatsheet/reply and live transcription. Local WhisperKit + local MLX stay as offline-mode fallbacks only, not the default. When cloud is unreachable, MeetMate keeps recording audio so nothing is lost — STT and polish replay when the network comes back.

**Phasing:** macOS first. Get it working perfectly there before polishing iPadOS/iOS. But every design decision has to stay portable — one codebase, no macOS-only data models, no APIs we can't swap on the iOS side. iPadOS/iOS targets exist today (mic-only RecordView ships) but are explicitly a follow-up phase, not parallel work.

## Active sprint (2026-Q2)

Captured from the 2026-04-22 paper-reading meeting where the live transcript almost got lost and the M3 Max throttled hard during polish.

### 1. Auto-save audio + transcript to disk

By default the meeting is saved (audio + transcript + polish + cheatsheet). User can opt out per meeting via a "Don't save" toggle before recording starts.

- [x] Storage root: `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("MeetMate/Sessions")`. Resolves to `~/Documents/MeetMate/Sessions/{YYYY-MM-DD-HHmm}/` on macOS (visible in Finder, iCloud-syncable for free), and to the app sandbox Documents on iPadOS/iOS (visible in the Files app).
- [x] Add `NSDocumentsFolderUsageDescription` to Info.plist (macOS sandbox prompt). For iOS/iPadOS Files app visibility, set `UIFileSharingEnabled = YES` and `LSSupportsOpeningDocumentsInPlace = YES`.
- [x] Save **two separate audio files**: `mic.m4a` + `system.m4a` — one per source, incrementally written (not held in RAM). Two files because once mixed you can't un-mix, and §7e needs separate streams for Azure Speech. On iPadOS/iOS (mic only), only `mic.m4a` is written.
- [x] `transcript.jsonl` — confirmed segments + timestamps, flushed every N seconds
- [x] `polished.md` — append-only after each polish cycle
- [x] `cheatsheet.md` — snapshot per cycle
- [x] On crash/quit, last-saved state survives — verify with `kill -9`
- [x] "Show in Finder" button for the active session folder (macOS) / Files share sheet (iOS/iPadOS)
- [x] **Basic playback UI** — `AVAudioPlayer` with play/pause button + seek slider. Plays `mic.m4a` (or both files simultaneously on macOS). Needed before §5 timestamp-click-to-seek can land.
- [x] **Delete meeting** — swipe-to-delete or context menu on meeting list. Removes the session folder from `~/Documents/MeetMate/Sessions/` + the SwiftData `Meeting` row. Confirm prompt before deleting.
- [x] SwiftData `Meeting` — **derive** session folder path from `Meeting.startedAt` (format `{YYYY-MM-DD-HHmm}`), no stored path field. Rename is a nice-to-have; derive keeps the model simple.
- [x] **Pre-record toggle**: "Save this meeting" — default ON. When OFF, write to `FileManager.default.temporaryDirectory` and delete on stop.

### 2. Cloud LLM as primary, audio-only fallback

Cloud is the new default. When the network is gone, MeetMate keeps capturing audio + raw transcript and skips polish. Polish replays from the saved transcript when back online.

- [x] `LLMProvider` protocol — `AzureOpenAIProvider` (primary) + optional `LocalMLXProvider` (kept as opt-in nice-to-have for offline-by-choice users)
- [x] Primary cloud provider: **Azure OpenAI** (same Azure resource as AI Speech). Protocol stays open for Anthropic/Gemini later if needed.
- [x] Settings: Azure endpoint + deployment name + API key entry, store in **Keychain** (NOT UserDefaults). API key auth for now — Entra ID / `az login` adds too much friction for a desktop app.
- [x] **Region note**: deploy Azure OpenAI and AI Speech in the same region. Don't hard-pin — region choice depends on which has the latest model deployments (e.g. some regions get GPT-5 before others). Document the active region in Settings UI.
- [ ] Per-task provider routing: polish vs cheatsheet vs reply vs re-polish can use different model tiers
- [x] Streaming response support (SSE) so UI stays responsive
- [x] **Reachability + failure handling** — 3 consecutive failures (timeout / 5xx / no network) → flip to `recordingOnly` mode, show banner: "Offline — audio + raw transcript still saving, polish paused"
- [x] **Replay queue** — while offline, queue polish/cheatsheet jobs to disk; drain when back online against the saved transcript
- [x] Manual "Pause cloud calls" toggle in UI for cost-sensitive moments
- [x] Cost display — exact tokens-in/out per session + estimated cost (Azure OpenAI returns `usage` in each response). Show as a running counter in the session view. Warning banner when cumulative cost exceeds a user-configurable threshold (e.g. "This session has used $X of API calls").
- [x] Auth pattern reference: `~/code/personal/worker-center` has a working Azure OpenAI client + Keychain storage pattern — reuse, don't re-derive.
- [ ] Privacy disclosure in onboarding + README — "Audio is streamed to Azure AI Speech for transcription. Transcript text is sent to Azure OpenAI for polishing. Local-only mode available in Settings (slower, requires model downloads)."
- [x] Update README — dropped "no cloud, no API keys" headline; reframed as cloud-first with offline fallbacks

### 3. Pre-meeting context input

- [x] "Context" pane in MainView with text area + URL field
- [x] URL fetch: download page, strip to readable text
- [x] PDF drop support — extract text from a paper
- [x] Inject context as system prompt prefix into polish + cheatsheet + reply
- [x] Persist `context.md` in the session folder
- [x] Token budget guard — truncate if too long, warn user

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

- [x] Pass Whisper segment timestamps through to the polish prompt
- [x] Polish JSON contract: `{"finalized": [{"id": "p_000123", "text": "...", "startSec": 12.3, "endSec": 18.7, "version": 1}], "draft": "..."}`
- [x] **Stable IDs assigned by Swift**, not the LLM (LLMs forget IDs across calls). Format `p_{6-digit zero-padded}`, monotonic per session, never reused.
- [x] **Version field** ships in #5 even though it stays at 1 until #6. Avoids contract migration later.
- [x] Persist `paragraphs.jsonl` (one paragraph per line, append-only) alongside `polished.md`
- [x] Render `[mm:ss]` prefix in the polished pane
- [x] Click a timestamp → seek the saved audio file (needs audio playback UI)
- [x] Backfill: when polisher merges 6 segments into 2 paragraphs, take start of first + end of last

### 6. Retroactive re-polish

Depends on #5 (stable IDs + version field) and #2 (cloud LLM). Re-polish never invents IDs — only references existing ones.

- [x] Trigger: every N cycles, take the last K finalized paragraphs by ID + new context, ask LLM to revise
- [x] Polish JSON gains `revisions`: `[{"replaceIds": ["p_000003","p_000004"], "newText": "...", "reason": "speaker corrected themselves"}]`
- [x] Append to `paragraphs.jsonl` as new versions (append-only, same `id`, bumped `version`)
- [x] UI: strikethrough old + new text, accept/reject
- [x] Edit trail view — click a paragraph to see all versions
- [x] Test case: "I want to buy an apple. Well, banana is better." → "Speaker decided on banana over apple."
- [x] Bound the re-polish window (last 5 paragraphs, **excluding** paragraphs newer than ~10s — those are likely still being revised by the live polisher)
- [x] Cloud-only — skip in `recordingOnly` mode

### 7. Transcription quality — Azure AI Speech, VAD, offline re-transcribe pass

The biggest accuracy gap today is STT, not the LLM. Live `large-v3` streaming on M3 Max throttles, hallucinates on silence, and butchers domain terms (e.g. "KV cache" → "KB cache"). Five layers fix this, all on a single provider.

**Provider choice: Azure AI Speech** — same vendor as the LLM (Azure OpenAI), one resource, one auth flow, one billing line. Native Swift SDK. Live streaming + batch transcription + phrase lists + diarization all included. Local WhisperKit stays as the offline-mode fallback only — no Whisper-on-cloud second provider needed.

#### 7a. Cloud STT (primary path) — Azure AI Speech

- [x] `STTProvider` protocol — mirror `LLMProvider` shape
- [x] ~~Wire Microsoft Cognitive Services Speech SDK~~ → Pure Swift WebSocket implementation (no native SDK dependency)
- [x] Use WebSocket continuous recognition (`wss://{region}.stt.speech.microsoft.com`) for live
- [x] API key + region in Keychain alongside Azure OpenAI keys (same Azure resource)
- [x] Stream audio chunks; receive partial + final results via WebSocket text frames
- [ ] Built-in **speaker diarization** — enable `SpeakerDiarizationEnabled` to get speaker labels for free
- [x] **Offline fallback**: cloud unreachable → fall back to local WhisperKit (already shipped). If user disabled local Whisper too, drop to `recordingOnly` (audio still saving).
- [x] Cost meter — minutes of audio sent + tokens of LLM output
- [ ] Privacy disclosure: "Audio is streamed to Azure AI Speech for transcription. Enable local STT in Settings to keep audio on-device (requires ~3 GB model download)."

#### 7b. VAD gating

Azure AI Speech does its own VAD server-side, but client-side VAD still saves cost and bandwidth.

- [x] ~~Silero VAD~~ → RMS-based VADGate (upgradeable to Silero CoreML later)
- [x] Gate audio chunks before streaming to Azure — silence never goes over the wire
- [x] Cuts cloud STT cost (we don't pay to transcribe silence)
- [x] Backstop for the local-WhisperKit offline path which lacks server-side VAD
- [x] Configurable threshold + hangover time

#### 7c. Vocabulary biasing (phrase lists)

- [x] Wire context from #3 (URL / PDF / text) into Azure Speech `PhraseListGrammar` (cloud) and Whisper `DecodingOptions.promptTokens` (local fallback)
- [x] Extract candidate terms from the context: capitalized words, acronyms, names
- [x] Names, paper titles, technical terms get spelled correctly after first mention
- [x] Per-meeting editable vocabulary list — surface in UI before recording

#### 7d. Offline re-transcribe pass (the killer feature)

After the meeting ends, run a higher-quality batch transcription on the saved `mic.m4a` + `system.m4a` from #1. Same Azure Speech service, different endpoint — batch transcription gets full-context decoding instead of 1.5s sliding windows. Dramatic accuracy bump.

- [x] On meeting stop, queue an offline re-transcribe job
- [x] ~~Use Azure Speech batch transcription REST API~~ → Re-uses real-time WebSocket (fast-pump saved audio, no blob storage dependency)
- [x] Inject the meeting's vocabulary list (#7c) as phrase list
- [ ] Enable diarization in batch mode — produces cleaner speaker labels than live
- [x] Write re-transcribed results to **separate files**: `transcript.batch.jsonl` + `paragraphs.batch.jsonl` — never silently overwrite the live versions (they have stable IDs from §5 that §6's accept/reject UI references)
- [x] Keep originals as-is; rename to `.live.jsonl` only after user explicitly accepts the batch version
- [ ] **Accept migration**: when user taps "Accept improved transcript", do a one-shot ID-preserving merge — match paragraphs by text overlap, keep existing IDs where possible, assign new IDs only for genuinely new segments
- [ ] Re-run polish + cheatsheet on the accepted transcript
- [x] UI: "Improved transcript ready" notification when done; one-click diff view + Accept/Keep Original buttons
- [ ] Local fallback: if user disabled cloud, run local `large-v3-turbo` against the saved file (no streaming constraint)

#### 7e. Separate mic + system audio streams

- [x] Stop mixing mic + ScreenCaptureKit into one mono stream before STT
- [x] Send mic and system audio as **two separate Azure Speech recognizers** (or one stereo stream with channel routing)
- [x] Tag segments by source: `[me]` vs `[remote]`
- [x] Eliminates cross-talk degradation on overlapping speech
- [ ] Combines with Azure's diarization — mic stream gets per-speaker labels for the in-room people, system stream gets per-speaker labels for the Zoom side

## Execution order

1. **#1 auto-save** — foundation. Must survive crash/quit before we layer cloud calls on top. Also unlocks #7d (offline re-transcribe needs the saved audio files). Includes basic playback UI + delete-meeting.
2. **#2 cloud LLM + audio-only fallback** — new default polish path. Ship reachability + replay queue here so #1's saved audio gets re-polished when back online.
3. **#7a + #7b cloud STT + VAD** — biggest accuracy win. Solves throttling and hallucinations in one shot. Do alongside or right after #2 since the provider/keychain/reachability scaffolding is identical.
4. **#3 context input** — unlocks #7c (vocabulary biasing) the moment it ships.
5. **#7c + #7d** — vocabulary biasing + offline re-transcribe. Closes ~80% of the accuracy gap vs the offline voice-memo pipeline.
6. **#5 timestamps + stable IDs + version field** — ship the full contract upfront to avoid migration during #6.
7. **#6 re-polish** — pure consumer of #5's contract + #2's cloud calls.
8. **#7e separate streams** — do after STT cloud is stable; needs two-channel handling. Audio files already saved separately from #1.
9. **#4 video** — biggest scope, lowest urgency, last.
10. **App icon** — pure polish, doesn't unblock anything. Batch with iOS polish phase.

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

- [ ] **App icon** — mic + brain or speech bubble + sparkle. Full icon set (16–1024 @1x/@2x). Batched here with iOS polish since it doesn't unblock any feature.
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
