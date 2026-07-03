import Foundation
import Photos
import UIKit
import AVFoundation

/// Resolves a project's slot fills into local video files inside the project sandbox.
/// Videos are copied via passthrough export; photos are pre-encoded into short
/// Ken-Burns-ready video clips so the composition stays uniform (video-only tracks).
struct MediaResolver {
    struct ResolvedSlot {
        let slotIndex: Int
        let url: URL
        let isFromPhoto: Bool
    }

    var progress: (@Sendable (Double) -> Void)?

    func resolve(project: EditProject, template: Template) async throws -> [Int: ResolvedSlot] {
        let mediaDir = ProjectStore.mediaDirectory(for: project.id)
        var resolved: [Int: ResolvedSlot] = [:]
        let total = Double(template.slots.count)

        for (index, slot) in template.slots.enumerated() {
            guard let fill = project.fills.first(where: { $0.id == slot.id }) else {
                throw MediaError.missingFill
            }
            guard let asset = PhotoLibrary.asset(withIdentifier: fill.assetLocalIdentifier) else {
                throw MediaError.assetUnavailable
            }
            if fill.isVideo {
                let url = try await PhotoLibrary.exportVideo(asset: asset, to: mediaDir)
                resolved[slot.id] = ResolvedSlot(slotIndex: slot.id, url: url, isFromPhoto: false)
            } else {
                let image = try await PhotoLibrary.loadImage(asset: asset)
                let url = mediaDir.appendingPathComponent("photo-\(fill.assetLocalIdentifier.hashValue.magnitude).mov")
                if !FileManager.default.fileExists(atPath: url.path) {
                    try await PhotoVideoEncoder.encode(
                        image: image, duration: slot.duration + 0.5, to: url
                    )
                }
                resolved[slot.id] = ResolvedSlot(slotIndex: slot.id, url: url, isFromPhoto: true)
            }
            progress?(Double(index + 1) / total)
        }
        return resolved
    }
}

/// Encodes a still image into a short H.264 video clip (used for photo slots).
enum PhotoVideoEncoder {
    static func encode(image: UIImage, duration: Double, to url: URL, fps: Int32 = 30) async throws {
        guard let cgImage = image.cgImage else { throw MediaError.exportFailed }

        // Cap encode size; aspect-fill crop happens later in the composition.
        let maxDim: CGFloat = 1920
        let scale = min(1, maxDim / max(CGFloat(cgImage.width), CGFloat(cgImage.height)))
        // Encoder dimensions must be even.
        let width = Int(CGFloat(cgImage.width) * scale) & ~1
        let height = Int(CGFloat(cgImage.height) * scale) & ~1

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaError.exportFailed }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else { throw MediaError.exportFailed }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { throw MediaError.exportFailed }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        // A still only needs a frame at each end of the clip; playback holds the frame.
        let frameCount = max(2, Int(duration * Double(fps)))
        let times = [0, frameCount - 1]
        for frameIndex in times {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let time = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
            adaptor.append(buffer, withPresentationTime: time)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? MediaError.exportFailed
        }
    }
}
