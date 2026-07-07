import Foundation
import UIKit
import CoreImage
import CoreGraphics

/// Immutable, Sendable snapshot of everything the compositor needs to burn
/// overlays per frame. Every text / caption word / watermark is rasterized to a
/// CGImage ONCE (up front, on the main actor) and wrapped as a CIImage so the
/// per-frame compositor only has to translate/scale/composite — no text layout.
///
/// All `frame`s are in render-pixel coordinates with a **top-left origin, y-down**
/// (the same convention the SwiftUI preview and the old CALayer tree used). The
/// compositor converts to Core Image's bottom-left / y-up space when placing.
///
/// `@unchecked Sendable`: the stored CIImages are immutable value snapshots that
/// are only read on the compositor thread; they are never mutated after `make`.
final class OverlaySpec: @unchecked Sendable {
    struct TextItem {
        let image: CIImage
        let frame: CGRect
        let start: Double
        let duration: Double
    }
    struct WordItem {
        let white: CIImage
        let accent: CIImage?   // karaoke: accent-colored copy composited once time >= start
        let frame: CGRect
        let start: Double
        let duration: Double
    }
    struct CaptionItem {
        let background: CIImage?      // block style rounded plate
        let backgroundFrame: CGRect
        let words: [WordItem]
        let start: Double
        let duration: Double
        let style: CaptionStyle
    }
    struct WatermarkItem {
        let image: CIImage
        let frame: CGRect
    }

    let renderSize: CGSize
    let texts: [TextItem]
    let captions: [CaptionItem]
    let watermark: WatermarkItem?

    init(renderSize: CGSize, texts: [TextItem], captions: [CaptionItem], watermark: WatermarkItem?) {
        self.renderSize = renderSize
        self.texts = texts
        self.captions = captions
        self.watermark = watermark
    }
}

/// Builds an `OverlaySpec` by rasterizing the project's overlay models. Runs on the
/// main actor because it uses UIGraphicsImageRenderer / UIKit text drawing. This is
/// a one-time cost per export (not per frame). Rasterization happens at full render
/// resolution (scale 1) so text stays crisp without supersampling.
enum OverlayBuilder {

    @MainActor
    static func make(
        textLayers: [TextLayerSpec],
        captions: [CaptionSegment],
        captionStyle: CaptionStyle,
        watermark: Bool,
        renderSize: CGSize
    ) -> OverlaySpec {
        let s = renderSize.width / 1080.0   // render scale relative to the 1080-wide authoring space

        var texts: [OverlaySpec.TextItem] = []
        for spec in textLayers {
            if let item = makeText(spec: spec, renderSize: renderSize, s: s) { texts.append(item) }
        }

        var caps: [OverlaySpec.CaptionItem] = []
        if captionStyle != .none {
            for segment in captions {
                if let item = makeCaption(segment: segment, style: captionStyle, renderSize: renderSize, s: s) {
                    caps.append(item)
                }
            }
        }

        var wm: OverlaySpec.WatermarkItem?
        if watermark { wm = makeWatermark(renderSize: renderSize, s: s) }

        return OverlaySpec(renderSize: renderSize, texts: texts, captions: caps, watermark: wm)
    }

    // MARK: - Template text

    @MainActor
    private static func makeText(spec: TextLayerSpec, renderSize: CGSize, s: CGFloat) -> OverlaySpec.TextItem? {
        let fontSize = spec.fontSize * s
        let font = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        if spec.style == .outlined {
            attributes[.strokeColor] = UIColor.black
            attributes[.strokeWidth] = -4.0    // negative == stroke + fill
        }
        let text = NSAttributedString(string: spec.text, attributes: attributes)

        let padding: CGFloat = (spec.style == .block ? 28 : 8) * s
        let maxWidth = max(1, renderSize.width - 80 * s)
        let bounds = text.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], context: nil
        )
        let contentSize = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        let holderSize = CGSize(width: contentSize.width + padding * 2, height: contentSize.height + padding * 2)

        let image = rasterize(size: holderSize) { _ in
            if spec.style == .block {
                let rect = CGRect(origin: .zero, size: holderSize)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 18 * s)
                UIColor.black.withAlphaComponent(0.75).setFill()
                path.fill()
            }
            let textRect = CGRect(x: padding, y: padding, width: contentSize.width, height: contentSize.height)
            text.draw(with: textRect, options: [.usesLineFragmentOrigin], context: nil)
        }
        guard let image else { return nil }

        let frame = CGRect(
            x: (renderSize.width - holderSize.width) / 2,
            y: renderSize.height * spec.relativeY - holderSize.height / 2,
            width: holderSize.width, height: holderSize.height
        )
        return OverlaySpec.TextItem(image: image, frame: frame, start: spec.start, duration: spec.duration)
    }

    // MARK: - Captions

    @MainActor
    private static func makeCaption(
        segment: CaptionSegment, style: CaptionStyle, renderSize: CGSize, s: CGFloat
    ) -> OverlaySpec.CaptionItem? {
        let fontSize = renderSize.width * 0.055
        let font = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        let spacing = fontSize * 0.28

        let words = segment.words.isEmpty
            ? [CaptionWord(text: segment.text, start: segment.start, duration: segment.duration)]
            : segment.words

        var wordSizes: [CGSize] = []
        for word in words {
            let size = (word.text as NSString).size(withAttributes: [.font: font])
            wordSizes.append(CGSize(width: ceil(size.width), height: ceil(size.height)))
        }
        let lineWidth = wordSizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, words.count - 1))
        let lineHeight = wordSizes.map(\.height).max() ?? ceil(fontSize)
        guard lineWidth >= 1, lineHeight >= 1 else { return nil }

        let holderFrame = CGRect(
            x: (renderSize.width - lineWidth) / 2,
            y: renderSize.height * 0.78 - lineHeight / 2,
            width: lineWidth, height: lineHeight
        )

        var background: CIImage?
        if style == .block {
            background = rasterize(size: CGSize(width: lineWidth, height: lineHeight)) { _ in
                let rect = CGRect(x: 0, y: 0, width: lineWidth, height: lineHeight)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 12 * s)
                UIColor.black.withAlphaComponent(0.7).setFill()
                path.fill()
            }
        }

        let accentColor = UIColor(red: 0.61, green: 0.36, blue: 1, alpha: 1)
        var items: [OverlaySpec.WordItem] = []
        var x = holderFrame.minX
        for (index, word) in words.enumerated() {
            let wordSize = CGSize(width: wordSizes[index].width, height: lineHeight)
            let strokeWidth: CGFloat = style == .block ? 0 : -4.0

            let white = rasterize(size: wordSize) { _ in
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: UIColor.white,
                    .strokeColor: UIColor.black, .strokeWidth: strokeWidth,
                ]
                NSAttributedString(string: word.text, attributes: attrs)
                    .draw(with: CGRect(origin: .zero, size: wordSize),
                          options: [.usesLineFragmentOrigin], context: nil)
            }
            var accent: CIImage?
            if style == .karaoke {
                accent = rasterize(size: wordSize) { _ in
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font, .foregroundColor: accentColor,
                        .strokeColor: UIColor.black, .strokeWidth: -4.0,
                    ]
                    NSAttributedString(string: word.text, attributes: attrs)
                        .draw(with: CGRect(origin: .zero, size: wordSize),
                              options: [.usesLineFragmentOrigin], context: nil)
                }
            }
            if let white {
                items.append(OverlaySpec.WordItem(
                    white: white, accent: accent,
                    frame: CGRect(x: x, y: holderFrame.minY, width: wordSize.width, height: wordSize.height),
                    start: word.start, duration: word.duration
                ))
            }
            x += wordSize.width + spacing
        }

        return OverlaySpec.CaptionItem(
            background: background, backgroundFrame: holderFrame, words: items,
            start: segment.start, duration: max(0.15, segment.duration), style: style
        )
    }

    // MARK: - Watermark

    @MainActor
    private static func makeWatermark(renderSize: CGSize, s: CGFloat) -> OverlaySpec.WatermarkItem? {
        let fontSize = renderSize.width * 0.032
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let string = "made with nik"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.55),
        ]
        let textSize = (string as NSString).size(withAttributes: attrs)
        let imageSize = CGSize(width: ceil(textSize.width) + 4, height: ceil(textSize.height) + 4)
        let image = rasterize(size: imageSize) { _ in
            NSAttributedString(string: string, attributes: attrs)
                .draw(with: CGRect(origin: .zero, size: imageSize),
                      options: [.usesLineFragmentOrigin], context: nil)
        }
        guard let image else { return nil }
        let frame = CGRect(
            x: renderSize.width - imageSize.width - 32 * s,
            y: renderSize.height * 0.06,
            width: imageSize.width, height: imageSize.height
        )
        return OverlaySpec.WatermarkItem(image: image, frame: frame)
    }

    // MARK: - Rasterization

    /// Draws into a bitmap at render resolution (scale 1) and returns it as a CIImage
    /// (origin top-left when authored; `CIImage(cgImage:)` presents it upright).
    @MainActor
    private static func rasterize(size: CGSize, draw: (CGContext) -> Void) -> CIImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let uiImage = renderer.image { ctx in draw(ctx.cgContext) }
        guard let cg = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }
}
