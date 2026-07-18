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
    /// bake task completed. Prefer explicit registerBakedSource + enqueueAfterBake
    /// at bake time; this path is a fallback when a baked file is applied later.
    static func considerAppliedBakedVideo(_ videoURL: URL, title: String? = nil) {
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return
        }

        // If library metadata still points at this artifact, refresh provenance.
        if let record = MediaLibraryService.shared.downloadedItems.first(where: { item in
            item.sceneBakeArtifact.map {
                URL(fileURLWithPath: $0.videoPath).standardizedFileURL == videoURL.standardizedFileURL
            } ?? false
        }), let artifact = record.sceneBakeArtifact {
            let sourcePath = record.sceneBakeEligibility?.contentRootPath ?? record.localFilePath
            VideoOptimizationQueueService.shared.registerBakedSource(
                videoURL: videoURL,
                sourcePath: sourcePath,
                artifact: artifact
            )
        } else {
            VideoOptimizationRecordStore.shared.recordImportedSourceIfNeeded(for: videoURL)
        }

        _ = VideoOptimizationQueueService.shared.enqueueAfterBakeIfNeeded(
            videoURL: videoURL,
            title: title
        )
    }
}
