#!/bin/bash
# Regenerates docs/images/meetmate-demo.gif and .png from the app's --demo mode.
#
# Needs: a built app (see README quickstart), ffmpeg, Xcode's swiftc, and a terminal that has
# Screen Recording and Accessibility permission (System Settings, Privacy and Security).
# It captures only the MeetMate window, which shows scripted, made-up content.
#
#   scripts/record-demo.sh                 # uses build/Build/Products/Debug/MeetMate.app
#   APP=/path/to/MeetMate.app scripts/record-demo.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$ROOT/build/Build/Products/Debug/MeetMate.app}"
OUT="$ROOT/docs/images"
WORK="$(mktemp -d)"
INTERVAL=1.4      # seconds per script step
START_DELAY=3     # seconds before step one
STEPS=11          # DemoScript.stepCount
trap 'pkill -x MeetMate 2>/dev/null || true; rm -rf "$WORK"' EXIT

[ -d "$APP" ] || { echo "No app at $APP. Build it first." >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found" >&2; exit 1; }

# Helper: print the window id of the MeetMate window.
cat > "$WORK/winid.swift" <<'SWIFT'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows where (w[kCGWindowOwnerName as String] as? String) == "MeetMate" {
    if let b = w[kCGWindowBounds as String] as? [String: Any], (b["Width"] as? Double ?? 0) > 300 {
        print(w[kCGWindowNumber as String] ?? "")
        break
    }
}
SWIFT
swiftc -O "$WORK/winid.swift" -o "$WORK/winid"

pkill -x MeetMate 2>/dev/null || true
sleep 2
open -n "$APP" --args --demo -demoInterval "$INTERVAL" -demoStartDelay "$START_DELAY"

ID=""
for _ in $(seq 1 40); do
  ID="$("$WORK/winid")"
  [ -n "$ID" ] && break
  sleep 0.5
done
[ -n "$ID" ] || { echo "MeetMate window did not appear" >&2; exit 1; }

osascript -e 'tell application "System Events" to tell process "MeetMate" to set size of window 1 to {1180, 720}'
osascript -e 'tell application "MeetMate" to activate'
sleep 0.4

mkdir -p "$WORK/frames"
DURATION=$(python3 -c "import math; print(math.ceil($START_DELAY + $STEPS * $INTERVAL + 3))")
T0=$(python3 -c 'import time; print(time.time())')
N=0
SECONDS=0
while [ "$SECONDS" -lt "$DURATION" ]; do
  # A capture can fail while the window is mid-animation. Skip it and keep the numbering gap-free.
  if screencapture -l "$ID" -o -x "$WORK/frames/f_$(printf %04d "$N").png" 2>/dev/null; then
    N=$((N + 1))
  fi
done
FPS=$(python3 -c "import time; print($N / (time.time() - $T0))")
echo "captured $N frames at $FPS fps"

mkdir -p "$OUT"
# Keep only frames that changed, then build a small palette GIF. The last frame holds for 3 s.
ffmpeg -loglevel error -y -framerate "$FPS" -i "$WORK/frames/f_%04d.png" \
  -vf "mpdecimate=hi=1200:lo=600:frac=0.3,scale=900:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=64:stats_mode=diff[p];[s1][p]paletteuse=dither=none:diff_mode=rectangle" \
  -fps_mode vfr -loop 0 -final_delay 300 "$OUT/meetmate-demo.gif"

# Poster: the last frame, after every step has played and the animations have settled.
cp "$WORK/frames/f_$(printf %04d $((N - 1))).png" "$OUT/meetmate-demo.png"

ls -la "$OUT"
