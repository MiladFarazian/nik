import Foundation
import Photos
import UIKit

/// Wraps PhotoKit: authorization, asset fetching, thumbnail caching, and
/// exporting picked assets into the project sandbox so edits never depend
/// on live (possibly iCloud-evicted) library assets.
@Observable
final class PhotoLibrary {
    enum AccessState { case unknown, granted, limited, denied }

    var accessState: AccessState = .unknown
    var assets: PHFetchResult<PHAsset>?

    let cachingManager = PHCachingImageManager()

    @MainActor
    func requestAccess() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized: accessState = .granted
        case .limited: accessState = .limited
        case .denied, .restricted: accessState = .denied
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            accessState = newStatus == .authorized ? .granted : (newStatus == .limited ? .limited : .denied)
        @unknown default: accessState = .denied
        }
        if accessState == .granted || accessState == .limited {
            fetchAssets()
        }
    }

    func fetchAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.video.rawValue, PHAssetMediaType.image.rawValue
        )
        assets = PHAsset.fetchAssets(with: options)
    }

    func thumbnail(for asset: PHAsset, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            var resumed = false
            cachingManager.requestImage(
                for: asset, targetSize: size, contentMode: .aspectFill, options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    static func asset(withIdentifier id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Copies a picked video asset into the project sandbox as a plain file.
    /// Passthrough export flattens slow-mo AVCompositions and resolves iCloud originals.
    static func exportVideo(asset: PHAsset, to directory: URL) async throws -> URL {
        let destination = directory.appendingPathComponent("\(asset.localIdentifier.hashValue.magnitude).mov")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        let session: AVAssetExportSession = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestExportSession(
                forVideo: asset, options: options, exportPreset: AVAssetExportPresetPassthrough
            ) { session, _ in
                if let session {
                    continuation.resume(returning: session)
                } else {
                    continuation.resume(throwing: MediaError.assetUnavailable)
                }
            }
        }
        session.outputURL = destination
        session.outputFileType = .mov
        await session.export()
        if session.status != .completed {
            throw session.error ?? MediaError.exportFailed
        }
        return destination
    }

    /// Loads a full-resolution still for a photo asset.
    static func loadImage(asset: PHAsset, maxDimension: CGFloat = 2160) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxDimension, height: maxDimension),
                contentMode: .aspectFit, options: options
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: MediaError.assetUnavailable)
                }
            }
        }
    }

    static func saveToPhotos(videoURL: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        }
    }
}

enum MediaError: LocalizedError {
    case assetUnavailable
    case exportFailed
    case missingFill

    var errorDescription: String? {
        switch self {
        case .assetUnavailable: return "That clip couldn't be loaded from your library."
        case .exportFailed: return "The video couldn't be processed."
        case .missingFill: return "A template slot is missing its clip."
        }
    }
}
