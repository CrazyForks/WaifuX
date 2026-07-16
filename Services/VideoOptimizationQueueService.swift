import Foundation
import AVFoundation
import AppKit
import CryptoKit
import CoreGraphics
import CoreVideo
import VideoToolbox
import Vision
import Combine

extension Notification.Name {
    /// 视频优化原地替换文件后发出；播放器决定该文件是否仍是当前壁纸。
    static let videoOptimizationFileDidReplace = Notification.Name("videoOptimizationFileDidReplace")
}

struct VideoFrameInterpolationDecision: Sendable {
    let sourceFPS: Double?
    let targetFPS: Int
    let shouldInterpolate: Bool
    let reason: String
}

enum VideoFrameInterpolationAnalyzer {
    static func decision(for url: URL, targetFPS: Int) async -> VideoFrameInterpolationDecision {
        guard targetFPS > 0 else {
            return VideoFrameInterpolationDecision(sourceFPS: nil, targetFPS: targetFPS, shouldInterpolate: false, reason: "目标 FPS 无效")
        }

        guard let sourceFPS = await sourceFrameRate(for: url), sourceFPS > 0 else {
            return VideoFrameInterpolationDecision(sourceFPS: nil, targetFPS: targetFPS, shouldInterpolate: false, reason: "无法读取原始 FPS")
        }

        let shouldInterpolate = sourceFPS < Double(targetFPS)
        return VideoFrameInterpolationDecision(
            sourceFPS: sourceFPS,
            targetFPS: targetFPS,
            shouldInterpolate: shouldInterpolate,
            reason: shouldInterpolate ? "原始 FPS 低于目标 FPS" : "原始 FPS 已达到或高于目标 FPS"
        )
    }

    static func sourceFrameRate(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        if let nominalFrameRate = try? await track.load(.nominalFrameRate),
           nominalFrameRate > 0 {
            return Double(nominalFrameRate)
        }

        if let minFrameDuration = try? await track.load(.minFrameDuration),
           minFrameDuration.isValid,
           minFrameDuration.seconds.isFinite,
           minFrameDuration.seconds > 0 {
            return 1.0 / minFrameDuration.seconds
        }

        return nil
    }
}

struct FrameInterpolationQueueItem: Identifiable, Equatable {
    enum Operation: String, CaseIterable, Codable, Hashable {
        case loopAnalysis
        case frameInterpolation

        var label: String {
            switch self {
            case .loopAnalysis: return t("videoOptimizationAnalyzeLoop")
            case .frameInterpolation: return t("videoOptimizationInterpolateVideo")
            }
        }
    }

    enum Status: Equatable {
        case waiting
        case analyzing
        case running
        case completed
        case failed(String)

        var label: String {
            switch self {
            case .waiting: return t("frameInterpolationStatusWaiting")
            case .analyzing: return t("frameInterpolationStatusAnalyzing")
            case .running: return t("frameInterpolationStatusRunning")
            case .completed: return t("frameInterpolationStatusCompleted")
            case .failed: return t("frameInterpolationStatusFailed")
            }
        }
    }

    enum Source: String, Codable {
        case automatic = "自动"
        case manual = "手动"
    }

    let id: UUID
    let videoURL: URL
    let title: String
    let targetFPS: Int
    let source: Source
    var operations: [Operation]
    var completedOperations: Set<Operation>
    var currentOperation: Operation?
    var sourceFPS: Double?
    var status: Status
    var progress: Double
    var writtenFrames: Int64
    var totalFrames: Int64?
    var opticalFlowFrames: Int64
    var elapsedSeconds: TimeInterval
    var remainingSeconds: TimeInterval?
    var currentStage: String
    var outputURL: URL?
    var addedAt: Date

    var statusText: String {
        if case let .failed(message) = status {
            return message.isEmpty ? status.label : "\(status.label)：\(message)"
        }
        return status.label
    }

    var isTerminalForCleanup: Bool {
        switch status {
        case .completed, .failed:
            return true
        case .waiting, .analyzing, .running:
            return false
        }
    }
}

typealias VideoOptimizationQueueItem = FrameInterpolationQueueItem

/// The settings-derived policy used when a downloaded or newly applied local
/// video is considered for automatic optimization. Manual requests always pass
/// their requested operations explicitly.
struct VideoOptimizationAutomaticPolicy: Equatable {
    var loopAnalysisEnabled: Bool
    var automaticallyAnalyzeLoopPoints: Bool
    var frameInterpolationEnabled: Bool
    var automaticallyInterpolateFrames: Bool
    var targetFPS: Int

    static let disabled = VideoOptimizationAutomaticPolicy(
        loopAnalysisEnabled: false,
        automaticallyAnalyzeLoopPoints: false,
        frameInterpolationEnabled: false,
        automaticallyInterpolateFrames: false,
        targetFPS: 60
    )
}

private enum VideoOptimizationQueueOutcome: String {
    case completed
    case failed
    case cancelled
}

struct FrameInterpolationExportProgress: Sendable {
    let progress: Double
    let writtenFrames: Int64
    let totalFrames: Int64?
    let opticalFlowFrames: Int64
    let elapsedSeconds: TimeInterval
    let remainingSeconds: TimeInterval?
    let currentStage: String
}

struct FrameInterpolationRecordItem: Identifiable, Equatable, Codable {
    let id: String
    let videoPath: String
    let title: String
    let targetFPS: Int
    let recordedAt: Date

    var videoURL: URL {
        URL(fileURLWithPath: videoPath)
    }
}

@MainActor
final class VideoOptimizationQueueService: ObservableObject {
    static let shared = VideoOptimizationQueueService()

    @Published private(set) var items: [FrameInterpolationQueueItem] = [] {
        didSet { scheduleQueueCheckpointSave() }
    }
    @Published private(set) var automaticPolicy = VideoOptimizationAutomaticPolicy.disabled

    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var heartbeatTasks: [UUID: Task<Void, Never>] = [:]
    private var taskStartDates: [UUID: Date] = [:]
    /// A source restore is unfinished pipeline work. It is checkpointed with
    /// the active queue until the resumed download writes its new sidecar.
    private var sourceRestoreRequests: [String: VideoOptimizationQueueCheckpointStore.SourceRestoreRequest] = [:]
    private var automaticPolicyLoaded = false
    private var didMigrateLegacyTerminalState = false
    private var queueCheckpointSaveTask: Task<Void, Never>?

    private init() {
        let restoredState = VideoOptimizationQueueCheckpointStore.load()
        items = restoredState.items
        sourceRestoreRequests = Dictionary(
            uniqueKeysWithValues: restoredState.sourceRestoreRequests.map { ($0.videoPath, $0) }
        )
        Task { @MainActor [weak self] in
            self?.scheduleNext()
        }
    }

    /// 由设置页恢复偏好后调用。
    func applySettings(automaticPolicy: VideoOptimizationAutomaticPolicy) {
        self.automaticPolicy = automaticPolicy
        automaticPolicyLoaded = true
        migrateLegacyTerminalStateIfNeeded()
    }

    var isLoopAnalysisEnabled: Bool {
        ensureAutomaticPolicyLoaded()
        return automaticPolicy.loopAnalysisEnabled
    }

    var isFrameInterpolationEnabled: Bool {
        ensureAutomaticPolicyLoaded()
        return automaticPolicy.frameInterpolationEnabled
    }

    /// 将单个视频加入循环分析任务。若同一文件已有待处理任务，返回原任务 id。
    @discardableResult
    func enqueueLoopAnalysis(
        videoURL: URL,
        title: String? = nil,
        source: FrameInterpolationQueueItem.Source = .manual
    ) -> UUID? {
        enqueue(
            videoURL: videoURL,
            title: title,
            targetFPS: FrameInterpolationTargetFPSResolver.targetFPSForManualAction(),
            source: source,
            operations: [.loopAnalysis]
        )
    }

    /// Explicit interpolation is independent from loop analysis. Automatic
    /// follow-up interpolation is decided only after a loop task finishes.
    @discardableResult
    func enqueueFrameInterpolation(
        videoURL: URL,
        title: String? = nil,
        targetFPS: Int? = nil,
        source: FrameInterpolationQueueItem.Source = .manual
    ) -> UUID? {
        enqueue(
            videoURL: videoURL,
            title: title,
            targetFPS: targetFPS ?? FrameInterpolationTargetFPSResolver.targetFPSForManualAction(),
            source: source,
            operations: [.frameInterpolation]
        )
    }

    /// 批量入口只接受本地视频，文件枚举与任务去重均由服务负责。
    @discardableResult
    func enqueue(
        videoURLs: [URL],
        operation: FrameInterpolationQueueItem.Operation,
        targetFPS: Int? = nil,
        source: FrameInterpolationQueueItem.Source = .manual
    ) -> [UUID] {
        videoURLs.compactMap { videoURL in
            enqueue(
                videoURL: videoURL,
                title: videoURL.deletingPathExtension().lastPathComponent,
                targetFPS: targetFPS ?? FrameInterpolationTargetFPSResolver.targetFPSForManualAction(),
                source: source,
                operations: [operation]
            )
        }
    }

    /// 文件夹批量入口。递归扫描支持的视频扩展名，但调用方无需自行枚举文件。
    @discardableResult
    func enqueueFolder(
        at folderURL: URL,
        operation: FrameInterpolationQueueItem.Operation,
        targetFPS: Int? = nil,
        source: FrameInterpolationQueueItem.Source = .manual
    ) -> [UUID] {
        let extensions = Set(["mp4", "mov", "m4v", "mkv"])
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let urls = enumerator.compactMap { $0 as? URL }.filter { url in
            guard extensions.contains(url.pathExtension.lowercased()) else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        return enqueue(videoURLs: urls, operation: operation, targetFPS: targetFPS, source: source)
    }

    /// 从“我的库”的逻辑文件夹解析本地视频并批量入队；视图只传递文件夹与操作，不枚举或替换文件。
    @discardableResult
    func enqueueLibraryFolder(
        _ folder: LibraryFolder,
        operations: [FrameInterpolationQueueItem.Operation],
        targetFPS: Int? = nil,
        source: FrameInterpolationQueueItem.Source = .manual
    ) -> [UUID] {
        let effectiveTargetFPS = targetFPS ?? FrameInterpolationTargetFPSResolver.targetFPSForManualAction()
        return libraryOptimizationTargets(in: folder).compactMap { target in
            enqueue(
                videoURL: target.videoURL,
                title: target.title,
                targetFPS: effectiveTargetFPS,
                source: source,
                operations: operations
            )
        }
    }

    /// 统一判断库条目是否能作为视频优化输入，避免各个视图各自猜测文件类型。
    func optimizableVideoURL(from localURL: URL?) -> URL? {
        guard let localURL, localURL.isFileURL else {
            return nil
        }
        guard let videoURL = MediaItem.resolveLocalVideoFile(from: localURL) else {
            return nil
        }
        return videoURL
    }

    /// 下载完成后按设置决定首个优化任务。自动循环分析与自动补帧
    /// 是独立队列：循环分析完成时才会按当前设置投递补帧。
    @discardableResult
    func enqueueAfterDownloadIfNeeded(
        videoURL: URL,
        title: String? = nil
    ) -> UUID? {
        let path = videoURL.standardizedFileURL.path
        if let request = sourceRestoreRequests.removeValue(forKey: path) {
            persistQueueCheckpointImmediately()
            if let operation = request.blacklistOperation {
                VideoOptimizationRecordStore.shared.markBlacklisted(
                    operation,
                    for: videoURL,
                    title: request.title ?? title ?? videoURL.deletingPathExtension().lastPathComponent,
                    targetFPS: request.targetFPS
                )
                return nil
            } else {
                return enqueue(
                    videoURL: videoURL,
                    title: request.title ?? title,
                    targetFPS: request.targetFPS,
                    source: .manual,
                    operations: request.operations
                )
            }
        }
        return enqueueAutomaticOptimizationIfNeeded(videoURL: videoURL, title: title)
    }

    /// Defers one manual operation until the original source has been downloaded.
    /// The restored source enters the same queue as every other request, so it
    /// cannot retain a separate multi-step pipeline outside the queue.
    func requestAfterSourceRestore(
        videoURL: URL,
        title: String? = nil,
        operations: [FrameInterpolationQueueItem.Operation]
    ) {
        let initialOperation = initialQueueOperation(from: operations)
        guard !initialOperation.isEmpty else { return }
        sourceRestoreRequests[videoURL.standardizedFileURL.path] = .enqueue(
            videoURL: videoURL,
            title: title,
            targetFPS: FrameInterpolationTargetFPSResolver.targetFPSForManualAction(),
            operations: initialOperation
        )
        persistQueueCheckpointImmediately()
    }

    /// A blacklist always applies to a fresh source file. The caller restores
    /// the original download first, then the terminal blacklist is written to
    /// that new file's adjacent sidecar instead of an in-memory flag.
    func requestBlacklistAfterSourceRestore(
        videoURL: URL,
        title: String? = nil,
        operation: FrameInterpolationQueueItem.Operation
    ) {
        sourceRestoreRequests[videoURL.standardizedFileURL.path] = .blacklist(
            videoURL: videoURL,
            title: title,
            targetFPS: FrameInterpolationTargetFPSResolver.targetFPSForManualAction(),
            operation: operation
        )
        persistQueueCheckpointImmediately()
    }

    func cancelSourceRestoreRequest(videoURL: URL) {
        sourceRestoreRequests.removeValue(forKey: videoURL.standardizedFileURL.path)
        persistQueueCheckpointImmediately()
    }

    /// Applies the persisted automatic policy to a local source video. Download
    /// completion, Scene bake completion, and a successful video application
    /// share this API; callers must not enumerate, replace, or refresh playback.
    ///
    /// When loop analysis is still needed it is always the first independent
    /// task. Frame interpolation is only enqueued after that loop task finishes.
    /// If loop analysis is disabled or already has a terminal record, an enabled
    /// automatic interpolation policy can enqueue directly.
    @discardableResult
    func enqueueAutomaticOptimizationIfNeeded(
        videoURL: URL,
        title: String? = nil
    ) -> UUID? {
        ensureAutomaticPolicyLoaded()
        let policy = automaticPolicy
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return nil
        }
        let ext = videoURL.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v", "mkv"].contains(ext) else { return nil }

        let targetFPS = FrameInterpolationTargetFPSResolver.nearestAllowedFixedFPS(policy.targetFPS)
        guard targetFPS > 0 else { return nil }
        if policy.loopAnalysisEnabled,
           policy.automaticallyAnalyzeLoopPoints,
           automaticOperationsNeedingWork([.loopAnalysis], for: videoURL, targetFPS: targetFPS) == [.loopAnalysis] {
            frameInterpolationDebugPrint("自动入口：加入循环点分析队列。视频=\(videoURL.lastPathComponent)")
            return enqueue(
                videoURL: videoURL,
                title: title,
                targetFPS: targetFPS,
                source: .automatic,
                operations: [.loopAnalysis]
            )
        }

        return enqueueAutomaticInterpolationIfNeeded(
            videoURL: videoURL,
            title: title,
            targetFPS: targetFPS
        )
    }

    /// Marks a freshly received source file as a new optimization origin.
    /// A re-download must not inherit terminal states from the prior optimized file.
    func registerDownloadedSource(videoURL: URL, sourceURL: URL? = nil) {
        resetOptimizationState(videoURL: videoURL)
        VideoOptimizationRecordStore.shared.recordDownloadedSource(for: videoURL, sourceURL: sourceURL)
    }

    /// A baked artifact is a new source only when its file path is new. Existing
    /// artifacts retain their sidecar decisions, while their bake provenance is
    /// refreshed from the authoritative artifact metadata.
    func registerBakedSource(
        videoURL: URL,
        sourcePath: String,
        artifact: SceneBakeArtifact
    ) {
        VideoOptimizationRecordStore.shared.recordBakeArtifact(
            for: videoURL,
            sourcePath: sourcePath,
            artifact: artifact
        )
    }

    @discardableResult
    func enqueueAfterBakeIfNeeded(videoURL: URL, title: String? = nil) -> UUID? {
        enqueueAutomaticOptimizationIfNeeded(videoURL: videoURL, title: title)
    }

    /// A loop task calls this only after it reaches a successful terminal
    /// outcome. It deliberately evaluates the latest settings at that moment.
    @discardableResult
    private func enqueueAutomaticInterpolationIfNeeded(
        videoURL: URL,
        title: String? = nil,
        targetFPS: Int? = nil
    ) -> UUID? {
        ensureAutomaticPolicyLoaded()
        let policy = automaticPolicy
        guard policy.frameInterpolationEnabled,
              policy.automaticallyInterpolateFrames,
              videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return nil
        }

        let effectiveTargetFPS = targetFPS ?? FrameInterpolationTargetFPSResolver.nearestAllowedFixedFPS(policy.targetFPS)
        guard effectiveTargetFPS > 0,
              automaticOperationsNeedingWork(
                [.frameInterpolation],
                for: videoURL,
                targetFPS: effectiveTargetFPS
              ) == [.frameInterpolation] else {
            return nil
        }

        frameInterpolationDebugPrint("自动入口：加入补帧队列。视频=\(videoURL.lastPathComponent)，目标 FPS=\(effectiveTargetFPS)")
        return enqueue(
            videoURL: videoURL,
            title: title,
            targetFPS: effectiveTargetFPS,
            source: .automatic,
            operations: [.frameInterpolation]
        )
    }

    func hasPendingInterpolation(videoURL: URL, targetFPS: Int) -> Bool {
        items.contains { item in
            item.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                && item.targetFPS == targetFPS
                && item.operations.contains(.frameInterpolation)
                && !item.completedOperations.contains(.frameInterpolation)
                && !item.isTerminalForCleanup
        }
    }

    func hasActiveInterpolation(videoURL: URL) -> Bool {
        items.contains { item in
            item.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                && item.operations.contains(.frameInterpolation)
                && !item.completedOperations.contains(.frameInterpolation)
                && !item.isTerminalForCleanup
        }
    }

    func activeInterpolationTargetFPS(videoURL: URL) -> Int? {
        items
            .filter { item in
                item.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                    && item.operations.contains(.frameInterpolation)
                    && !item.completedOperations.contains(.frameInterpolation)
                    && !item.isTerminalForCleanup
            }
            .map(\.targetFPS)
            .max()
    }

    func hasActiveInterpolation(videoURL: URL, satisfying targetFPS: Int) -> Bool {
        guard let activeTargetFPS = activeInterpolationTargetFPS(videoURL: videoURL) else {
            return false
        }
        return activeTargetFPS >= targetFPS
    }

    func needsInterpolation(videoURL: URL, targetFPS: Int) async -> Bool {
        await VideoFrameInterpolationAnalyzer.decision(for: videoURL, targetFPS: targetFPS).shouldInterpolate
    }

    func completedRecord(videoURL: URL) -> FrameInterpolationRecordItem? {
        if let event = VideoOptimizationRecordStore.shared.latestFrameEvent(for: videoURL),
           event.kind == .frameApplied {
            return FrameInterpolationRecordItem(
                id: interpolationRecordID(for: videoURL),
                videoPath: videoURL.standardizedFileURL.path,
                title: videoURL.deletingPathExtension().lastPathComponent,
                targetFPS: event.metadata["targetFPS"].flatMap(Int.init) ?? 0,
                recordedAt: event.date
            )
        }
        return nil
    }

    func completedRecord(videoURL: URL, satisfying targetFPS: Int) -> FrameInterpolationRecordItem? {
        guard let record = completedRecord(videoURL: videoURL),
              record.targetFPS >= targetFPS else {
            return nil
        }
        return record
    }

    func isBlacklisted(videoURL: URL, operation: FrameInterpolationQueueItem.Operation) -> Bool {
        switch operation {
        case .loopAnalysis:
            return VideoOptimizationRecordStore.shared.loopState(for: videoURL) == .blacklisted
        case .frameInterpolation:
            return VideoOptimizationRecordStore.shared.frameState(for: videoURL) == .blacklisted
        }
    }

    func isBlacklisted(videoURL: URL) -> Bool {
        isBlacklisted(videoURL: videoURL, operation: .frameInterpolation)
    }

    func markCompleted(videoURL: URL, title: String, targetFPS: Int) {
        let existingRecord = completedRecord(videoURL: videoURL)
        let effectiveTargetFPS = max(targetFPS, existingRecord?.targetFPS ?? targetFPS)
        VideoOptimizationRecordStore.shared.append(
            .frameApplied,
            for: videoURL,
            metadata: [
                "targetFPS": String(effectiveTargetFPS),
                "title": title.isEmpty ? videoURL.deletingPathExtension().lastPathComponent : title,
            ]
        )
    }

    func markInterpolationNotNeeded(videoURL: URL, title: String, targetFPS: Int, reason: String) {
        VideoOptimizationRecordStore.shared.append(
            .frameNotNeeded,
            for: videoURL,
            detail: reason,
            metadata: [
                "targetFPS": String(targetFPS),
                "title": title.isEmpty ? videoURL.deletingPathExtension().lastPathComponent : title,
            ]
        )
    }

    func removeBlacklisted(
        videoURL: URL,
        operation: FrameInterpolationQueueItem.Operation = .frameInterpolation
    ) {
        VideoOptimizationRecordStore.shared.removeBlacklist(operation, for: videoURL)
    }

    /// Removes every optimization state associated with a video before it is
    /// re-downloaded or deliberately restored to its source version.
    func resetOptimizationState(videoURL: URL) {
        let standardizedURL = videoURL.standardizedFileURL
        let matchingIDs = items.compactMap { item in
            item.videoURL.standardizedFileURL == standardizedURL ? item.id : nil
        }

        for id in matchingIDs {
            if let task = runningTasks[id] {
                task.cancel()
                runningTasks[id] = nil
            }
            stopHeartbeat(id: id)
            taskStartDates[id] = nil
        }
        items.removeAll { $0.videoURL.standardizedFileURL == standardizedURL }
        VideoOptimizationRecordStore.shared.reset(for: standardizedURL)
        persistQueueCheckpointImmediately()
        scheduleNext()
    }

    /// A library delete may race an active export. Remove matching jobs at once
    /// rather than waiting for the next persisted-checkpoint restore.
    func removeTasks(forDeletedContentAt contentURL: URL) {
        let rootURL = contentURL.standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let matchingIDs = items.compactMap { item -> UUID? in
            let path = item.videoURL.standardizedFileURL.path
            return path == rootURL.path || path.hasPrefix(rootPath) ? item.id : nil
        }
        guard !matchingIDs.isEmpty else { return }

        for id in matchingIDs {
            runningTasks[id]?.cancel()
            runningTasks[id] = nil
            stopHeartbeat(id: id)
        }
        items.removeAll { matchingIDs.contains($0.id) }
        frameInterpolationDebugPrint("视频优化队列：媒体已删除，移除任务数=\(matchingIDs.count)，路径=\(contentURL.path)")
        persistQueueCheckpointImmediately()
        scheduleNext()
    }

    @discardableResult
    func enqueue(
        videoURL: URL,
        title: String? = nil,
        targetFPS: Int,
        source: FrameInterpolationQueueItem.Source,
        operations: [FrameInterpolationQueueItem.Operation] = [.frameInterpolation]
    ) -> UUID? {
        guard targetFPS > 0 else { return nil }
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return nil
        }
        VideoOptimizationRecordStore.shared.recordImportedSourceIfNeeded(for: videoURL)
        var requestedOperations = normalizedOperations(operations)
        requestedOperations.removeAll { isBlacklisted(videoURL: videoURL, operation: $0) }
        guard !requestedOperations.isEmpty else { return nil }

        requestedOperations = initialQueueOperation(from: requestedOperations)

        if requestedOperations == [.frameInterpolation],
           let record = completedRecord(videoURL: videoURL, satisfying: targetFPS) {
            frameInterpolationDebugPrint("补帧队列：已有完成记录覆盖目标 FPS，跳过添加。记录 FPS=\(record.targetFPS)，目标 FPS=\(targetFPS)，视频=\(videoURL.lastPathComponent)")
            return nil
        }

        if let coveredIndex = items.firstIndex(where: {
            $0.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                && $0.targetFPS >= targetFPS
                && $0.operations == requestedOperations
                && !$0.isTerminalForCleanup
        }) {
            frameInterpolationDebugPrint("视频优化队列：已有相同操作覆盖目标 FPS，跳过重复添加。任务 FPS=\(items[coveredIndex].targetFPS)，目标 FPS=\(targetFPS)，视频=\(videoURL.lastPathComponent)")
            return items[coveredIndex].id
        }

        let lowerWaitingIDs: [UUID]
        if requestedOperations == [.frameInterpolation] {
            lowerWaitingIDs = items.compactMap { item -> UUID? in
                guard item.videoURL.standardizedFileURL == videoURL.standardizedFileURL,
                      item.operations == [.frameInterpolation],
                      item.targetFPS < targetFPS,
                      case .waiting = item.status else {
                    return nil
                }
                return item.id
            }
        } else {
            lowerWaitingIDs = []
        }
        for waitingID in lowerWaitingIDs {
            guard let index = items.firstIndex(where: { $0.id == waitingID }) else { continue }
            let removedItem = items.remove(at: index)
            archive(removedItem, outcome: .cancelled, message: "被更高目标帧率任务替代")
            frameInterpolationDebugPrint("补帧队列：目标 FPS 已提高，移除低目标等待任务。旧 FPS=\(removedItem.targetFPS)，新 FPS=\(targetFPS)，视频=\(videoURL.lastPathComponent)")
        }

        let id = UUID()
        let item = FrameInterpolationQueueItem(
            id: id,
            videoURL: videoURL,
            title: title?.isEmpty == false ? title! : videoURL.deletingPathExtension().lastPathComponent,
            targetFPS: targetFPS,
            source: source,
            operations: requestedOperations,
            completedOperations: [],
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
            addedAt: Date()
        )
        items.append(item)
        frameInterpolationDebugPrint("补帧队列：已添加任务。来源=\(source.rawValue)，目标 FPS=\(targetFPS)，视频=\(videoURL.path)")
        clearProgressForWaitingItems()
        persistQueueCheckpointImmediately()
        scheduleNext()
        return id
    }

    /// Loop analysis and frame interpolation use independent worker pools.
    /// Each pool can process two different videos at once, while a single
    /// source file is still never analyzed and rewritten concurrently.
    private let maxConcurrentTasksPerOperation = 2

    private func scheduleNext() {
        removeMissingVideoTasksIfNeeded()
        clearProgressForWaitingItems()
        persistQueueCheckpointImmediately()

        while runningTaskCount(for: .loopAnalysis) < maxConcurrentTasksPerOperation,
              let id = nextWaitingItemID(for: .loopAnalysis) {
            startLoopAnalysis(id: id)
        }

        while runningTaskCount(for: .frameInterpolation) < maxConcurrentTasksPerOperation,
              let id = nextWaitingItemID(for: .frameInterpolation) {
            startFrameInterpolation(id: id)
        }
    }

    private func nextWaitingItemID(for operation: FrameInterpolationQueueItem.Operation) -> UUID? {
        items
            .filter { item in
                guard runningTasks[item.id] == nil,
                      item.currentOperation == nil,
                      nextPendingOperation(for: item) == operation,
                      !hasRunningTask(for: item.videoURL) else {
                    return false
                }
                if case .waiting = item.status { return true }
                return false
            }
            .sorted { $0.addedAt < $1.addedAt }
            .first?
            .id
    }

    private func nextPendingOperation(
        for item: FrameInterpolationQueueItem
    ) -> FrameInterpolationQueueItem.Operation? {
        item.operations.first { !item.completedOperations.contains($0) }
    }

    private func runningTaskCount(for operation: FrameInterpolationQueueItem.Operation) -> Int {
        runningTasks.keys.reduce(into: 0) { count, id in
            guard let item = items.first(where: { $0.id == id }) else { return }
            if item.currentOperation == operation {
                count += 1
            }
        }
    }

    private func hasRunningTask(for videoURL: URL) -> Bool {
        let standardizedURL = videoURL.standardizedFileURL
        return runningTasks.keys.contains { id in
            items.first(where: { $0.id == id })?.videoURL.standardizedFileURL == standardizedURL
        }
    }

    private func prepareToRun(
        id: UUID,
        operation: FrameInterpolationQueueItem.Operation,
        stage: String
    ) -> (videoURL: URL, targetFPS: Int)? {
        guard runningTasks[id] == nil,
              let index = items.firstIndex(where: { $0.id == id }),
              nextPendingOperation(for: items[index]) == operation,
              !hasRunningTask(for: items[index].videoURL) else {
            return nil
        }

        items[index].status = .analyzing
        items[index].progress = 0
        items[index].writtenFrames = 0
        items[index].totalFrames = nil
        items[index].opticalFlowFrames = 0
        items[index].elapsedSeconds = 0
        items[index].remainingSeconds = nil
        items[index].currentOperation = operation
        items[index].currentStage = stage
        startHeartbeat(id: id)
        return (items[index].videoURL, items[index].targetFPS)
    }

    private func startLoopAnalysis(id: UUID) {
        guard let work = prepareToRun(id: id, operation: .loopAnalysis, stage: "循环分析中") else {
            return
        }
        let videoURL = work.videoURL
        VideoOptimizationRecordStore.shared.append(.loopQueued, for: videoURL)
        VideoOptimizationRecordStore.shared.append(.loopAnalysisStarted, for: videoURL)
        frameInterpolationDebugPrint("循环点分析队列：开始任务。视频=\(videoURL.lastPathComponent)")

        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                let loopResult = try await VideoLoopAnalysisService.analyzeAndReplace(videoURL: videoURL) { progress in
                    Task { @MainActor in
                        self?.updateLoopProgress(id: id, progress: progress)
                    }
                }
                guard !Task.isCancelled else {
                    await MainActor.run { self?.finishCancelled(id: id, reason: "任务已取消") }
                    return
                }

                await MainActor.run {
                    guard let self else { return }
                    switch loopResult {
                    case .applied(let firstContentFrame, let lastIncludedFrame):
                        VideoOptimizationRecordStore.shared.append(
                            .loopApplied,
                            for: videoURL,
                            metadata: [
                                "firstContentFrame": String(firstContentFrame),
                                "lastIncludedFrame": String(lastIncludedFrame),
                            ]
                        )
                        NotificationCenter.default.post(name: .videoOptimizationFileDidReplace, object: videoURL)
                    case .notNeeded:
                        VideoOptimizationRecordStore.shared.markLoopNotNeeded(for: videoURL)
                    case .noReliablePoint:
                        VideoOptimizationRecordStore.shared.append(.loopNoReliablePoint, for: videoURL)
                    }
                    self.finishLoopAnalysis(id: id)
                }
            } catch is CancellationError {
                await MainActor.run { self?.finishCancelled(id: id, reason: "任务已取消") }
            } catch {
                await MainActor.run {
                    VideoOptimizationRecordStore.shared.append(
                        .loopFailed,
                        for: videoURL,
                        detail: error.localizedDescription
                    )
                    self?.finishFailed(id: id, message: error.localizedDescription)
                }
            }
        }
        runningTasks[id] = task
    }

    private func finishLoopAnalysis(id: UUID) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            scheduleNext()
            return
        }

        let videoURL = items[index].videoURL
        let title = items[index].title
        let targetFPS = items[index].targetFPS
        items[index].completedOperations.insert(.loopAnalysis)
        items[index].currentOperation = nil
        if nextPendingOperation(for: items[index]) == nil {
            finishCompleted(id: id, message: "循环分析完成")
            _ = enqueueAutomaticInterpolationIfNeeded(
                videoURL: videoURL,
                title: title,
                targetFPS: targetFPS
            )
            return
        }

        items[index].status = .waiting
        clearProgress(at: index)
        persistQueueCheckpointImmediately()
        scheduleNext()
    }

    private func startFrameInterpolation(id: UUID) {
        guard let work = prepareToRun(
            id: id,
            operation: .frameInterpolation,
            stage: t("frameInterpolationStageReadingFPS")
        ) else {
            return
        }
        let videoURL = work.videoURL
        let targetFPS = work.targetFPS
        VideoOptimizationRecordStore.shared.append(.frameQueued, for: videoURL)
        VideoOptimizationRecordStore.shared.append(.frameAnalysisStarted, for: videoURL)
        frameInterpolationDebugPrint("补帧队列：开始任务。视频=\(videoURL.lastPathComponent)，目标 FPS=\(targetFPS)")

        let task = Task.detached(priority: .utility) { [weak self] in
            let decision = await VideoFrameInterpolationAnalyzer.decision(for: videoURL, targetFPS: targetFPS)
            await MainActor.run {
                guard let self,
                      let itemIndex = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[itemIndex].sourceFPS = decision.sourceFPS
                self.items[itemIndex].status = .running
                self.items[itemIndex].currentStage = t("frameInterpolationStagePreparingExport")
            }

            guard !Task.isCancelled else {
                await MainActor.run { self?.finishCancelled(id: id, reason: "任务已取消") }
                return
            }
            guard decision.shouldInterpolate else {
                await MainActor.run { self?.finishWithoutExport(id: id, reason: decision.reason) }
                return
            }

            await MainActor.run {
                VideoOptimizationRecordStore.shared.append(.frameInterpolationStarted, for: videoURL)
            }
            let outputURL = await VideoFrameInterpolationExporter.exportIfNeeded(
                sourceURL: videoURL,
                targetFPS: targetFPS
            ) { progress in
                Task { @MainActor in
                    self?.updateProgress(id: id, progress: progress)
                }
            }

            let wasCancelled = Task.isCancelled
            await MainActor.run {
                guard !wasCancelled else {
                    self?.finishCancelled(id: id, reason: "任务已取消")
                    return
                }
                self?.finishExport(id: id, sourceURL: videoURL, outputURL: outputURL)
            }
        }
        runningTasks[id] = task
    }

    private func startHeartbeat(id: UUID) {
        stopHeartbeat(id: id)
        taskStartDates[id] = Date()
        heartbeatTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.updateHeartbeat(id: id)
                }
            }
        }
    }

    private func stopHeartbeat(id: UUID) {
        heartbeatTasks[id]?.cancel()
        heartbeatTasks[id] = nil
        taskStartDates[id] = nil
    }

    private func updateHeartbeat(id: UUID) {
        removeMissingVideoTasksIfNeeded()
        guard let index = items.firstIndex(where: { $0.id == id }),
              let startDate = taskStartDates[id] else {
            stopHeartbeat(id: id)
            return
        }

        switch items[index].status {
        case .analyzing, .running:
            break
        default:
            stopHeartbeat(id: id)
            return
        }

        let elapsed = Date().timeIntervalSince(startDate)
        items[index].elapsedSeconds = elapsed

        if let totalFrames = items[index].totalFrames,
           totalFrames > 0,
           items[index].writtenFrames > 0 {
            let speed = Double(items[index].writtenFrames) / max(elapsed, 0.001)
            let remainingFrames = max(0, totalFrames - items[index].writtenFrames)
            items[index].remainingSeconds = speed > 0 && remainingFrames > 0
                ? Double(remainingFrames) / speed
                : nil
        }

        let percent = Int((items[index].progress * 100).rounded())
        frameInterpolationDebugPrint(
            "补帧队列心跳：状态=\(items[index].statusText)，阶段=\(items[index].currentStage)，进度=\(percent)%，已写=\(items[index].writtenFrames)/\(items[index].totalFrames.map(String.init) ?? "未知")，光流帧=\(items[index].opticalFlowFrames)，耗时=\(Self.formatSeconds(elapsed))，剩余=\(items[index].remainingSeconds.map(Self.formatSeconds) ?? "未知")，视频=\(items[index].videoURL.lastPathComponent)"
        )
    }

    /// Queue checkpoints already discard missing files after an app restart.
    /// Mirror that behavior at runtime so a deleted video cannot keep an
    /// invisible worker alive or later replace a newly removed source.
    private func removeMissingVideoTasksIfNeeded() {
        let missingIDs = items.compactMap { item -> UUID? in
            FileManager.default.fileExists(atPath: item.videoURL.path) ? nil : item.id
        }
        guard !missingIDs.isEmpty else { return }

        for id in missingIDs {
            runningTasks[id]?.cancel()
            runningTasks[id] = nil
            stopHeartbeat(id: id)
        }
        items.removeAll { missingIDs.contains($0.id) }
        frameInterpolationDebugPrint("视频优化队列：检测到源文件已删除，移除任务数=\(missingIDs.count)")
        persistQueueCheckpointImmediately()
    }

    private func updateProgress(id: UUID, progress: FrameInterpolationExportProgress) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard runningTasks[id] != nil else {
            if case .waiting = items[index].status {
                clearProgress(at: index)
            }
            frameInterpolationDebugPrint("补帧队列：忽略非运行任务的进度回调。状态=\(items[index].statusText)，视频=\(items[index].videoURL.lastPathComponent)")
            return
        }
        switch items[index].status {
        case .analyzing, .running:
            break
        default:
            frameInterpolationDebugPrint("补帧队列：忽略状态不匹配的进度回调。状态=\(items[index].statusText)，视频=\(items[index].videoURL.lastPathComponent)")
            return
        }
        items[index].progress = progress.progress
        items[index].writtenFrames = progress.writtenFrames
        items[index].totalFrames = progress.totalFrames
        items[index].opticalFlowFrames = progress.opticalFlowFrames
        items[index].elapsedSeconds = progress.elapsedSeconds
        items[index].remainingSeconds = progress.remainingSeconds
        items[index].currentStage = progress.currentStage
    }

    private func updateLoopProgress(id: UUID, progress: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              runningTasks[id] != nil,
              items[index].currentOperation == .loopAnalysis else {
            return
        }
        items[index].status = .analyzing
        items[index].progress = max(items[index].progress, min(1, max(0, progress)))
        items[index].currentStage = "循环分析中"
    }

    /// 取消等待或正在执行的任务。取消不会影响同队列中的其它视频。
    func cancel(id: UUID) {
        if let task = runningTasks[id] {
            task.cancel()
            return
        }
        finishCancelled(id: id, reason: "任务已取消")
    }

    func item(for videoURL: URL) -> VideoOptimizationQueueItem? {
        let standardizedURL = videoURL.standardizedFileURL
        return items.first { item in
            item.videoURL.standardizedFileURL == standardizedURL && item.currentOperation != nil
        } ?? items.first { item in
            item.videoURL.standardizedFileURL == standardizedURL && !item.isTerminalForCleanup
        }
    }

    /// A read-only operation lane for status surfaces. Work remains persisted
    /// in one checkpoint, while loop analysis and interpolation are scheduled
    /// independently from each other.
    func pendingItems(for operation: FrameInterpolationQueueItem.Operation) -> [VideoOptimizationQueueItem] {
        items
            .filter {
                !$0.isTerminalForCleanup
                    && $0.operations.contains(operation)
                    && !$0.completedOperations.contains(operation)
            }
            .sorted { $0.addedAt < $1.addedAt }
    }

    func activeItem(for operation: FrameInterpolationQueueItem.Operation) -> VideoOptimizationQueueItem? {
        pendingItems(for: operation).first { $0.currentOperation == operation }
    }

    private func clearProgressForWaitingItems() {
        for index in items.indices {
            if case .waiting = items[index].status {
                clearProgress(at: index)
            }
        }
    }

    private func clearProgress(at index: Array<FrameInterpolationQueueItem>.Index) {
        items[index].progress = 0
        items[index].writtenFrames = 0
        items[index].totalFrames = nil
        items[index].opticalFlowFrames = 0
        items[index].elapsedSeconds = 0
        items[index].remainingSeconds = nil
        items[index].currentStage = t("frameInterpolationStageWaiting")
    }

    private func finishWithoutExport(id: UUID, reason: String) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        if let index = items.firstIndex(where: { $0.id == id }) {
            let videoName = items[index].videoURL.lastPathComponent
            let videoURL = items[index].videoURL
            let title = items[index].title
            let targetFPS = items[index].targetFPS
            let shouldKeepCompletedState = completedRecord(videoURL: videoURL) != nil
                && reason.contains("已达到或高于目标 FPS")
            items[index].status = .completed
            items[index].progress = 1
            items[index].completedOperations.insert(.frameInterpolation)
            let completedItem = items.remove(at: index)
            if shouldKeepCompletedState {
                markCompleted(videoURL: videoURL, title: title, targetFPS: targetFPS)
                frameInterpolationDebugPrint("补帧队列：本地文件已满足目标 FPS，已修复完成记录。目标 FPS=\(targetFPS)，视频=\(videoName)")
            } else {
                VideoOptimizationRecordStore.shared.append(
                    .frameNotNeeded,
                    for: videoURL,
                    detail: reason,
                    metadata: ["targetFPS": String(targetFPS)]
                )
            }
            archive(completedItem, outcome: .completed, message: reason)
            frameInterpolationDebugPrint("补帧队列：无需补帧，任务已移除。原因=\(reason)，视频=\(videoName)")
        }
        scheduleNext()
    }

    private func finishCancelled(id: UUID, reason: String) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        if let index = items.firstIndex(where: { $0.id == id }) {
            let videoName = items[index].videoURL.lastPathComponent
            let cancelledItem = items.remove(at: index)
            archive(cancelledItem, outcome: .cancelled, message: reason)
            frameInterpolationDebugPrint("补帧队列：任务已取消并移除。原因=\(reason)，视频=\(videoName)")
        }
        scheduleNext()
    }

    private func finishExport(id: UUID, sourceURL: URL, outputURL: URL?) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            scheduleNext()
            return
        }

        if let outputURL {
            let title = items[index].title
            let targetFPS = items[index].targetFPS
            items[index].status = .completed
            items[index].progress = 1
            items[index].outputURL = outputURL
            items[index].completedOperations.insert(.frameInterpolation)
            let completedItem = items.remove(at: index)
            markCompleted(videoURL: outputURL, title: title, targetFPS: targetFPS)
            frameInterpolationDebugPrint("补帧队列：任务完成，已原地替换源视频。路径=\(outputURL.path)")
            archive(completedItem, outcome: .completed, message: nil)
            NotificationCenter.default.post(name: .videoOptimizationFileDidReplace, object: outputURL)
        } else {
            items[index].status = .failed("optical-flow 导出失败")
            let failedItem = items.remove(at: index)
            VideoOptimizationRecordStore.shared.append(
                .frameFailed,
                for: sourceURL,
                detail: "optical-flow 导出失败",
                metadata: ["targetFPS": String(failedItem.targetFPS)]
            )
            archive(failedItem, outcome: .failed, message: "optical-flow 导出失败")
            frameInterpolationDebugPrint("补帧队列：任务失败。视频=\(sourceURL.lastPathComponent)")
        }
        scheduleNext()
    }

    private func finishCompleted(id: UUID, message: String?) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            scheduleNext()
            return
        }
        var item = items.remove(at: index)
        item.status = .completed
        item.progress = 1
        archive(item, outcome: .completed, message: message)
        scheduleNext()
    }

    private func finishFailed(id: UUID, message: String) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            scheduleNext()
            return
        }
        var item = items.remove(at: index)
        item.status = .failed(message)
        if item.currentOperation == .frameInterpolation {
            VideoOptimizationRecordStore.shared.append(.frameFailed, for: item.videoURL, detail: message)
        }
        archive(item, outcome: .failed, message: message)
        frameInterpolationDebugPrint("视频优化队列：任务失败。原因=\(message)，视频=\(item.videoURL.lastPathComponent)")
        scheduleNext()
    }

    /// Queue checkpoints are deliberately short-lived. A restart can resume
    /// remaining operations, while a completed, failed, or cancelled item is
    /// removed from this file and leaves only its terminal sidecar outcome.
    private func scheduleQueueCheckpointSave() {
        queueCheckpointSaveTask?.cancel()
        let itemSnapshot = items
        let sourceRestoreSnapshot = Array(sourceRestoreRequests.values)
        queueCheckpointSaveTask = Task { [itemSnapshot, sourceRestoreSnapshot] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            VideoOptimizationQueueCheckpointStore.save(
                itemSnapshot,
                sourceRestoreRequests: sourceRestoreSnapshot
            )
        }
    }

    private func persistQueueCheckpointImmediately() {
        queueCheckpointSaveTask?.cancel()
        VideoOptimizationQueueCheckpointStore.save(
            items,
            sourceRestoreRequests: Array(sourceRestoreRequests.values)
        )
    }

    private func normalizedOperations(_ operations: [FrameInterpolationQueueItem.Operation]) -> [FrameInterpolationQueueItem.Operation] {
        FrameInterpolationQueueItem.Operation.allCases.filter { operations.contains($0) }
    }

    /// A queue item represents exactly one operation. When callers from an
    /// older checkpoint request both operations, retain the loop analysis as
    /// the first task and let its terminal handler decide whether to enqueue
    /// automatic interpolation.
    private func initialQueueOperation(
        from operations: [FrameInterpolationQueueItem.Operation]
    ) -> [FrameInterpolationQueueItem.Operation] {
        let normalized = normalizedOperations(operations)
        if normalized.contains(.loopAnalysis) {
            return [.loopAnalysis]
        }
        if normalized.contains(.frameInterpolation) {
            return [.frameInterpolation]
        }
        return []
    }

    /// Automatic triggers should not rerun a terminal decision every time the
    /// same wallpaper is selected. Manual actions intentionally remain retryable
    /// for failed/no-reliable loop analysis states.
    private func automaticOperationsNeedingWork(
        _ operations: [FrameInterpolationQueueItem.Operation],
        for videoURL: URL,
        targetFPS: Int
    ) -> [FrameInterpolationQueueItem.Operation] {
        operations.filter { operation in
            switch operation {
            case .loopAnalysis:
                switch VideoOptimizationRecordStore.shared.loopState(for: videoURL) {
                case .applied, .notNeeded, .noReliablePoint, .failed, .blacklisted:
                    return false
                case .idle:
                    return true
                }
            case .frameInterpolation:
                switch VideoOptimizationRecordStore.shared.frameState(for: videoURL) {
                case let .applied(recordedTargetFPS), let .notNeeded(recordedTargetFPS):
                    return (recordedTargetFPS ?? 0) < targetFPS
                case .failed, .blacklisted:
                    return false
                case .idle:
                    return true
                }
            }
        }
    }

    private struct LibraryOptimizationTarget {
        let videoURL: URL
        let title: String
    }

    private func libraryOptimizationTargets(in folder: LibraryFolder) -> [LibraryOptimizationTarget] {
        switch (folder.contentType, folder.collection) {
        case (.media, .downloads):
            return MediaLibraryService.shared.downloadedItems(inFolder: folder.id).compactMap { record in
                makeLibraryOptimizationTarget(localURL: record.localFileURL, title: record.item.title)
            }
        case (.media, .favorites):
            return MediaLibraryService.shared.favoriteItems(inFolder: folder.id).compactMap { item in
                makeLibraryOptimizationTarget(
                    localURL: MediaLibraryService.shared.localFileURLIfAvailable(for: item),
                    title: item.title
                )
            }
        case (.wallpaper, .downloads):
            return WallpaperLibraryService.shared.downloadedWallpapers(inFolder: folder.id).compactMap { record in
                makeLibraryOptimizationTarget(
                    localURL: record.localFileURL,
                    title: record.wallpaper.title ?? record.localFileURL.deletingPathExtension().lastPathComponent
                )
            }
        case (.wallpaper, .favorites):
            return WallpaperLibraryService.shared.favoriteWallpapers(inFolder: folder.id).compactMap { wallpaper in
                makeLibraryOptimizationTarget(
                    localURL: WallpaperLibraryService.shared.localFileURLIfAvailable(for: wallpaper),
                    title: wallpaper.title ?? wallpaper.id
                )
            }
        }
    }

    private func makeLibraryOptimizationTarget(localURL: URL?, title: String) -> LibraryOptimizationTarget? {
        guard let videoURL = optimizableVideoURL(from: localURL) else { return nil }
        return LibraryOptimizationTarget(videoURL: videoURL, title: title)
    }

    private func archive(
        _ item: FrameInterpolationQueueItem,
        outcome: VideoOptimizationQueueOutcome,
        message: String?
    ) {
        // Terminal outcomes already live in the video's sidecar. The active
        // queue intentionally keeps no second persisted history store.
        frameInterpolationDebugPrint(
            "视频优化队列归档：结果=\(outcome.rawValue)，操作=\(item.operations.map(\.rawValue).joined(separator: ","))，视频=\(item.videoURL.lastPathComponent)，说明=\(message ?? "无")"
        )
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "未知" }
        if seconds < 60 { return "\(String(format: "%.1f", seconds))s" }
        return "\(Int(seconds) / 60)m\(Int(seconds) % 60)s"
    }

    var activeProcessingItem: FrameInterpolationQueueItem? {
        activeItem(for: .loopAnalysis) ?? activeItem(for: .frameInterpolation)
    }

    var remainingWorkCount: Int {
        let activeID = activeProcessingItem?.id
        return items.filter { item in
            guard item.id != activeID else { return false }
            return !item.isTerminalForCleanup
        }.count
    }

    /// SettingsViewModel is created lazily by the settings window. Load the
    /// persisted policy only when the queue is first queried, never while this
    /// singleton is initializing, to avoid startup-time preferences recursion.
    private func ensureAutomaticPolicyLoaded() {
        guard !automaticPolicyLoaded else { return }
        let defaults = UserDefaults.standard
        let loopEnabled = defaults.object(forKey: "loop_point_analysis_enabled") as? Bool ?? true
        let autoLoop = loopEnabled
            && (defaults.object(forKey: "auto_analyze_loop_point") as? Bool ?? false)
        let frameEnabled = defaults.object(forKey: "frame_interpolation_enabled") as? Bool ?? false
        let autoFrame = frameEnabled
            && (defaults.object(forKey: "frame_interpolation_auto_on_download") as? Bool ?? false)
        let configuredFPS = (defaults.object(forKey: "frame_interpolation_target_fps") as? NSNumber)?.doubleValue ?? 60

        automaticPolicy = VideoOptimizationAutomaticPolicy(
            loopAnalysisEnabled: loopEnabled,
            automaticallyAnalyzeLoopPoints: autoLoop,
            frameInterpolationEnabled: frameEnabled,
            automaticallyInterpolateFrames: autoFrame,
            targetFPS: FrameInterpolationTargetFPSResolver.nearestAllowedFixedFPS(Int(configuredFPS.rounded()))
        )
        automaticPolicyLoaded = true
        migrateLegacyTerminalStateIfNeeded()
    }

    /// The former queue persisted terminal interpolation records in
    /// UserDefaults. Migrate those one time to the adjacent sidecar, then
    /// delete the duplicate store so future decisions have exactly one source.
    private func migrateLegacyTerminalStateIfNeeded() {
        guard !didMigrateLegacyTerminalState else { return }
        didMigrateLegacyTerminalState = true

        let defaults = UserDefaults.standard
        let completedKey = "frame_interpolation_completed_records_v1"
        let blacklistedKey = "frame_interpolation_blacklist_records_v1"
        let historyKey = "video_optimization_history_v1"

        if let data = defaults.data(forKey: completedKey),
           let records = try? JSONDecoder().decode([FrameInterpolationRecordItem].self, from: data) {
            for record in records {
                let videoURL = record.videoURL
                guard FileManager.default.fileExists(atPath: videoURL.path),
                      VideoOptimizationRecordStore.shared.latestFrameEvent(for: videoURL) == nil else {
                    continue
                }
                VideoOptimizationRecordStore.shared.append(
                    .frameApplied,
                    for: videoURL,
                    metadata: [
                        "targetFPS": String(record.targetFPS),
                        "title": record.title,
                        "migrated": "true",
                    ]
                )
            }
        }

        if let data = defaults.data(forKey: blacklistedKey),
           let records = try? JSONDecoder().decode([FrameInterpolationRecordItem].self, from: data) {
            for record in records {
                let videoURL = record.videoURL
                guard FileManager.default.fileExists(atPath: videoURL.path) else { continue }
                VideoOptimizationRecordStore.shared.append(
                    .frameBlacklisted,
                    for: videoURL,
                    metadata: [
                        "targetFPS": String(record.targetFPS),
                        "title": record.title,
                        "migrated": "true",
                    ]
                )
            }
        }

        defaults.removeObject(forKey: completedKey)
        defaults.removeObject(forKey: blacklistedKey)
        defaults.removeObject(forKey: historyKey)
    }

    private func interpolationRecordID(for videoURL: URL) -> String {
        videoURL.standardizedFileURL.path
    }
}

private actor VideoFrameInterpolationExportCoordinator {
    static let shared = VideoFrameInterpolationExportCoordinator()
    private let maxConcurrentExports = 2
    private var activeExportCount = 0
    private var exportWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var tasks: [String: Task<URL?, Never>] = [:]

    func export(
        key: String,
        sourceURL: URL,
        outputURL: URL,
        targetFPS: Int,
        progress: (@Sendable (FrameInterpolationExportProgress) -> Void)? = nil
    ) async -> URL? {
        if let task = tasks[key] {
            frameInterpolationDebugPrint("导出队列：同一个视频已有任务，复用当前任务。视频=\(sourceURL.lastPathComponent)")
            return await task.value
        }

        let task: Task<URL?, Never> = Task.detached(priority: .utility) { () -> URL? in
            let videoName = sourceURL.lastPathComponent
            do {
                try await VideoFrameInterpolationExportCoordinator.shared.acquireExportSlot(videoName: videoName)
            } catch {
                frameInterpolationDebugPrint("导出队列：等待补帧槽位时已取消。视频=\(videoName)")
                return nil
            }

            let result = await VideoFrameInterpolationExporter.performExport(
                sourceURL: sourceURL,
                outputURL: outputURL,
                targetFPS: targetFPS,
                progress: progress
            )
            await VideoFrameInterpolationExportCoordinator.shared.releaseExportSlot(videoName: videoName)
            return result
        }
        tasks[key] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        tasks.removeValue(forKey: key)
        return result
    }

    private func acquireExportSlot(videoName: String) async throws {
        if activeExportCount < maxConcurrentExports {
            activeExportCount += 1
            frameInterpolationDebugPrint("导出队列：开始补帧。当前并发=\(activeExportCount)/\(maxConcurrentExports)，视频=\(videoName)")
            return
        }

        frameInterpolationDebugPrint("导出队列：补帧任务排队等待。当前并发=\(activeExportCount)/\(maxConcurrentExports)，视频=\(videoName)")
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exportWaiters.append((id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await VideoFrameInterpolationExportCoordinator.shared.cancelExportWaiter(id: waiterID, videoName: videoName)
            }
        }
        try Task.checkCancellation()
        frameInterpolationDebugPrint("导出队列：排队任务获得补帧槽位。当前并发=\(activeExportCount)/\(maxConcurrentExports)，视频=\(videoName)")
    }

    private func releaseExportSlot(videoName: String) {
        if exportWaiters.isEmpty {
            activeExportCount = max(0, activeExportCount - 1)
        } else {
            let waiter = exportWaiters.removeFirst()
            waiter.continuation.resume()
        }
        frameInterpolationDebugPrint("导出队列：补帧任务结束。当前并发=\(activeExportCount)/\(maxConcurrentExports)，视频=\(videoName)")
    }

    private func cancelExportWaiter(id: UUID, videoName: String) {
        guard let index = exportWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = exportWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        frameInterpolationDebugPrint("导出队列：已移除取消的排队任务。视频=\(videoName)")
    }
}

enum VideoFrameInterpolationExporter {
    static func exportIfNeeded(
        sourceURL: URL,
        targetFPS: Int,
        progress: (@Sendable (FrameInterpolationExportProgress) -> Void)? = nil
    ) async -> URL? {
        let outputURL = temporaryOutputURL(for: sourceURL)
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        frameInterpolationDebugPrint("导出服务：临时输出路径准备完成。输出：\(outputURL.path)")
        let key = exportTaskKey(for: sourceURL, targetFPS: targetFPS)
        return await VideoFrameInterpolationExportCoordinator.shared.export(
            key: key,
            sourceURL: sourceURL,
            outputURL: outputURL,
            targetFPS: targetFPS,
            progress: progress
        )
    }

    static func performExport(
        sourceURL: URL,
        outputURL: URL,
        targetFPS: Int,
        progress: (@Sendable (FrameInterpolationExportProgress) -> Void)? = nil
    ) async -> URL? {
        try? FileManager.default.removeItem(at: outputURL)
        guard !Task.isCancelled,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            frameInterpolationDebugPrint("导出任务：启动前已取消。视频=\(sourceURL.lastPathComponent)")
            return nil
        }

        let asset = AVURLAsset(url: sourceURL)
        frameInterpolationDebugPrint("导出任务：离线补帧开始。当前只使用算法=optical-flow，不执行降级逻辑，目标 FPS=\(targetFPS)，视频=\(sourceURL.lastPathComponent)。")
        guard let exportInfo = await makeFrameInterpolationExportInfo(asset: asset, targetFPS: targetFPS) else {
            frameInterpolationDebugPrint("导出任务：读取视频轨道、尺寸、方向、码率或时长失败。")
            return nil
        }
        guard !Task.isCancelled,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            frameInterpolationDebugPrint("导出任务：读取参数后已取消。视频=\(sourceURL.lastPathComponent)")
            return nil
        }
        guard SystemMemoryPressure.hasRoomForFrameInterpolationExport(width: exportInfo.width, height: exportInfo.height) else {
            let requiredBytes = SystemMemoryPressure.estimatedFrameInterpolationWorkingSetBytes(
                width: exportInfo.width,
                height: exportInfo.height
            )
            let availableBytes = SystemMemoryPressure.approximateReclaimableBytes()
            frameInterpolationDebugPrint(
                "导出任务：跳过补帧，当前可回收内存不足。需要≈\(formatBytes(requiredBytes))，可用≈\(formatBytes(availableBytes))，视频=\(sourceURL.lastPathComponent)。"
            )
            return nil
        }

        try? FileManager.default.removeItem(at: outputURL)
        frameInterpolationDebugPrint("导出任务：当前使用算法：optical-flow。")
        let succeeded = autoreleasepool {
            frameInterpolationExport(
                asset: asset,
                info: exportInfo,
                outputURL: outputURL,
                targetFPS: targetFPS,
                progress: progress
            )
        }

        guard succeeded else {
            frameInterpolationDebugPrint("导出任务：optical-flow 导出失败；本轮不降级，继续使用原视频播放。")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        guard !Task.isCancelled,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            frameInterpolationDebugPrint("导出任务：写入完成后已取消，保留原视频。视频=\(sourceURL.lastPathComponent)")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        do {
            try replaceSourceVideo(sourceURL, with: outputURL)
            frameInterpolationDebugPrint("导出任务：补帧完成，已替换源视频。算法=optical-flow，路径=\(sourceURL.path)")
            return sourceURL
        } catch {
            frameInterpolationDebugPrint("导出任务：替换源视频失败。\(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
    }

    private struct FrameInterpolationExportInfo {
        let videoTrack: AVAssetTrack
        let width: Int
        let height: Int
        let preferredTransform: CGAffineTransform
        let duration: CMTime
        let sourceFPS: Double
        let bitrate: Double
    }

    private static func makeFrameInterpolationExportInfo(asset: AVURLAsset, targetFPS: Int) async -> FrameInterpolationExportInfo? {
        guard targetFPS > 0,
              let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await videoTrack.load(.naturalSize),
              let preferredTransform = try? await videoTrack.load(.preferredTransform),
              let duration = try? await asset.load(.duration) else {
            return nil
        }

        let transformedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        let renderSize = CGSize(
            width: max(2, abs(transformedRect.width)),
            height: max(2, abs(transformedRect.height))
        )

        let nominalFPS = (try? await videoTrack.load(.nominalFrameRate)).map(Double.init) ?? 0
        let minFrameDuration = (try? await videoTrack.load(.minFrameDuration)) ?? .invalid
        let fallbackFPS = minFrameDuration.isValid && minFrameDuration.seconds.isFinite && minFrameDuration.seconds > 0
            ? 1.0 / minFrameDuration.seconds
            : 30.0
        let sourceFPS = nominalFPS > 0 ? nominalFPS : fallbackFPS
        let bitrate = Double((try? await videoTrack.load(.estimatedDataRate)) ?? 0)

        frameInterpolationDebugPrint("导出任务：离线补帧参数已准备，源 FPS=\(String(format: "%.2f", sourceFPS))，输出尺寸=\(Int(renderSize.width))x\(Int(renderSize.height))。")
        return FrameInterpolationExportInfo(
            videoTrack: videoTrack,
            width: Int(renderSize.width.rounded()),
            height: Int(renderSize.height.rounded()),
            preferredTransform: preferredTransform,
            duration: duration,
            sourceFPS: sourceFPS,
            bitrate: bitrate
        )
    }

    private static func frameInterpolationExport(
        asset: AVAsset,
        info: FrameInterpolationExportInfo,
        outputURL: URL,
        targetFPS: Int,
        progress: (@Sendable (FrameInterpolationExportProgress) -> Void)? = nil
    ) -> Bool {
        do {
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = false

            let videoOutput = AVAssetReaderTrackOutput(
                track: info.videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else {
                frameInterpolationDebugPrint("导出任务：无法添加视频读取输出。")
                return false
            }
            reader.add(videoOutput)

            let fpsRatio = max(1.0, Double(targetFPS) / max(1.0, info.sourceFPS))
            let bitrate = Int(min(max(info.bitrate * fpsRatio, 4_000_000), 80_000_000))
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: info.width,
                AVVideoHeightKey: info.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: targetFPS,
                    AVVideoMaxKeyFrameIntervalKey: targetFPS * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAllowFrameReorderingKey: false
                ] as [String: Any]
            ]

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
            videoInput.transform = info.preferredTransform
            guard writer.canAdd(videoInput) else {
                frameInterpolationDebugPrint("导出任务：无法添加视频写入输入。")
                return false
            }
            writer.add(videoInput)

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: info.width,
                    kCVPixelBufferHeightKey as String: info.height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            let pixelBufferPool = adaptor.pixelBufferPool
            var exportCompleted = false
            defer {
                if !exportCompleted {
                    if reader.status == .reading {
                        reader.cancelReading()
                    }
                    if writer.status == .writing {
                        writer.cancelWriting()
                    }
                }
                if let pixelBufferPool {
                    CVPixelBufferPoolFlush(pixelBufferPool, CVPixelBufferPoolFlushFlags.excessBuffers)
                }
                FrameInterpolationMetalInterpolator.shared.flushTextureCache()
            }

            guard reader.startReading(), writer.startWriting() else {
                frameInterpolationDebugPrint("导出任务：reader/writer 启动失败。reader=\(reader.error?.localizedDescription ?? "nil") writer=\(writer.error?.localizedDescription ?? "nil")")
                return false
            }
            writer.startSession(atSourceTime: .zero)

            let targetFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            let duration = info.duration
            let durationSeconds = duration.seconds.isFinite && duration.seconds > 0 ? duration.seconds : 0
            let totalTargetFrames = durationSeconds > 0
                ? max(1, Int64((durationSeconds * Double(targetFPS)).rounded(.up)))
                : 0
            let exportStartDate = Date()
            var outputFrameIndex: Int64 = 0
            var writtenFrameCount: Int64 = 0
            var opticalFlowFrameCount: Int64 = 0
            var sourcePairCount: Int64 = 0
            var lastProgressLogFrame: Int64 = -Int64(max(1, targetFPS))

            frameInterpolationDebugPrint(
                "导出任务：进度初始化。算法==Vision optical-flow + Metal GPU warp，目标总帧数=\(totalTargetFrames > 0 ? "\(totalTargetFrames)" : "未知")，视频时长=\(formatSeconds(durationSeconds))，源 FPS=\(String(format: "%.2f", info.sourceFPS))，目标 FPS=\(targetFPS)。"
            )
            frameInterpolationDebugPrint("导出任务：使用 Vision optical-flow + Metal GPU warp；Metal 不可用或 GPU 执行失败时终止本次补帧。")

            func outputTime(for index: Int64) -> CMTime {
                CMTimeMultiply(targetFrameDuration, multiplier: Int32(index))
            }

            func waitUntilReady() -> Bool {
                while !videoInput.isReadyForMoreMediaData {
                    if Task.isCancelled { return false }
                    if writer.status == .failed || reader.status == .failed || reader.status == .cancelled {
                        return false
                    }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                return true
            }

            func emitProgress(
                stage: String,
                presentationTime: CMTime? = nil,
                shouldLog: Bool = true
            ) {
                let elapsed = Date().timeIntervalSince(exportStartDate)
                let speed = elapsed > 0 ? Double(writtenFrameCount) / elapsed : 0
                let remainingFrames = totalTargetFrames > 0 ? max(0, totalTargetFrames - writtenFrameCount) : 0
                let eta = speed > 0 && remainingFrames > 0 ? Double(remainingFrames) / speed : 0
                progress?(FrameInterpolationExportProgress(
                    progress: totalTargetFrames > 0 ? min(1, max(0, Double(writtenFrameCount) / Double(totalTargetFrames))) : 0,
                    writtenFrames: writtenFrameCount,
                    totalFrames: totalTargetFrames > 0 ? totalTargetFrames : nil,
                    opticalFlowFrames: opticalFlowFrameCount,
                    elapsedSeconds: elapsed,
                    remainingSeconds: eta > 0 ? eta : nil,
                    currentStage: stage
                ))

                guard shouldLog, let presentationTime, durationSeconds > 0 else { return }
                let seconds = presentationTime.seconds
                let percent = totalTargetFrames > 0
                    ? min(100, max(0, Double(writtenFrameCount) / Double(totalTargetFrames) * 100))
                    : min(100, max(0, seconds / durationSeconds * 100))
                frameInterpolationDebugPrint(
                    "导出进度：阶段=\(stage)，算法=optical-flow，\(String(format: "%.1f", percent))%，已写=\(writtenFrameCount)/\(totalTargetFrames > 0 ? "\(totalTargetFrames)" : "未知") 帧，光流帧=\(opticalFlowFrameCount)，源帧对=\(sourcePairCount)，视频时间=\(formatSeconds(seconds))/\(formatSeconds(durationSeconds))，耗时=\(formatSeconds(elapsed))，速度=\(String(format: "%.1f", speed)) 帧/秒，预计剩余=\(eta > 0 ? formatSeconds(eta) : "未知")。"
                )
            }

            func appendFrame(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) -> Bool {
                guard waitUntilReady() else { return false }
                guard !Task.isCancelled else { return false }
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    frameInterpolationDebugPrint("导出任务：追加帧失败。time=\(presentationTime.seconds)，error=\(writer.error?.localizedDescription ?? "未知错误")")
                    return false
                }
                writtenFrameCount += 1
                let progressLogInterval = Int64(max(1, targetFPS))
                if writtenFrameCount - lastProgressLogFrame >= progressLogInterval || writtenFrameCount == totalTargetFrames {
                    lastProgressLogFrame = writtenFrameCount
                    emitProgress(stage: "已写入第 \(writtenFrameCount) 帧", presentationTime: presentationTime)
                }
                return true
            }

            guard var currentSample = videoOutput.copyNextSampleBuffer(),
                  var currentPixelBuffer = CMSampleBufferGetImageBuffer(currentSample) else {
                frameInterpolationDebugPrint("导出任务：读取首帧失败。")
                writer.cancelWriting()
                reader.cancelReading()
                return false
            }
            defer {
                CMSampleBufferInvalidate(currentSample)
            }

            while let nextSample = videoOutput.copyNextSampleBuffer() {
                var didPromoteNextSample = false
                defer {
                    if !didPromoteNextSample {
                        CMSampleBufferInvalidate(nextSample)
                    }
                }
                if Task.isCancelled {
                    frameInterpolationDebugPrint("导出任务：收到取消请求，停止写入临时文件。")
                    writer.cancelWriting()
                    reader.cancelReading()
                    return false
                }
                sourcePairCount += 1
                let nextPTS = CMSampleBufferGetPresentationTimeStamp(nextSample)
                let currentPTS = CMSampleBufferGetPresentationTimeStamp(currentSample)
                guard let nextPixelBuffer = CMSampleBufferGetImageBuffer(nextSample) else {
                    continue
                }
                var opticalFlowBufferForPair: CVPixelBuffer?
                while outputTime(for: outputFrameIndex) < nextPTS {
                    let presentationTime = outputTime(for: outputFrameIndex)
                    let alpha = interpolationAlpha(currentPTS: currentPTS, nextPTS: nextPTS, outputPTS: presentationTime)
                    let pixelBuffer: CVPixelBuffer?
                    if alpha > 0.001, alpha < 0.999 {
                        opticalFlowFrameCount += 1
                        if opticalFlowBufferForPair == nil {
                            emitProgress(
                                stage: "正在计算源帧对 \(sourcePairCount) 的 optical-flow 场",
                                presentationTime: presentationTime
                            )
                            let flowStart = Date()
                            opticalFlowBufferForPair = autoreleasepool {
                                makeOpticalFlowBuffer(current: currentPixelBuffer, next: nextPixelBuffer)
                            }
                            let flowElapsed = Date().timeIntervalSince(flowStart)
                            guard opticalFlowBufferForPair != nil else {
                                frameInterpolationDebugPrint("导出任务：源帧对 \(sourcePairCount) 的 optical-flow 场计算失败，用时=\(formatSeconds(flowElapsed))。")
                                writer.cancelWriting()
                                reader.cancelReading()
                                return false
                            }
                            frameInterpolationDebugPrint("导出任务：源帧对 \(sourcePairCount) 的 optical-flow 场计算完成，用时=\(formatSeconds(flowElapsed))，将复用生成本组中间帧。")
                        }
                        emitProgress(
                            stage: "正在 warp 第 \(opticalFlowFrameCount) 个 optical-flow 中间帧（源帧对 \(sourcePairCount)，alpha=\(String(format: "%.2f", alpha))）",
                            presentationTime: presentationTime
                        )
                        pixelBuffer = autoreleasepool {
                            makeOpticalFlowWarpedPixelBuffer(
                                current: currentPixelBuffer,
                                next: nextPixelBuffer,
                                flow: opticalFlowBufferForPair!,
                                alpha: alpha,
                                adaptor: adaptor
                            )
                        }
                    } else {
                        pixelBuffer = alpha >= 0.999 ? nextPixelBuffer : currentPixelBuffer
                    }
                    guard let pixelBuffer else {
                        frameInterpolationDebugPrint("导出任务：算法 optical-flow 生成帧失败。time=\(presentationTime.seconds)")
                        writer.cancelWriting()
                        reader.cancelReading()
                        return false
                    }
                    guard appendFrame(pixelBuffer, at: presentationTime) else {
                        writer.cancelWriting()
                        reader.cancelReading()
                        return false
                    }
                    outputFrameIndex += 1
                }
                opticalFlowBufferForPair = nil
                CMSampleBufferInvalidate(currentSample)
                currentSample = nextSample
                currentPixelBuffer = nextPixelBuffer
                didPromoteNextSample = true
            }

            while outputTime(for: outputFrameIndex) < duration {
                if Task.isCancelled {
                    frameInterpolationDebugPrint("导出任务：收到取消请求，停止写入尾帧。")
                    writer.cancelWriting()
                    reader.cancelReading()
                    return false
                }
                let presentationTime = outputTime(for: outputFrameIndex)
                guard appendFrame(currentPixelBuffer, at: presentationTime) else {
                    writer.cancelWriting()
                    reader.cancelReading()
                    return false
                }
                outputFrameIndex += 1
            }

            videoInput.markAsFinished()
            let finishSemaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { finishSemaphore.signal() }
            finishSemaphore.wait()

            guard writer.status == .completed else {
                frameInterpolationDebugPrint("导出任务：writer 完成状态异常。status=\(writer.status.rawValue)，error=\(writer.error?.localizedDescription ?? "未知错误")")
                return false
            }

            frameInterpolationDebugPrint("导出任务：算法 optical-flow 导出完成，输出 FPS=\(targetFPS)，总帧数=\(writtenFrameCount)。")
            exportCompleted = true
            return true
        } catch {
            frameInterpolationDebugPrint("导出任务：异常失败。\(error.localizedDescription)")
            return false
        }
    }

    private static func interpolationAlpha(currentPTS: CMTime, nextPTS: CMTime, outputPTS: CMTime) -> Double {
        let span = nextPTS - currentPTS
        guard span.seconds.isFinite, span.seconds > 0 else { return 0 }
        let offset = outputPTS - currentPTS
        guard offset.seconds.isFinite else { return 0 }
        return min(1, max(0, offset.seconds / span.seconds))
    }

    private static func makeOpticalFlowBuffer(
        current: CVPixelBuffer,
        next: CVPixelBuffer
    ) -> CVPixelBuffer? {
        guard CVPixelBufferGetWidth(current) == CVPixelBufferGetWidth(next),
              CVPixelBufferGetHeight(current) == CVPixelBufferGetHeight(next),
              CVPixelBufferGetPixelFormatType(current) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(next) == kCVPixelFormatType_32BGRA else {
            return nil
        }

        do {
            let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: next, options: [:])
            request.computationAccuracy = .medium
            request.usesCPUOnly = false
            request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
            let handler = VNImageRequestHandler(cvPixelBuffer: current, options: [:])
            try handler.perform([request])
            return request.results?.first?.pixelBuffer
        } catch {
            frameInterpolationDebugPrint("导出任务：optical-flow 计算失败：\(error.localizedDescription)")
            return nil
        }
    }

    private static func makeOpticalFlowWarpedPixelBuffer(
        current: CVPixelBuffer,
        next: CVPixelBuffer,
        flow: CVPixelBuffer,
        alpha: Double,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        guard let output = makePixelBuffer(from: adaptor) else { return nil }
        guard CVPixelBufferGetWidth(current) == CVPixelBufferGetWidth(flow),
              CVPixelBufferGetHeight(current) == CVPixelBufferGetHeight(flow),
              CVPixelBufferGetPixelFormatType(flow) == kCVPixelFormatType_TwoComponent32Float else {
            return nil
        }

        if FrameInterpolationMetalInterpolator.shared.interpolate(
            current: current,
            next: next,
            flow: flow,
            alpha: alpha,
            output: output
        ) {
            return output
        }

        frameInterpolationDebugPrint("导出任务：Metal GPU warp 失败，已按 GPU-only 策略终止本次补帧。")
        return nil
    }

    private static func makePixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "未知" }
        if seconds < 60 {
            return "\(String(format: "%.1f", seconds))s"
        }
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return "\(minutes)m\(remainingSeconds)s"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1024.0 / 1024.0 / 1024.0
        return "\(String(format: "%.2f", gib))GB"
    }

    private static func temporaryOutputURL(for sourceURL: URL) -> URL {
        sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(sourceURL.deletingPathExtension().lastPathComponent).waifux-interpolating-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
    }

    private static func replaceSourceVideo(_ sourceURL: URL, with temporaryURL: URL) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CancellationError()
        }
        let backupURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(sourceURL.lastPathComponent).waifux-original-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: sourceURL, to: backupURL)
            try FileManager.default.moveItem(at: temporaryURL, to: sourceURL)
            try? FileManager.default.removeItem(at: backupURL)
        } catch {
            if !FileManager.default.fileExists(atPath: sourceURL.path),
               FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.moveItem(at: backupURL, to: sourceURL)
            }
            throw error
        }
    }

    private static func exportTaskKey(for sourceURL: URL, targetFPS: Int) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = attrs?[.size] as? UInt64 ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let raw = "\(sourceURL.standardizedFileURL.path)|\(size)|\(modified)|fps=\(targetFPS)|algorithm=optical-flow-only-v1"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
