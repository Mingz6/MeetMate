# Phase 0 Validation Checklist

Before writing any MeetMate code, prove the building blocks work on your hardware.

## Hardware

- [ ] Mac: M3 Max, macOS 14+ ✅ (you have this)
- [ ] iPad: M-series chip, iPadOS 17+ (verify model)

## Toolchain

- [ ] Install Xcode (free, App Store, ~15GB download)
- [ ] Sign in to Xcode with Apple ID (Xcode → Settings → Accounts)
- [ ] Verify free provisioning profile is created automatically

## WhisperKit Validation

- [ ] Clone: `git clone https://github.com/argmaxinc/WhisperKit ~/code/oss/WhisperKit`
- [ ] Open `WhisperKit/Examples/WhisperAX/WhisperAX.xcodeproj` in Xcode
- [ ] Run on Mac → record yourself talking → verify live transcription
- [ ] Switch destination to your iPad → run → verify on-device transcription
- [ ] Note latency: speech-to-text delay (target <2 seconds)
- [ ] Note tokens-per-second printed in console

## MLX Swift Validation

- [ ] Clone: `git clone https://github.com/ml-explore/mlx-swift-examples ~/code/oss/mlx-swift-examples`
- [ ] Open `mlx-swift-examples/Applications/LLMEval/LLMEval.xcodeproj` (or `Chat`)
- [ ] Run on Mac → load Qwen3 4B → ask a question → verify response
- [ ] Run on iPad → load Qwen3 4B → measure tokens/sec
- [ ] If iPad too slow, try Phi-3 mini or Qwen2.5 1.5B
- [ ] Note: time to first token, sustained tokens/sec

## Concurrent Workload Test

- [ ] On Mac: run WhisperKit demo + MLX demo at same time
- [ ] Watch Activity Monitor → CPU, GPU, ANE usage
- [ ] Verify no thermal throttling after 10 min

## Decision Gate

After all the above:

- [ ] WhisperKit latency acceptable on Mac? (target <2s)
- [ ] WhisperKit latency acceptable on iPad? (target <3s)
- [ ] LLM tokens/sec acceptable on Mac? (target >20 tok/sec)
- [ ] LLM tokens/sec acceptable on iPad? (target >10 tok/sec)
- [ ] No thermal throttling under combined load?

If all yes → proceed to Phase 1.1 (project setup).
If any no → revise model choices in plan, retry, or pivot to lighter stack.
