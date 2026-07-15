import AVFoundation
import CoreVideo
import Foundation

/// Performs offline loop-point analysis for a single video.
///
/// The service deliberately has no knowledge of queues, wallpaper application,
/// library state, or UI. Callers own scheduling and record the returned outcome.
/// Its matching algorithm is the established low-resolution luminance pipeline:
/// a natural-loop preflight, whole-file candidate scan, 20-frame refinement, and
/// a `[start, end)` crop so the matching tail frame is excluded from the result.
enum VideoLoopAnalysisOutcome: Sendable, Equatable {
    case applied(firstContentFrame: Int, matchFrame: Int)
    case notNeeded
    case noReliablePoint
}

enum VideoLoopAnalysisService {
    static func analyzeAndReplace(
        videoURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VideoLoopAnalysisOutcome {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaifuXLoopAnalysis", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try FileManager.default.createDirectory(
            at: temporaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let decision = try await exportAnalyzedLoopVideo(
            from: videoURL,
            to: temporaryURL,
            progress: progress
        )

        switch decision {
        case .trim(let result):
            guard FileManager.default.fileExists(atPath: temporaryURL.path) else {
                throw NSError(
                    domain: "VideoLoopAnalysis",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Exported file not found"]
                )
            }
            _ = try FileManager.default.replaceItemAt(videoURL, withItemAt: temporaryURL)
            progress(1)
            return .applied(
                firstContentFrame: result.firstContentFrame,
                matchFrame: result.matchFrame
            )
        case .notNeeded:
            progress(1)
            return .notNeeded
        case .noReliablePoint:
            progress(1)
            return .noReliablePoint
        }
    }

    private struct LoopAnalysisResult: Sendable {
        let firstContentFrame: Int
        let matchFrame: Int
        let startTime: CMTime
        let endTime: CMTime
    }

    private enum LoopAnalysisDecision: Sendable {
        case trim(LoopAnalysisResult)
        case notNeeded
        case noReliablePoint
    }

    private struct TimedFrameSignature: Sendable {
        let frame: Int
        let time: CMTime
        let signature: FrameSignature
    }

    private struct RefinedLoopBoundary: Sendable {
        let start: TimedFrameSignature
        let end: TimedFrameSignature
        let difference: FrameWindowDifference
    }

    private static func exportAnalyzedLoopVideo(
        from originalURL: URL,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LoopAnalysisDecision {
        let asset = AVURLAsset(url: originalURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw NSError(
                domain: "VideoLoopAnalysis",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No video track"]
            )
        }

        progress(0.04)
        if try await isAlreadySeamlessLoop(asset: asset, videoTrack: videoTrack, duration: duration) {
            progress(0.98)
            return .notNeeded
        }

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = makeLoopAnalysisVideoOutput(for: videoTrack)
        guard reader.canAdd(videoOutput) else {
            throw NSError(
                domain: "VideoLoopAnalysis",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Unable to read video frames"]
            )
        }
        reader.add(videoOutput)
        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "VideoLoopAnalysis",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Unable to start video reader"]
            )
        }

        var referenceFrames: [TimedFrameSignature] = []
        var activeCandidates: [PendingLoopCandidate] = []
        var verifiedCandidates: [LoopCandidate] = []
        var lastSignature: FrameSignature?
        var frameIndex = 0
        let durationSeconds = max(0.001, duration.seconds)
        let verificationFrameCount = 12
        let refinementFrameCount = 20
        let minimumLoopDuration: Double = 0.75

        // Decode once from the first non-black frame. A candidate needs 12
        // consecutive matching frames before it is eligible for refinement.
        while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                frameIndex += 1
                continue
            }
            let signature = try FrameSignature(pixelBuffer: pixelBuffer)
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            lastSignature = signature

            if referenceFrames.isEmpty {
                if !signature.isPureBlack {
                    referenceFrames.append(TimedFrameSignature(
                        frame: frameIndex,
                        time: presentationTime,
                        signature: signature
                    ))
                }
            } else if referenceFrames.count < refinementFrameCount {
                referenceFrames.append(TimedFrameSignature(
                    frame: frameIndex,
                    time: presentationTime,
                    signature: signature
                ))
            } else if let startTime = referenceFrames.first?.time {
                var remainingCandidates: [PendingLoopCandidate] = []
                remainingCandidates.reserveCapacity(activeCandidates.count)

                for var candidate in activeCandidates {
                    let referenceIndex = candidate.comparedFrameCount
                    candidate.append(signature, reference: referenceFrames[referenceIndex].signature)
                    if candidate.comparedFrameCount == verificationFrameCount {
                        if candidate.difference.isReliableLoopMatch {
                            verifiedCandidates.append(candidate.completed())
                        }
                    } else {
                        remainingCandidates.append(candidate)
                    }
                }
                activeCandidates = remainingCandidates

                let elapsedFromStart = max(0, CMTimeGetSeconds(CMTimeSubtract(presentationTime, startTime)))
                if elapsedFromStart >= minimumLoopDuration {
                    let difference = signature.difference(to: referenceFrames[0].signature)
                    if difference.isPotentialLoopMatch {
                        activeCandidates.append(PendingLoopCandidate(
                            frame: frameIndex,
                            time: presentationTime,
                            firstDifference: difference
                        ))
                    }
                }
            }

            if frameIndex % 12 == 0 {
                let elapsed = max(0, presentationTime.seconds)
                progress(0.05 + 0.70 * min(1, elapsed / durationSeconds))
            }
            frameIndex += 1
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "VideoLoopAnalysis",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Video frame reading failed"]
            )
        }
        guard let firstReferenceFrame = referenceFrames.first else {
            throw NSError(
                domain: "VideoLoopAnalysis",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "No non-black frame found"]
            )
        }

        guard !verifiedCandidates.isEmpty else {
            return lastSignature?.isLoopBoundarySimilar(to: firstReferenceFrame.signature) == true
                ? .notNeeded
                : .noReliablePoint
        }

        // Videos longer than ten seconds cannot crop to a short accidental
        // repetition. For short source clips, preserve the last candidate.
        let minimumAcceptedLoopDuration: Double = 10
        let candidatesForRefinement: [LoopCandidate]
        if durationSeconds <= minimumAcceptedLoopDuration {
            candidatesForRefinement = verifiedCandidates.max { lhs, rhs in
                CMTimeCompare(lhs.time, rhs.time) < 0
            }.map { [$0] } ?? []
        } else {
            candidatesForRefinement = verifiedCandidates.filter { candidate in
                CMTimeGetSeconds(CMTimeSubtract(candidate.time, firstReferenceFrame.time)) >= minimumAcceptedLoopDuration
            }
        }
        guard !candidatesForRefinement.isEmpty else {
            return .noReliablePoint
        }

        let fallbackCandidate = selectLastReliableCandidate(from: candidatesForRefinement)
        var refinedBoundaries: [RefinedLoopBoundary] = []
        refinedBoundaries.reserveCapacity(candidatesForRefinement.count)
        for (index, candidate) in candidatesForRefinement.enumerated() {
            try Task.checkCancellation()
            do {
                if let refinedBoundary = try await refineLoopBoundary(
                    in: asset,
                    videoTrack: videoTrack,
                    duration: duration,
                    referenceFrames: referenceFrames,
                    candidate: candidate
                ) {
                    refinedBoundaries.append(refinedBoundary)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLogger.info(.media, "循环点候选精修跳过", metadata: [
                    "frame": String(candidate.frame),
                    "error": error.localizedDescription,
                ])
            }
            progress(0.70 + 0.07 * Double(index + 1) / Double(max(1, candidatesForRefinement.count)))
        }

        let bestRefinedBoundary = refinedBoundaries.min { lhs, rhs in
            if lhs.difference.qualityScore == rhs.difference.qualityScore {
                return lhs.end.time > rhs.end.time
            }
            return lhs.difference.qualityScore < rhs.difference.qualityScore
        }
        guard let selectedBoundary = bestRefinedBoundary ?? fallbackCandidate.map({
            RefinedLoopBoundary(
                start: firstReferenceFrame,
                end: TimedFrameSignature(frame: $0.frame, time: $0.time, signature: firstReferenceFrame.signature),
                difference: $0.difference
            )
        }),
        selectedBoundary.end.frame > selectedBoundary.start.frame,
        CMTimeCompare(selectedBoundary.end.time, selectedBoundary.start.time) > 0 else {
            return .noReliablePoint
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let sourceRange = CMTimeRange(
            start: selectedBoundary.start.time,
            duration: CMTimeSubtract(selectedBoundary.end.time, selectedBoundary.start.time)
        )
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "VideoLoopAnalysis", code: 2)
        }
        try compositionVideoTrack.insertTimeRange(sourceRange, of: videoTrack, at: .zero)
        compositionVideoTrack.preferredTransform = try await videoTrack.load(.preferredTransform)

        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compositionAudioTrack.insertTimeRange(sourceRange, of: audioTrack, at: .zero)
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw NSError(domain: "VideoLoopAnalysis", code: 4)
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = false
        progress(0.78)

        let observation = exportSession.observe(\.progress, options: [.initial, .new]) { _, change in
            let exportProgress = min(1, max(0, Double(change.newValue ?? 0)))
            progress(0.78 + 0.21 * exportProgress)
        }
        defer { observation.invalidate() }
        await exportSession.export()
        if let error = exportSession.error { throw error }
        guard exportSession.status == .completed else {
            throw NSError(
                domain: "VideoLoopAnalysis",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Export status: \(exportSession.status.rawValue)"]
            )
        }

        progress(0.98)
        return .trim(LoopAnalysisResult(
            firstContentFrame: selectedBoundary.start.frame,
            matchFrame: selectedBoundary.end.frame,
            startTime: selectedBoundary.start.time,
            endTime: selectedBoundary.end.time
        ))
    }

    private static func makeLoopAnalysisVideoOutput(for videoTrack: AVAssetTrack) -> AVAssetReaderTrackOutput {
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        output.alwaysCopiesSampleData = false
        return output
    }

    private static func isAlreadySeamlessLoop(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        duration: CMTime
    ) async throws -> Bool {
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds >= 1 else { return false }

        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let fps = frameRate > 0 ? Double(frameRate) : 30
        let windowDurationSeconds = min(max(0.75, 42 / fps), durationSeconds * 0.25)
        let windowDuration = CMTime(seconds: windowDurationSeconds, preferredTimescale: 600_000)
        let tailStart = CMTimeMaximum(.zero, CMTimeSubtract(duration, windowDuration))
        let firstFrames = Array(try readLoopSignatures(
            from: asset,
            videoTrack: videoTrack,
            timeRange: CMTimeRange(start: .zero, duration: windowDuration),
            maximumCount: 28
        ).filter { !$0.isPureBlack }.prefix(14))
        let lastFrames = Array(try readLoopSignatures(
            from: asset,
            videoTrack: videoTrack,
            timeRange: CMTimeRange(start: tailStart, duration: CMTimeSubtract(duration, tailStart)),
            maximumCount: 42
        ).filter { !$0.isPureBlack }.suffix(14))
        guard firstFrames.count >= 4, lastFrames.count >= 4 else { return false }

        let first = firstFrames[0]
        let next = firstFrames[1]
        let previousLast = lastFrames[lastFrames.count - 2]
        let last = lastFrames[lastFrames.count - 1]
        let boundaryDifference = last.difference(to: first)
        let incomingTransition = previousLast.difference(to: last)
        let outgoingTransition = first.difference(to: next)
        let boundaryMatches = boundaryDifference.meanAbsoluteDifference <= 10
            && boundaryDifference.rootMeanSquareDifference <= 22
            && boundaryDifference.strongDifferenceRatio <= 0.08
        let transitionIsContinuous = abs(
            incomingTransition.meanAbsoluteDifference - outgoingTransition.meanAbsoluteDifference
        ) <= 8
        return boundaryMatches && transitionIsContinuous
    }

    private static func readLoopSignatures(
        from asset: AVAsset,
        videoTrack: AVAssetTrack,
        timeRange: CMTimeRange,
        maximumCount: Int
    ) throws -> [FrameSignature] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let output = makeLoopAnalysisVideoOutput(for: videoTrack)
        guard reader.canAdd(output) else {
            throw NSError(domain: "VideoLoopAnalysis", code: 18)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VideoLoopAnalysis", code: 19)
        }

        var signatures: [FrameSignature] = []
        signatures.reserveCapacity(maximumCount)
        while signatures.count < maximumCount,
              let sampleBuffer = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            signatures.append(try FrameSignature(pixelBuffer: pixelBuffer))
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "VideoLoopAnalysis", code: 20)
        }
        if reader.status == .reading { reader.cancelReading() }
        return signatures
    }

    private static func refineLoopBoundary(
        in asset: AVAsset,
        videoTrack: AVAssetTrack,
        duration: CMTime,
        referenceFrames: [TimedFrameSignature],
        candidate: LoopCandidate
    ) async throws -> RefinedLoopBoundary? {
        let localFrameCount = min(20, referenceFrames.count)
        let starts = Array(referenceFrames.prefix(localFrameCount))
        guard starts.count >= 5 else { return nil }

        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let framesPerSecond = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30
        let frameDuration = CMTime(seconds: 1 / framesPerSecond, preferredTimescale: 600_000)
        let readerStart = CMTimeMaximum(
            .zero,
            CMTimeSubtract(candidate.time, CMTimeMultiply(frameDuration, multiplier: Int32(localFrameCount)))
        )
        let readerEnd = CMTimeMinimum(
            duration,
            CMTimeAdd(candidate.time, CMTimeMultiply(frameDuration, multiplier: Int32(localFrameCount + 1)))
        )
        guard CMTimeCompare(readerEnd, readerStart) > 0 else { return nil }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: readerStart, duration: CMTimeSubtract(readerEnd, readerStart))
        let output = makeLoopAnalysisVideoOutput(for: videoTrack)
        guard reader.canAdd(output) else {
            throw NSError(domain: "VideoLoopAnalysis", code: 15)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VideoLoopAnalysis", code: 16)
        }

        var candidateFrames: [TimedFrameSignature] = []
        while candidateFrames.count < localFrameCount * 2 + 1,
              let sampleBuffer = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            candidateFrames.append(TimedFrameSignature(
                frame: candidate.frame - localFrameCount + candidateFrames.count,
                time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                signature: try FrameSignature(pixelBuffer: pixelBuffer)
            ))
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "VideoLoopAnalysis", code: 17)
        }
        if reader.status == .reading { reader.cancelReading() }

        let validationFrameCount = 5
        var bestBoundary: RefinedLoopBoundary?
        var bestScore = Double.greatestFiniteMagnitude
        for startIndex in starts.indices {
            for endIndex in candidateFrames.indices {
                let availableFrames = min(starts.count - startIndex, candidateFrames.count - endIndex)
                guard availableFrames >= validationFrameCount,
                      CMTimeCompare(candidateFrames[endIndex].time, starts[startIndex].time) > 0 else {
                    continue
                }
                var difference = FrameWindowDifference()
                for offset in 0..<validationFrameCount {
                    difference.append(starts[startIndex + offset].signature.difference(
                        to: candidateFrames[endIndex + offset].signature
                    ))
                }
                guard difference.isReliableLoopMatch else { continue }
                let score = difference.qualityScore + Double(abs(startIndex - endIndex)) * 0.015
                if score < bestScore {
                    bestScore = score
                    bestBoundary = RefinedLoopBoundary(
                        start: starts[startIndex],
                        end: candidateFrames[endIndex],
                        difference: difference
                    )
                }
            }
        }
        return bestBoundary
    }

    private struct FrameWindowDifference: Sendable {
        private(set) var absoluteDifferenceTotal = 0
        private(set) var squaredDifferenceTotal = 0
        private(set) var strongDifferenceCount = 0
        private(set) var sampleCount = 0

        init() {}

        init(_ difference: FrameDifference) { append(difference) }

        mutating func append(_ difference: FrameDifference) {
            absoluteDifferenceTotal += difference.absoluteDifferenceTotal
            squaredDifferenceTotal += difference.squaredDifferenceTotal
            strongDifferenceCount += difference.strongDifferenceCount
            sampleCount += difference.sampleCount
        }

        var meanAbsoluteDifference: Double {
            Double(absoluteDifferenceTotal) / Double(max(1, sampleCount))
        }

        var rootMeanSquareDifference: Double {
            sqrt(Double(squaredDifferenceTotal) / Double(max(1, sampleCount)))
        }

        var strongDifferenceRatio: Double {
            Double(strongDifferenceCount) / Double(max(1, sampleCount))
        }

        var isReliableLoopMatch: Bool {
            meanAbsoluteDifference <= 7
                && rootMeanSquareDifference <= 16
                && strongDifferenceRatio <= 0.05
        }

        var qualityScore: Double {
            meanAbsoluteDifference / 7
                + rootMeanSquareDifference / 16
                + strongDifferenceRatio / 0.05
        }
    }

    private struct FrameDifference: Sendable {
        let absoluteDifferenceTotal: Int
        let squaredDifferenceTotal: Int
        let strongDifferenceCount: Int
        let sampleCount: Int

        var meanAbsoluteDifference: Double {
            Double(absoluteDifferenceTotal) / Double(max(1, sampleCount))
        }

        var rootMeanSquareDifference: Double {
            sqrt(Double(squaredDifferenceTotal) / Double(max(1, sampleCount)))
        }

        var strongDifferenceRatio: Double {
            Double(strongDifferenceCount) / Double(max(1, sampleCount))
        }

        var isPotentialLoopMatch: Bool {
            meanAbsoluteDifference <= 11
                && rootMeanSquareDifference <= 28
                && strongDifferenceRatio <= 0.12
        }
    }

    private struct PendingLoopCandidate: Sendable {
        let frame: Int
        let time: CMTime
        private(set) var comparedFrameCount = 1
        private(set) var difference: FrameWindowDifference

        init(frame: Int, time: CMTime, firstDifference: FrameDifference) {
            self.frame = frame
            self.time = time
            difference = FrameWindowDifference(firstDifference)
        }

        mutating func append(_ signature: FrameSignature, reference: FrameSignature) {
            difference.append(signature.difference(to: reference))
            comparedFrameCount += 1
        }

        func completed() -> LoopCandidate {
            LoopCandidate(frame: frame, time: time, difference: difference)
        }
    }

    private struct LoopCandidate: Sendable {
        let frame: Int
        let time: CMTime
        let difference: FrameWindowDifference
    }

    private static func selectLastReliableCandidate(from candidates: [LoopCandidate]) -> LoopCandidate? {
        guard !candidates.isEmpty else { return nil }
        let clusterGap: Double = 0.75
        var clusters: [[LoopCandidate]] = []
        var currentCluster: [LoopCandidate] = []
        for candidate in candidates {
            if let previous = currentCluster.last,
               CMTimeGetSeconds(CMTimeSubtract(candidate.time, previous.time)) > clusterGap {
                clusters.append(currentCluster)
                currentCluster = [candidate]
            } else {
                currentCluster.append(candidate)
            }
        }
        if !currentCluster.isEmpty { clusters.append(currentCluster) }
        return clusters.last?.min { lhs, rhs in
            lhs.difference.qualityScore < rhs.difference.qualityScore
        }
    }

    private struct FrameSignature: Sendable {
        let luma: [UInt8]
        let averageLuma: Double

        init(pixelBuffer: CVPixelBuffer) throws {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            let sampleWidth = 96
            let sampleHeight = 54
            var sampledLuma = [UInt8]()
            sampledLuma.reserveCapacity(sampleWidth * sampleHeight)
            var sum = 0

            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            switch pixelFormat {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
                let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
                guard width > 0, height > 0,
                      let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                    throw NSError(domain: "VideoLoopAnalysis", code: 13)
                }
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                let source = baseAddress.assumingMemoryBound(to: UInt8.self)
                for sampleY in 0..<sampleHeight {
                    let sourceY = min(height - 1, (sampleY * height + sampleHeight / 2) / sampleHeight)
                    let row = source.advanced(by: sourceY * bytesPerRow)
                    for sampleX in 0..<sampleWidth {
                        let sourceX = min(width - 1, (sampleX * width + sampleWidth / 2) / sampleWidth)
                        let value = row[sourceX]
                        sampledLuma.append(value)
                        sum += Int(value)
                    }
                }
            case kCVPixelFormatType_32BGRA:
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                guard width > 0, height > 0,
                      let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                    throw NSError(domain: "VideoLoopAnalysis", code: 14)
                }
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let source = baseAddress.assumingMemoryBound(to: UInt8.self)
                for sampleY in 0..<sampleHeight {
                    let sourceY = min(height - 1, (sampleY * height + sampleHeight / 2) / sampleHeight)
                    let row = source.advanced(by: sourceY * bytesPerRow)
                    for sampleX in 0..<sampleWidth {
                        let sourceX = min(width - 1, (sampleX * width + sampleWidth / 2) / sampleWidth)
                        let pixel = row.advanced(by: sourceX * 4)
                        let blue = Int(pixel[2])
                        let green = Int(pixel[1])
                        let red = Int(pixel[0])
                        let luminance = 77 * blue + 150 * green + 29 * red + 128
                        let value = UInt8(luminance >> 8)
                        sampledLuma.append(value)
                        sum += Int(value)
                    }
                }
            default:
                throw NSError(
                    domain: "VideoLoopAnalysis",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported video pixel format: \(pixelFormat)"]
                )
            }
            luma = sampledLuma
            averageLuma = Double(sum) / Double(max(1, sampledLuma.count))
        }

        var isPureBlack: Bool { averageLuma <= 3 }

        func difference(to other: FrameSignature) -> FrameDifference {
            guard luma.count == other.luma.count else {
                return FrameDifference(
                    absoluteDifferenceTotal: .max / 4,
                    squaredDifferenceTotal: .max / 4,
                    strongDifferenceCount: .max / 4,
                    sampleCount: 1
                )
            }
            var absoluteDifferenceTotal = 0
            var squaredDifferenceTotal = 0
            var strongDifferenceCount = 0
            for index in luma.indices {
                let delta = abs(Int(luma[index]) - Int(other.luma[index]))
                absoluteDifferenceTotal += delta
                squaredDifferenceTotal += delta * delta
                if delta > 36 { strongDifferenceCount += 1 }
            }
            return FrameDifference(
                absoluteDifferenceTotal: absoluteDifferenceTotal,
                squaredDifferenceTotal: squaredDifferenceTotal,
                strongDifferenceCount: strongDifferenceCount,
                sampleCount: luma.count
            )
        }

        func isLoopBoundarySimilar(to other: FrameSignature) -> Bool {
            let difference = difference(to: other)
            return difference.meanAbsoluteDifference <= 7
                && difference.rootMeanSquareDifference <= 16
                && difference.strongDifferenceRatio <= 0.05
        }
    }
}
