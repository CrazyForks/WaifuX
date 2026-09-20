//  Extension-side reader for shared preferences written by the main app.
//  以及 extension 状态写入（isActive），供 App 读取。
//
//  线程安全 via OSAllocatedUnfairLock。监听 Darwin 通知以在 App 写入新值时重新加载。
//
//  参考 Phosphene (MIT) 的实现。

import Foundation
import os

final class WallpaperPrefs: @unchecked Sendable {
    static let shared = WallpaperPrefs()

    private struct PrefsFile: Codable, Equatable {
        var userPaused: Bool = false
        var alwaysPauseDesktop: Bool = true
        var pauseWhenOccluded: Bool = false
        var desktopOccluded: Bool = false
        var pausedDisplayIDs: Set<UInt32>?
        var mutedDisplayIDs: Set<UInt32>?
    }

    private struct ContextState: Codable {
        var displayID: UInt32
        var videoID: String?
        var videoName: String?
    }

    /// 扩展 → 宿主的状态文件。pid/updatedAt/lastError 是心跳字段：
    /// 宿主读到 isActive=true 但 pid 已死时可立即清理残留，不必等 20s 复核。
    /// 新字段全部 optional，旧宿主/旧扩展双向兼容。
    private struct StateFile: Codable {
        var isActive: Bool
        var currentVideoID: String?
        var currentVideoName: String?
        var contexts: [ContextState]?
        var pid: Int32? = nil
        var updatedAt: TimeInterval? = nil
        var lastError: String? = nil
    }

    private let lock = OSAllocatedUnfairLock(initialState: PrefsFile())
    /// App 退出后扩展继续存活时，临时解除“仅锁屏播放”限制。
    /// 这是进程内状态，不写回共享 prefs；App 下次启动并刷新 prefs 后自动清除。
    private let appHostTerminatedLock = OSAllocatedUnfairLock(initialState: false)

    private static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app")
    }

    private static var prefsURL: URL? {
        sharedContainerURL?.appendingPathComponent("waifux-wallpaper-prefs.json")
    }

    private static var stateURL: URL? {
        sharedContainerURL?.appendingPathComponent("waifux-wallpaper-state.json")
    }

    private init() { reload() }

    // MARK: - Public (Prefs — app → extension)

    var userPaused: Bool { lock.withLock { $0.userPaused } }
    var alwaysPauseDesktop: Bool { lock.withLock { $0.alwaysPauseDesktop } }
    var effectiveAlwaysPauseDesktop: Bool {
        guard !appHostTerminatedLock.withLock({ $0 }) else { return false }
        return alwaysPauseDesktop
    }
    var isAppHostTerminated: Bool {
        appHostTerminatedLock.withLock { $0 }
    }
    var pauseWhenOccluded: Bool { lock.withLock { $0.pauseWhenOccluded } }
    var desktopOccluded: Bool { lock.withLock { $0.desktopOccluded } }

    var pausedDisplayIDs: Set<UInt32> {
        lock.withLock { $0.pausedDisplayIDs ?? [] }
    }

    /// 指定 displayID 是否应暂停
    func isDisplayPaused(_ displayID: UInt32) -> Bool {
        lock.withLock { $0.pausedDisplayIDs?.contains(displayID) ?? false }
    }

    /// 指定 displayID 是否应静音
    func isDisplayMuted(_ displayID: UInt32) -> Bool {
        lock.withLock { $0.mutedDisplayIDs?.contains(displayID) ?? false }
    }

    // MARK: - Public (State — extension → app)

    /// 扩展获得或失去活跃壁纸上下文时调用
    func setActive(_ active: Bool) {
        let videoID = active ? WallpaperState.shared.currentVideoID : nil
        let contexts = active ? buildContextStates() : nil
        writeState(StateFile(isActive: active, currentVideoID: videoID, currentVideoName: nil, contexts: contexts))
        extLog("[WallpaperPrefs] setActive(\(active), video: \(videoID ?? "nil"))")
    }

    /// 活动壁纸变化时调用（扩展已激活状态）
    func updateCurrentVideo() {
        let videoID = WallpaperState.shared.currentVideoID
        let contexts = buildContextStates()
        writeState(StateFile(isActive: true, currentVideoID: videoID, currentVideoName: nil, contexts: contexts))
        extLog("[WallpaperPrefs] updateCurrentVideo(\(videoID ?? "nil"))")
    }

    /// 渲染/切换失败时附加 lastError 写入 state；宿主读到后落日志。
    /// 正常路径的 setActive/updateCurrentVideo 会覆盖清空旧错误。
    func reportError(_ message: String) {
        let active = WallpaperState.shared.activeContextCount > 0
        let videoID = active ? WallpaperState.shared.currentVideoID : nil
        let contexts = active ? buildContextStates() : nil
        writeState(StateFile(isActive: active, currentVideoID: videoID, currentVideoName: nil, contexts: contexts,
                             lastError: message))
        extLog("[WallpaperPrefs] reportError(\(message))")
    }

    private func writeState(_ state: StateFile) {
        var stamped = state
        stamped.pid = ProcessInfo.processInfo.processIdentifier
        stamped.updatedAt = Date().timeIntervalSince1970
        guard let data = try? JSONEncoder().encode(stamped),
              let url = Self.stateURL else { return }
        try? data.write(to: url, options: .atomic)
        postStateNotification()
    }

    private func buildContextStates() -> [ContextState] {
        WallpaperState.shared.activeDisplayContexts().map { ctx in
            ContextState(displayID: ctx.displayID, videoID: ctx.videoID, videoName: nil)
        }
    }

    // MARK: - I/O

    func reload() {
        guard let url = Self.prefsURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PrefsFile.self, from: data) else { return }
        // 内容未变时跳过 applyPauseState：宿主侧库变化与 prefs 变化共用同一个
        // Darwin 通知，无差别重算会给所有渲染器来一次策略抖动（可能触发速率 ramp）。
        let changed = lock.withLock { state -> Bool in
            guard state != decoded else { return false }
            state = decoded
            return true
        }
        guard changed else { return }
        applyPauseState()
    }

    /// 更新宿主 App 存活状态。返回值表示状态是否发生变化。
    @discardableResult
    func setAppHostRunning(_ isRunning: Bool) -> Bool {
        let terminated = !isRunning
        return appHostTerminatedLock.withLock { current in
            guard current != terminated else { return false }
            current = terminated
            return true
        }
    }

    /// 标记宿主 App 已退出。扩展保留当前上下文，并由调用方重新计算播放策略。
    func markAppHostTerminated() {
        setAppHostRunning(false)
    }

    // MARK: - Darwin Observer

    private var isObservingChanges = false

    func observeChanges() {
        guard !isObservingChanges else { return }
        isObservingChanges = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                WallpaperPrefs.shared.reload()
            },
            "com.waifux.app.wallpaper.prefsChanged" as CFString,
            nil,
            .deliverImmediately
        )
    }

    private var previousDesktopOccluded = false

    /// 重新计算播放策略并应用到所有活跃渲染器
    private func applyPauseState() {
        let state = WallpaperState.shared
        let occlusionChanged = desktopOccluded != previousDesktopOccluded
        previousDesktopOccluded = desktopOccluded
        let animated = occlusionChanged && pauseWhenOccluded

        let power = PowerMonitor.shared.currentState
        let displayIDs = state.uniqueDisplayIDs()
        let currentPausedDisplays = pausedDisplayIDs
        let effectiveMode = isAppHostTerminated
            && !state.isScreenLocked
            && !state.isDisplayAsleep
            ? "active"
            : state.presentationMode
        let effectiveActivity = isAppHostTerminated
            && !state.isScreenLocked
            && !state.isDisplayAsleep
            ? "active"
            : state.activityState

        if displayIDs.isEmpty {
            let policy = PlaybackPolicy.compute(
                presentationMode: effectiveMode,
                activityState: effectiveActivity,
                userPaused: userPaused,
                alwaysPauseDesktop: effectiveAlwaysPauseDesktop,
                pauseWhenOccluded: pauseWhenOccluded,
                desktopOccluded: desktopOccluded,
                powerState: power
            )
            state.forEachRenderer { renderer in
                renderer.applyPolicy(policy, animated: animated)
            }
        } else {
            for displayID in displayIDs {
                let isDisplayPaused = currentPausedDisplays.contains(displayID)
                let policy = PlaybackPolicy.compute(
                    presentationMode: effectiveMode,
                    activityState: effectiveActivity,
                    userPaused: userPaused || isDisplayPaused,
                    alwaysPauseDesktop: effectiveAlwaysPauseDesktop,
                    pauseWhenOccluded: pauseWhenOccluded,
                    desktopOccluded: desktopOccluded,
                    powerState: power
                )
                state.forRenderers(displayID: displayID) { renderer in
                    renderer.applyPolicy(policy, animated: animated)
                }
            }
        }
    }

    private func postStateNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.waifux.app.wallpaper.stateChanged" as CFString),
            nil, nil, true
        )
    }
}
