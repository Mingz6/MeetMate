# Meeting Assistant — Build Plan

Personal cross-platform meeting assistant: real-time transcription, live cheatsheet,
reply suggestions, post-meeting summary. Runs on **macOS and iPadOS**.
Fully local-first, no paid services.

**iPhone deferred** — can't capture system audio (Apple privacy block) so it's useless for Teams/Zoom. NPU also too weak for whisper + 4B LLM concurrently. Revisit as Phase 3 stretch.

**Project name (TBD):** MeetMate / EarSidekick / WhisperBuddy
**Repo location:** `~/code/personal/meeting-assistant/`
**License:** Personal use, MIT for any open-source pieces

---

## Constraints (Locked In)

- ❌ **No paid apps or services** — no MacWhisper Pro, no Granola, no OpenAI API
- ✅ **Runs on macOS and iPadOS** — same codebase via SwiftUI (iPhone deferred)
- ✅ **100% local processing** — audio + transcription + LLM all on-device
- ✅ **Real-time:** live transcript + rolling topic summary + reply suggestions

---

## Tech Stack Decision

macOS + iPadOS support means **Swift + SwiftUI**. Python won't run on iPad.

| Layer | Choice | Why |
|-------|--------|-----|
| UI | SwiftUI | Single codebase for macOS + iPadOS |
| Speech-to-text | [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Argmax, MIT licensed) | Native Swift, runs on Apple Neural Engine + GPU, real-time capable, MLX-backed |
| Local LLM | [MLX Swift Examples](https://github.com/ml-explore/mlx-swift-examples) — **device-tiered**: Llama 3.1 8B / Qwen3 14B on Mac, Qwen3 4B on iPad, Phi-3 mini / Qwen2.5 1.5B on iPhone | Auto-detect RAM at runtime, pick best model that fits |
| Audio capture (macOS) | ScreenCaptureKit (system audio) + AVAudioEngine (mic) | Built-in, no virtual device needed |
| Audio capture (iPadOS) | AVAudioEngine (mic only — system audio limited on iPad) | Works for in-person meetings + Teams-on-Mac mirroring |
| Storage | SwiftData / Core Data | Native persistence |
| Sync (optional) | iCloud Drive | Free, all platforms |
| Build tool | Xcode | Required for iOS deployment |

**Distribution:** sideload via Xcode (free, requires Apple ID), or paid Apple Developer account ($99/yr) for App Store. Sideload is fine for personal use.

---

## Platform Capability Matrix

| Feature | macOS | iPadOS |
|---------|-------|--------|
| Mic transcription (in-person meeting) | ✅ | ✅ |
| System audio capture (Teams/Zoom) | ✅ via ScreenCaptureKit | ⚠️ limited |
| Live cheatsheet overlay | ✅ floating window | ✅ Slide Over / Stage Manager |
| Reply suggestions | ✅ | ✅ |
| LLM inference speed | ✅ blazing (M3 Max) | ✅ good (M-series iPad) |
| Background recording | ✅ | ✅ with audio session |

**Implication:** macOS = primary (captures both sides of Teams). iPadOS = secondary (in-person meetings, conferences, lectures, or follow-along during a Teams call on Mac).

---

## Phase 0 — Prerequisites & Validation

Before writing app code, validate the building blocks work.

- [ ] Install Xcode (free, App Store)
- [ ] Verify Apple ID is signed in to Xcode (free dev cert)
- [ ] Clone WhisperKit repo and run their demo app on Mac
- [ ] Run WhisperKit demo on iPhone — verify real-time transcription works
- [ ] Clone mlx-swift-examples and run their LLM chat demo on Mac
- [ ] Run MLX LLM demo on iPad/iPhone — verify Qwen or Phi-3 mini works
- [ ] Benchmark: time to first token, tokens/sec on each device
- [ ] Confirm whisper + LLM can run simultaneously without thermal throttling
- [ ] Decision: ship or keep iterating

---

## Phase 1 — macOS App (MVP)

Start with macOS because it's the most useful (captures Teams audio) and fastest to iterate.

### Phase 1.1 — Project Setup

- [ ] Create Xcode project: SwiftUI multiplatform (macOS + iOS + iPadOS targets)
- [ ] Add WhisperKit Swift Package dependency
- [ ] Add MLX Swift dependency
- [ ] Configure entitlements: microphone, screen recording (macOS)
- [ ] Set up Git repo with `.gitignore` for Xcode (`DerivedData/`, `*.xcuserstate`)
- [ ] Add README with architecture diagram
- [ ] Initial commit

### Phase 1.2 — Audio Capture (macOS)

- [ ] Implement microphone capture with AVAudioEngine
- [ ] Implement system audio capture with ScreenCaptureKit (macOS 13+)
- [ ] Mix mic + system audio into single 16kHz mono stream
- [ ] Add VAD (voice activity detection) to skip silence
- [ ] Save raw audio to disk (~/Library/Application Support/MeetMate/recordings/)
- [ ] Test with a real Teams call — verify both sides captured

### Phase 1.3 — Real-Time Transcription

- [ ] Bundle WhisperKit `large-v3-turbo` model (1.5GB, downloaded on first run)
- [ ] Stream audio chunks (1-2s windows) into WhisperKit
- [ ] Display live transcript in scrolling text view
- [ ] Buffer transcript with timestamps for later summarization
- [ ] Measure latency: target <2s from speech to text

### Phase 1.4 — Local LLM (Cheatsheet Generator)

- [ ] Bundle Qwen3 4B (Q4) via MLX Swift — ~2.5GB
- [ ] Build rolling summarization loop: every 60s, send last N minutes → LLM
- [ ] Prompt template:
  ```
  You are a meeting assistant. Based on the transcript below, provide:
  1. Current topic (1 line)
  2. Key points discussed (3-5 bullets)
  3. Open questions
  4. Action items mentioned
  Transcript: {last 5 minutes}
  ```
- [ ] Parse structured output (JSON or markdown)
- [ ] Update cheatsheet UI without blocking transcription thread

### Phase 1.5 — Reply Suggestions

The killer feature. Detect when you're being addressed → generate reply.

- [ ] Configure your name in Settings (e.g., "Ming")
- [ ] Detect mention in last 30s of transcript ("Ming, what do you think?", "Ming?")
- [ ] On detection, trigger reply generation:
  ```
  Someone just asked you: "{question text}"
  Meeting context so far: {current cheatsheet}
  Last 2 minutes of transcript: {recent context}
  Provide a 2-3 sentence suggested reply that's professional and addresses the question.
  ```
- [ ] Show suggestion prominently in UI with subtle notification sound
- [ ] Add manual hotkey trigger (⌘+Shift+R) for cases where name isn't said
- [ ] Auto-dismiss suggestion after 30s or when next person speaks

### Phase 1.6 — Cheatsheet UI (macOS)

- [ ] Floating always-on-top window (~400px wide)
- [ ] Sections (top to bottom):
  - Current Topic (large, bold)
  - Key Points (bulleted, scrollable)
  - ⚡ Reply Suggestion (highlighted yellow when active)
  - Action Items (small, bottom)
- [ ] Hotkey to show/hide window (⌘+Shift+M)
- [ ] Click-through transparent areas option (don't block clicks underneath)
- [ ] Position memory (remember where I dragged it)
- [ ] Dark mode support

### Phase 1.7 — Post-Meeting Pipeline

- [ ] On stop button press: finalize transcript + audio file
- [ ] Run final summarization pass with Qwen3 4B (or Llama 3.1 8B if loaded)
- [ ] Generate structured markdown summary
- [ ] Save to `~/code/crna/meetings/{YYYY-MM-DD}-{slug}-summary.md` (or user-configured path)
- [ ] Update meeting index README automatically
- [ ] Optional: pull meeting title from active calendar event (EventKit)

### Phase 1.8 — Polish & Operational

- [ ] Privacy mode: instant pause/clear with hotkey
- [ ] Battery/thermal monitoring — pause LLM if device hot
- [ ] Disk usage display + cleanup of old audio files
- [ ] Crash recovery: checkpoint transcript every 30s
- [ ] App icon + branding
- [ ] Logging (separate from meeting content)

---

## Phase 2 — iPadOS Port

Once macOS app is solid, port to iPad. Same SwiftUI codebase, adapt UI for touch.

- [ ] Test all SwiftUI views on iPad simulator (split view, Stage Manager)
- [ ] Adapt floating window → Slide Over panel on iPad
- [ ] Implement audio session for background recording
- [ ] Test on real iPad (sideload via Xcode + Apple ID)
- [ ] Verify Qwen3 4B fits comfortably on iPad RAM
- [ ] iCloud Drive sync of meeting summaries between Mac and iPad
- [ ] Touch-friendly interactions (bigger tap targets, swipe to dismiss reply)

---

## Phase 3 — Stretch Features

Only after Phases 1 & 2 are used for ≥10 real meetings.

- [ ] Speaker diarization with WhisperKit's experimental speaker labels
- [ ] Action item extraction with auto-DevOps card creation
- [ ] Apple Watch companion app — quick "show me the cheatsheet" glance
- [ ] iPhone port — accept mic-only limitation, useful for hallway conversations
- [ ] Semantic search across all past meetings (local embeddings via MLX)
- [ ] Calendar integration — auto-start when meeting begins
- [ ] Multi-language support (English + French for some CRNA meetings)
- [ ] Export to Notion / Obsidian / Apple Notes
- [ ] Open-source release on GitHub

---

## Reference Apps to Study

Read source code before writing your own:

- [ ] **[WhisperKit Examples](https://github.com/argmaxinc/WhisperKitExamples)** — official Argmax demos
- [ ] **[mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples)** — Apple's MLX Swift demos including LLM chat
- [ ] **[LidIA](https://github.com/lidia-app/LidIA)** — Swift meeting assistant (requires macOS 26 — read the code anyway)
- [ ] **[Whisper Transcription](https://github.com/martin-lutz/SwiftWhisper)** — Swift wrapper patterns

---

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-15 | Build native, not buy MacWhisper | No paid apps |
| 2026-04-18 | Swift + SwiftUI (not Python) | iOS/iPadOS support requires native Apple toolchain |
| 2026-04-18 | WhisperKit (not whisper.cpp) | Native Swift, ANE acceleration, App Store compatible |
| 2026-04-18 | MLX Swift (not Ollama) | Ollama doesn't ship to iOS; MLX is Apple-native |
| 2026-04-18 | Sideload via Xcode (no $99/yr Apple Dev) | No paid services |
| 2026-04-18 | Drop iPhone from Phase 1 & 2 | iPhone can't capture system audio (Apple block) + NPU too weak for whisper + 4B LLM. Revisit in Phase 3. |
| TBD | LLM model: Qwen3 4B vs Phi-3-mini vs Qwen2.5-1.5B | Benchmark on iPhone first |
| TBD | Mention detection: keyword vs ML classifier | Start with keyword |

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| WhisperKit real-time too slow on iPad | Use smaller model (small.en) on iPad |
| LLM inference too slow on iPad | Use Phi-3-mini or Qwen2.5-1.5B on iPad if Qwen3 4B struggles |
| Sideloaded apps expire after 7 days (free Apple ID) | Re-sign weekly via Xcode, or accept the friction |
| iPad system audio capture limited | Use iPad as second-screen cheatsheet during Mac-hosted Teams calls; full mic capture for in-person meetings |
| Battery drain during long meetings | Add power-aware mode (pause LLM, keep transcription) |
| Steep learning curve (Swift + SwiftUI + WhisperKit + MLX) | Start tiny: get basic transcription working before adding LLM |
| Model files too large for iPad storage | Make models downloadable on first run (not bundled) |
| App Store rejection if I ever publish | Personal use first; revisit if going public |

---

## Success Criteria

- [ ] Phase 0: WhisperKit and MLX demos run successfully on Mac + iPad
- [ ] Phase 1: Used macOS app for ≥3 real Teams meetings, transcription + cheatsheet works
- [ ] Phase 1: Reply suggestion appeared and was actually useful at least once
- [ ] Phase 1: Auto-summary file appeared in `~/code/crna/meetings/` after meeting ended
- [ ] Phase 2: Used iPad app for ≥1 in-person meeting (e.g., conference, coffee chat)
- [ ] Phase 2: iPad app used as second-screen cheatsheet during a Mac Teams call
- [ ] Phase 3: Replaced 100% of voice-memo-analyzer manual workflow

---

## Why This Will Work

- WhisperKit is real and proven — Argmax (the company) ships production iOS speech apps with it
- MLX Swift is Apple's official ML framework, designed for exactly this use case
- M-series chips (Mac and iPad) have huge unified memory — can run 4B param LLMs comfortably
- Single SwiftUI codebase for both platforms means iterating once, not twice

## Why This Might Fail

- Swift + SwiftUI learning curve if not familiar (likely 1-2 weeks of ramp-up)
- iPhone NPU might not handle simultaneous whisper + LLM — would need to alternate
- Free Apple ID provisioning expires every 7 days — annoying for a daily-use app
- WhisperKit + MLX bundle size could be 4-5GB total — big app
