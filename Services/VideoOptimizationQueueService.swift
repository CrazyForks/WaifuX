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
            case .loopAnalysis: return "循环分析"
            case .frameInterpolation: return "补帧"
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

struct VideoOptimizationHistoryRecord: Identifiable, Equatable, Codable {
    enum Outcome: String, Codable {
        case completed
        case failed
        case cancelled
    }

    let id: UUID
    let videoPath: String
    let title: String
    let targetFPS: Int
    let source: FrameInterpolationQueueItem.Source
    let operations: [FrameInterpolationQueueItem.Operation]
    let completedOperations: [FrameInterpolationQueueItem.Operation]
    let outcome: Outcome
    let message: String?
    let completedAt: Date

    var videoURL: URL { URL(fileURLWithPath: videoPath) }
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

    @Published private(set) var items: [FrameInterpolationQueueItem] = []
    @Published private(set) var completedInterpolationItems: [FrameInterpolationRecordItem] = []
    @Published private(set) var blacklistedInterpolationItems: [FrameInterpolationRecordItem] = []
    @Published private(set) var history: [VideoOptimizationHistoryRecord] = []
    /// 下载完成时是否自动入队补帧（调度/设壁纸路径禁止使用）。
    @Published var autoInterpolateOnDownload: Bool {
        didSet {
            UserDefaults.standard.set(autoInterpolateOnDownload, forKey: Self.autoOnDownloadKey)
        }
    }

    /// 兼容旧设置页绑定名；映射到「下载时自动补帧」。
    @Published var autoEnqueueEnabled: Bool {
        didSet {
            if autoEnqueueEnabled != autoInterpolateOnDownload {
                autoInterpolateOnDownload = autoEnqueueEnabled
            }
        }
    }

    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var heartbeatTasks: [UUID: Task<Void, Never>] = [:]
    private var taskStartDates: [UUID: Date] = [:]
    private var interpolationRecordsLoaded = false
    private var historyLoaded = false

    private static let completedInterpolationRecordsKey = "frame_interpolation_completed_records_v1"
    private static let blacklistedInterpolationRecordsKey = "frame_interpolation_blacklist_records_v1"
    private static let autoOnDownloadKey = "frame_interpolation_auto_on_download"
    private static let legacyAutoEnqueueKey = "frame_interpolation_auto_enqueue"
    private static let historyKey = "video_optimization_history_v1"

    private init() {
        // 不在单例初始化阶段读取 UserDefaults。macOS 26+ 上启动早期读偏好设置
        // 可能触发 _CFXPreferences 递归；真实设置由 SettingsViewModel 延迟恢复后同步过来。
        self.autoInterpolateOnDownload = false
        self.autoEnqueueEnabled = false
    }

    /// 由设置页恢复偏好后调用。
    func applySettings(autoOnDownload: Bool) {
        autoInterpolateOnDownload = autoOnDownload
        autoEnqueueEnabled = autoOnDownload
        // 清理旧的「切换壁纸时自动补帧」开关，避免再被读回。
        UserDefaults.standard.set(false, forKey: Self.legacyAutoEnqueueKey)
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

    /// 将同一个文件按“循环分析 -> 补帧”的顺序加入统一队列。
    @discardableResult
    func enqueueLoopAnalysisThenInterpolation(
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
            operations: [.loopAnalysis, .frameInterpolation]
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

    /// 下载完成后按设置决定是否入队补帧。调度/设壁纸路径不得调用。
    @discardableResult
    func enqueueAfterDownloadIfNeeded(
        videoURL: URL,
        title: String? = nil
    ) -> UUID? {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "frame_interpolation_enabled") as? Bool ?? false
        let onDownload = autoInterpolateOnDownload
            || (defaults.object(forKey: Self.autoOnDownloadKey) as? Bool ?? false)
        guard enabled, onDownload else { return nil }
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return nil
        }
        let ext = videoURL.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v", "mkv"].contains(ext) else { return nil }

        let targetFPS = FrameInterpolationTargetFPSResolver.targetFPSForManualAction()
        guard targetFPS > 0 else { return nil }
        guard !isBlacklisted(videoURL: videoURL) else { return nil }
        if completedRecord(videoURL: videoURL, satisfying: targetFPS) != nil { return nil }

        frameInterpolationDebugPrint("下载完成：按设置自动入队补帧。视频=\(videoURL.lastPathComponent)，目标 FPS=\(targetFPS)")
        return enqueue(
            videoURL: videoURL,
            title: title,
            targetFPS: targetFPS,
            source: .automatic
        )
    }

    func hasPendingInterpolation(videoURL: URL, targetFPS: Int) -> Bool {
        items.contains { item in
            item.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                && item.targetFPS == targetFPS
                && !item.isTerminalForCleanup
        }
    }

    func hasActiveInterpolation(videoURL: URL) -> Bool {
        items.contains { item in
            item.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                && !item.isTerminalForCleanup
        }
    }

    func activeInterpolationTargetFPS(videoURL: URL) -> Int? {
        items
            .filter { item in
                item.videoURL.standardizedFileURL == videoURL.standardizedFileURL
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

    func isCompleted(videoURL: URL) -> Bool {
        ensureInterpolationRecordsLoaded()
        let id = interpolationRecordID(for: videoURL)
        return completedInterpolationItems.contains { $0.id == id }
    }

    func completedRecord(videoURL: URL) -> FrameInterpolationRecordItem? {
        ensureInterpolationRecordsLoaded()
        let id = interpolationRecordID(for: videoURL)
        return completedInterpolationItems
            .filter { $0.id == id }
            .max {
                if $0.targetFPS == $1.targetFPS {
                    return $0.recordedAt < $1.recordedAt
                }
                return $0.targetFPS < $1.targetFPS
            }
    }

    func completedRecord(videoURL: URL, satisfying targetFPS: Int) -> FrameInterpolationRecordItem? {
        guard let record = completedRecord(videoURL: videoURL),
              record.targetFPS >= targetFPS else {
            return nil
        }
        return record
    }

    func isBlacklisted(videoURL: URL) -> Bool {
        ensureInterpolationRecordsLoaded()
        let id = interpolationRecordID(for: videoURL)
        return blacklistedInterpolationItems.contains { $0.id == id }
    }

    func markCompleted(videoURL: URL, title: String, targetFPS: Int) {
        ensureInterpolationRecordsLoaded()
        let existingRecord = completedRecord(videoURL: videoURL)
        let effectiveTargetFPS = max(targetFPS, existingRecord?.targetFPS ?? targetFPS)
        let effectiveTitle = title.isEmpty ? (existingRecord?.title ?? "") : title
        let record = makeInterpolationRecord(videoURL: videoURL, title: effectiveTitle, targetFPS: effectiveTargetFPS)
        completedInterpolationItems.removeAll { $0.id == record.id }
        completedInterpolationItems.append(record)
        completedInterpolationItems.sort { $0.recordedAt > $1.recordedAt }
        blacklistedInterpolationItems.removeAll { $0.id == record.id }
        saveInterpolationRecords()
    }

    func removeCompleted(videoURL: URL) {
        ensureInterpolationRecordsLoaded()
        let id = interpolationRecordID(for: videoURL)
        completedInterpolationItems.removeAll { $0.id == id }
        saveInterpolationRecords()
    }

    func markBlacklisted(videoURL: URL, title: String, targetFPS: Int) {
        ensureInterpolationRecordsLoaded()
        let record = makeInterpolationRecord(videoURL: videoURL, title: title, targetFPS: targetFPS)
        blacklistedInterpolationItems.removeAll { $0.id == record.id }
        blacklistedInterpolationItems.append(record)
        blacklistedInterpolationItems.sort { $0.recordedAt > $1.recordedAt }
        completedInterpolationItems.removeAll { $0.id == record.id }
        saveInterpolationRecords()
    }

    func removeBlacklisted(videoURL: URL) {
        ensureInterpolationRecordsLoaded()
        let id = interpolationRecordID(for: videoURL)
        blacklistedInterpolationItems.removeAll { $0.id == id }
        saveInterpolationRecords()
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
        let requestedOperations = normalizedOperations(operations)
        guard !requestedOperations.isEmpty else { return nil }
        guard !isBlacklisted(videoURL: videoURL) else {
            frameInterpolationDebugPrint("补帧队列：视频在黑名单中，跳过添加。视频=\(videoURL.lastPathComponent)")
            return nil
        }

        if requestedOperations == [.frameInterpolation],
           let record = completedRecord(videoURL: videoURL, satisfying: targetFPS) {
            frameInterpolationDebugPrint("补帧队列：已有完成记录覆盖目标 FPS，跳过添加。记录 FPS=\(record.targetFPS)，目标 FPS=\(targetFPS)，视频=\(videoURL.lastPathComponent)")
            return nil
        }

        if let coveredIndex = items.firstIndex(where: {
            $0.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                && $0.targetFPS >= targetFPS
                && !$0.isTerminalForCleanup
        }) {
            if case .waiting = items[coveredIndex].status {
                items[coveredIndex].operations = normalizedOperations(
                    items[coveredIndex].operations + requestedOperations
                )
            }
            frameInterpolationDebugPrint("补帧队列：已有任务覆盖目标 FPS，跳过重复添加。任务 FPS=\(items[coveredIndex].targetFPS)，目标 FPS=\(targetFPS)，视频=\(videoURL.lastPathComponent)")
            return items[coveredIndex].id
        }

        let lowerWaitingIDs = items.compactMap { item -> UUID? in
            guard item.videoURL.standardizedFileURL == videoURL.standardizedFileURL,
                  item.targetFPS < targetFPS,
                  case .waiting = item.status else {
                return nil
            }
            return item.id
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
        scheduleNext()
        return id
    }

    private func scheduleNext() {
        clearProgressForWaitingItems()
        let runningCount = runningTasks.count
        let availableSlots = max(0, 1 - runningCount)
        guard availableSlots > 0 else { return }

        let waitingIDs = items
            .filter { item in
                guard runningTasks[item.id] == nil else { return false }
                if case .waiting = item.status { return true }
                return false
            }
            .sorted { $0.addedAt < $1.addedAt }
            .prefix(availableSlots)
            .map(\.id)

        for id in waitingIDs {
            startItem(id: id)
        }
    }

    private func startItem(id: UUID) {
        guard runningTasks[id] == nil,
              runningTasks.count < 1,
              let index = items.firstIndex(where: { $0.id == id }) else { return }

        items[index].status = .analyzing
        items[index].progress = 0
        items[index].writtenFrames = 0
        items[index].totalFrames = nil
        items[index].opticalFlowFrames = 0
        items[index].elapsedSeconds = 0
        items[index].remainingSeconds = nil
        let operations = items[index].operations
        items[index].currentOperation = operations.first
        items[index].currentStage = operations.first == .loopAnalysis
            ? "循环分析中"
            : t("frameInterpolationStageReadingFPS")
        let videoURL = items[index].videoURL
        let targetFPS = items[index].targetFPS
        startHeartbeat(id: id)
        frameInterpolationDebugPrint("补帧队列：开始任务。视频=\(videoURL.lastPathComponent)，目标 FPS=\(targetFPS)")

        let task = Task.detached(priority: .utility) { [weak self] in
            if operations.contains(.loopAnalysis) {
                let loopResult = await VideoLoopPreprocessingService.shared.preprocessIfNeeded(videoURL)

                guard !Task.isCancelled else {
                    await MainActor.run { self?.finishCancelled(id: id, reason: "任务已取消") }
                    return
                }

                switch loopResult {
                case .failed(let message):
                    await MainActor.run { self?.finishFailed(id: id, message: message) }
                    return
                case .processed:
                    await MainActor.run {
                        NotificationCenter.default.post(name: .videoOptimizationFileDidReplace, object: videoURL)
                    }
                case .alreadyProcessed:
                    break
                }

                await MainActor.run {
                    self?.markOperationCompleted(id: id, operation: .loopAnalysis)
                }
            }

            guard operations.contains(.frameInterpolation) else {
                await MainActor.run { self?.finishCompleted(id: id, message: "循环分析完成") }
                return
            }

            await MainActor.run {
                guard let self,
                      let itemIndex = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[itemIndex].currentOperation = .frameInterpolation
                self.items[itemIndex].status = .analyzing
                self.items[itemIndex].currentStage = t("frameInterpolationStageReadingFPS")
            }

            let decision = await VideoFrameInterpolationAnalyzer.decision(for: videoURL, targetFPS: targetFPS)
            await MainActor.run {
                guard let self,
                      let itemIndex = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[itemIndex].sourceFPS = decision.sourceFPS
                self.items[itemIndex].status = .running
                self.items[itemIndex].currentStage = t("frameInterpolationStagePreparingExport")
            }

            guard !Task.isCancelled else {
                await MainActor.run {
                    self?.finishCancelled(id: id, reason: "任务已取消")
                }
                return
            }
            guard decision.shouldInterpolate else {
                await MainActor.run {
                    self?.finishWithoutExport(id: id, reason: decision.reason)
                }
                return
            }

            let outputURL = await VideoFrameInterpolationExporter.exportIfNeeded(sourceURL: videoURL, targetFPS: targetFPS) { progress in
                Task { @MainActor in
                    VideoOptimizationQueueService.shared.updateProgress(id: id, progress: progress)
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

    /// 取消等待或正在执行的任务。取消不会影响同队列中的其它视频。
    func cancel(id: UUID) {
        if let task = runningTasks[id] {
            task.cancel()
            return
        }
        finishCancelled(id: id, reason: "任务已取消")
    }

    /// 仅重试失败任务；成功和主动取消不会被隐式重新执行。
    @discardableResult
    func retry(historyID: UUID) -> UUID? {
        ensureHistoryLoaded()
        guard let record = history.first(where: { $0.id == historyID }),
              record.outcome == .failed else {
            return nil
        }
        return enqueue(
            videoURL: record.videoURL,
            title: record.title,
            targetFPS: record.targetFPS,
            source: record.source,
            operations: record.operations
        )
    }

    func item(for videoURL: URL) -> VideoOptimizationQueueItem? {
        items.first { $0.videoURL.standardizedFileURL == videoURL.standardizedFileURL }
    }

    func history(for videoURL: URL) -> [VideoOptimizationHistoryRecord] {
        ensureHistoryLoaded()
        let path = videoURL.standardizedFileURL.path
        return history.filter { $0.videoPath == path }
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
            let shouldRepairCompletedRecord = completedRecord(videoURL: videoURL) != nil
                && reason.contains("已达到或高于目标 FPS")
            items[index].status = .completed
            items[index].progress = 1
            items[index].completedOperations.insert(.frameInterpolation)
            let completedItem = items.remove(at: index)
            if shouldRepairCompletedRecord {
                markCompleted(videoURL: videoURL, title: title, targetFPS: targetFPS)
                frameInterpolationDebugPrint("补帧队列：本地文件已满足目标 FPS，已修复完成记录。目标 FPS=\(targetFPS)，视频=\(videoName)")
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
            archive(failedItem, outcome: .failed, message: "optical-flow 导出失败")
            frameInterpolationDebugPrint("补帧队列：任务失败。视频=\(sourceURL.lastPathComponent)")
        }
        scheduleNext()
    }

    private func markOperationCompleted(id: UUID, operation: FrameInterpolationQueueItem.Operation) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].completedOperations.insert(operation)
        items[index].currentOperation = nil
        items[index].progress = operation == .loopAnalysis ? 0.08 : items[index].progress
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
        archive(item, outcome: .failed, message: message)
        frameInterpolationDebugPrint("视频优化队列：任务失败。原因=\(message)，视频=\(item.videoURL.lastPathComponent)")
        scheduleNext()
    }

    private func normalizedOperations(_ operations: [FrameInterpolationQueueItem.Operation]) -> [FrameInterpolationQueueItem.Operation] {
        FrameInterpolationQueueItem.Operation.allCases.filter { operations.contains($0) }
    }

    private func archive(
        _ item: FrameInterpolationQueueItem,
        outcome: VideoOptimizationHistoryRecord.Outcome,
        message: String?
    ) {
        ensureHistoryLoaded()
        let record = VideoOptimizationHistoryRecord(
            id: item.id,
            videoPath: item.videoURL.standardizedFileURL.path,
            title: item.title,
            targetFPS: item.targetFPS,
            source: item.source,
            operations: item.operations,
            completedOperations: item.completedOperations.sorted { $0.rawValue < $1.rawValue },
            outcome: outcome,
            message: message,
            completedAt: Date()
        )
        history.insert(record, at: 0)
        history = Array(history.prefix(200))
        saveHistory()
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "未知" }
        if seconds < 60 { return "\(String(format: "%.1f", seconds))s" }
        return "\(Int(seconds) / 60)m\(Int(seconds) % 60)s"
    }

    var activeProcessingItem: FrameInterpolationQueueItem? {
        items.first { item in
            if case .analyzing = item.status { return true }
            if case .running = item.status { return true }
            return false
        }
    }

    var remainingWorkCount: Int {
        let activeID = activeProcessingItem?.id
        return items.filter { item in
            guard item.id != activeID else { return false }
            return !item.isTerminalForCleanup
        }.count
    }

    private func ensureInterpolationRecordsLoaded() {
        guard !interpolationRecordsLoaded else { return }
        completedInterpolationItems = Self.loadInterpolationRecords(key: Self.completedInterpolationRecordsKey)
        blacklistedInterpolationItems = Self.loadInterpolationRecords(key: Self.blacklistedInterpolationRecordsKey)
        interpolationRecordsLoaded = true
    }

    private func saveInterpolationRecords() {
        Self.saveInterpolationRecords(completedInterpolationItems, key: Self.completedInterpolationRecordsKey)
        Self.saveInterpolationRecords(blacklistedInterpolationItems, key: Self.blacklistedInterpolationRecordsKey)
    }

    private func makeInterpolationRecord(videoURL: URL, title: String, targetFPS: Int) -> FrameInterpolationRecordItem {
        FrameInterpolationRecordItem(
            id: interpolationRecordID(for: videoURL),
            videoPath: videoURL.standardizedFileURL.path,
            title: title.isEmpty ? videoURL.deletingPathExtension().lastPathComponent : title,
            targetFPS: targetFPS,
            recordedAt: Date()
        )
    }

    private func interpolationRecordID(for videoURL: URL) -> String {
        videoURL.standardizedFileURL.path
    }

    private static func loadInterpolationRecords(key: String) -> [FrameInterpolationRecordItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([FrameInterpolationRecordItem].self, from: data) else {
            return []
        }
        return records.sorted { $0.recordedAt > $1.recordedAt }
    }

    private static func saveInterpolationRecords(_ records: [FrameInterpolationRecordItem], key: String) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func ensureHistoryLoaded() {
        guard !historyLoaded else { return }
        defer { historyLoaded = true }
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let records = try? JSONDecoder().decode([VideoOptimizationHistoryRecord].self, from: data) else {
            return
        }
        history = records.sorted { $0.completedAt > $1.completedAt }
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyKey)
    }
}

private actor VideoFrameInterpolationExportCoordinator {
    static let shared = VideoFrameInterpolationExportCoordinator()
    private let maxConcurrentExports = 1
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
        guard !Task.isCancelled else {
            frameInterpolationDebugPrint("导出任务：启动前已取消。视频=\(sourceURL.lastPathComponent)")
            return nil
        }

        let asset = AVURLAsset(url: sourceURL)
        frameInterpolationDebugPrint("导出任务：离线补帧开始。当前只使用算法=optical-flow，不执行降级逻辑，目标 FPS=\(targetFPS)，视频=\(sourceURL.lastPathComponent)。")
        guard let exportInfo = await makeFrameInterpolationExportInfo(asset: asset, targetFPS: targetFPS) else {
            frameInterpolationDebugPrint("导出任务：读取视频轨道、尺寸、方向、码率或时长失败。")
            return nil
        }
        guard !Task.isCancelled else {
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
        guard !Task.isCancelled else {
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

// MARK: - Video Loop Preprocessing Service

enum VideoLoopPreprocessingResult: Sendable {
    case alreadyProcessed
    case processed
    case failed(String)
}

/// 负责视频壁纸的离线 crossfade 预处理。
/// 只在用户**设置壁纸时**触发，不会在下载时自动处理，也不做批量扫描。
/// 处理完成后直接替换原始文件，并在对应下载记录中标记 `isLooped = true`。
@MainActor
final class VideoLoopPreprocessingService: ObservableObject {
    static let shared = VideoLoopPreprocessingService()

    @Published private(set) var isProcessing = false
    @Published private(set) var currentProcessingFile: String?

    private let tempDirectory: URL

    private init() {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaifuXLoopExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Query

    /// 通过下载记录判断指定路径的视频是否已做 loop 预处理
    func isProcessed(_ fileURL: URL) -> Bool {
        let path = fileURL.path
        if let record = WallpaperLibraryService.shared.downloadRecord(forLocalFilePath: path) {
            return record.isLooped == true
        }
        if let record = MediaLibraryService.shared.downloadRecord(forLocalFilePath: path) {
            return record.isLooped == true
        }
        return false
    }

    // MARK: - Preprocessing

    /// 异步预处理指定视频。如果已处理则不重复导出。
    /// 处理完成后替换原始文件，并更新对应下载记录的 `isLooped` 标记。
    func preprocessIfNeeded(_ originalURL: URL) async -> VideoLoopPreprocessingResult {
        guard !isProcessed(originalURL) else { return .alreadyProcessed }

        isProcessing = true
        currentProcessingFile = originalURL.lastPathComponent
        defer {
            isProcessing = false
            currentProcessingFile = nil
        }

        do {
            let tempURL = tempDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            try await exportLoopedVideo(from: originalURL, to: tempURL)

            guard FileManager.default.fileExists(atPath: tempURL.path) else {
                throw NSError(domain: "VideoLoop", code: 6, userInfo: [NSLocalizedDescriptionKey: "Exported file not found"])
            }

            // 原子替换原始文件
            _ = try FileManager.default.replaceItemAt(originalURL, withItemAt: tempURL)

            // 更新下载记录标记
            let path = originalURL.path
            WallpaperLibraryService.shared.markAsLooped(localFilePath: path)
            MediaLibraryService.shared.markAsLooped(localFilePath: path)

            print("[VideoLoopPreprocessing] Replaced original with looped version: \(originalURL.lastPathComponent)")
            return .processed
        } catch {
            print("[VideoLoopPreprocessing] Failed for \(originalURL.lastPathComponent): \(error)")
            let tempURL = tempDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            try? FileManager.default.removeItem(at: tempURL)
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Export

    private func exportLoopedVideo(from originalURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: originalURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        guard let videoTrack = videoTracks.first else {
            throw NSError(domain: "VideoLoop", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }

        let fadeDuration: Double = 1.0
        let fadeCMTime = CMTime(seconds: fadeDuration, preferredTimescale: 600)

        // 视频太短不做 crossfade，直接复制原文件
        guard duration > CMTimeMultiply(fadeCMTime, multiplier: 2) else {
            try? FileManager.default.copyItem(at: originalURL, to: outputURL)
            return
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()

        // Track 1: 原视频完整播放（底层）
        guard let track1 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "VideoLoop", code: 2)
        }
        try track1.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)

        // Track 2: 原视频开头 fadeDuration 秒，插入到 (duration - fadeDuration) 处（上层）
        guard let track2 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "VideoLoop", code: 3)
        }
        let track2InsertTime = duration - fadeCMTime
        try track2.insertTimeRange(CMTimeRange(start: .zero, duration: fadeCMTime), of: videoTrack, at: track2InsertTime)

        // 音频：简单复制完整音频
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
        }

        // Video composition: opacity ramps
        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let frameRate = nominalFrameRate > 0 ? nominalFrameRate : 30

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = naturalSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layerInstruction1 = AVMutableVideoCompositionLayerInstruction(assetTrack: track1)
        let layerInstruction2 = AVMutableVideoCompositionLayerInstruction(assetTrack: track2)

        let fadeStart = duration - fadeCMTime
        layerInstruction1.setOpacityRamp(
            fromStartOpacity: 1.0, toEndOpacity: 0.0,
            timeRange: CMTimeRange(start: fadeStart, duration: fadeCMTime)
        )
        layerInstruction2.setOpacityRamp(
            fromStartOpacity: 0.0, toEndOpacity: 1.0,
            timeRange: CMTimeRange(start: fadeStart, duration: fadeCMTime)
        )

        instruction.layerInstructions = [layerInstruction1, layerInstruction2]
        videoComposition.instructions = [instruction]

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "VideoLoop", code: 4, userInfo: [NSLocalizedDescriptionKey: "Export session creation failed"])
        }

        exportSession.videoComposition = videoComposition
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = false

        await exportSession.export()

        if let error = exportSession.error {
            throw error
        }
        guard exportSession.status == .completed else {
            throw NSError(domain: "VideoLoop", code: 5, userInfo: [NSLocalizedDescriptionKey: "Export status: \(exportSession.status.rawValue)"])
        }
    }
}
