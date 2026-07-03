# nik — CapCut/Roll-style iOS content creation app

**Goal:** an iOS app that makes it dramatically easier to make and post short-form content — camera-roll-linked, template-driven ("make your own version of this viral video"), in the spirit of Roll, with the CapCut template flywheel as the model.

*Reference reel:* instagram.com/reel/DZnXUnWvLox — a Roll promo by @jarrettcreates ("Everything you've ever wanted is on the other side of believing in yourself. Post that reel start that business quit that job. Comment the app name 'Roll'…" #viral #editing #Roll #AI). The formula it demonstrates: motivational hook text over a meme-style clip + a comment-gated CTA — i.e. exactly the "text-hook template + your clip" videos this app generates.

---

## 1. What the research says (synthesis)

Deep competitive research was run across CapCut, Roll, InShot, Videoleap, Captions/Mirage, Opus Clip, SendShort, Submagic, Pippit, Blotato, Crayo, Revid, ZapCap, Zeemo, and others. Full findings live in the research reports; the load-bearing conclusions:

### The category playbook
- **The template flywheel is the whole game.** CapCut's growth engine: trending template → "Use template" deep link from the feed → slot-based auto-fill from camera roll → one-tap export → post carries attribution → more users. Roll is a lighter-weight, mobile-first version of exactly this loop.
- **Templates must compile into ordinary projects** — auto-fill first, full editing optional. Speed-to-post is the product; editing depth is secondary.
- **Nobody in the mobile template niche does posting well.** CapCut, InShot, Videoleap all end at the share sheet. Scheduling/analytics live in web tools (Blotato, Opus, Submagic). A mobile app that owns even a light "post workflow" (per-platform caption composer, hashtags, deep links) differentiates.

### Where incumbents are vulnerable (from thousands of 1-star reviews)
1. **Paywall creep + export-time gating** — CapCut's #1 complaint: features free yesterday are Pro today, and the paywall ambushes you *after* you've done the work. → Rule: **never gate at export time for work already done**; gates live at feature-entry (Pro template, 4K toggle), stated upfront.
2. **Billing dark patterns** — weekly-subscription traps (Videoleap), trial-to-charge ambushes (Blotato, Crayo), impossible cancellation (Opus). → Transparent trial timeline (Videoleap's "Today → Day 5 reminder → Day 7 billed" pattern is the one thing they do right), annual-first pricing.
3. **Reliability** — lost projects, "original file is missing" (InShot), audio desync, failed exports. → Copy media into the project sandbox at pick time (already implemented); autosave everything.
4. **Credit opacity** (Revid, Pippit, Captions) — irrelevant for v1 (no credits), keep it that way as long as possible.

### Table stakes vs differentiators
- **MVP table stakes:** template feed w/ categories + auto-fill slot flow, 9:16 1080p export, text overlays, auto-captions (users now expect these free), music/clip audio control, watermark-on-free.
- **Differentiators worth building:** trending-template velocity (server-delivered templates, no app update), beat-synced slots, on-device transcription captions (private + free vs CapCut's caption paywall = direct attack), smart 9:16 crop via Vision saliency, post-workflow polish.
- **Monetization consensus:** soft paywall. Free = full template flow with watermark; Pro (~$39.99/yr anchor, 7-day trial) = watermark removal, 4K/60fps, Pro templates, premium caption styles. Watermark toggle at export is the highest-intent paywall trigger; watermarked free exports are the acquisition channel.

---

## 2. Product spec (UX)

Full UX research is reflected in the built app; the essentials:

- **3 tabs:** Templates (landing) · Projects · Profile. Dark-only UI, one accent color reserved for CTAs, monospaced digits for all durations/timecodes.
- **Template feed:** category chips + 2-col grid of 9:16 cards showing usage count, clip count, duration, PRO badge → full-screen vertical pager with pinned **"Use template"** CTA (TikTok-style).
- **Clip-fill (the signature screen):** media grid on top (All/Videos/Photos), numbered slot tray pinned at the bottom with per-slot duration hints; taps fill the highlighted slot and auto-advance; too-short videos rejected with error haptic; `Preview (3/8)` CTA disabled until full.
- **Editor:** live preview w/ synced text + caption overlays, segment rail (tap → mute / trim-start / hints), tool tray (Text, Captions, transport). Text edit sheet: content, style (Bold/Outline/Block/Small), size, Y-position, timing. Captions sheet: generate on-device → style carousel (Plain/Karaoke/Bounce/Block).
- **Export:** settings sheet (resolution w/ 4K=Pro, watermark toggle → paywall) → progress ring ("keep nik open") → success screen: auto-save to camera roll, per-platform buttons, ShareLink, "Create another".
- **Paywall:** contextual sheet, always-visible ✕, transparent trial copy, restore link.

## 3. Technical architecture

**Stack:** SwiftUI + AVFoundation, iOS 17+, XcodeGen project, zero third-party dependencies.

```
Sources/
├── Models/        Template (slots, text layers, music/beats) · EditProject (fills, captions, export settings)
├── Stores/        TemplateStore (catalog; server-deliverable later) · ProjectStore (JSON + per-project media sandbox)
├── Media/         PhotoLibrary (PhotoKit auth, thumbnails, passthrough export, save-to-Photos)
├── Engine/
│   ├── MediaResolver         picks → local files; photos pre-encoded to video clips (uniform pipeline)
│   ├── CompositionBuilder    template+fills → AVComposition + AVVideoComposition + AVAudioMix
│   │                         (aspect-fill w/ preferredTransform, speed via scaleTimeRange,
│   │                          transitions: cut/dip-fade/zoom-settle/punch-in as transform+opacity ramps)
│   ├── OverlayLayerFactory   CALayer tree burned at export via AVVideoCompositionCoreAnimationTool
│   │                         (rasterized text bitmaps, karaoke/bounce word animations, watermark)
│   ├── ExportService         full-res rebuild → AVAssetExportSession → MP4, progress, cancel
│   └── TranscriptionService  audio extract → SFSpeechRecognizer on-device → word-timed caption pages
└── Views/         Templates / Picker / Editor / Export / Projects / Profile+Paywall
```

**Key invariants** (from the architecture research):
1. One builder drives preview *and* export — preview at 540×960, export at full res.
2. Overlay model uses unit coordinates; SwiftUI preview overlays and export CALayers render from the same specs.
3. Picked media is copied into the project sandbox at resolve time — edits never depend on live/iCloud-evicted PHAssets.
4. Templates compile into ordinary projects; the editor doesn't know templates exist.
5. All timeline math in CMTime(timescale 600); seconds only at the JSON boundary.

**Known constraint:** `AVVideoCompositionCoreAnimationTool` (overlay burn-in) crashes in the iOS 26 *simulator's* offline CA renderer (IOSurface/xpc trap) — burn-in is compiled out for simulator builds and works on device. The v2 fix that removes the constraint entirely: a custom `AVVideoCompositing` compositor rendering overlays via Core Image (also unlocks LUT filters, luma transitions, per-word glow).

**Posting reality (researched):** TikTok = OpenSDK share (video pre-loaded in their composer). Instagram = no programmatic Reel publish for personal accounts; best-effort `instagram-reels://share` pasteboard route (needs FB app ID) with share-sheet fallback. YouTube Shorts = share sheet. v1 ships save-to-Photos + deep links + ShareLink; SDK integrations are v2.

## 4. Roadmap

**v1 — shipped in this repo (builds green, E2E-tested on simulator):**
Template catalog (8 built-ins across 7 categories) · full clip-fill flow · composition engine (transitions, speed, photo Ken Burns, audio mix) · live-preview editor · text overlays · on-device auto-captions with 4 styles · 1080p/4K export · watermark + Pro gating + paywall UX · projects persistence · share screen.

**v2 — make it real:**
- StoreKit 2 behind the existing `Entitlements` interface; App Store Connect products.
- Real template preview videos (bundle or CDN) replacing animated gradient placeholders.
- Server-delivered template bundles (JSON + music + fonts, the schema is already Codable) + bundled licensed music with precomputed beat maps; slot durations snap to beats.
- TikTok OpenSDK + `instagram-reels://` share; caption/hashtag composer on the share screen.
- Custom compositor (Core Image): filters/LUTs, real crossfades (A/B roll), overlay burn-in that also works on simulator.
- Per-slot trim UI with filmstrip (fixed window, content slides under it); pinch-to-reframe.
- Smart crop: Vision saliency + face detection choosing the 9:16 crop per clip.

**v3 — growth & AI:**
- Deep links `nik://template/{id}` + template attribution in shares (the flywheel).
- WhisperKit upgrade path for multilingual captions; TTS voiceover; auto B-roll.
- "Roll-style" AI: describe the video → template + auto-picked clips (Vision scene scoring over the camera roll).
- Onboarding personalization quiz → For You feed ordering; post-2nd-export rating prompt.

## 5. Validation status

- `xcodebuild` green (iPhone 17 Pro sim, Xcode 26.2).
- Maestro E2E: launch → template pager → 4-slot fill from seeded camera roll → editor (preview plays, overlay text renders, segment rail live) → export → **valid 1080×1920 H.264/AAC MP4, 6.6s** (verified with ffprobe) → share screen.
- Auto-captions and overlay burn-in require a real device (simulator lacks reliable speech recognition + offline CA rendering).
