import Foundation

/// Persists durable optimization lifecycle events beside each video.
///
/// This store deliberately has no dependency on the queue, player, scheduler, or
/// wallpaper application services. It only records and reads state; callers own
/// the resulting behavior.
@MainActor
final class VideoOptimizationRecordStore {
    static let shared = VideoOptimizationRecordStore()

    private static let exactLoopPreflightVersion = "exact-decoded-pixels-v1"

    enum EventKind: String, Codable {
        case sourceDownloaded
        case bakeCompleted
        case loopQueued
        case loopAnalysisStarted
        case loopApplied
        case loopNotNeeded
        case loopNoReliablePoint
        case loopFailed
        case loopBlacklisted
        case loopCancelled
        case frameQueued
        case frameAnalysisStarted
        case frameInterpolationStarted
        case frameApplied
        case frameNotNeeded
        case frameFailed
        case frameCancelled
        case frameBlacklisted
        case frameReset
    }

    /// The origin describes how this exact video file came to exist. It is
    /// deliberately stored beside the video rather than inferred from a
    /// library record, because optimized and baked files can outlive a cache
    /// rebuild or an application restart.
    enum SourceKind: String, Codable, Equatable {
        case download
        case sceneBake
        case imported
        case unknown
    }

    struct SourceInfo: Codable, Equatable {
        var kind: SourceKind
        var sourceURL: String?
        var sourcePath: String?
        var recordedAt: Date
    }

    enum DownloadStatus: String, Codable, Equatable {
        case completed
        case failed
        case cancelled
        case unavailable
    }

    struct DownloadInfo: Codable, Equatable {
        var status: DownloadStatus
        var sourceURL: String?
        var completedAt: Date
    }

    enum BakeStatus: String, Codable, Equatable {
        case completed
        case failed
        case cancelled
        case unavailable
    }

    struct BakeInfo: Codable, Equatable {
        var status: BakeStatus
        var sourcePath: String?
        var artifactPath: String
        var renderer: String?
        var durationSeconds: Double?
        var framesPerSecond: Int?
        var width: Int?
        var height: Int?
        var completedAt: Date
    }

    struct Event: Codable, Identifiable, Equatable {
        let id: UUID
        let date: Date
        let kind: EventKind
        let detail: String?
        let metadata: [String: String]

        init(kind: EventKind, detail: String? = nil, metadata: [String: String] = [:]) {
            self.id = UUID()
            self.date = Date()
            self.kind = kind
            self.detail = detail
            self.metadata = metadata
        }
    }

    struct Record: Codable, Equatable {
        /// Keep provenance first in the human-readable sidecar. Existing
        /// records decode because all provenance fields remain optional.
        var source: SourceInfo?
        var download: DownloadInfo?
        var bake: BakeInfo?
        let schemaVersion: Int
        let videoPath: String
        let createdAt: Date
        var updatedAt: Date
        var events: [Event]

        init(videoURL: URL) {
            let now = Date()
            source = SourceInfo(
                kind: .unknown,
                sourceURL: nil,
                sourcePath: nil,
                recordedAt: now
            )
            download = nil
            bake = nil
            schemaVersion = 3
            videoPath = videoURL.standardizedFileURL.path
            createdAt = now
            updatedAt = now
            events = []
        }
    }

    enum LoopState: Equatable {
        case idle
        case applied
        case notNeeded
        case noReliablePoint
        case failed
        case blacklisted
    }

    enum FrameState: Equatable {
        case idle
        case applied(targetFPS: Int?)
        case notNeeded(targetFPS: Int?)
        case failed
        case blacklisted
    }

    private let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv", "flv"
    ]

    private init() {}

    func sidecarURL(for videoURL: URL) -> URL {
        URL(fileURLWithPath: videoURL.standardizedFileURL.path + ".waifux-optimization.json")
    }

    func record(for videoURL: URL) -> Record? {
        guard isVideoFile(videoURL) else { return nil }
        guard let data = try? Data(contentsOf: sidecarURL(for: videoURL)) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    func append(
        _ kind: EventKind,
        for videoURL: URL,
        detail: String? = nil,
        metadata: [String: String] = [:]
    ) {
        guard isVideoFile(videoURL) else { return }

        var record = record(for: videoURL) ?? Record(videoURL: videoURL)
        record.events.append(Event(kind: kind, detail: detail, metadata: metadata))
        record.updatedAt = Date()
        write(record, for: videoURL)
    }

    /// A no-op loop result is valid only when it was verified against the
    /// current full-frame comparison. Older similarity-based records are
    /// intentionally re-evaluated.
    func markLoopNotNeeded(for videoURL: URL) {
        append(
            .loopNotNeeded,
            for: videoURL,
            metadata: ["preflightVersion": Self.exactLoopPreflightVersion]
        )
    }

    /// Registers a completed download as the source of this exact video. A
    /// fresh download starts a new optimization lifecycle, so callers reset
    /// the old sidecar before invoking this method.
    func recordDownloadedSource(for videoURL: URL, sourceURL: URL?) {
        guard isVideoFile(videoURL) else { return }

        var record = record(for: videoURL) ?? Record(videoURL: videoURL)
        let now = Date()
        let sourceURLString = sourceURL?.absoluteString
        record.source = SourceInfo(
            kind: .download,
            sourceURL: sourceURLString,
            sourcePath: nil,
            recordedAt: now
        )
        record.download = DownloadInfo(
            status: .completed,
            sourceURL: sourceURLString,
            completedAt: now
        )
        record.events.append(Event(kind: .sourceDownloaded, metadata: compactMetadata([
            "sourceURL": sourceURLString,
        ])))
        record.updatedAt = now
        write(record, for: videoURL)
    }

    /// Gives pre-existing local files a durable origin the first time they are
    /// applied or optimized. Download and Scene bake completion later replace
    /// this fallback with their more specific provenance.
    func recordImportedSourceIfNeeded(for videoURL: URL) {
        guard isVideoFile(videoURL) else { return }

        var record = record(for: videoURL) ?? Record(videoURL: videoURL)
        guard record.source == nil || record.source?.kind == .unknown else { return }

        let now = Date()
        record.source = SourceInfo(
            kind: .imported,
            sourceURL: nil,
            sourcePath: videoURL.standardizedFileURL.path,
            recordedAt: now
        )
        record.updatedAt = now
        write(record, for: videoURL)
    }

    /// Stores the Scene project and output parameters that produced a baked
    /// MP4. The bake status is local to the artifact and does not rely on the
    /// media-library cache being present after a restart.
    func recordBakeArtifact(
        for videoURL: URL,
        sourcePath: String,
        artifact: SceneBakeArtifact
    ) {
        guard isVideoFile(videoURL) else { return }

        var record = record(for: videoURL) ?? Record(videoURL: videoURL)
        let now = Date()
        let bakedAt = Date(timeIntervalSince1970: artifact.bakedAt.timeIntervalSince1970.rounded(.down))
        let source = SourceInfo(
            kind: .sceneBake,
            sourceURL: nil,
            sourcePath: sourcePath,
            recordedAt: bakedAt
        )
        let bake = BakeInfo(
            status: .completed,
            sourcePath: sourcePath,
            artifactPath: videoURL.standardizedFileURL.path,
            renderer: artifact.renderer?.rawValue,
            durationSeconds: artifact.durationSeconds,
            framesPerSecond: artifact.fps,
            width: artifact.width,
            height: artifact.height,
            completedAt: bakedAt
        )
        guard record.source != source || record.bake != bake else { return }

        record.source = source
        record.bake = bake
        record.events.append(Event(kind: .bakeCompleted, metadata: compactMetadata([
            "sourcePath": sourcePath,
            "renderer": artifact.renderer?.rawValue,
            "durationSeconds": String(artifact.durationSeconds),
            "fps": String(artifact.fps),
            "width": String(artifact.width),
            "height": String(artifact.height),
        ])))
        record.updatedAt = now
        write(record, for: videoURL)
    }

    func latestEvent(for videoURL: URL, matching kinds: Set<EventKind>) -> Event? {
        record(for: videoURL)?.events.reversed().first { kinds.contains($0.kind) }
    }

    func latestLoopEvent(for videoURL: URL) -> Event? {
        latestEvent(
            for: videoURL,
            matching: [
                .loopApplied,
                .loopNotNeeded,
                .loopNoReliablePoint,
                .loopFailed,
                .loopBlacklisted,
            ]
        )
    }

    func latestFrameEvent(for videoURL: URL) -> Event? {
        latestEvent(
            for: videoURL,
            matching: [
                .frameApplied,
                .frameNotNeeded,
                .frameFailed,
                .frameBlacklisted,
            ]
        )
    }

    /// Converts durable terminal events into the state shown outside the queue.
    /// Queue progress is intentionally not serialized beside the video.
    func loopState(for videoURL: URL) -> LoopState {
        guard let event = latestLoopEvent(for: videoURL) else { return .idle }
        switch event.kind {
        case .loopApplied:
            return .applied
        case .loopNotNeeded:
            return event.metadata["preflightVersion"] == Self.exactLoopPreflightVersion
                ? .notNeeded
                : .idle
        case .loopNoReliablePoint:
            return .noReliablePoint
        case .loopFailed:
            return .failed
        case .loopBlacklisted:
            return .blacklisted
        case .sourceDownloaded, .bakeCompleted,
             .loopQueued, .loopAnalysisStarted, .loopCancelled,
             .frameQueued, .frameAnalysisStarted, .frameInterpolationStarted,
             .frameApplied, .frameNotNeeded, .frameFailed, .frameCancelled,
             .frameBlacklisted, .frameReset:
            return .idle
        }
    }

    /// Converts durable interpolation events into a queue-independent state.
    func frameState(for videoURL: URL) -> FrameState {
        guard let event = latestFrameEvent(for: videoURL) else { return .idle }
        let targetFPS = event.metadata["targetFPS"].flatMap(Int.init)
        switch event.kind {
        case .frameApplied:
            return .applied(targetFPS: targetFPS)
        case .frameNotNeeded:
            return .notNeeded(targetFPS: targetFPS)
        case .frameFailed:
            return .failed
        case .frameBlacklisted:
            return .blacklisted
        case .frameReset, .sourceDownloaded, .bakeCompleted,
             .loopQueued, .loopAnalysisStarted, .loopApplied, .loopNotNeeded,
             .loopNoReliablePoint, .loopFailed, .loopBlacklisted, .loopCancelled,
             .frameQueued, .frameAnalysisStarted, .frameInterpolationStarted,
             .frameCancelled:
            return .idle
        }
    }

    func markBlacklisted(
        _ operation: FrameInterpolationQueueItem.Operation,
        for videoURL: URL,
        title: String,
        targetFPS: Int
    ) {
        let kind: EventKind = operation == .loopAnalysis ? .loopBlacklisted : .frameBlacklisted
        append(
            kind,
            for: videoURL,
            metadata: compactMetadata([
                "operation": operation.rawValue,
                "targetFPS": operation == .frameInterpolation ? String(targetFPS) : nil,
                "title": title.isEmpty ? videoURL.deletingPathExtension().lastPathComponent : title,
            ])
        )
    }

    /// Removing a blacklist is a real deletion, rather than a compensating
    /// "reset" event. The JSON remains an accurate record of current terminal
    /// state and never needs an in-memory override after relaunch.
    func removeBlacklist(
        _ operation: FrameInterpolationQueueItem.Operation,
        for videoURL: URL
    ) {
        guard var record = record(for: videoURL) else { return }
        let kind: EventKind = operation == .loopAnalysis ? .loopBlacklisted : .frameBlacklisted
        record.events.removeAll { $0.kind == kind }
        record.updatedAt = Date()
        write(record, for: videoURL)
    }

    func reset(for videoURL: URL) {
        guard isVideoFile(videoURL) else { return }
        try? FileManager.default.removeItem(at: sidecarURL(for: videoURL))
    }

    private func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    private func compactMetadata(_ values: [String: String?]) -> [String: String] {
        values.reduce(into: [:]) { partialResult, entry in
            if let value = entry.value, !value.isEmpty {
                partialResult[entry.key] = value
            }
        }
    }

    private func write(_ record: Record, for videoURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(record) else { return }
        do {
            try data.write(to: sidecarURL(for: videoURL), options: .atomic)
        } catch {
            AppLogger.error(.media, "写入视频优化记录失败", metadata: [
                "video": videoURL.path,
                "sidecar": sidecarURL(for: videoURL).path,
                "error": error.localizedDescription,
            ])
        }
    }
}
