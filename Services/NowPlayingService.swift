import Foundation
import AppKit
import Combine
import Darwin

// MARK: - System Now Playing (MediaRemote)
//
// Host 侧读取 macOS「正在播放」：title / artist / album / artwork / progress。
// 不涉及 Apple Music token；Web 壁纸只通过 bridge 收推送。
//
// 通过 dlopen 私有 MediaRemote.framework，避免硬链接私有符号。

/// 系统当前媒体快照（给 Web Media Integration 用）
public struct NowPlayingSnapshot: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var isPlaying: Bool
    public var elapsed: Double
    public var duration: Double
    public var rate: Double
    /// 原始封面字节（JPEG/PNG 等）
    public var artworkData: Data?
    /// 封面内容 hash，用于避免重复推送
    public var artworkHash: Int

    public var hasMedia: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static let empty = NowPlayingSnapshot(
        title: "",
        artist: "",
        album: "",
        isPlaying: false,
        elapsed: 0,
        duration: 0,
        rate: 1,
        artworkData: nil,
        artworkHash: 0
    )
}

@MainActor
public final class NowPlayingService: ObservableObject {

    public static let shared = NowPlayingService()

    @Published public private(set) var snapshot: NowPlayingSnapshot = .empty

    /// 带本地外推的播放进度（秒）
    public var estimatedElapsed: Double {
        guard snapshot.hasMedia else { return 0 }
        guard snapshot.isPlaying, anchorPlaying else { return max(0, anchorBase) }
        let dt = Date().timeIntervalSince(anchorAt) * max(0, anchorRate)
        let value = anchorBase + dt
        if snapshot.duration > 0 {
            return min(max(0, value), snapshot.duration)
        }
        return max(0, value)
    }

    private var referenceCount = 0
    private var pollTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var mediaRemoteAvailable = false
    private var mediaRemoteHandle: UnsafeMutableRawPointer?

    // Elapsed anchor：系统推送稀疏时本地外推
    private var anchorBase: Double = 0
    private var anchorAt: Date = .distantPast
    private var anchorPlaying = false
    private var anchorRate: Double = 1

    private var lastInfoIdentity: String = ""

    // 已解析的 CFString 常量（字典 key / 通知名）
    private var keyTitle: String = "kMRMediaRemoteNowPlayingInfoTitle"
    private var keyArtist: String = "kMRMediaRemoteNowPlayingInfoArtist"
    private var keyAlbum: String = "kMRMediaRemoteNowPlayingInfoAlbum"
    private var keyDuration: String = "kMRMediaRemoteNowPlayingInfoDuration"
    private var keyElapsed: String = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    private var keyRate: String = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    private var keyArtwork: String = "kMRMediaRemoteNowPlayingInfoArtworkData"
    private var notifInfoChanged: String = "kMRMediaRemoteNowPlayingInfoDidChangeNotification"
    private var notifPlayingChanged: String = "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
    private var notifAppChanged: String = "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"

    // MediaRemote function pointers（C + ObjC block ABI）
    private var registerForNotifications: (@convention(c) (DispatchQueue) -> Void)?
    private var getNowPlayingInfo: (@convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void)?
    private var getIsPlaying: (@convention(c) (DispatchQueue, @escaping @convention(block) (UInt8) -> Void) -> Void)?

    private init() {
        mediaRemoteAvailable = loadMediaRemote()
    }

    // MARK: - Lifecycle (ref-counted)

    public func start() {
        referenceCount += 1
        guard referenceCount == 1 else { return }
        guard mediaRemoteAvailable else {
            print("[NowPlayingService] MediaRemote unavailable — media integration idle")
            return
        }
        registerNotifications()
        startPolling()
        refresh()
    }

    public func stop() {
        guard referenceCount > 0 else { return }
        referenceCount -= 1
        guard referenceCount == 0 else { return }
        stopPolling()
        unregisterNotifications()
        apply(.empty)
    }

    /// 主动拉一次（换壁纸后立即同步）
    public func refresh() {
        guard mediaRemoteAvailable else { return }
        fetchNowPlaying()
    }

    // MARK: - MediaRemote load

    private func loadMediaRemote() -> Bool {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            print("[NowPlayingService] dlopen MediaRemote failed")
            return false
        }
        mediaRemoteHandle = handle

        typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
        typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
        typealias GetPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (UInt8) -> Void) -> Void

        guard
            let regSym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications"),
            let infoSym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo"),
            let playSym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying")
        else {
            print("[NowPlayingService] dlsym MediaRemote symbols failed")
            return false
        }

        registerForNotifications = unsafeBitCast(regSym, to: RegisterFn.self)
        getNowPlayingInfo = unsafeBitCast(infoSym, to: GetInfoFn.self)
        getIsPlaying = unsafeBitCast(playSym, to: GetPlayingFn.self)

        // 解析 CFString 常量真实值（字典 key / 通知名）
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoTitle") { keyTitle = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoArtist") { keyArtist = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoAlbum") { keyAlbum = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoDuration") { keyDuration = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoElapsedTime") { keyElapsed = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoPlaybackRate") { keyRate = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoArtworkData") { keyArtwork = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingInfoDidChangeNotification") { notifInfoChanged = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification") { notifPlayingChanged = s }
        if let s = Self.cfStringConstant(handle, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification") { notifAppChanged = s }

        print("[NowPlayingService] MediaRemote loaded keys title=\(keyTitle)")
        return true
    }

    /// 读取导出的 `CFStringRef` 全局常量
    private static func cfStringConstant(_ handle: UnsafeMutableRawPointer, _ symbol: String) -> String? {
        guard let sym = dlsym(handle, symbol) else { return nil }
        // 全局变量地址 → CFStringRef 值
        let cf = sym.assumingMemoryBound(to: CFString?.self).pointee
        guard let cf else { return nil }
        return cf as String
    }

    private func registerNotifications() {
        registerForNotifications?(DispatchQueue.main)

        let names = [notifInfoChanged, notifPlayingChanged, notifAppChanged]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.fetchNowPlaying()
                }
            }
            notificationTokens.append(token)
        }
    }

    private func unregisterNotifications() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func startPolling() {
        stopPolling()
        // 通知偶发丢失时兜底；1s 足够媒体元数据
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchNowPlaying()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Fetch

    private func fetchNowPlaying() {
        guard let getInfo = getNowPlayingInfo else { return }
        let getPlaying = getIsPlaying

        getInfo(DispatchQueue.main) { [weak self] info in
            Task { @MainActor in
                guard let self else { return }
                if let getPlaying {
                    getPlaying(DispatchQueue.main) { flag in
                        Task { @MainActor in
                            self.consume(info: info, isPlaying: flag != 0)
                        }
                    }
                } else {
                    self.consume(info: info, isPlaying: nil)
                }
            }
        }
    }

    private func consume(info: NSDictionary?, isPlaying: Bool?) {
        guard let info, info.count > 0 else {
            apply(.empty)
            return
        }

        func string(_ keys: [String]) -> String {
            for k in keys {
                if let s = info[k] as? String, !s.isEmpty { return s }
            }
            return ""
        }
        func number(_ keys: [String]) -> Double? {
            for k in keys {
                if let n = info[k] as? NSNumber { return n.doubleValue }
                if let d = info[k] as? Double { return d }
                if let f = info[k] as? Float { return Double(f) }
            }
            return nil
        }

        // 优先用框架常量解析出的 key，并兼容短名
        let title = string([keyTitle, "kMRMediaRemoteNowPlayingInfoTitle", "title", "Title"])
        let artist = string([keyArtist, "kMRMediaRemoteNowPlayingInfoArtist", "artist", "Artist"])
        let album = string([keyAlbum, "kMRMediaRemoteNowPlayingInfoAlbum", "album", "Album"])

        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            apply(.empty)
            return
        }

        let duration = number([keyDuration, "kMRMediaRemoteNowPlayingInfoDuration", "duration", "Duration"]) ?? 0
        let elapsed = number([keyElapsed, "kMRMediaRemoteNowPlayingInfoElapsedTime", "elapsedTime", "ElapsedTime"]) ?? 0
        let rate = number([keyRate, "kMRMediaRemoteNowPlayingInfoPlaybackRate", "playbackRate", "PlaybackRate"]) ?? 1

        var artwork: Data?
        if let data = info[keyArtwork] as? Data {
            artwork = data
        } else if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
            artwork = data
        } else if let data = info["artworkData"] as? Data {
            artwork = data
        }

        let playing: Bool
        if let isPlaying {
            playing = isPlaying
        } else {
            playing = rate > 0.01
        }

        let artHash = artwork.map { $0.hashValue } ?? 0
        let next = NowPlayingSnapshot(
            title: title,
            artist: artist,
            album: album,
            isPlaying: playing,
            elapsed: max(0, elapsed),
            duration: max(0, duration),
            rate: rate > 0 ? rate : 1,
            artworkData: artwork,
            artworkHash: artHash
        )
        apply(next)
    }

    private func apply(_ next: NowPlayingSnapshot) {
        let identity = "\(next.title)|\(next.artist)|\(next.album)|\(next.isPlaying)|\(next.artworkHash)|\(String(format: "%.1f", next.elapsed))|\(String(format: "%.1f", next.duration))"
        noteElapsed(from: next)
        if identity != lastInfoIdentity
            || snapshot.title != next.title
            || snapshot.artist != next.artist
            || snapshot.isPlaying != next.isPlaying
            || snapshot.artworkHash != next.artworkHash {
            lastInfoIdentity = identity
            snapshot = next
        } else if abs(snapshot.elapsed - next.elapsed) > 0.05 || abs(snapshot.duration - next.duration) > 0.05 {
            var copy = snapshot
            copy.elapsed = next.elapsed
            copy.duration = next.duration
            copy.rate = next.rate
            copy.isPlaying = next.isPlaying
            snapshot = copy
        }
    }

    private func noteElapsed(from track: NowPlayingSnapshot) {
        let base = max(0, track.elapsed)
        let rate = max(0, track.rate)
        let playing = track.isPlaying
        if abs(base - anchorBase) > 0.35 || playing != anchorPlaying || abs(rate - anchorRate) > 0.01 {
            anchorBase = base
            anchorAt = Date()
            anchorPlaying = playing
            anchorRate = rate > 0 ? rate : 1
        }
    }
}

// MARK: - Thumbnail helpers

public enum NowPlayingThumbnail {
    /// 将封面压成 JPEG data URL，限制长边，避免 IPC/evaluateJS 过大
    public static func jpegDataURL(from data: Data, maxEdge: CGFloat = 320, quality: CGFloat = 0.72) -> String? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = NSSize(
            width: max(1, floor(size.width * scale)),
            height: max(1, floor(size.height * scale))
        )

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            return nil
        }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}
