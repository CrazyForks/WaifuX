import Foundation

/// Persists only unfinished video-optimization work. Terminal video outcomes
/// live in the sidecar JSON beside the media file, never in this queue store.
struct VideoOptimizationQueueCheckpointStore {
    private struct Snapshot: Codable {
        let version: Int
        let items: [Item]
        let sourceRestoreRequests: [SourceRestoreRequest]?
    }

    struct RestoredState {
        let items: [FrameInterpolationQueueItem]
        let sourceRestoreRequests: [SourceRestoreRequest]
    }

    /// A restore request is unfinished pipeline work too: the downloaded file
    /// might arrive after the app relaunches, so its requested retry or
    /// blacklist operation must not depend on a live detail sheet.
    struct SourceRestoreRequest: Codable {
        let videoPath: String
        let title: String?
        let targetFPS: Int
        let operations: [FrameInterpolationQueueItem.Operation]
        let blacklistOperation: FrameInterpolationQueueItem.Operation?

        static func enqueue(
            videoURL: URL,
            title: String?,
            targetFPS: Int,
            operations: [FrameInterpolationQueueItem.Operation]
        ) -> SourceRestoreRequest {
            SourceRestoreRequest(
                videoPath: videoURL.standardizedFileURL.path,
                title: title,
                targetFPS: targetFPS,
                operations: operations,
                blacklistOperation: nil
            )
        }

        static func blacklist(
            videoURL: URL,
            title: String?,
            targetFPS: Int,
            operation: FrameInterpolationQueueItem.Operation
        ) -> SourceRestoreRequest {
            SourceRestoreRequest(
                videoPath: videoURL.standardizedFileURL.path,
                title: title,
                targetFPS: targetFPS,
                operations: [],
                blacklistOperation: operation
            )
        }
    }

    struct Item: Codable {
        let id: UUID
        let videoPath: String
        let title: String
        let targetFPS: Int
        let source: FrameInterpolationQueueItem.Source
        let operations: [FrameInterpolationQueueItem.Operation]
        let completedOperations: [FrameInterpolationQueueItem.Operation]
        let currentOperation: FrameInterpolationQueueItem.Operation?
        let progress: Double
        let currentStage: String
        let addedAt: Date

        init(queueItem: FrameInterpolationQueueItem) {
            id = queueItem.id
            videoPath = queueItem.videoURL.standardizedFileURL.path
            title = queueItem.title
            targetFPS = queueItem.targetFPS
            source = queueItem.source
            operations = queueItem.operations
            completedOperations = Array(queueItem.completedOperations)
            currentOperation = queueItem.currentOperation
            progress = queueItem.progress
            currentStage = queueItem.currentStage
            addedAt = queueItem.addedAt
        }

        func restoredQueueItem() -> FrameInterpolationQueueItem? {
            let videoURL = URL(fileURLWithPath: videoPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: videoURL.path) else { return nil }

            let pendingOperations = operations.filter { !completedOperations.contains($0) }
            guard !pendingOperations.isEmpty else { return nil }

            return FrameInterpolationQueueItem(
                id: id,
                videoURL: videoURL,
                title: title,
                targetFPS: targetFPS,
                source: source,
                operations: operations,
                completedOperations: Set(completedOperations),
                currentOperation: nil,
                sourceFPS: nil,
                status: .waiting,
                progress: 0,
                writtenFrames: 0,
                totalFrames: nil,
                opticalFlowFrames: 0,
                elapsedSeconds: 0,
                remainingSeconds: nil,
                currentStage: t("frameInterpolationStageWaiting"),
                outputURL: nil,
                addedAt: addedAt
            )
        }
    }

    static func load() -> RestoredState {
        guard let data = try? Data(contentsOf: fileURL) else {
            return RestoredState(items: [], sourceRestoreRequests: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data), snapshot.version == 1 else {
            return RestoredState(items: [], sourceRestoreRequests: [])
        }
        return RestoredState(
            items: snapshot.items.compactMap { $0.restoredQueueItem() },
            sourceRestoreRequests: snapshot.sourceRestoreRequests ?? []
        )
    }

    static func save(
        _ items: [FrameInterpolationQueueItem],
        sourceRestoreRequests: [SourceRestoreRequest]
    ) {
        let pendingItems = items.filter { !$0.isTerminalForCleanup }
        guard !pendingItems.isEmpty || !sourceRestoreRequests.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        let snapshot = Snapshot(
            version: 1,
            items: pendingItems.map(Item.init(queueItem:)),
            sourceRestoreRequests: sourceRestoreRequests
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.error(.media, "写入视频优化任务断点失败", metadata: [
                "path": fileURL.path,
                "error": error.localizedDescription,
            ])
        }
    }

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent("WaifuX", isDirectory: true)
            .appendingPathComponent("VideoOptimization", isDirectory: true)
            .appendingPathComponent("pending-queue.json")
    }
}
