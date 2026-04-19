# Setup Guide

## Step 1: Install Xcode

1. Open App Store → search "Xcode" → install (free, ~15GB)
2. Launch Xcode once to install Command Line Tools
3. Sign in with Apple ID under Xcode → Settings → Accounts

## Step 2: Create the Xcode project

The Swift source files in `MeetMate/` are scaffolded but no `.xcodeproj` exists yet.
Create one via the Xcode GUI:

1. Xcode → File → New → Project
2. Choose **Multiplatform → App**
3. Product Name: `MeetMate`
4. Team: your personal team (free)
5. Organization Identifier: `dev.mingz`
6. Interface: **SwiftUI**, Language: **Swift**, Storage: **SwiftData**
7. Save to `~/code/personal/meeting-assistant/` — let Xcode use the existing folder
8. Replace Xcode's auto-generated files with the ones already in `MeetMate/`

## Step 3: Add Swift Package dependencies

In Xcode: File → Add Package Dependencies

- `https://github.com/argmaxinc/WhisperKit` — pick latest version
- `https://github.com/ml-explore/mlx-swift-examples` — pick latest version

## Step 4: Configure capabilities

For the **macOS** target:
- Signing & Capabilities → + Capability → **Microphone Usage**
- Add to Info.plist: `NSMicrophoneUsageDescription` = "MeetMate transcribes meeting audio."
- Add: `NSScreenCaptureDescription` = "MeetMate captures Teams/Zoom audio."
- Hardened Runtime → enable **Audio Input**

For the **iPadOS** target:
- Same microphone permission + Info.plist entry
- Background Modes → **Audio** (for background recording)

## Step 5: Sign with free Apple ID

- Signing & Capabilities → Team: your personal team
- Bundle Identifier: `dev.mingz.MeetMate` (must be globally unique — change if conflict)

## Step 6: Build and run

- Select destination: My Mac → Run (⌘R)
- For iPad: connect via USB or use simulator

## Free sideloading limitation

Apps signed with a free Apple ID expire after **7 days**. To keep using:
- Reconnect device, hit Run in Xcode again to re-sign
- Or pay $99/yr for Apple Developer Program (we said no money — so live with the 7-day re-sign)
