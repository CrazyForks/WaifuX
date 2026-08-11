import Foundation
import AppKit

/// 桌面壁纸跨 Space 同步管理器
///
/// macOS 的 `NSWorkspace.setDesktopImageURL` 默认只更新当前 active Space 的壁纸。
/// 即使在 options 中传入 `allSpaces: true`，已有 Spaces 仍可能不同步。
///
/// 解决思路：
/// 1. 监听 `activeSpaceDidChangeNotification`，当用户切换到另一个 Space 时，
///    自动将每个屏幕最后设置的壁纸重新应用到新的 active Space。
/// 2. 作为备用，在应用重新变为活跃时（applicationDidBecomeActive）也执行一次同步，
///    因为 `activeSpaceDidChangeNotification` 在应用后台时可能不可靠。
@MainActor
final class DesktopWallpaperSyncManager {
    static let shared = DesktopWallpaperSyncManager()

    /// 每个屏幕最后通过 WaifuX 设置的静态壁纸 URL（key 为 screenID）
    private var lastSetImageURLByScreen: [String: URL] = [:]
    /// 每个物理显示器指纹最后设置的静态壁纸 URL，用于外接屏重连后 screenID 变化时恢复。
    private var lastSetImageURLByFingerprint: [String: URL] = [:]

    /// 每个屏幕最后设置的选项
    private var lastOptionsByScreen: [String: [NSWorkspace.DesktopImageOptionKey: Any]] = [:]
    /// 每个物理显示器指纹最后设置的选项。
    private var lastOptionsByFingerprint: [String: [NSWorkspace.DesktopImageOptionKey: Any]] = [:]
    /// WaifuX 接管前的系统壁纸快照（按物理指纹持久化）。关闭 ownership 时用于还原。
    private var originalImageURLByFingerprint: [String: URL] = [:]

    /// 记录最后一次尝试同步的时间，避免过于频繁的重复同步
    private var lastSyncTime: Date?
    private let minimumSyncInterval: TimeInterval = 0.5
    /// 用于 Space 切换的 debounce，快速连续切换时只保留最后一次
    private var pendingSyncWorkItem: DispatchWorkItem?
    private var pendingScreenChangeWorkItem: DispatchWorkItem?
    private var pendingActivationSyncWorkItem: DispatchWorkItem?
    /// 动态桌面层合成完成后，强制菜单栏外观重采样的延后任务。
    /// 按显示器指纹去抖，避免首帧/菜单栏路径的多次 WindowServer commit 连续重写。
    private var pendingPresentationRefreshWorkItems: [String: DispatchWorkItem] = [:]
    /// 菜单栏采样强制刷新的交替槽位（可选的 setDesktop 补充路径）。
    /// WallpaperAgent / Dock 对「同一 file URL 再次 setDesktopImageURL」会当 no-op。
    private var menuBarAppearanceRefreshSlot = 0
    private lazy var menuBarAppearanceRefreshDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.waifux.menubar-appearance-refresh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    /// 正在进行的菜单栏 backdrop poke 窗口（创建即销毁，不长期复用）。
    /// 用户观察：任意窗口树变化都会触发菜单栏重采样；短生命周期 NSWindow
    /// 的 map/unmap 比只 setDesktop 更接近“点一下其它 App”的触发条件。
    private var liveMenuBarBackdropPokeWindows: [NSWindow] = []
    /// 标记“应用重新激活时确实需要做一次恢复性同步”。
    /// 仅在显示器参数变化/系统唤醒等场景置为 true，避免普通前后台切换也去重写桌面壁纸。
    private var requiresActivationRecoverySync = false

    /// 持久化键：`{displayIdentity: imageURLString}` JSON。
    /// 用于外接屏断开重连（App 可能已被系统杀掉重启）后判断该屏是否曾由 App 设过壁纸。
    private static let fingerprintStateKey = "desktop_wallpaper_sync_fingerprint_state_v1"
    private static let originalFingerprintStateKey = "desktop_wallpaper_sync_original_fingerprint_state_v1"

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // 系统唤醒后同步壁纸到所有显示器（外接显示器可能延迟枚举）
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        // 恢复持久化的指纹 -> 壁纸 URL 映射，供外接屏重连后判断是否曾由 App 设过壁纸
        loadFingerprintState()
        loadOriginalFingerprintState()
        purgeLegacyRendererCaptureState()
    }

    /// 在 WaifuX 首次改写某屏系统壁纸前，记录当时的系统桌面图。
    func captureOriginalSystemWallpaperIfNeeded(for screens: [NSScreen]) {
        var changed = false
        for screen in screens {
            let fingerprint = screen.wallpaperScreenFingerprint
            guard originalImageURLByFingerprint[fingerprint] == nil,
                  let imageURL = NSWorkspace.shared.desktopImageURL(for: screen),
                  imageURL.isFileURL else {
                continue
            }
            originalImageURLByFingerprint[fingerprint] = imageURL
            changed = true
        }
        if changed {
            persistOriginalFingerprintState()
        }
    }

    /// 恢复指定显示器在 WaifuX 接管前的系统壁纸；没有可用快照时只清理 WaifuX 的同步记录。
    func restoreOriginalSystemWallpaper(for screen: NSScreen) {
        let fingerprint = screen.wallpaperScreenFingerprint
        defer {
            originalImageURLByFingerprint.removeValue(forKey: fingerprint)
            clearRegistration(for: screen)
            persistOriginalFingerprintState()
        }

        guard let imageURL = originalImageURLByFingerprint[fingerprint],
              FileManager.default.fileExists(atPath: imageURL.path) else {
            return
        }

        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true
        ]
        do {
            try NSWorkspace.shared.setDesktopImageURLForAllSpaces(imageURL, for: screen, options: fillOptions)
        } catch {
            AppLogger.error(.wallpaper, "Failed to restore original system wallpaper", metadata: [
                "screen": screen.localizedName,
                "error": error.localizedDescription
            ])
        }
    }

    private func persistOriginalFingerprintState() {
        let state = originalImageURLByFingerprint.mapValues(\.absoluteString)
        if state.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.originalFingerprintStateKey)
        } else if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.originalFingerprintStateKey)
        }
    }

    private func loadOriginalFingerprintState() {
        guard let data = UserDefaults.standard.data(forKey: Self.originalFingerprintStateKey),
              let state = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        originalImageURLByFingerprint = state.reduce(into: [:]) { result, entry in
            guard let url = URL(string: entry.value), url.isFileURL else { return }
            result[entry.key] = url
        }
    }

    /// 注册一次静态壁纸设置，后续 Space 切换时会自动同步
    /// - Parameters:
    ///   - url: 壁纸图片 URL
    ///   - screen: 目标屏幕；nil 表示注册到所有当前屏幕
    ///   - options: 设置选项
    func registerWallpaperSet(_ url: URL, for screen: NSScreen? = nil, options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]) {
        // 系统壁纸同步关闭时禁止注册，防止后续 Space 切换时绕开关闭状态重新写入系统壁纸。
        guard VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled else {
            print("[DesktopWallpaperSyncManager] 🧊 系统壁纸同步已关闭，跳过注册")
            return
        }
        if #available(macOS 26.0, *),
           VideoWallpaperManager.shared.isLockScreenEnabled {
            print("[DesktopWallpaperSyncManager] 🔒 动态锁屏已启用，跳过静态桌面壁纸注册")
            return
        }

        let targetScreens: [NSScreen]
        if let screen = screen {
            targetScreens = [screen]
        } else {
            targetScreens = NSScreen.screens
        }

        for targetScreen in targetScreens {
            let screenID = targetScreen.wallpaperScreenIdentifier
            let fingerprint = targetScreen.wallpaperScreenFingerprint
            lastSetImageURLByScreen[screenID] = url
            lastSetImageURLByFingerprint[fingerprint] = url
            lastOptionsByScreen[screenID] = options
            lastOptionsByFingerprint[fingerprint] = options
        }
        persistFingerprintState()
    }

    /// 动态壁纸窗口已提交到 WindowServer 后，强制菜单栏外观重新采样。
    ///
    /// ## 底层机制
    /// 菜单栏毛玻璃 / 图标深浅由 Dock 的 `CABackdropLayer` + `IconAppearance` 驱动。
    /// 用户实测：**任意窗口树变化**（orderFront / orderOut / 切 App）都会触发重采样；
    /// 只靠 `setDesktopImageURL` 或 `com.apple.desktop` 在动态层盖住桌面时经常不生效
    /// （WallpaperAgent 对同一路径 no-op，或 backdrop 缓存未失效）。
    ///
    /// ## 策略（按可靠度）
    /// 1. **主路径**：App 活跃时在菜单栏条带创建短生命周期透明 NSWindow（真实 create → map → unmap → destroy），
    ///    模拟用户观察到的“任意窗口变化就刷新”（不抢焦点、不可见、不接鼠标）。
    ///    App 在后台时降级为 `com.apple.desktop` 分布式通知——macOS 27 beta 在后台 App
    ///    `orderFrontRegardless()` 路径会让 ViewBridge 的 `NSRemoteView
    ///    containingWindowWillOrderOnScreen:` 抛出不可恢复 ObjC 异常（SIGSEGV）。
    /// 2. **补充**：若已登记系统背板且允许写桌面，再把 poster 复制到交替路径 set 一次
    ///    （帮 WallpaperAgent 认“新图”，改善锁屏/Space 侧一致性）。
    /// 3. 动态锁屏 / 关系统壁纸同步时仍执行 (1)，不写桌面。
    func scheduleSystemWallpaperRefreshAfterDynamicPresentation(
        on screens: [NSScreen],
        delay: TimeInterval = 0.12
    ) {
        guard !screens.isEmpty else { return }

        // 按物理屏指纹去重；多路 reveal/forceCommit 会短时间连打。
        var uniqueByFingerprint: [String: NSScreen] = [:]
        for screen in screens {
            uniqueByFingerprint[screen.wallpaperScreenFingerprint] = screen
        }

        for (fingerprint, screen) in uniqueByFingerprint {
            let screenID = screen.wallpaperScreenIdentifier

            pendingPresentationRefreshWorkItems[fingerprint]?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                defer { self.pendingPresentationRefreshWorkItems.removeValue(forKey: fingerprint) }

                guard let currentScreen = NSScreen.screens.first(where: {
                    $0.wallpaperScreenIdentifier == screenID
                        || $0.wallpaperScreenFingerprint == fingerprint
                }) else {
                    return
                }

                // 1) 窗口树 poke：与“点一下其它 App”同类触发，不依赖焦点切换。
                //    App 后台时内部降级为系统通知，避免 macOS 27 ViewBridge 崩溃。
                self.pokeMenuBarBackdropResample(on: currentScreen)

                // 2) 可选：换路径重提系统背板（仅在允许写桌面时）。
                let canRewriteDesktop = VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled
                    && {
                        if #available(macOS 26.0, *) {
                            return !VideoWallpaperManager.shared.isLockScreenEnabled
                        }
                        return true
                    }()
                if canRewriteDesktop,
                   let registeredURL = self.lastSetImageURLByScreen[currentScreen.wallpaperScreenIdentifier]
                    ?? self.lastSetImageURLByFingerprint[currentScreen.wallpaperScreenFingerprint],
                   FileManager.default.fileExists(atPath: registeredURL.path) {
                    let currentOptions = self.lastOptionsByScreen[currentScreen.wallpaperScreenIdentifier]
                        ?? self.lastOptionsByFingerprint[currentScreen.wallpaperScreenFingerprint]
                        ?? [:]
                    do {
                        let refreshURL = try self.makeMenuBarAppearanceRefreshURL(from: registeredURL)
                        try NSWorkspace.shared.setDesktopImageURLForAllSpaces(
                            refreshURL,
                            for: currentScreen,
                            options: currentOptions
                        )
                        self.registerWallpaperSet(
                            refreshURL,
                            for: currentScreen,
                            options: currentOptions
                        )
                    } catch {
                        self.requestSystemDesktopAppearanceResample()
                    }
                    // setDesktop 后再 poke 一次：backdrop 可能刚缓存完旧帧。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                        self?.pokeMenuBarBackdropResample(on: currentScreen)
                    }
                }

                AppLogger.debug(.wallpaper, "Menu-bar appearance poke after dynamic presentation", metadata: [
                    "screen": currentScreen.localizedName,
                    "desktopRewrite": canRewriteDesktop
                ])
            }
            pendingPresentationRefreshWorkItems[fingerprint] = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    /// 用短生命周期透明窗口制造一次完整窗口树变化，迫使菜单栏 CABackdrop / IconAppearance 重采样。
    ///
    /// 用户实测“任意窗口变化就会刷新”；1pt / 极低 alpha 的复用窗常被 WindowServer 优化掉。
    /// 这里改为：覆盖整条菜单栏条带、alpha=1 但内容透明、停留约 2 帧再 orderOut + close。
    /// 不 makeKey、不激活 App、不接鼠标；用户不可见。
    ///
    /// ## 后台降级（macOS 27 beta 崩溃修复）
    /// App 在后台（`NSApp.isActive == false`）时调用 `orderFrontRegardless()` 会让
    /// ViewBridge 的 `NSRemoteView containingWindowWillOrderOnScreen:` 抛出不可恢复的
    /// ObjC 异常，最终 SIGSEGV（见 crash report：Role=Background，Thread 0 Crashed）。
    /// 后台时降级为 `com.apple.desktop` 分布式通知，不创建任何 NSWindow。
    private func pokeMenuBarBackdropResample(on screen: NSScreen) {
        guard NSApp.isActive else {
            requestSystemDesktopAppearanceResample()
            return
        }

        let barHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        // 与 NotchOverlay 一致：盖住菜单栏区域 + 向下 1pt，确保 backdrop 采样矩形相交。
        let pokeFrame = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - barHeight - 1,
            width: max(1, screen.frame.width),
            height: barHeight + 1
        )

        let window = NSWindow(
            contentRect: pokeFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        // 高于 desktop 壁纸，低于普通 UI / 状态栏；保证合入菜单栏 backdrop 的采样层。
        // statusWindow-1 比 desktop+1 更接近“普通窗口进出”的合成路径，但仍不抢焦点。
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        window.level = .init(rawValue: max(statusLevel - 1, Int(CGWindowLevelForKey(.desktopWindow)) + 2))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.animationBehavior = .none
        window.hidesOnDeactivate = false
        window.alphaValue = 1

        let view = NSView(frame: NSRect(origin: .zero, size: pokeFrame.size))
        view.wantsLayer = true
        // 完全透明但仍参与合成（有 layer surface），比 alpha=0.01 的 1pt 窗更难被优化掉。
        view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = view
        window.setFrame(pokeFrame, display: false)

        liveMenuBarBackdropPokeWindows.append(window)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 不要 orderBack：那会把它塞回桌面底，菜单栏 backdrop 可能采不到。
        window.orderFrontRegardless()
        window.displayIfNeeded()
        CATransaction.commit()
        CATransaction.flush()
        CFRunLoopWakeUp(CFRunLoopGetMain())

        // 保持约 2 帧（~33ms@60Hz）再 unmap，给 WindowServer 时间把窗口纳入合成并触发 IconAppearance。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self, weak window] in
            guard let self, let window else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            window.orderOut(nil)
            CATransaction.commit()
            CATransaction.flush()

            // 再 pulse 一次：部分系统要连续两次 map/unmap 才重算。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak window] in
                guard let self, let window else { return }
                // App 在两次 pulse 之间失焦时跳过二次上屏：后台 orderFrontRegardless 会触发
                // macOS 27 ViewBridge 崩溃。直接走清理路径销毁窗口即可。
                guard NSApp.isActive else {
                    self.tearDownPokeWindow(window)
                    return
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                window.orderFrontRegardless()
                window.displayIfNeeded()
                CATransaction.commit()
                CATransaction.flush()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.tearDownPokeWindow(window)
                }
            }
        }
    }

    /// 销毁一个 poke 窗口：orderOut + close + 清引用。
    /// `orderOut` 不会触发 `containingWindowWillOrderOnScreen:`，后台调用安全。
    private func tearDownPokeWindow(_ window: NSWindow) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        CATransaction.commit()
        CATransaction.flush()
        liveMenuBarBackdropPokeWindows.removeAll { $0 === window }
    }

    /// Request a desktop refresh without creating or ordering an AppKit window.
    private func requestSystemDesktopAppearanceResample() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.desktop"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// 给主进程内视频回退路径使用的菜单栏 poke 入口。
    /// 内部仍保留 macOS 27 防护：App 后台时只发系统通知，不创建/排序 NSWindow。
    func requestMenuBarBackdropResamplePoke(on screens: [NSScreen]) {
        for screen in screens {
            pokeMenuBarBackdropResample(on: screen)
        }
    }

    /// 把当前系统背板复制到交替缓存路径，迫使 WallpaperAgent 重新加载。
    private func makeMenuBarAppearanceRefreshURL(from sourceURL: URL) throws -> URL {
        menuBarAppearanceRefreshSlot = 1 - menuBarAppearanceRefreshSlot
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        // 若源已是 refresh 副本（mb_s0_xxx_stamp），剥掉前缀避免文件名无限嵌套。
        var baseName = sourceURL.deletingPathExtension().lastPathComponent
        if baseName.hasPrefix("mb_s0_") || baseName.hasPrefix("mb_s1_") {
            let stripped = String(baseName.dropFirst(6))
            if let lastUnderscore = stripped.lastIndex(of: "_"),
               stripped[stripped.index(after: lastUnderscore)...].allSatisfy(\.isNumber) {
                baseName = String(stripped[..<lastUnderscore])
            } else {
                baseName = stripped
            }
        }
        let stamp = Int(Date().timeIntervalSince1970 * 1000) % 1_000_000
        let dest = menuBarAppearanceRefreshDirectory
            .appendingPathComponent("mb_s\(menuBarAppearanceRefreshSlot)_\(baseName)_\(stamp).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        cleanupMenuBarAppearanceRefreshFiles(keeping: dest)
        return dest
    }

    private func cleanupMenuBarAppearanceRefreshFiles(keeping keepURL: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: menuBarAppearanceRefreshDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        let sorted = files
            .filter { $0.lastPathComponent.hasPrefix("mb_s") }
            .compactMap { url -> (URL, Date)? in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in sorted.dropFirst(6) where url != keepURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 返回指定屏幕最后通过 App 设置的静态壁纸 URL（无记录时返回 nil）
    func imageURL(for screen: NSScreen) -> URL? {
        let screenID = screen.wallpaperScreenIdentifier
        let fingerprint = screen.wallpaperScreenFingerprint
        return lastSetImageURLByScreen[screenID] ?? lastSetImageURLByFingerprint[fingerprint]
    }

    /// 清除静态壁纸注册（例如用户手动在系统设置里改了壁纸）
    /// - Parameter screen: 目标屏幕；nil 表示清除所有屏幕
    func clearRegistration(for screen: NSScreen? = nil) {
        if let screen = screen {
            let screenID = screen.wallpaperScreenIdentifier
            let fingerprint = screen.wallpaperScreenFingerprint
            lastSetImageURLByScreen.removeValue(forKey: screenID)
            lastSetImageURLByFingerprint.removeValue(forKey: fingerprint)
            lastOptionsByScreen.removeValue(forKey: screenID)
            lastOptionsByFingerprint.removeValue(forKey: fingerprint)
        } else {
            lastSetImageURLByScreen.removeAll()
            lastSetImageURLByFingerprint.removeAll()
            lastOptionsByScreen.removeAll()
            lastOptionsByFingerprint.removeAll()
        }
        persistFingerprintState()
    }

    func clearRegistration(screenID: String, fingerprint: String) {
        lastSetImageURLByScreen.removeValue(forKey: screenID)
        lastSetImageURLByFingerprint.removeValue(forKey: fingerprint)
        lastOptionsByScreen.removeValue(forKey: screenID)
        lastOptionsByFingerprint.removeValue(forKey: fingerprint)
        persistFingerprintState()
    }

    /// 应用变为活跃时的备用同步入口（处理 activeSpaceDidChangeNotification 丢失的情况）
    func syncOnAppActivation() {
        let screenCount = NSScreen.screens.count
        if screenCount <= 1, !requiresActivationRecoverySync {
            AppLogger.debug(.ui, "Desktop wallpaper activation sync skipped", metadata: [
                "reason": "singleDisplayNoRecoveryNeeded",
                "screenCount": screenCount
            ])
            return
        }

        pendingActivationSyncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.performSync(source: "appActivation")
            self.requiresActivationRecoverySync = false
        }
        pendingActivationSyncWorkItem = workItem
        // 激活应用的首帧优先给 UI；桌面跨 Space 同步延后一拍，避免把窗口唤醒卡在主线程上。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    @objc private func handleActiveSpaceChanged() {
        // Debounce：快速连续切换 Space 时，取消之前的延迟任务，只保留最后一次
        pendingSyncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performSync(source: "spaceChange")
        }
        pendingSyncWorkItem = workItem
        // 延迟再同步，确保 Space 切换动画完全结束、系统桌面状态稳定后再执行
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    @objc private func handleScreenParametersChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.requiresActivationRecoverySync = true
            // 防抖：延迟 0.5s 执行
            self.pendingScreenChangeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.relinkScreenStateForCurrentDisplays()
                // 显示器变化后立即同步壁纸，确保新接入/重新枚举的显示器立即获得正确的壁纸
                self.performSync(source: "screenChange")
            }
            self.pendingScreenChangeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }

    @objc private func handleSystemDidWake() {
        // 系统唤醒后延迟同步，给 macOS 时间重新枚举所有显示器
        // 注意：不 cancel pendingScreenChangeWorkItem（那是 screenParametersChanged 的专用 work item），
        // 避免 screenParametersChanged 在唤醒期间触发时把唤醒重建任务连带后续二次重试一起 cancel 掉。
        // performSync 内部有 0.5s 防抖，重复同步会被自动跳过。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.requiresActivationRecoverySync = true
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.relinkScreenStateForCurrentDisplays()
                self.performSync(source: "systemWake")
                // 二次延迟同步：外接显示器可能 1~2 秒后才被 macOS 完全枚举
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    self.relinkScreenStateForCurrentDisplays()
                    self.performSync(source: "systemWakeRetry")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }
    }

    @objc private func handleScreensDidWake() {
        // 屏幕唤醒后延迟同步（不 cancel pendingScreenChangeWorkItem，理由同上）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.requiresActivationRecoverySync = true
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.relinkScreenStateForCurrentDisplays()
                self.performSync(source: "screensWake")
                // 二次延迟同步：应对显示器延迟枚举
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    self.relinkScreenStateForCurrentDisplays()
                    self.performSync(source: "screensWakeRetry")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }
    }

    private func relinkScreenStateForCurrentDisplays() {
        let currentScreenIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))

        // 清掉已断屏的 screenID 键；fingerprint 级注册保留，供重插 / Space 同步
        let orphanScreenIDs = Set(lastSetImageURLByScreen.keys)
            .union(lastOptionsByScreen.keys)
            .subtracting(currentScreenIDs)
        for screenID in orphanScreenIDs {
            lastSetImageURLByScreen.removeValue(forKey: screenID)
            lastOptionsByScreen.removeValue(forKey: screenID)
        }
        if !orphanScreenIDs.isEmpty {
            print("[DesktopWallpaperSyncManager] Dropped \(orphanScreenIDs.count) orphaned screenID registration(s) after disconnect")
        }

        var relinkedCount = 0
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            let fingerprint = screen.wallpaperScreenFingerprint

            if lastSetImageURLByScreen[screenID] == nil,
               let url = lastSetImageURLByFingerprint[fingerprint] {
                lastSetImageURLByScreen[screenID] = url
                relinkedCount += 1
            }
            if lastOptionsByScreen[screenID] == nil,
               let options = lastOptionsByFingerprint[fingerprint] {
                lastOptionsByScreen[screenID] = options
            }
        }
        if relinkedCount > 0 {
            print("[DesktopWallpaperSyncManager] Relinked wallpaper registration for \(relinkedCount) reconnected screen(s)")
        }
    }

    // MARK: - 持久化（指纹维度）

    /// 查询某块外接屏（按物理指纹）是否曾由 App 设过壁纸，用于外接屏重连时抑制"显示器接入"弹窗。
    /// 校验持久化的壁纸文件仍存在于磁盘，并跳过运行时临时 capture 路径。
    func hasPersistedWallpaperForFingerprint(_ fingerprint: String) -> Bool {
        guard let url = lastSetImageURLByFingerprint[fingerprint] else { return false }
        let path = url.path
        // 跳过 wallpaper-wgpu / wallpaperengine-cli 运行时 capture 路径，应用重启后不存在
        if path.contains("wallpaper-wgpu-capture") || path.contains("wallpaperengine-cli-capture") {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
    }

    private func persistFingerprintState() {
        let fpDict = lastSetImageURLByFingerprint.mapValues { $0.absoluteString }
        if fpDict.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.fingerprintStateKey)
        } else if let data = try? JSONSerialization.data(withJSONObject: fpDict),
                  let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: Self.fingerprintStateKey)
        }
    }

    private func loadFingerprintState() {
        guard let str = UserDefaults.standard.string(forKey: Self.fingerprintStateKey),
              let data = str.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        for (fingerprint, urlString) in dict {
            lastSetImageURLByFingerprint[fingerprint] = URL(string: urlString)
        }
        migrateLegacyFingerprintStateIfNeeded()
    }

    /// 旧版会把 scene 实时渲染窗口截图注册为系统壁纸。该来源已经移除，必须同时
    /// 清掉持久化注册，避免切换 Space 或唤醒时把历史截图重新写回桌面/锁屏。
    private func purgeLegacyRendererCaptureState() {
        let legacyDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.waifux.wallpaperengine/captured-frames", isDirectory: true)
            .standardizedFileURL
        let legacyPrefix = legacyDirectory.path.hasSuffix("/")
            ? legacyDirectory.path
            : legacyDirectory.path + "/"

        let legacyFingerprints = lastSetImageURLByFingerprint.compactMap { fingerprint, url in
            url.standardizedFileURL.path.hasPrefix(legacyPrefix) ? fingerprint : nil
        }
        for fingerprint in legacyFingerprints {
            lastSetImageURLByFingerprint.removeValue(forKey: fingerprint)
            lastOptionsByFingerprint.removeValue(forKey: fingerprint)
        }

        let legacyScreenIDs = lastSetImageURLByScreen.compactMap { screenID, url in
            url.standardizedFileURL.path.hasPrefix(legacyPrefix) ? screenID : nil
        }
        for screenID in legacyScreenIDs {
            lastSetImageURLByScreen.removeValue(forKey: screenID)
            lastOptionsByScreen.removeValue(forKey: screenID)
        }

        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("cached_frame_") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: legacyDirectory)

        if !legacyFingerprints.isEmpty || !legacyScreenIDs.isEmpty {
            persistFingerprintState()
            print("[DesktopWallpaperSyncManager] 已清除旧 scene 窗口截图壁纸注册")
        }
    }

    /// 旧版无序列号指纹无法可靠地区分同型号显示器。升级时从 macOS 当前每屏
    /// 桌面读取实际壁纸重建新版状态，不能复用旧字典中的单个 URL。
    private func migrateLegacyFingerprintStateIfNeeded() {
        let screensByLegacyFingerprint = Dictionary(grouping: NSScreen.screens, by: \.legacyWallpaperScreenFingerprint)
        var didChange = false

        for (legacyFingerprint, screens) in screensByLegacyFingerprint {
            guard lastSetImageURLByFingerprint[legacyFingerprint] != nil,
                  let firstScreen = screens.first,
                  firstScreen.wallpaperScreenFingerprint != legacyFingerprint else {
                continue
            }

            lastSetImageURLByFingerprint.removeValue(forKey: legacyFingerprint)
            didChange = true

            for screen in screens {
                guard let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else {
                    continue
                }
                lastSetImageURLByFingerprint[screen.wallpaperScreenFingerprint] = currentURL
            }
        }

        if didChange {
            persistFingerprintState()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// 执行实际同步逻辑
    private func performSync(source: String) {
        let start = Date()
        // 防抖动：避免短时间内多次同步（Space 切换通常不会连续触发）
        if let last = lastSyncTime, Date().timeIntervalSince(last) < minimumSyncInterval {
            print("[DesktopWallpaperSyncManager] Skipping sync from '\(source)' (too soon)")
            return
        }
        lastSyncTime = Date()

        let videoManager = VideoWallpaperManager.shared
        let hasStaticRegistrations = !lastSetImageURLByScreen.isEmpty || !lastSetImageURLByFingerprint.isEmpty
        let hasDynamicWallpaper = videoManager.isVideoWallpaperActive
        guard hasStaticRegistrations || hasDynamicWallpaper else {
            AppLogger.debug(.ui, "Desktop wallpaper sync skipped", metadata: [
                "source": source,
                "reason": "noRegisteredWallpaperState"
            ])
            return
        }

        let workspace = NSWorkspace.shared
        let currentScreens = NSScreen.screens
        relinkScreenStateForCurrentDisplays()
        let shouldSkipStaticDesktopWrites: Bool = {
            if #available(macOS 26.0, *) {
                return videoManager.isLockScreenEnabled
            }
            return false
        }()
        var syncWrites = 0

        // 1. 对每个当前屏幕，优先同步该屏幕自己的壁纸状态
        for screen in currentScreens {
            let screenID = screen.wallpaperScreenIdentifier
            let fingerprint = screen.wallpaperScreenFingerprint

            // 系统壁纸同步关闭时跳过本屏的同步，避免后续 Space 切换回写系统壁纸。
            guard videoManager.isSystemWallpaperSyncEnabled else {
                print("[DesktopWallpaperSyncManager] [\(source)] 🧊 系统壁纸同步已关闭，跳过同步 for screen \(screen.localizedName)")
                continue
            }

            // 如果该屏幕属于视频壁纸目标，同步其 poster（不再跳过，确保所有 Spaces 都正确）
            if videoManager.hasActiveWallpaper(on: screen),
               let posterURL = videoManager.posterURL(for: screen),
               videoManager.isVideoWallpaperActive {
                // ⚠️ 动态锁屏启用时跳过 poster 同步，避免触发 setDesktopImageURL 导致系统重置扩展选择
                if shouldSkipStaticDesktopWrites {
                    print("[DesktopWallpaperSyncManager] [\(source)] 🔒 动态锁屏已启用，跳过 poster 同步 for screen \(screen.localizedName)")
                } else {
                    do {
                        let writeStart = Date()
                        // 使用 "充满屏幕" 缩放模式，与初始设置保持一致
                        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
                            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                            .allowClipping: true
                        ]
                        try workspace.setDesktopImageURLForAllSpaces(posterURL, for: screen, options: fillOptions)
                        syncWrites += 1
                        let elapsedMS = Date().timeIntervalSince(writeStart) * 1000
                        if elapsedMS >= 250 {
                            AppLogger.warn(.ui, "Desktop wallpaper sync write was slow", metadata: [
                                "source": source,
                                "screen": screen.localizedName,
                                "kind": "videoPoster",
                                "durationMS": String(format: "%.0f", elapsedMS)
                            ])
                        }
                        print("[DesktopWallpaperSyncManager] [\(source)] Synced video poster for screen \(screen.localizedName)")
                    } catch {
                        print("[DesktopWallpaperSyncManager] [\(source)] Failed to sync poster for screen \(screen.localizedName): \(error)")
                    }
                }
                continue
            }

            // 否则同步该屏幕最后注册的静态壁纸
            guard let url = lastSetImageURLByScreen[screenID] ?? lastSetImageURLByFingerprint[fingerprint] else {
                continue
            }

            // 跳过 wallpaper-wgpu 渲染的临时 capture 路径（应用重启后不存在）
            if url.path.contains("wallpaper-wgpu-capture") || url.path.contains("wallpaperengine-cli-capture") {
                print("[DesktopWallpaperSyncManager] [\(source)] Skipping wallpaper-wgpu capture path for screen \(screen.localizedName)")
                continue
            }

            if shouldSkipStaticDesktopWrites {
                print("[DesktopWallpaperSyncManager] [\(source)] 🔒 动态锁屏已启用，跳过静态壁纸同步 for screen \(screen.localizedName)")
                continue
            }

            do {
                let writeStart = Date()
                // 使用 setDesktopImageURLForAllSpaces 确保所有 Spaces 同步，
                // 该方法内部已发送 com.apple.desktop 通知，无需额外触发
                let options = lastOptionsByScreen[screenID] ?? lastOptionsByFingerprint[fingerprint] ?? [:]
                try workspace.setDesktopImageURLForAllSpaces(url, for: screen, options: options)
                syncWrites += 1
                let elapsedMS = Date().timeIntervalSince(writeStart) * 1000
                if elapsedMS >= 250 {
                    AppLogger.warn(.ui, "Desktop wallpaper sync write was slow", metadata: [
                        "source": source,
                        "screen": screen.localizedName,
                        "kind": "staticWallpaper",
                        "durationMS": String(format: "%.0f", elapsedMS)
                    ])
                }
                print("[DesktopWallpaperSyncManager] [\(source)] Synced static wallpaper for screen \(screen.localizedName)")
            } catch {
                print("[DesktopWallpaperSyncManager] [\(source)] Failed to sync wallpaper for screen \(screen.localizedName): \(error)")
            }
        }

        let totalMS = Date().timeIntervalSince(start) * 1000
        let logMetadata: [String: Any] = [
            "source": source,
            "screens": currentScreens.count,
            "writes": syncWrites,
            "durationMS": String(format: "%.0f", totalMS),
            "skipStaticWrites": shouldSkipStaticDesktopWrites
        ]
        if totalMS >= 500 {
            AppLogger.warn(.ui, "Desktop wallpaper sync completed slowly", metadata: logMetadata)
        } else {
            AppLogger.debug(.ui, "Desktop wallpaper sync completed", metadata: logMetadata)
        }
    }
}
