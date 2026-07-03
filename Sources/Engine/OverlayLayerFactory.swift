import Foundation
import UIKit
import AVFoundation

/// Builds the CALayer tree burned into exports via AVVideoCompositionCoreAnimationTool.
/// All positions come from unit coordinates in the models so the SwiftUI preview
/// (which draws the same layers as views) matches the export pixel-for-pixel.
enum OverlayLayerFactory {

    /// CA layer animations must anchor to AVCoreAnimationBeginTimeAtZero, never 0.
    private static func caTime(_ seconds: Double) -> CFTimeInterval {
        AVCoreAnimationBeginTimeAtZero + max(0, seconds)
    }

    static func makeOverlayLayer(
        textLayers: [TextLayerSpec],
        captions: [CaptionSegment],
        captionStyle: CaptionStyle,
        watermark: Bool,
        renderSize: CGSize
    ) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)
        container.isGeometryFlipped = true  // CA origin is bottom-left; we lay out top-down

        for spec in textLayers {
            container.addSublayer(makeTextLayer(spec: spec, renderSize: renderSize))
        }
        if captionStyle != .none {
            for segment in captions {
                container.addSublayer(
                    makeCaptionLayer(segment: segment, style: captionStyle, renderSize: renderSize)
                )
            }
        }
        if watermark {
            container.addSublayer(makeWatermarkLayer(renderSize: renderSize))
        }
        return container
    }

    // MARK: - Template text layers

    static func attributedString(for spec: TextLayerSpec, scale: CGFloat = 1) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: spec.fontSize * scale, weight: .heavy)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        switch spec.style {
        case .outlined:
            attributes[.strokeColor] = UIColor.black
            attributes[.strokeWidth] = -4.0   // negative = stroke + fill
        case .bold, .block, .caption:
            break
        }
        return NSAttributedString(string: spec.text, attributes: attributes)
    }

    private static func makeTextLayer(spec: TextLayerSpec, renderSize: CGSize) -> CALayer {
        let text = attributedString(for: spec)
        let padding: CGFloat = spec.style == .block ? 28 : 8
        let bounds = text.boundingRect(
            with: CGSize(width: renderSize.width - 80, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], context: nil
        )
        let size = CGSize(width: ceil(bounds.width) + padding * 2, height: ceil(bounds.height) + padding * 2)

        let holder = CALayer()
        holder.frame = CGRect(
            x: (renderSize.width - size.width) / 2,
            y: renderSize.height * spec.relativeY - size.height / 2,
            width: size.width, height: size.height
        )
        if spec.style == .block {
            holder.backgroundColor = UIColor.black.withAlphaComponent(0.75).cgColor
            holder.cornerRadius = 18
        }

        let textLayer = CALayer()
        textLayer.contents = rasterize(text, size: CGSize(width: ceil(bounds.width), height: ceil(bounds.height)),
                                       shadow: spec.style == .bold)
        textLayer.frame = holder.bounds.insetBy(dx: padding, dy: padding)
        holder.addSublayer(textLayer)

        // Visible only during [start, start+duration]; pop-in scale.
        holder.opacity = 0
        let visibility = CAKeyframeAnimation(keyPath: "opacity")
        visibility.values = [0, 1, 1, 0]
        visibility.keyTimes = [0, 0.001, 0.999, 1]
        visibility.beginTime = caTime(spec.start)
        visibility.duration = spec.duration
        visibility.isRemovedOnCompletion = false
        visibility.fillMode = .backwards
        holder.add(visibility, forKey: "visibility")

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.8, 1.06, 1.0]
        pop.keyTimes = [0, 0.6, 1]
        pop.beginTime = caTime(spec.start)
        pop.duration = min(0.35, spec.duration)
        pop.isRemovedOnCompletion = false
        pop.fillMode = .both
        holder.add(pop, forKey: "pop")

        return holder
    }

    // MARK: - Captions

    private static func makeCaptionLayer(
        segment: CaptionSegment, style: CaptionStyle, renderSize: CGSize
    ) -> CALayer {
        let fontSize = renderSize.width * 0.055
        let font = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        let holder = CALayer()

        let words = segment.words.isEmpty
            ? [CaptionWord(text: segment.text, start: segment.start, duration: segment.duration)]
            : segment.words

        // Lay words out on one centered line (segments are pre-paged to 3-4 words).
        var wordSizes: [CGSize] = []
        let spacing: CGFloat = fontSize * 0.28
        for word in words {
            let size = (word.text as NSString).size(withAttributes: [.font: font])
            wordSizes.append(CGSize(width: ceil(size.width), height: ceil(size.height)))
        }
        let lineWidth = wordSizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, words.count - 1))
        let lineHeight = wordSizes.map(\.height).max() ?? fontSize

        holder.frame = CGRect(
            x: (renderSize.width - lineWidth) / 2,
            y: renderSize.height * 0.78 - lineHeight / 2,
            width: lineWidth, height: lineHeight
        )

        if style == .block {
            holder.backgroundColor = UIColor.black.withAlphaComponent(0.7).cgColor
            holder.cornerRadius = 12
        }

        var x: CGFloat = 0
        for (index, word) in words.enumerated() {
            let layer = CALayer()
            let attributed = NSAttributedString(string: word.text, attributes: [
                .font: font,
                .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black,
                .strokeWidth: style == .block ? 0 : -4.0,
            ])
            layer.contents = rasterize(attributed, size: CGSize(width: wordSizes[index].width, height: lineHeight))
            layer.frame = CGRect(x: x, y: 0, width: wordSizes[index].width, height: lineHeight)
            x += wordSizes[index].width + spacing
            holder.addSublayer(layer)

            switch style {
            case .karaoke:
                // Accent-colored copy fades in on top as the word is spoken.
                let accent = CALayer()
                let accentText = NSAttributedString(string: word.text, attributes: [
                    .font: font,
                    .foregroundColor: UIColor(red: 0.61, green: 0.36, blue: 1, alpha: 1),
                    .strokeColor: UIColor.black,
                    .strokeWidth: -4.0,
                ])
                accent.contents = rasterize(accentText, size: CGSize(width: wordSizes[index].width, height: lineHeight))
                accent.frame = layer.bounds
                accent.opacity = 0
                let sweep = CAKeyframeAnimation(keyPath: "opacity")
                sweep.values = [0, 1]
                sweep.keyTimes = [0, 0.2]
                sweep.beginTime = caTime(word.start)
                sweep.duration = max(0.1, word.duration)
                sweep.isRemovedOnCompletion = false
                sweep.fillMode = .both
                accent.add(sweep, forKey: "karaoke")
                layer.addSublayer(accent)
            case .bounce:
                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [1.0, 1.25, 1.0]
                scale.keyTimes = [0, 0.4, 1]
                scale.beginTime = caTime(word.start)
                scale.duration = max(0.12, word.duration)
                scale.isRemovedOnCompletion = false
                scale.fillMode = .both
                layer.add(scale, forKey: "bounce")
            case .plain, .block, .none:
                break
            }
        }

        holder.opacity = 0
        let visibility = CAKeyframeAnimation(keyPath: "opacity")
        visibility.values = [0, 1, 1, 0]
        visibility.keyTimes = [0, 0.02, 0.98, 1]
        visibility.beginTime = caTime(segment.start)
        visibility.duration = max(0.15, segment.duration)
        visibility.isRemovedOnCompletion = false
        visibility.fillMode = .backwards
        holder.add(visibility, forKey: "visibility")

        return holder
    }

    // MARK: - Watermark

    private static func makeWatermarkLayer(renderSize: CGSize) -> CALayer {
        let fontSize = renderSize.width * 0.032
        let text = NSAttributedString(string: "made with nik", attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.55),
        ])
        let size = (text.string as NSString).size(withAttributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        ])
        let layer = CALayer()
        layer.contents = rasterize(text, size: CGSize(width: ceil(size.width) + 4, height: ceil(size.height) + 4))
        layer.frame = CGRect(
            x: renderSize.width - size.width - 32,
            y: renderSize.height * 0.06,
            width: ceil(size.width) + 4, height: ceil(size.height) + 4
        )
        return layer
    }

    /// Draws an attributed string into a bitmap. The offline CA export renderer is
    /// far more reliable compositing plain bitmap contents than live CATextLayers,
    /// and this also renders color emoji correctly.
    private static func rasterize(_ text: NSAttributedString, size: CGSize, shadow: Bool = false) -> CGImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            if shadow {
                context.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 3), blur: 8,
                    color: UIColor.black.withAlphaComponent(0.8).cgColor
                )
            }
            text.draw(with: CGRect(origin: .zero, size: size),
                      options: [.usesLineFragmentOrigin], context: nil)
        }
        return image.cgImage
    }
}
