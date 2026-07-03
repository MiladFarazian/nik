# Competitive & Technical Research Notes

Condensed from a multi-agent research sweep (July 2026) across the template-video and content-tool landscape. PLAN.md holds the synthesis; this file keeps the reference data.

## Competitor matrix

| App | Core job | Pricing | Rating / trust | Biggest weakness |
|---|---|---|---|---|
| **Roll** | Camera roll → your version of viral videos (templates) | freemium, influencer-promoted (comment-gated DM funnel) | early, thin public footprint | tiny catalog vs CapCut; the niche is open |
| **CapCut** | Full mobile editor + template flywheel w/ TikTok | Free w/ watermark; Standard ~$9.99/mo; Pro $19.99/mo / $179.99/yr (annual ~doubled in 2026) | 4.6★ (1.1M) but intense recent 1★ | paywall creep, export-time gating, ByteDance ToS/ban distrust |
| **InShot** | Fast simple editor | $4.99/mo, $19.99/yr, **$49.99 lifetime**; ad-watch watermark removal | 4.9★ (2.5M) masking reliability issues | lost drafts ("original file is missing"), export failures, shallow layers |
| **Videoleap** (Lightricks) | Pro-grade mobile compositing + AI (LTX models) | ~$9.99/mo / $69.99/yr; weekly-plan A/B tests ($9.99/wk!) | 4.6★ (145K) | subscription-trap complaints, paywall creep, no posting layer |
| **Captions/Mirage** | Talking-head AI (eye contact, dubbing, avatars) | $9.99–$279.99/mo credit tiers | 4.7★ (36K) | credit opacity, no distribution layer |
| **Opus Clip** | Long-form → shorts w/ virality score + scheduler | Free 60min/mo; $15/$29/mo; API on Business | G2 4.5; TP 4.0 (22% 1★) | cancellation dark patterns, virality-score skepticism |
| **Submagic** | Captions + shorts polish + scheduler + API | $19/$39/$69/mo; clips are a paid add-on | TP 4.6 (~700+) | billing/renewal complaints; strength: support |
| **SendShort** | Budget clips + faceless + scheduler | $19/$29/$59/mo | TP ~3.0 | credit double-billing, small-team support |
| **Pippit** (ByteDance) | Product URL → marketing video, publish + analytics | ~$29.99/mo credit pool, expiring | TP ~33 reviews, heavily negative | credit burn on failed gens, robot support |
| **Blotato** | AI content engine + 9-platform publishing + API/MCP | $29/$97/$499/mo | TP 2.0 (billing), product praised | trial→charge ambush; no mobile app |
| **Crayo** | Faceless clipper formats (fake-text, Reddit story) | $13/$27/$55/mo credits | TP ~2.7–3.8 polarized | post-cancel charges, no-refund policy |
| **Revid** | Prompt/tweet/link → video + auto-mode + API/MCP/CLI | $39–$199/mo credits | TP ~4.0 polarized | opaque credit burn (~735 credits per 30s video) |
| **Zeemo / ZapCap** | Budget captioning | $6.67–$16/mo | thin | credit economics, support |

## Category laws extracted

1. **Template flywheel** (CapCut × TikTok): deep link from feed → auto-fill → post w/ attribution. Support `app://template/{id}` from day one.
2. **Speed-to-post beats editing depth** in this niche; templates compile into ordinary projects so power users can still edit.
3. **Never gate at export time for completed work** — the single most-hated pattern in every review corpus.
4. **Billing transparency is a moat by itself**: annual-first, visible trial timeline, easy cancel. Half the category bleeds 1★ reviews purely over billing.
5. **Reliability = copy source media into a sandbox** at pick time; autosave; never edit against live PHAssets.
6. **Free captions attack CapCut directly** (they gate captions ~1/mo free); on-device transcription costs nothing to serve.
7. **Watermarked free exports are the acquisition channel**; watermark-removal toggle is the top-converting paywall trigger.
8. **Nobody in mobile does posting/scheduling well** — even a light post-workflow (caption composer, per-platform deep links) is a differentiator; full auto-posting is web-tool territory (and an IG policy minefield).

## Key technical facts (iOS engine)

- Same `AVComposition` + `AVVideoComposition` + `AVAudioMix` drives preview (AVPlayer, 540×960) and export (AVAssetExportSession, full res). Immutable-copy the composition before attaching to a player.
- Layer instructions cover transforms/opacity (cuts, dip-fades, zoom ramps); true crossfades need A/B roll overlap; filters/LUTs/luma wipes need a custom `AVVideoCompositing` (Core Image + Metal CIContext, BGRA pixel buffers from the render context pool).
- `AVVideoCompositionCoreAnimationTool` is export-only (preview needs `AVSynchronizedLayer` or view overlays) and **crashes in the iOS 26 simulator** (CA::OGL IOSurface xpc trap) — device-only; rasterize text to bitmaps for reliability/emoji.
- `preferredTransform` must be normalized (translate displayed rect to origin) before aspect-fill math; encoder dimensions must be even.
- Speed: insert `slotDuration × speed` of source, then `scaleTimeRange` to the slot duration — also stretches short sources gracefully.
- Photos → pre-encode to video clips (AVAssetWriter, 2 frames) so the composition stays uniform.
- PhotoKit: passthrough `requestExportSession` flattens slow-mo AVCompositions and pulls iCloud originals; always copy into the project sandbox.
- Transcription: SFSpeechRecognizer on-device (word timings via segments) now; SpeechAnalyzer (iOS 26) or WhisperKit for quality/multilingual later. Page captions at 3–4 words or >0.8s gaps.
- Sharing: TikTok OpenSDK (localIdentifier share) is the only first-class path; IG Reels via `instagram-reels://share` pasteboard (FB app ID, best-effort); YT via share sheet; save-to-Photos is the universal fallback.
- Export on-device realities: no background export runtime (`isIdleTimerDisabled`, warn user), thermal observation, HDR→SDR tone-map for v1.

## Reference reel

`instagram.com/reel/DZnXUnWvLox` — @jarrettcreates, June 15 2026, 1.4K likes / 618 comments. Caption: "Everything you've ever wanted is on the other side of believing in yourself. Post that reel start that business quit that job. Comment the app name 'Roll' and I will send it to you to try for free 📲" #viral #editing #Roll #AI. Format: motivational text-hook over meme-style visual + comment-gated CTA (classic Roll growth motion: influencer promo → comment → DM with download link). The video file itself is login-gated on Instagram and couldn't be pulled anonymously for audio transcription.
