import AppKit
import Combine

// MARK: - 菜单栏音量滑块自定义视图
private final class WallpaperVolumeSliderView: NSView {
    private let iconView = NSImageView()
    private let slider = NSSlider()
    private var cancellables = Set<AnyCancellable>()

    var onVolumeChanged: ((Double) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        // 图标
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // 滑块
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            slider.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = Double(sender.doubleValue) / 100.0
        onVolumeChanged?(value)
        updateIcon(volume: value)
    }

    func setVolume(_ volume: Double, isMuted: Bool) {
        let effectiveVolume = isMuted ? 0 : volume
        slider.doubleValue = effectiveVolume * 100
        updateIcon(volume: effectiveVolume)
    }

    private func updateIcon(volume: Double) {
        let name: String
        if volume == 0 {
            name = "speaker.slash.fill"
        } else if volume < 0.35 {
            name = "speaker.wave.1.fill"
        } else if volume < 0.7 {
            name = "speaker.wave.2.fill"
        } else {
            name = "speaker.wave.3.fill"
        }
        iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

// MARK: - 单屏幕音量控制（名称 + 滑块）
private final class ScreenVolumeControlView: NSView {
    private let nameLabel = NSTextField()
    private let sliderView = WallpaperVolumeSliderView()

    var onVolumeChanged: ((Double) -> Void)? {
        didSet { sliderView.onVolumeChanged = onVolumeChanged }
    }

    init(screenName: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        setupUI(screenName: screenName)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI(screenName: String) {
        nameLabel.stringValue = screenName
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.backgroundColor = .clear
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        sliderView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(nameLabel)
        addSubview(sliderView)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            sliderView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            sliderView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            sliderView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            sliderView.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    func setVolume(_ volume: Double, isMuted: Bool) {
        sliderView.setVolume(volume, isMuted: isMuted)
    }
}

// MARK: - Fixed-width task queue row
private final class TaskQueueRowView: NSView {
    static let menuWidth: CGFloat = 300
    private let titleLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")

    init(title: String, progress: Double, isSectionHeader: Bool = false) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: 24))
        titleLabel.font = NSFont.systemFont(ofSize: isSectionHeader ? 13 : 12, weight: isSectionHeader ? .semibold : .regular)
        titleLabel.textColor = isSectionHeader ? .secondaryLabelColor : .disabledControlTextColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = .disabledControlTextColor
        progressLabel.alignment = .right
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(progressLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: progressLabel.leadingAnchor, constant: -8),
            progressLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progressLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressLabel.widthAnchor.constraint(equalToConstant: 44)
        ])
        update(title: title, progress: progress, isSectionHeader: isSectionHeader)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(title: String, progress: Double, isSectionHeader: Bool = false) {
        titleLabel.stringValue = title
        progressLabel.stringValue = isSectionHeader ? "" : "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }
}

@MainActor
final class StatusBarController: NSObject {
    // MARK: - 单例
    static let shared = StatusBarController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private lazy var openWindowItem = NSMenuItem(title: t("statusbar.showWindow"), action: #selector(showMainWindow), keyEquivalent: "")
    private lazy var openLibraryItem = NSMenuItem(title: t("statusbar.openMyLibrary"), action: #selector(openMyLibrary), keyEquivalent: "")
    private lazy var openSettingsItem = NSMenuItem(title: t("settings"), action: #selector(openAppSettingsPanel), keyEquivalent: "")
    private lazy var releaseMemoryItem = NSMenuItem(title: t("statusbar.releaseMemory"), action: #selector(releaseForegroundMemory), keyEquivalent: "")
    private lazy var toggleWallpaperItem = NSMenuItem(title: t("statusbar.enableWallpaper"), action: #selector(toggleDynamicWallpaper), keyEquivalent: "")
    private lazy var playPauseItem = NSMenuItem(title: t("statusbar.pauseWallpaper"), action: #selector(togglePlayback), keyEquivalent: "")
    private lazy var muteItem = NSMenuItem(title: t("statusbar.muteWallpaper"), action: #selector(toggleMute), keyEquivalent: "")
    private lazy var desktopIconsItem = NSMenuItem(title: t("statusbar.hideDesktopIcons"), action: #selector(toggleDesktopIcons), keyEquivalent: "")
    private lazy var designWallpaperItem = NSMenuItem(title: t("design.designWallpaper"), action: #selector(openWebWallpaperDesignPanel), keyEquivalent: "")
    private lazy var sceneConfigItem = NSMenuItem(title: t("statusbar.sceneAdvancedSettings"), action: #selector(openSceneConfigPanel), keyEquivalent: "")
    private lazy var checkUpdateItem = NSMenuItem(title: t("checkForUpdates"), action: #selector(checkForUpdates), keyEquivalent: "")
    private lazy var quitItem = NSMenuItem(title: t("statusbar.quit"), action: #selector(quitApplication), keyEquivalent: "q")

    private let videoWallpaperManager = VideoWallpaperManager.shared
    private let weBridge = WallpaperEngineXBridge.shared
    private var showWindowHandler: (() -> Void)?
    private var releaseMemoryHandler: (() -> Void)?
    private var quitHandler: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()

    // 各屏幕独立音量条
    private var screenVolumeItems: [NSMenuItem] = []
    // 各屏幕独立暂停/关闭菜单项
    private var wallpaperControlItems: [NSMenuItem] = []

    // MARK: - 任务队列状态栏显示
    private var originalButtonImage: NSImage?
    private lazy var taskQueueItem = NSMenuItem(title: t("statusbar.taskQueue"), action: nil, keyEquivalent: "")
    private lazy var taskQueueMenu = NSMenu(title: t("statusbar.taskQueue"))
    private var taskQueueRowsByID: [String: TaskQueueRowView] = [:]
    private var taskQueueStructure: [String] = []

    // 标记是否已配置，防止重复配置
    private var isConfigured = false

    private override init() {
        super.init()
        configureStatusItem()
        bindWallpaperState()
        bindTaskQueueState()
        bindLocalizationState()
        refreshMenuState()
    }

    /// 配置处理程序（只能调用一次）
    func configure(
        showWindow: @escaping () -> Void,
        releaseMemory: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        guard !isConfigured else {
            print("[StatusBarController] Already configured, skipping...")
            return
        }
        self.showWindowHandler = showWindow
        self.releaseMemoryHandler = releaseMemory
        self.quitHandler = quit
        self.isConfigured = true
    }

    private func configureStatusItem() {
        // 确保状态栏项的按钮存在
        guard let button = statusItem.button else {
            print("[StatusBarController] Failed to get status item button")
            return
        }

        // 尝试使用系统图标，如果不存在则使用备用图标
        let systemImageNames = ["sparkles.tv", "photo.fill", "tv.fill", "desktopcomputer"]
        var image: NSImage?

        for name in systemImageNames {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "WaifuX") {
                image = img
                break
            }
        }

        if let image = image {
            image.isTemplate = true
            // 在 macOS 14 上需要设置合适的图标大小
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        } else {
            // 最后的备选方案：使用文字
            button.title = "WH"
            button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        }

        button.toolTip = "WaifuX"

        openWindowItem.target = self
        openLibraryItem.target = self
        openSettingsItem.target = self
        releaseMemoryItem.target = self
        muteItem.target = self
        desktopIconsItem.target = self
        designWallpaperItem.target = self
        sceneConfigItem.target = self
        checkUpdateItem.target = self
        quitItem.target = self

        taskQueueItem.submenu = taskQueueMenu
        // The initial Combine emission is an empty task list. Build the empty
        // categories here so the submenu is still openable before any task is
        // created, instead of leaving AppKit with an empty submenu.
        rebuildTaskQueueMenu([])
        menu.addItem(taskQueueItem)
        menu.addItem(.separator())
        menu.addItem(openWindowItem)
        menu.addItem(openLibraryItem)
        menu.addItem(releaseMemoryItem)
        menu.addItem(openSettingsItem)
        menu.addItem(.separator())
        menu.addItem(desktopIconsItem)
        menu.addItem(designWallpaperItem)
        menu.addItem(sceneConfigItem)
        // toggleWallpaperItem 和 playPauseItem 在 refreshMenuState 中动态构建
        menu.addItem(muteItem)
        menu.addItem(.separator())
        menu.addItem(checkUpdateItem)
        menu.addItem(quitItem)

        statusItem.menu = menu
        menu.delegate = self
    }

    private func bindLocalizationState() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLanguageDidChange),
            name: .appLanguageDidChange,
            object: nil
        )
    }

    @objc private func handleLanguageDidChange() {
        taskQueueStructure.removeAll()
        updateTaskQueue(TaskQueueStatusService.shared.entries)
        refreshMenuState()
    }

    private func bindWallpaperState() {
        videoWallpaperManager.$currentVideoURL
            .combineLatest(videoWallpaperManager.$isPaused, videoWallpaperManager.$isMuted, videoWallpaperManager.$volume)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
                self?.refreshMenuState()
            }
            .store(in: &cancellables)

        weBridge.$isControllingExternalEngine
            .combineLatest(weBridge.$isExternalPaused)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.refreshMenuState()
            }
            .store(in: &cancellables)

        WallpaperSchedulerService.shared.$config
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMenuState()
            }
            .store(in: &cancellables)
    }

    // MARK: - Unified task queue status

    private func bindTaskQueueState() {
        originalButtonImage = statusItem.button?.image
        TaskQueueStatusService.shared.$entries
            .throttle(for: .milliseconds(180), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                self?.updateTaskQueue(entries)
            }
            .store(in: &cancellables)
    }

    private func updateTaskQueue(_ entries: [TaskQueueStatusService.Entry]) {
        updateTaskQueueButton(entries)
        let structure = entries.map { "\($0.category.localizationKey):\($0.id)" }
        if structure != taskQueueStructure {
            taskQueueStructure = structure
            rebuildTaskQueueMenu(entries)
        } else {
            for entry in entries {
                taskQueueRowsByID[entry.id]?.update(title: entry.title, progress: entry.progress)
            }
        }
    }

    private func updateTaskQueueButton(_ entries: [TaskQueueStatusService.Entry]) {
        guard let button = statusItem.button else { return }
        guard !entries.isEmpty else {
            button.image = originalButtonImage
            button.title = ""
            button.toolTip = "WaifuX"
            return
        }
        let progress = entries.reduce(0) { $0 + $1.progress } / Double(entries.count)
        button.image = nil
        button.title = "\(Int((progress * 100).rounded()))% · \(entries.count)"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        button.toolTip = "WaifuX — \(entries.count)"
    }

    private func rebuildTaskQueueMenu(_ entries: [TaskQueueStatusService.Entry]) {
        taskQueueMenu.removeAllItems()
        taskQueueRowsByID.removeAll()
        for category in TaskQueueStatusService.Category.allCases {
            let section = NSMenuItem()
            section.view = TaskQueueRowView(title: t(category.localizationKey), progress: 0, isSectionHeader: true)
            section.isEnabled = false
            taskQueueMenu.addItem(section)
            let categoryEntries = entries.filter { $0.category == category }
            if categoryEntries.isEmpty {
                let emptyItem = NSMenuItem(title: "    \(t("statusbar.taskQueue.empty"))", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                taskQueueMenu.addItem(emptyItem)
            } else {
                for entry in categoryEntries {
                    let row = TaskQueueRowView(title: entry.title, progress: entry.progress)
                    let item = NSMenuItem()
                    item.view = row
                    item.isEnabled = false
                    taskQueueMenu.addItem(item)
                    taskQueueRowsByID[entry.id] = row
                }
            }
            if category != TaskQueueStatusService.Category.allCases.last {
                taskQueueMenu.addItem(.separator())
            }
        }
    }

    /// 为指定屏幕构建音量滑块菜单项
    private func buildVolumeMenuItem(for screen: NSScreen) -> NSMenuItem {
        let controlView = ScreenVolumeControlView(screenName: screen.localizedName)
        controlView.onVolumeChanged = { [weak self] volume in
            guard let self = self else { return }
            // 只设该屏幕的音量，不触及其他屏幕，也不动全局静音
            self.videoWallpaperManager.setVolume(volume, for: screen)
            if self.weBridge.isControllingExternalEngine {
                self.weBridge.setVolume(volume, for: screen)
            }
        }
        let item = NSMenuItem()
        item.view = controlView
        let vol = videoWallpaperManager.volume(for: screen)
        // 显示实际音量，不受全局 isMuted 影响
        controlView.setVolume(vol, isMuted: false)
        return item
    }

    private func refreshMenuState() {
        refreshLocalizedTitles()

        let hasNativeWallpaper = videoWallpaperManager.isVideoWallpaperActive
        let hasExternalWallpaper = weBridge.isControllingExternalEngine
        let hasWallpaper = hasNativeWallpaper || hasExternalWallpaper
        let shouldShowDesignWallpaperItem: Bool
        if let sceneWallpaperPath = currentSceneDesignWallpaperPath() {
            shouldShowDesignWallpaperItem = true
            designWallpaperItem.representedObject = sceneWallpaperPath
        } else if let wallpaperPath = weBridge.currentWallpaperPathForDesign {
            if weBridge.isCurrentWallpaperWeb {
                shouldShowDesignWallpaperItem = WebWallpaperDesignService.shared.hasEditableProperties(for: wallpaperPath)
                designWallpaperItem.representedObject = wallpaperPath
            } else if weBridge.isCurrentWallpaperScene {
                shouldShowDesignWallpaperItem = true
                designWallpaperItem.representedObject = wallpaperPath
            } else {
                shouldShowDesignWallpaperItem = false
                designWallpaperItem.representedObject = nil
            }
        } else {
            shouldShowDesignWallpaperItem = false
            designWallpaperItem.representedObject = nil
        }
        designWallpaperItem.isHidden = !shouldShowDesignWallpaperItem
        designWallpaperItem.isEnabled = shouldShowDesignWallpaperItem

        // 场景高级设置（仅在实时渲染场景壁纸时显示）
        let shouldShowSceneConfig = weBridge.isCurrentWallpaperScene
            && UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled")
        sceneConfigItem.isHidden = !shouldShowSceneConfig
        sceneConfigItem.isEnabled = shouldShowSceneConfig
        if shouldShowSceneConfig, let path = weBridge.currentWallpaperPathForDesign {
            sceneConfigItem.representedObject = path
        } else {
            sceneConfigItem.representedObject = nil
        }

        // 移除旧的动态菜单项
        for item in wallpaperControlItems {
            if item.menu != nil {
                menu.removeItem(item)
            }
        }
        wallpaperControlItems.removeAll()

        // macOS 26+：扩展控制模式下，动态壁纸由扩展偏好控制。
        let isExtensionMode: Bool
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            isExtensionMode = true
        } else {
            isExtensionMode = false
        }

        let isGlobalDisplaySyncEnabled = WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled
        // 状态栏始终列出当前连接的所有显示器，不再以“当前是否播放动态壁纸”作为可见条件。
        // 全局模式则以单一入口呈现，避免把同一份全局配置重复显示多次。
        let displayScreens: [NSScreen]
        if isGlobalDisplaySyncEnabled {
            displayScreens = NSScreen.screens.first.map { [$0] } ?? []
        } else {
            displayScreens = NSScreen.screens
        }

        // 每屏一个顶层子菜单（多屏直接平铺，无外层「显示器」包裹）
        let hasWallpaperOnAnyScreen = hasWallpaper || hasNativeWallpaper || hasExternalWallpaper

        for screen in displayScreens {
            let screenName = isGlobalDisplaySyncEnabled
                ? t("statusbar.globalDisplaySettings")
                : screen.localizedName

            // 该屏是否有壁纸（决定控件是否启用）
            let screenHasWallpaper: Bool
            if isExtensionMode {
                screenHasWallpaper = hasWallpaperOnAnyScreen
            } else if weBridge.isManaging(screen: screen) {
                screenHasWallpaper = true
            } else {
                screenHasWallpaper = videoWallpaperManager.hasActiveWallpaper(on: screen)
            }

            // 该屏壁纸是否为 web（web 暂不支持可视区域调节）
            let isWebWallpaper = weBridge.isWebWallpaperOn(screen: screen)

            // 暂停状态
            let isScreenPaused: Bool
            if isExtensionMode, #available(macOS 26.0, *),
               let displayID = Self.cgDisplayID(for: screen) {
                isScreenPaused = LockScreenWallpaperService.shared.isDisplayPaused(displayID)
            } else if weBridge.isManaging(screen: screen) {
                isScreenPaused = weBridge.isExternalPaused
            } else {
                isScreenPaused = videoWallpaperManager.isPaused(on: screen)
            }

            let screenMenuItem = NSMenuItem(title: screenName, action: nil, keyEquivalent: "")
            let screenSubMenu = NSMenu(title: screenName)
            screenMenuItem.submenu = screenSubMenu
            let schedulerConfig = isGlobalDisplaySyncEnabled
                ? WallpaperSchedulerService.shared.globalDisplayConfig
                : WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: screen.wallpaperScreenIdentifier)

            // 自动切换开关
            let autoSwitchItem = NSMenuItem(
                title: schedulerConfig.isEnabled ? t("statusbar.disableAutoSwitch") : t("statusbar.enableAutoSwitch"),
                action: #selector(togglePerScreenAutoSwitch(_:)),
                keyEquivalent: "")
            autoSwitchItem.target = self
            autoSwitchItem.representedObject = screen
            screenSubMenu.addItem(autoSwitchItem)

            // 切换下一张壁纸
            let nextWallpaperItem = NSMenuItem(
                title: t("statusbar.nextWallpaper"),
                action: #selector(nextWallpaperForScreen(_:)),
                keyEquivalent: "")
            nextWallpaperItem.target = self
            nextWallpaperItem.representedObject = screen
            nextWallpaperItem.isEnabled = WallpaperSchedulerService.shared.hasSchedulableItems(for: screen.wallpaperScreenIdentifier)
            screenSubMenu.addItem(nextWallpaperItem)

            screenSubMenu.addItem(.separator())

            // 动态壁纸控制。关闭后不显示暂停和“打开当前壁纸”，避免对空目标执行无效操作。
            let disableItem = NSMenuItem(
                title: screenHasWallpaper ? t("statusbar.disableWallpaper") : t("statusbar.enableWallpaper"),
                action: #selector(perScreenToggleDynamicWallpaper(_:)),
                keyEquivalent: "")
            disableItem.target = self
            disableItem.representedObject = screen
            screenSubMenu.addItem(disableItem)

            if screenHasWallpaper {
                let openCurrentItem = NSMenuItem(
                    title: t("statusbar.openCurrentWallpaper"),
                    action: #selector(openCurrentWallpaper(_:)),
                    keyEquivalent: "")
                openCurrentItem.target = self
                openCurrentItem.representedObject = screen
                screenSubMenu.addItem(openCurrentItem)

                let pauseItem = NSMenuItem(
                    title: isScreenPaused ? t("statusbar.resumeWallpaper") : t("statusbar.pauseWallpaper"),
                    action: #selector(perScreenTogglePlayback(_:)),
                    keyEquivalent: "")
                pauseItem.target = self
                pauseItem.representedObject = screen
                screenSubMenu.addItem(pauseItem)
            }

            // 音量（扩展模式跳过，与原逻辑一致）
            if !isExtensionMode {
                screenSubMenu.addItem(buildVolumeMenuItem(for: screen))
            }

            screenSubMenu.addItem(.separator())

            // 可视区域调节…
            let isAdjusting = CropAdjustOverlayController.shared.isActive(for: screen)
            let cropAdjustItem = NSMenuItem(
                title: isAdjusting ? t("statusbar.cropExit") : t("statusbar.cropAdjust"),
                action: #selector(toggleCropAdjustment(_:)),
                keyEquivalent: "")
            cropAdjustItem.target = self
            cropAdjustItem.representedObject = screen
            if isWebWallpaper {
                cropAdjustItem.isEnabled = false
                cropAdjustItem.toolTip = t("statusbar.cropUnsupported")
            }
            screenSubMenu.addItem(cropAdjustItem)

            // 比例子菜单
            let aspectItem = NSMenuItem(title: t("statusbar.cropAspect"), action: nil, keyEquivalent: "")
            let aspectMenu = NSMenu(title: t("statusbar.cropAspect"))
            let currentSettings = DisplayCropSettingsStore.shared.settings(for: screen)
            for preset in AspectPreset.allCases {
                let title = preset == .autoFill ? t("statusbar.cropAspectAutoFill")
                    : preset == .custom ? t("statusbar.cropAspectCustom")
                    : preset.displayName()
                let item = NSMenuItem(title: title, action: #selector(setCropAspect(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = CropAspectPayload(screen: screen, preset: preset)
                item.state = (currentSettings.aspectPreset == preset) ? .on : .off
                if isWebWallpaper { item.isEnabled = false }
                aspectMenu.addItem(item)
            }
            aspectItem.submenu = aspectMenu
            if isWebWallpaper {
                aspectItem.isEnabled = false
                aspectItem.toolTip = t("statusbar.cropUnsupported")
            }
            screenSubMenu.addItem(aspectItem)

            // 重置
            let resetItem = NSMenuItem(
                title: t("statusbar.cropReset"),
                action: #selector(resetCrop(_:)),
                keyEquivalent: "")
            resetItem.target = self
            resetItem.representedObject = screen
            if isWebWallpaper {
                resetItem.isEnabled = false
                resetItem.toolTip = t("statusbar.cropUnsupported")
            }
            screenSubMenu.addItem(resetItem)

            wallpaperControlItems.append(screenMenuItem)
        }

        // 将动态菜单项（每屏一个顶层子菜单）插入到 muteItem 之前
        let separatorIndex = menu.index(of: muteItem)
        if separatorIndex != -1 {
            var currentInsertIndex = separatorIndex
            for item in wallpaperControlItems {
                menu.insertItem(item, at: currentInsertIndex)
                currentInsertIndex += 1
            }
        }

        // 桌面图标开关
        desktopIconsItem.title = DesktopIconManager.shared.areDesktopIconsHidden
            ? t("statusbar.showDesktopIcons")
            : t("statusbar.hideDesktopIcons")

        // 全局静音开关
        muteItem.isEnabled = hasNativeWallpaper || hasExternalWallpaper
        muteItem.title = videoWallpaperManager.isMuted ? t("statusbar.unmuteWallpaper") : t("statusbar.muteWallpaper")
    }

    private func refreshLocalizedTitles() {
        taskQueueItem.title = t("statusbar.taskQueue")
        taskQueueMenu.title = t("statusbar.taskQueue")
        openWindowItem.title = t("statusbar.showWindow")
        openLibraryItem.title = t("statusbar.openMyLibrary")
        openSettingsItem.title = t("settings")
        releaseMemoryItem.title = t("statusbar.releaseMemory")
        toggleWallpaperItem.title = t("statusbar.enableWallpaper")
        playPauseItem.title = t("statusbar.pauseWallpaper")
        desktopIconsItem.title = t("statusbar.hideDesktopIcons")
        muteItem.title = videoWallpaperManager.isMuted ? t("statusbar.unmuteWallpaper") : t("statusbar.muteWallpaper")
        designWallpaperItem.title = t("design.designWallpaper")
        sceneConfigItem.title = t("statusbar.sceneAdvancedSettings")
        checkUpdateItem.title = t("checkForUpdates")
        quitItem.title = t("statusbar.quit")
    }

    @objc private func showMainWindow() {
        showWindowHandler?()
    }

    @objc private func openMyLibrary() {
        MainNavigationRequestStore.requestLibraryTab()
        showWindowHandler?()
    }

    @objc private func openAppSettingsPanel() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.showSettingsWindow(nil)
    }

    @objc private func releaseForegroundMemory() {
        releaseMemoryHandler?()
    }

    // MARK: - 可视区域调节 (Crop)

    /// 比例菜单项携带的载荷。
    private struct CropAspectPayload {
        let screen: NSScreen
        let preset: AspectPreset
    }

    @objc private func toggleCropAdjustment(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        CropAdjustOverlayController.shared.toggle(for: screen, statusBarItemRef: statusItem)
        refreshMenuState()
    }

    @objc private func setCropAspect(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? CropAspectPayload else { return }
        DisplayCropSettingsStore.shared.update(for: payload.screen) { s in
            s.aspectPreset = payload.preset
        }
        refreshMenuState()
    }

    @objc private func resetCrop(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        DisplayCropSettingsStore.shared.reset(for: screen)
        refreshMenuState()
    }

    @objc private func togglePerScreenAutoSwitch(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
            let isEnabled = WallpaperSchedulerService.shared.globalDisplayConfig.isEnabled
            WallpaperSchedulerService.shared.updateGlobalDisplayEnabled(!isEnabled)
            refreshMenuState()
            return
        }
        let screenID = screen.wallpaperScreenIdentifier
        let isEnabled = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: screenID).isEnabled
        WallpaperSchedulerService.shared.updateDisplayEnabled(!isEnabled, for: screenID)
        refreshMenuState()
    }

    @objc private func nextWallpaperForScreen(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        let screenID = screen.wallpaperScreenIdentifier
        let hasItems = WallpaperSchedulerService.shared.hasSchedulableItems(for: screenID)
        print("[StatusBar] nextWallpaperForScreen screen=\(screen.localizedName) id=\(screenID) hasItems=\(hasItems)")
        guard hasItems else {
            print("[StatusBar] nextWallpaper ignored: no schedulable items for \(screenID)")
            return
        }
        WallpaperSchedulerService.shared.triggerNextWallpaperNow(for: screenID)
    }

    @objc private func perScreenTogglePlayback(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else {
            togglePlayback()
            return
        }

        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
            if weBridge.isControllingExternalEngine {
                let wasPaused = weBridge.isExternalPaused
                wasPaused ? weBridge.resumeWallpaper() : weBridge.pauseWallpaper()
                WallpaperSchedulerService.shared.setAutomaticSwitchPaused(!wasPaused)
            } else if videoWallpaperManager.isPaused {
                videoWallpaperManager.resumeWallpaper()
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
                WallpaperSchedulerService.shared.setAutomaticSwitchPaused(false)
            } else {
                videoWallpaperManager.pauseWallpaper()
                WallpaperSchedulerService.shared.setAutomaticSwitchPaused(true)
            }
            return
        }

        if weBridge.isControllingExternalEngine {
            // CLI 壁纸暂不支持单屏暂停，走全局
            let wasPaused = weBridge.isExternalPaused
            if wasPaused {
                weBridge.resumeWallpaper()
            } else {
                weBridge.pauseWallpaper()
            }
            WallpaperSchedulerService.shared.setAutomaticSwitchPaused(!wasPaused)
            return
        }

        // macOS 26+：扩展控制模式下通过共享 prefs 控制 per-display 暂停
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            if let displayID = Self.cgDisplayID(for: screen) {
                let isPaused = LockScreenWallpaperService.shared.isDisplayPaused(displayID)
                LockScreenWallpaperService.shared.setDisplayPaused(!isPaused, forDisplayID: displayID)
                WallpaperSchedulerService.shared.setAutomaticSwitchPaused(!isPaused, for: screen)
            }
            return
        }

        let wasPaused = videoWallpaperManager.isPaused(on: screen)
        if wasPaused {
            videoWallpaperManager.resumeWallpaper(for: screen)
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
        } else {
            videoWallpaperManager.pauseWallpaper(for: screen)
        }
        WallpaperSchedulerService.shared.setAutomaticSwitchPaused(!wasPaused, for: screen)
    }

    @objc private func perScreenToggleDynamicWallpaper(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else {
            toggleDynamicWallpaper()
            return
        }

        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
            if videoWallpaperManager.isVideoWallpaperActive || weBridge.isControllingExternalEngine {
                toggleDynamicWallpaper()
            } else {
                WallpaperSchedulerService.shared.triggerNextGlobalWallpaperNow()
            }
            return
        }

        if weBridge.isManaging(screen: screen) {
            // 关闭外部引擎壁纸（单屏）
            weBridge.ensureStoppedForNonCLIWallpaper(for: screen)
            // 对称关闭该屏静态图 overlay
            StaticImageWallpaperOverlayManager.shared.hide(for: screen)
            return
        }

        // macOS 26+：扩展控制模式下停止单屏视频
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            videoWallpaperManager.stopWallpaper(for: screen)
            return
        }

        if videoWallpaperManager.hasActiveWallpaper(on: screen) {
            videoWallpaperManager.stopWallpaper(for: screen)
        } else {
            WallpaperSchedulerService.shared.triggerNextWallpaperNow(for: screen.wallpaperScreenIdentifier)
        }
    }

    @objc private func openCurrentWallpaper(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        let url: URL?
        if let videoURL = videoWallpaperManager.videoURL(for: screen) {
            url = videoURL
        } else if let path = weBridge.currentWallpaperPath(for: screen) {
            url = URL(fileURLWithPath: path)
        } else {
            url = nil
        }

        guard let url else {
            NSSound.beep()
            return
        }
        MainNavigationRequestStore.requestLibraryItem(for: url)
        showWindowHandler?()
    }

    @objc private func togglePlayback() {
        // 如果当前由 Wallpaper Engine X 接管，走 URL Scheme
        if weBridge.isControllingExternalEngine {
            let wasPaused = weBridge.isExternalPaused
            if wasPaused {
                weBridge.resumeWallpaper()
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            } else {
                weBridge.pauseWallpaper()
            }
            WallpaperSchedulerService.shared.setAutomaticSwitchPaused(!wasPaused)
            return
        }

        // macOS 26+：扩展控制模式下全局暂停/恢复
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            let wasPaused = videoWallpaperManager.isPaused
            LockScreenWallpaperService.shared.setPaused(!wasPaused)
            videoWallpaperManager.toggleExtensionGlobalPause()
            WallpaperSchedulerService.shared.setAutomaticSwitchPaused(!wasPaused)
            return
        }

        // 检测多显示器
        let screens = NSScreen.screens
        if screens.count > 1 && videoWallpaperManager.isVideoWallpaperActive {
            // 多显示器环境下显示选择弹窗
            DisplaySelectorManager.shared.showSelector(
                title: videoWallpaperManager.isPaused ? t("resumeWallpaper") : t("pauseWallpaper"),
                message: t("selectDisplayToControl")
            ) { [weak self] selectedScreen in
                guard let self, let selectedScreen else { return }

                let wasPaused = self.videoWallpaperManager.isPaused(on: selectedScreen)
                if wasPaused {
                    self.videoWallpaperManager.resumeWallpaper(for: selectedScreen)
                    DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
                } else {
                    self.videoWallpaperManager.pauseWallpaper(for: selectedScreen)
                }
                WallpaperSchedulerService.shared.setAutomaticSwitchPaused(!wasPaused, for: selectedScreen)
            }
        } else {
            // 单显示器环境下直接操作
            let wasPaused = videoWallpaperManager.isPaused
            if wasPaused {
                videoWallpaperManager.resumeWallpaper()
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            } else {
                videoWallpaperManager.pauseWallpaper()
            }
            WallpaperSchedulerService.shared.setAutomaticSwitchPaused(!wasPaused)
        }
    }

    @objc private func toggleDynamicWallpaper() {
        if weBridge.isControllingExternalEngine {
            // 关闭外部引擎壁纸，但保留恢复记录，便于再次点击开启
            weBridge.disableWallpaperKeepingRestoreState()
            return
        }

        // macOS 26+：扩展控制模式下停止视频壁纸，但仍需保留 WE 恢复链
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            if videoWallpaperManager.isVideoWallpaperActive {
                videoWallpaperManager.stopWallpaper()
                return
            }
            // 视频壁纸未播放时，走正常恢复链（WE → 视频 → 静态 overlay）
        }

        if videoWallpaperManager.isVideoWallpaperActive {
            // 关闭动态壁纸
            videoWallpaperManager.stopWallpaper()
        } else {
            // 优先恢复实时渲染壁纸（WE 状态存在时跳过视频恢复，避免视频壁纸遗留状态抢占 WE 恢复机会）
            if weBridge.hasPersistedRestoreState() {
                Task { [weak self] in
                    guard let self else { return }
                    await self.weBridge.restoreIfNeeded()
                    if !self.weBridge.isControllingExternalEngine {
                        self.showWindowHandler?()
                    }
                }
            } else {
                videoWallpaperManager.restoreIfNeeded()
                if !videoWallpaperManager.isVideoWallpaperActive {
                    Task { [weak self] in
                        guard let self else { return }
                        await self.weBridge.restoreIfNeeded()
                        if !self.weBridge.isControllingExternalEngine {
                            self.showWindowHandler?()
                        }
                    }
                }
                // 动态壁纸均无可恢复状态时，尝试恢复静态图 overlay（sync 关闭场景）
                if !videoWallpaperManager.isVideoWallpaperActive
                    && !weBridge.hasPersistedRestoreState() {
                    StaticImageWallpaperOverlayManager.shared.restoreIfNeeded()
                }
            }
        }
    }

    @objc private func toggleMute() {
        // macOS 26+：扩展模式下静音对所有显示器生效（扩展不播放音频，但记录状态）
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            let newMuted = !videoWallpaperManager.isMuted
            videoWallpaperManager.setMuted(newMuted)
            // 同步到所有活跃显示器的 prefs
            for screen in NSScreen.screens {
                if let displayID = Self.cgDisplayID(for: screen) {
                    LockScreenWallpaperService.shared.setDisplayMuted(newMuted, forDisplayID: displayID)
                }
            }
            // 同步到 wallpaper-wgpu 渲染进程（音频控制文件）
            if weBridge.isControllingExternalEngine {
                weBridge.setMuted(newMuted)
            }
            return
        }

        let newMuted = !videoWallpaperManager.isMuted
        videoWallpaperManager.setMuted(newMuted)
        if weBridge.isControllingExternalEngine {
            weBridge.setMuted(newMuted)
        }
    }

    @objc private func toggleDesktopIcons() {
        DesktopIconManager.shared.toggle()
        refreshMenuState()
    }

    @objc private func openSceneConfigPanel() {
        guard let wallpaperPath = sceneConfigItem.representedObject as? String ?? weBridge.currentWallpaperPathForDesign else {
            NSSound.beep()
            return
        }
        presentEditorPopover { anchorView in
            WebPropertyEditorPanelController.shared.presentSceneConfig(for: wallpaperPath, from: anchorView)
        }
    }

    @objc private func openWebWallpaperDesignPanel() {
        if let sceneWallpaperPath = currentSceneDesignWallpaperPath() {
            presentEditorPopover { anchorView in
                WebPropertyEditorPanelController.shared.presentSceneDesign(for: sceneWallpaperPath, from: anchorView)
            }
            return
        }

        guard let wallpaperPath = weBridge.currentWallpaperPathForDesign else {
            NSSound.beep()
            return
        }
        if weBridge.isCurrentWallpaperWeb {
            presentEditorPopover { anchorView in
                WebPropertyEditorPanelController.shared.presentWeb(for: wallpaperPath, from: anchorView)
            }
            return
        }
        if weBridge.isCurrentWallpaperScene {
            // 实时渲染模式下，显示属性编辑面板；否则显示文本设计面板
            if UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled") {
                presentEditorPopover { anchorView in
                    WebPropertyEditorPanelController.shared.presentScene(for: wallpaperPath, from: anchorView)
                }
            } else {
                presentEditorPopover { anchorView in
                    WebPropertyEditorPanelController.shared.presentSceneDesign(for: wallpaperPath, from: anchorView)
                }
            }
            return
        }
        NSSound.beep()
    }

    private func presentEditorPopover(_ present: @escaping (NSView) -> Void) {
        guard let statusButton = statusItem.button else {
            NSSound.beep()
            return
        }
        // NSMenu is still tracking while its item's action runs. Presenting on
        // the next turn prevents it from immediately dismissing the popover.
        DispatchQueue.main.async {
            present(statusButton)
        }
    }

    private func currentSceneDesignWallpaperPath() -> String? {
        guard let videoURL = videoWallpaperManager.currentVideoURL,
              let info = WallpaperDynamicTextParser.loadSidecar(for: videoURL),
              info.hasDynamicText,
              let wallpaperPath = info.wallpaperPath,
              !wallpaperPath.isEmpty else {
            return nil
        }
        return wallpaperPath
    }

    @objc private func quitApplication() {
        quitHandler?()
    }

    /// 触发 Sparkle 检查更新（UI 反馈由 Sparkle 内置弹窗处理）
    @objc private func checkForUpdates() {
        AppDelegate.shared?.checkForUpdates()
    }

    /// 从 NSScreen 获取 CGDirectDisplayID（用于 per-display prefs 的 key）
    private static func cgDisplayID(for screen: NSScreen) -> UInt32? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return screenNumber.uint32Value
    }
}

// MARK: - NSMenuDelegate
extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
    }
}
