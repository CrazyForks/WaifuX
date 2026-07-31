import AVFoundation
import Foundation

/// B 帧视频转码服务
///
/// 有 B 帧 + 高码率的视频 seek 时需要逐帧解码导致卡顿。
/// 使用 AVAssetWriter 转码为无 B 帧格式，seek 直接跳到最近 I 帧。
/// 转码结果直接覆盖原文件。
///
/// - 注意：不再自动触发，需通过 UI 手动调用。
enum VideoTranscodeService {

    /// 码率阈值：低于此值即使有 B 帧也不会卡
    private static let bitrateThreshold: Double = 8_000_000

    /// 修正 HEVC MP4 的 sample entry，避免 macOS AVFoundation 拒绝播放 `hev1`。
    ///
    /// Steam Workshop 中部分视频由 FFmpeg 写成 `hev1`，第三方播放器可以用
    /// 自带解码器播放，但 Quick Look/AVFoundation 只接受同一份码流的
    /// Apple 兼容 `hvc1` 标记。这里仅修改 MP4 容器中的 4 字节类型，不重新编码。
    static func ensureAppleCompatibleContainer(_ videoURL: URL) async -> URL {
        guard videoURL.isFileURL else { return videoURL }
        let url = videoURL
        return await Task.detached(priority: .utility) {
            normalizeHEVCContainers(at: url)
        }.value
    }

    // MARK: - Public

    /// 分析视频是否需要转码。
    /// - 烘焙产物（SceneBakes）始终跳过，已是 H.265 优化编码。
    static func needsTranscode(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        // SceneBakes 烘焙产物跳过
        if url.path.contains("/SceneBakes/") {
            return false
        }
        let info = analyze(url)
        return info.needsTranscode
    }

    /// 转码视频为 seek-friendly 格式，直接覆盖原文件。
    /// 调用前应先通过 `needsTranscode(_:)` 确认是否需要。
    static func ensureSeekFriendly(_ videoURL: URL, progress: (@Sendable (Double) -> Void)? = nil) async -> URL {
        guard videoURL.isFileURL else { return videoURL }

        let info = analyze(videoURL)
        guard info.needsTranscode else { return videoURL }

        let tmpURL = videoURL.appendingPathExtension("transcoding.mp4")
        let videoURLCopy = videoURL
        let success: Bool = await Task.detached(priority: .userInitiated) {
            transcode(videoURLCopy, info: info, outputURL: tmpURL, progress: progress)
        }.value

        guard success else { return videoURL }

        do {
            try FileManager.default.removeItem(at: videoURL)
            try FileManager.default.moveItem(at: tmpURL, to: videoURL)
            return videoURL
        } catch {
            print("[VideoTranscodeService] Replace failed: \(error)")
            try? FileManager.default.removeItem(at: tmpURL)
            return videoURL
        }
    }

    // MARK: - 分析

    struct VideoInfo {
        let width: Int
        let height: Int
        let bitrate: Double
        let fps: Double
        let hasBFrames: Bool
        let needsTranscode: Bool
    }

    static func analyze(_ url: URL) -> VideoInfo {
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            return VideoInfo(width: 0, height: 0, bitrate: 0, fps: 0, hasBFrames: false, needsTranscode: false)
        }
        let size = track.naturalSize.applying(track.preferredTransform)
        let w = Int(abs(size.width)), h = Int(abs(size.height))
        let br = Double(track.estimatedDataRate)
        let fps = Double(track.nominalFrameRate)
        let bframes = track.requiresFrameReordering
        return VideoInfo(width: w, height: h, bitrate: br, fps: fps, hasBFrames: bframes,
                         needsTranscode: bframes && br > bitrateThreshold)
    }

    // MARK: - AVAssetWriter 转码

    private static func transcode(_ inputURL: URL, info: VideoInfo, outputURL: URL, progress: ((Double) -> Void)?) -> Bool {
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVAsset(url: inputURL)
        let duration = asset.duration.seconds

        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        guard let writer = try? AVAssetWriter(url: outputURL, fileType: .mp4) else { return false }
        writer.shouldOptimizeForNetworkUse = true

        // --- Video track ---
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return false }

        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
        reader.add(videoOutput)

        let videoInputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: info.width,
            AVVideoHeightKey: info.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(max(info.bitrate * 1.1, info.bitrate + 500_000)),
                AVVideoMaxKeyFrameIntervalKey: Int(info.fps),
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoInputSettings)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        // --- Audio track ---
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let aOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(aOut)
            audioOutput = aOut

            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            aIn.expectsMediaDataInRealTime = false
            writer.add(aIn)
            audioInput = aIn
        }

        guard reader.startReading(), writer.startWriting() else {
            print("[VideoTranscodeService] Start failed: \(reader.error ?? writer.error)")
            return false
        }
        writer.startSession(atSourceTime: .zero)

        // 等待视频 + 音频都完成
        let group = DispatchGroup()

        // 视频
        group.enter()
        let videoQueue = DispatchQueue(label: "transcode.video")
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                guard let buf = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                if !videoInput.append(buf) { videoInput.markAsFinished(); group.leave(); return }
                let pts = CMSampleBufferGetPresentationTimeStamp(buf).seconds
                if duration > 0, pts.isFinite { progress?(min(pts / duration, 1.0)) }
            }
        }

        // 音频
        if let audioOutput, let audioInput {
            group.enter()
            let audioQueue = DispatchQueue(label: "transcode.audio")
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard let buf = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    if !audioInput.append(buf) { audioInput.markAsFinished(); group.leave(); return }
                }
            }
        }

        // 等待全部完成
        group.wait()

        let finishSem = DispatchSemaphore(value: 0)
        writer.finishWriting { finishSem.signal() }
        finishSem.wait()

        if writer.status == .failed {
            print("[VideoTranscodeService] Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }

        return writer.status == .completed
    }

    // MARK: - HEVC container compatibility

    private static func normalizeHEVCContainers(at url: URL) -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return url
        }
        guard isDirectory.boolValue else {
            return normalizeHEVCSampleEntry(at: url)
        }

        let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return url
        }
        for case let fileURL as URL in enumerator
            where videoExtensions.contains(fileURL.pathExtension.lowercased()) {
            _ = normalizeHEVCSampleEntry(at: fileURL)
        }
        return url
    }

    private static func normalizeHEVCSampleEntry(at url: URL) -> URL {
        guard let original = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return url
        }
        var data = original
        var replacements = 0

        scanBoxes(
            data: &data,
            range: 0..<data.count,
            replacements: &replacements
        )
        guard replacements > 0 else { return url }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).hvc1-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(
                url,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
            print("[VideoTranscodeService] Normalized HEVC container: \(url.lastPathComponent) replacements=\(replacements)")
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            print("[VideoTranscodeService] HEVC container normalization failed: \(error)")
        }
        return url
    }

    private struct MP4Box {
        let type: String
        let start: Int
        let headerSize: Int
        let end: Int
    }

    private static let nestedBoxTypes: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "edts", "dinf",
        "mvex", "moof", "traf", "mfra", "udta", "meta", "ilst", "sinf", "schi"
    ]

    private static func scanBoxes(
        data: inout Data,
        range: Range<Int>,
        replacements: inout Int,
        prefixBytes: Int = 0
    ) {
        var offset = range.lowerBound + prefixBytes
        let end = range.upperBound
        while offset + 8 <= end {
            guard let box = readBox(in: data, at: offset, limit: end) else { return }

            if box.type == "stsd" {
                normalizeSampleDescriptions(
                    in: box,
                    data: &data,
                    replacements: &replacements
                )
            } else if nestedBoxTypes.contains(box.type) {
                let childPrefix = box.type == "meta" ? 4 : 0
                scanBoxes(
                    data: &data,
                    range: (box.start + box.headerSize)..<box.end,
                    replacements: &replacements,
                    prefixBytes: childPrefix
                )
            }
            offset = box.end
        }
    }

    private static func normalizeSampleDescriptions(
        in box: MP4Box,
        data: inout Data,
        replacements: inout Int
    ) {
        let payloadStart = box.start + box.headerSize
        guard payloadStart + 8 <= box.end,
              let entryCount = readUInt32(in: data, at: payloadStart + 4) else {
            return
        }

        var entryOffset = payloadStart + 8
        for _ in 0..<entryCount {
            guard let entry = readBox(in: data, at: entryOffset, limit: box.end) else { return }
            guard entry.end > entryOffset + 8 else { return }

            if entry.type == "hev1" {
                data.replaceSubrange(
                    (entryOffset + 4)..<(entryOffset + 8),
                    with: Array("hvc1".utf8)
                )
                replacements += 1
            }
            entryOffset = entry.end
        }
    }

    private static func readBox(in data: Data, at offset: Int, limit: Int) -> MP4Box? {
        guard offset >= 0, offset + 8 <= limit,
              let size32 = readUInt32(in: data, at: offset) else {
            return nil
        }

        let typeBytes = data[(offset + 4)..<(offset + 8)]
        guard let type = String(bytes: typeBytes, encoding: .ascii) else { return nil }

        let headerSize: Int
        let boxSize: UInt64
        if size32 == 1 {
            guard offset + 16 <= limit,
                  let extendedSize = readUInt64(in: data, at: offset + 8) else {
                return nil
            }
            headerSize = 16
            boxSize = extendedSize
        } else if size32 == 0 {
            headerSize = 8
            boxSize = UInt64(limit - offset)
        } else {
            headerSize = 8
            boxSize = UInt64(size32)
        }

        guard boxSize >= UInt64(headerSize),
              boxSize <= UInt64(Int.max),
              offset <= limit - Int(boxSize) else {
            return nil
        }
        return MP4Box(
            type: type,
            start: offset,
            headerSize: headerSize,
            end: offset + Int(boxSize)
        )
    }

    private static func readUInt32(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt64(in data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        return (UInt64(data[offset]) << 56)
            | (UInt64(data[offset + 1]) << 48)
            | (UInt64(data[offset + 2]) << 40)
            | (UInt64(data[offset + 3]) << 32)
            | (UInt64(data[offset + 4]) << 24)
            | (UInt64(data[offset + 5]) << 16)
            | (UInt64(data[offset + 6]) << 8)
            | UInt64(data[offset + 7])
    }
}
