# nik

A CapCut/Roll-style iOS app for making and posting short-form content: browse viral-video templates, auto-fill them with clips from your camera roll, add text + on-device auto-captions, and export a 9:16 video ready to post.

Built with SwiftUI + AVFoundation, iOS 17+, zero third-party dependencies. See [PLAN.md](PLAN.md) for the full product plan, research synthesis, architecture, and roadmap.

## Run it

```bash
brew install xcodegen   # if needed
xcodegen generate
open Nik.xcodeproj      # select the Nik scheme, run on a simulator or device
```

Notes:
- Auto-captions (Speech framework) and overlay burn-in on export work on a **real device**; the iOS 26 simulator's offline Core Animation renderer crashes, so burn-in is compiled out for simulator builds.
- To try the flow on a simulator, seed its camera roll first: drag videos onto the simulator or `xcrun simctl addmedia booted *.mp4`.

## E2E test

With [Maestro](https://maestro.mobile.dev) installed, a full journey (template → fill 4 slots → editor → export → share) is scripted; the last run produced a valid 1080×1920 H.264 MP4.
