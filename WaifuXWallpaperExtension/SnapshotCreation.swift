//  IOSurface snapshot creation for WallpaperAgent.

import AVFoundation
import CoreMedia
import ImageIO
@preconcurrency import IOSurface

func createSnapshotViaRuntime(currentTime: CMTime? = nil) async -> AnyObject? {
    extLog("  [Snapshot] 开始创建 — currentTime=\(currentTime.map { "\($0.value)/\($0.timescale)" } ?? "nil")")

    if let image = loadSharedSnapshotImage(),
       let snapshotXPC = renderSnapshotToIOSurface(image: image) {
        extLog("  [Snapshot] Created WallpaperSnapshotXPC from shared thumbnail \(image.width)x\(image.height)")
        return snapshotXPC
    }
    extLog("  [Snapshot] Strategy 1 (shared thumbnail) missed")

    if let ioSurfaceSnapshot = WallpaperState.shared.anyIOSurfaceRenderer()?.makeSnapshotXPC() {
        extLog("  [Snapshot] Created WallpaperSnapshotXPC from active IOSurface")
        return ioSurfaceSnapshot
    }
    extLog("  [Snapshot] Strategy 2 (IOSurface renderer) missed")

    guard let videoURL = findVideoURL() else {
        extLog("  [Snapshot] Strategy 3 missed: no video file found")
        return nil
    }
    extLog("  [Snapshot] Strategy 3: found video \(videoURL.lastPathComponent)")
    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true

    let requestTime: CMTime
    if let currentTime, currentTime.isValid, currentTime.seconds > 0 {
        requestTime = currentTime
    } else {
        do {
            let duration = try await asset.load(.duration)
            if duration.isValid, duration.seconds > 0 {
                let randomOffset = Double.random(in: 0 ..< duration.seconds)
                requestTime = CMTime(seconds: randomOffset, preferredTimescale: duration.timescale)
            } else {
                requestTime = .zero
            }
        } catch {
            requestTime = .zero
        }
    }

    let image: CGImage
    do {
        let result = try await generator.image(at: requestTime)
        image = result.image
    } catch {
        extLog("  [Snapshot] Failed to get video frame: \(error)")
        return nil
    }
    guard let snapshotXPC = renderSnapshotToIOSurface(image: image) else { return nil }
    extLog("  [Snapshot] Created WallpaperSnapshotXPC \(image.width)x\(image.height)")
    return snapshotXPC
}

private func loadSharedSnapshotImage() -> CGImage? {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
        return nil
    }

    for url in sharedSnapshotCandidateURLs(in: container) {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            continue
        }
        extLog("  [Snapshot] Using shared snapshot image: \(url.lastPathComponent)")
        return image
    }
    return nil
}

private func sharedSnapshotCandidateURLs(in container: URL) -> [URL] {
    var candidates: [URL] = []

    if let imagePath = currentPrefsPath("currentImagePath") {
        candidates.append(URL(fileURLWithPath: imagePath))
    }

    let thumbDir = container.appendingPathComponent("WallpaperCache/thumbnails")
    if let latestDisplayThumb = latestDisplayThumbnail(in: thumbDir) {
        candidates.append(latestDisplayThumb)
    }

    if let videoPath = currentPrefsPath("currentVideoPath") {
        let videoID = URL(fileURLWithPath: videoPath).deletingPathExtension().lastPathComponent
        candidates.append(thumbDir.appendingPathComponent("\(videoID).jpg"))
    }

    var seen = Set<String>()
    return candidates.filter { seen.insert($0.path).inserted }
}

private func currentPrefsPath(_ key: String) -> String? {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
        return nil
    }
    let prefsURL = container.appendingPathComponent("waifux-wallpaper-prefs.json")
    guard let data = try? Data(contentsOf: prefsURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let path = object[key] as? String,
          !path.isEmpty else {
        return nil
    }
    return path
}

private func latestDisplayThumbnail(in thumbDir: URL) -> URL? {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: thumbDir,
        includingPropertiesForKeys: [.contentModificationDateKey]
    ) else {
        return nil
    }

    return files
        .filter { file in
            file.pathExtension.lowercased() == "jpg"
                && file.deletingPathExtension().lastPathComponent.hasPrefix("display-")
        }
        .max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if lhsDate == rhsDate {
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            return lhsDate < rhsDate
        }
}

private func renderSnapshotToIOSurface(image: CGImage) -> AnyObject? {
    let width = image.width
    let height = image.height
    let surfaceProps: [IOSurfacePropertyKey: any Sendable] = [
        .width: width,
        .height: height,
        .bytesPerElement: 4,
        .pixelFormat: 0x4247_5241, // 'BGRA'
    ]
    guard let surface = IOSurface(properties: surfaceProps) else {
        extLog("  [Snapshot] Failed to create IOSurface")
        return nil
    }
    surface.lock(options: [], seed: nil)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    if let ctx = CGContext(
        data: surface.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: surface.bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) {
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    surface.unlock(options: [], seed: nil)

    guard let snapshotClass = objc_getClass("WallpaperSnapshotXPC") as? AnyClass,
          let instance = class_createInstance(snapshotClass, 0) else {
        extLog("  [Snapshot] ❌ Failed to create WallpaperSnapshotXPC instance")
        return nil
    }

    // 诊断：输出类信息和实例大小，帮助检测 macOS 版本间的布局变化
    let instanceSize = class_getInstanceSize(snapshotClass)
    extLog("  [Snapshot] WallpaperSnapshotXPC instanceSize=\(instanceSize)")

    let surfaceRef = Unmanaged.passRetained(surface).toOpaque()
    let instancePtr = Unmanaged.passUnretained(instance as AnyObject).toOpaque()
    // The real class has a single `rawValue` ivar at offset 8 containing
    // a WallpaperSnapshot struct (8 bytes = IOSurface refcounted pointer).
    instancePtr.advanced(by: 8).storeBytes(of: surfaceRef, as: UnsafeMutableRawPointer.self)
    return instance as AnyObject
}
