import Foundation
import Speech
import AVFoundation

/// On-device transcription of the project's audio into caption segments with
/// word timings (for karaoke/bounce styles). Uses SFSpeechRecognizer; the
/// upgrade path is SpeechAnalyzer (iOS 26+) or WhisperKit for more languages.
enum TranscriptionService {
    static let maxWordsPerPage = 4

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Extracts the composition's audio to a file and transcribes it.
    static func transcribe(composition: AVComposition, projectID: UUID) async throws -> [CaptionSegment] {
        let audioURL = ProjectStore.mediaDirectory(for: projectID)
            .deletingLastPathComponent()
            .appendingPathComponent("transcribe.m4a")
        try? FileManager.default.removeItem(at: audioURL)

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaError.exportFailed
        }
        session.outputURL = audioURL
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else {
            throw session.error ?? MediaError.exportFailed
        }

        return try await transcribeAudio(url: audioURL)
    }

    private static func transcribeAudio(url: URL) async throws -> [CaptionSegment] {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw TranscriptionError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result)
                } else if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }
        }

        let words = result.bestTranscription.segments.map {
            CaptionWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
        }
        return page(words: words)
    }

    /// Groups words into short caption pages (TikTok style: 3-4 words per page).
    static func page(words: [CaptionWord]) -> [CaptionSegment] {
        guard !words.isEmpty else { return [] }
        var segments: [CaptionSegment] = []
        var pageWords: [CaptionWord] = []

        func flush() {
            guard let first = pageWords.first, let last = pageWords.last else { return }
            let start = first.start
            let end = last.start + last.duration
            segments.append(CaptionSegment(
                text: pageWords.map(\.text).joined(separator: " "),
                start: start,
                duration: max(0.3, end - start),
                words: pageWords
            ))
            pageWords = []
        }

        for word in words {
            // Break the page on word-count or a >0.8s silence gap.
            if let last = pageWords.last,
               pageWords.count >= maxWordsPerPage || word.start - (last.start + last.duration) > 0.8 {
                flush()
            }
            pageWords.append(word)
        }
        flush()
        return segments
    }
}

enum TranscriptionError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Speech recognition isn't available on this device."
        }
    }
}
