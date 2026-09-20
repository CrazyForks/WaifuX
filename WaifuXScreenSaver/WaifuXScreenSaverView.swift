import AppKit
import CoreGraphics
import OSLog
import QuartzCore
import ScreenSaver
@preconcurrency import AVFoundation

/// WaifuX 屏保视图。
///
/// 结构对齐 `MirageScreenSaverView`：屏保宿主自己读配置、自己解码渲染，
/// 不要求主程序运行；主程序只负责写 `screensaver.json` 并在改动后发
/// DistributedNotification 通知热重载。
///
/// 与 Mirage 的差异：Scene / Web 壁纸由主程序先离线烘焙成 MP4，
/// 所以这里只有"播视频"和"放静图"两条渲染通路，不需要内嵌场景渲染 dylib。
@objc(WaifuXScreenSaverView)
final class WaifuXScreenSaverView: ScreenSaverView {

    private static let logger = Logger(subsystem: "com.waifux.app.screensaver", category: "Rendering")

    /// 主程序写入配置后广播的通知名。
    static let configurationChangedNotification = Notification.Name("com.waifux.app.screensaver.configurationChanged")

    // MARK: - 状态

    private var configuration: SaverConfiguration?
    private var didLoadWallpaper = false
    private var isAnimatingWallpaper = false
    private var isWaitingForLayout = false
    private var wallpaperLoadWorkItem: DispatchWorkItem?
    private var configurationReload: DispatchWorkItem?
    private var configurationRequestID = UUID()
    private var configurationObserver: NSObjectProtocol?
    private var hostReportedSize = CGSize.zero

    // MARK: - 渲染层

    /// 根层：承载 letterbox 底色并裁掉超出屏幕的媒体。
    private let rootLayer = CALayer()
    /// 内容层：用 viewport mask 把媒体裁进可视框（比例预设不是屏幕比例时留黑边）。
    private let contentLayer = CALayer()
    private let viewportMask = CALayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var imageLayer: CALayer?
    private var readyObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var messageLabel: NSTextField?

    /// 媒体原始像素尺寸；未知时退化为"铺满屏幕"。
    private var mediaSize: CGSize = .zero
    /// 上一次实际应用过的裁剪，用于按帧检测 App 侧改动。
    private var appliedCrop: SaverCropSettings?
    private var cropRefreshTick = 0

    // MARK: - 生命周期

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setUpLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpLayers()
    }

    private func setUpLayers() {
        autoresizingMask = [.width, .height]
        wantsLayer = true
        rootLayer.masksToBounds = true
        rootLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer = rootLayer

        contentLayer.masksToBounds = true
        contentLayer.frame = bounds
        rootLayer.addSublayer(contentLayer)

        viewportMask.backgroundColor = CGColor(gray: 1, alpha: 1)
    }

    override var hasConfigureSheet: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { releaseWallpaper() } else { scheduleWallpaperLoad() }
    }

    override func startAnimation() {
        super.startAnimation()
        isAnimatingWallpaper = true
        observeConfiguration()
        scheduleWallpaperLoad()
        player?.playImmediately(atRate: configuration?.playbackRate ?? 1)
    }

    override func stopAnimation() {
        configurationRequestID = UUID()
        configurationReload?.cancel()
        configurationReload = nil
        isAnimatingWallpaper = false
        releaseWallpaper()
        super.stopAnimation()
    }

    override func layout() {
        super.layout()
        normalizeFullScreenBoundsIfNeeded()
        guard hasValidBounds else {
            releaseWallpaper()
            return
        }
        scheduleWallpaperLoad()
        rootLayer.contentsScale = window?.backingScaleFactor ?? rootLayer.contentsScale
        playerLayer?.contentsScale = rootLayer.contentsScale
        applyGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleWallpaperLoad()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        scheduleWallpaperLoad()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
        scheduleWallpaperLoad()
    }

    override func animateOneFrame() {
        normalizeFullScreenBoundsIfNeeded()
        // 裁剪是用户在 App 里随手拖的，改完不一定触发配置通知；
        // 这里按秒轮询一次 App Group 里的实时值，做到不重启屏保就生效。
        cropRefreshTick += 1
        let fps = max(10, configuration?.fps ?? 30)
        if cropRefreshTick % fps == 0 {
            refreshCropIfNeeded()
        }
    }

    // MARK: - 加载

    private func scheduleWallpaperLoad() {
        guard isAnimatingWallpaper, !didLoadWallpaper, window != nil, wallpaperLoadWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wallpaperLoadWorkItem = nil
            self.loadWallpaper()
        }
        wallpaperLoadWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func loadWallpaper(_ replacement: SaverConfiguration? = nil) {
        guard isAnimatingWallpaper, !didLoadWallpaper, window != nil else { return }
        layoutSubtreeIfNeeded()
        normalizeFullScreenBoundsIfNeeded()
        layoutSubtreeIfNeeded()
        guard hasValidBounds, displayPixelSize() != nil else {
            if !isWaitingForLayout {
                isWaitingForLayout = true
                Self.logger.info("Waiting for valid screen saver layout: \(self.bounds.width) x \(self.bounds.height)")
            }
            return
        }
        isWaitingForLayout = false
        didLoadWallpaper = true
        guard let configuration = replacement ?? SaverConfiguration.load() else {
            showMessage(localized("noConfiguration"))
            return
        }
        self.configuration = configuration
        animationTimeInterval = 1.0 / Double(configuration.fps)
        Self.logger.info("Loading wallpaper title=\(configuration.title) kind=\(configuration.kind.rawValue) path=\(configuration.renderURL.path)")
        switch configuration.kind {
        case .video: loadVideo(configuration)
        case .image: loadImage(configuration)
        }
        // loadWallpaper 之前可能已经跑过一次 layout（那时还没有配置，只能用默认裁剪），
        // 这里立刻按真实配置重排一次，避免要等下一次 layout / 动画回调才生效。
        applyGeometry()
    }

    private func observeConfiguration() {
        guard configurationObserver == nil else { return }
        configurationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.configurationChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 注册时指定了 queue: .main，这里直接认领主线程语义。
            MainActor.assumeIsolated {
                self?.reloadConfiguration()
            }
        }
    }

    private func reloadConfiguration() {
        guard isAnimatingWallpaper else { return }
        configurationReload?.cancel()
        let request = UUID()
        configurationRequestID = request
        let work = DispatchWorkItem { [weak self] in
            let value = SaverConfiguration.load()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.configurationRequestID == request, self.isAnimatingWallpaper else { return }
                guard let value else {
                    self.releaseWallpaper()
                    self.showMessage(self.localized("noConfiguration"))
                    return
                }
                // 同一张壁纸、同样的设置：保持正在播放的画面，不做无谓重载。
                if value.identity == self.configuration?.identity { return }
                self.releaseWallpaper()
                self.loadWallpaper(value)
            }
        }
        configurationReload = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: - 视频

    private func loadVideo(_ configuration: SaverConfiguration) {
        teardownMedia()
        let item = AVPlayerItem(url: configuration.renderURL)
        let player = AVQueuePlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = configuration.muted
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: item)

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = bounds
        playerLayer.contentsScale = window?.backingScaleFactor ?? 1
        playerLayer.backgroundColor = CGColor(gray: 0, alpha: 0)
        contentLayer.addSublayer(playerLayer)
        applyVideoDynamicRange(to: playerLayer, enabled: configuration.enableHDRVideo)

        self.player = player
        self.looper = looper
        self.playerLayer = playerLayer

        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateMediaSize()
                self.hideMessage()
                if self.isAnimatingWallpaper {
                    self.player?.playImmediately(atRate: configuration.playbackRate)
                }
            }
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            switch item.status {
            case .readyToPlay:
                // readiness 回调（isReadyForDisplay）在部分宿主/预览场景下会迟到甚至不来，
                // 所以解码器一就绪就补上媒体尺寸，避免首帧先按屏幕比例铺满再跳一下。
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateMediaSize()
                }
            case .failed:
                let reason = item.error?.localizedDescription ?? "unknown"
                DispatchQueue.main.async {
                    guard let self else { return }
                    Self.logger.error("Screen saver video failed: \(reason)")
                    self.showMessage(self.localized("unplayableVideo"))
                }
            default:
                break
            }
        }

        if isAnimatingWallpaper {
            player.playImmediately(atRate: configuration.playbackRate)
        }
    }

    /// 视频原始尺寸：优先 presentationSize，其次 readyForDisplay 后的 videoRect。
    private func updateMediaSize() {
        guard let playerLayer else { return }
        var size = playerLayer.player?.currentItem?.presentationSize ?? .zero
        if size.width <= 0 || size.height <= 0 {
            size = playerLayer.videoRect.size
        }
        guard size.width > 0, size.height > 0 else { return }
        mediaSize = size
        applyGeometry()
    }

    // MARK: - 静图

    private func loadImage(_ configuration: SaverConfiguration) {
        teardownMedia()
        guard let image = NSImage(contentsOf: configuration.renderURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showMessage(localized("missingMedia"))
            return
        }
        let layer = CALayer()
        layer.contents = cgImage
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.frame = bounds
        contentLayer.addSublayer(layer)
        imageLayer = layer
        mediaSize = CGSize(width: cgImage.width, height: cgImage.height)
        applyGeometry()
    }

    // MARK: - 几何

    private func applyGeometry() {
        guard hasValidBounds else { return }
        let crop = configuration?.cropSettings(forDisplayKey: currentDisplayKey) ?? .default
        let screenSize = displayPixelSize() ?? bounds.size
        // 尺寸未知时按屏幕比例兜底，等 readiness 回调补上真实尺寸再重排。
        let wallpaperSize = mediaSize == .zero ? screenSize : mediaSize
        let layout = SaverCropEngine.compute(wallpaperSize: wallpaperSize, screenSize: screenSize, settings: crop)
        apply(layout: layout)
        appliedCrop = crop
    }

    /// 检测 App 侧裁剪改动，变了才重排。
    private func refreshCropIfNeeded() {
        guard configuration != nil else { return }
        let crop = configuration?.cropSettings(forDisplayKey: currentDisplayKey) ?? .default
        guard crop != appliedCrop else { return }
        applyGeometry()
    }

    private func apply(layout: SaverCropLayout) {
        let geometry = SaverCropGeometry.layerGeometry(layout: layout, in: bounds)
        rootLayer.backgroundColor = layout.letterboxColor
        contentLayer.frame = bounds
        // 只有可视框小于屏幕（比例预设 / 平移裁切）时才需要 mask；
        // 全屏时摘掉 mask，省一层合成。
        let coversScreen = geometry.viewportRect.insetBy(dx: -0.5, dy: -0.5).contains(bounds)
        if coversScreen {
            contentLayer.mask = nil
        } else {
            viewportMask.frame = geometry.viewportRect
            contentLayer.mask = viewportMask
        }
        playerLayer?.frame = geometry.mediaFrame
        imageLayer?.frame = geometry.mediaFrame
    }

    private func applyVideoDynamicRange(to playerLayer: AVPlayerLayer, enabled: Bool) {
        let screen = window?.screen ?? NSScreen.main
        let useHDR = enabled && (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        if #available(macOS 26.0, *) {
            let range: CALayer.DynamicRange = useHDR ? .constrainedHigh : .standard
            rootLayer.preferredDynamicRange = range
            playerLayer.preferredDynamicRange = range
        } else {
            rootLayer.wantsExtendedDynamicRangeContent = useHDR
            playerLayer.wantsExtendedDynamicRangeContent = useHDR
        }
    }

    // MARK: - 释放

    private func teardownMedia() {
        readyObservation?.invalidate()
        readyObservation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        looper?.disableLooping()
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player?.removeAllItems()
        player = nil
        looper = nil
        imageLayer?.removeFromSuperlayer()
        imageLayer = nil
        mediaSize = .zero
        appliedCrop = nil
    }

    private func releaseWallpaper() {
        wallpaperLoadWorkItem?.cancel()
        wallpaperLoadWorkItem = nil
        if !isAnimatingWallpaper || window == nil { isWaitingForLayout = false }
        // Swift 6 里 deinit 是 nonisolated，碰不到这些主线程属性，
        // 所以把清理收在这里：stopAnimation / 移出窗口时都会走到。
        configurationReload?.cancel()
        configurationReload = nil
        if let configurationObserver {
            DistributedNotificationCenter.default().removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        teardownMedia()
        hideMessage()
        configuration = nil
        didLoadWallpaper = false
        hostReportedSize = .zero
    }

    // MARK: - 布局兜底

    /// 屏保宿主首帧可能给出与实际显示器不一致的 bounds（起屏动画期间尤其明显），
    /// 这里把 frame/bounds 归一到当前屏幕的逻辑尺寸，避免画面被拉伸或留边。
    private func normalizeFullScreenBoundsIfNeeded() {
        if hostReportedSize == .zero {
            hostReportedSize = bounds.size
        }
        guard !isPreview else { return }
        guard let screen = window?.screen ?? NSScreen.main else { return }
        guard screen.backingScaleFactor.isFinite, screen.backingScaleFactor > 0 else { return }
        let backingSize = screen.convertRectToBacking(screen.frame).size
        let logicalSize = CGSize(
            width: backingSize.width / screen.backingScaleFactor,
            height: backingSize.height / screen.backingScaleFactor
        )
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0 else { return }
        if !approximatelyEqual(bounds.size, logicalSize) {
            var normalizedBounds = bounds
            normalizedBounds.size = logicalSize
            bounds = normalizedBounds
        }
        if !approximatelyEqual(frame.size, logicalSize) {
            var normalizedFrame = frame
            normalizedFrame.size = logicalSize
            frame = normalizedFrame
        }
    }

    private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
    }

    private var hasValidBounds: Bool {
        bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0
    }

    private func displayPixelSize() -> CGSize? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        let size = screen.convertRectToBacking(screen.frame).size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return size
    }

    private var currentDisplayKey: String? {
        guard !isPreview, let screen = window?.screen,
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { return nil }
        return saverDisplayKey(displayID)
    }

    // MARK: - 文案

    private func localized(_ key: String) -> String {
        SaverLocalization.string(key, language: configuration?.language)
    }

    private func showMessage(_ text: String) {
        guard messageLabel?.stringValue != text else { return }
        messageLabel?.removeFromSuperview()
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
        messageLabel = label
    }

    private func hideMessage() {
        messageLabel?.removeFromSuperview()
        messageLabel = nil
    }
}
