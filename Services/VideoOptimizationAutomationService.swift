import Foundation

/// Bridges a successfully applied ordinary video to the shared optimization
/// queue. It intentionally has no player, scheduler, Scene, or UI behavior.
@MainActor
enum VideoOptimizationAutomationService {
    /// Applying a video must keep playback on the source file. The queue will
    /// later notify the player only when an optimization actually replaces it.
    static func considerAppliedVideo(_ videoURL: URL, title: String? = nil) {
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return
        }

        VideoOptimizationRecordStore.shared.recordImportedSourceIfNeeded(for: videoURL)

        _ = VideoOptimizationQueueService.shared.enqueueAutomaticOptimizationIfNeeded(
            videoURL: videoURL,
            title: title
        )
    }

    /// Existing Scene bake artifacts can be selected long after their original
    /// bake task completed. Rehydrate their provenance before applying the
    /// shared automatic policy so the sidecar remains the one durable source.
    static func considerAppliedBakedVideo(_ videoURL: URL, title: String? = nil) {
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return
        }

        if let record = MediaLibraryService.shared.downloadedItems.first(where: { record in
            record.sceneBakeArtifact.map {
                URL(fileURLWithPath: $0.videoPath).standardizedFileURL == videoURL.standardizedFileURL
            } ?? false
        }), let artifact = record.sceneBakeArtifact {
            VideoOptimizationQueueService.shared.registerBakedSource(
                videoURL: videoURL,
                sourcePath: record.sceneBakeEligibility?.contentRootPath ?? record.localFilePath,
                artifact: artifact
            )
        }

        _ = VideoOptimizationQueueService.shared.enqueueAutomaticOptimizationIfNeeded(
            videoURL: videoURL,
            title: title
        )
    }
}
