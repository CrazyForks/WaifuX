import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation

/// 屏保集成。
///
/// 结构对齐 MirageWallpaper 的 `ScreenSaverManager`：
/// - 组件安装在 `~/Library/Screen Savers/WaifuXScreenSaver.saver`（系统只从该目录加载用户屏保）；
/// - 配置写在 `~/Library/Application Support/WaifuX/screensaver.json`，屏保自己读，主程序不必常驻；
/// - 替换组件前后终止系统屏保宿主进程，否则旧二进制会一直留在内存里。
///
/// 与 Mirage 的差异：Scene / Web 壁纸不做屏保内实时渲染，统一走已有离线烘焙产物，
/// 因此屏保端只需要 AVPlayer（见 `WaifuXScreenSaver/`）。
@MainActor
final class ScreenSaverService: ObservableObject {

    static let shared = ScreenSaverService()

    /// 与 `WaifuXScreenSaver/SaverConfiguration.swift` 的 `supportedVersion` 保持一致。
    static let configurationVersion = 1
    static let saverBundleName = "WaifuXScreenSaver.saver"
    static let saverExecutableName = "WaifuXScreenSaver"
    static let saverBundleIdentifier = "com.waifux.app.screensaver"
    /// 配置写入后广播，让正在运行的屏保热重载。
    static let configurationChangedNotification = Notification.Name("com.waifux.app.screensaver.configurationChanged")

    enum ScreenSaverError: LocalizedError {
        case bundledComponentMissing
        case mediaMissing(String)
        case invalidBundle
        case installationVerificationFailed
        case screenSaverHostDidNotTerminate
        case noDesktopWallpaper

        var errorDescription: String? {
            switch self {
            case .bundledComponentMissing:
                return t("screensaver.error.bundledMissing")
            case .mediaMissing(let name):
                return String(format: t("screensaver.error.mediaMissing"), name)
            case .invalidBundle:
                return t("screensaver.error.invalidBundle")
            case .installationVerificationFailed:
                return t("screensaver.error.verifyFailed")
            case .screenSaverHostDidNotTerminate:
                return t("screensaver.error.hostNotTerminated")
            case .noDesktopWallpaper:
                return t("screensaver.error.noDesktop")
            }
        }
    }

    /// 可以作为屏保的壁纸。
    struct Candidate: Identifiable, Hashable {
        enum Kind: String, Hashable {
            case video
            case scene
            case web
            case image

            /// 屏保侧的渲染介质：只有静图走静态显示，其余都播烘焙/原始视频。
            var isStillImage: Bool { self == .image }
        }

        let id: String
        let title: String
        let kind: Kind
        /// 屏保真正渲染的文件。
        let renderURL: URL
        /// 源文件 / 工程目录，仅用于展示与日志。
        let sourceURL: URL
    }

    /// 暂不可用的壁纸（用于在设置页说明原因）。
    struct UnavailableItem: Identifiable, Hashable {
        let id: String
        let title: String
        let reason: String
    }

    /// 单张下载记录的屏保资格判定结果。
    enum Resolution {
        case ready(Candidate)
        case unavailable(UnavailableItem)
    }

    @Published private(set) var configuredItemID: String?
    @Published private(set) var configuredTitle: String?
    /// 组件是否已装在 `~/Library/Screen Savers`。
    @Published private(set) var isInstalled: Bool = false

    private let fm = FileManager.default
    private var cancellables = Set<AnyCancellable>()

    private init() {
        isInstalled = fm.fileExists(atPath: installedURL.path)
        refreshConfiguredState()
        installFollowObservers()
    }

    // MARK: - 跟随桌面壁纸

    /// 与动态锁屏同语义：安装组件后屏保**自动跟随当前桌面壁纸**，
    /// 不需要在设置里单独挑一张。观察桌面壁纸变化与烘焙产物落库两个信号。
    private func installFollowObservers() {
        // CurrentWallpaperService 聚合了视频 / Scene / Web / 静图四条管线的活跃路径
        CurrentWallpaperService.shared.$activeFilePaths
            .receive(on: DispatchQueue.main)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.syncFromDesktop(reason: "wallpaperChanged")
            }
            .store(in: &cancellables)

        // Scene / Web 的离线烘焙（含实时伴生烘焙）完成后会更新下载记录，
        // 此时屏保才能从"上一个可用壁纸"切到烘焙 MP4，所以监听记录变化再同步一次。
        MediaLibraryService.shared.$downloadRecords
            .receive(on: DispatchQueue.main)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.syncFromDesktop(reason: "libraryChanged")
            }
            .store(in: &cancellables)
    }

    /// 把屏保配置同步为当前桌面壁纸。桌面壁纸变化、烘焙产物落库、App 启动、组件安装时调用。
    /// 当前壁纸不可用作屏保（Scene/Web 未烘焙、文件丢失）时保留上一个可用配置，屏保不至于黑屏。
    @discardableResult
    func syncFromDesktop(reason: String, force: Bool = false) -> Bool {
        guard let candidate = desktopCandidate() else {
            print("[ScreenSaverService] 当前没有可用作屏保的桌面壁纸 (\(reason))，保留现有配置")
            return false
        }
        if !force, isConfigured(as: candidate) { return true }
        do {
            try apply(candidate)
            print("[ScreenSaverService] 屏保已跟随桌面壁纸 (\(reason)): \(candidate.title)")
            return true
        } catch {
            print("[ScreenSaverService] 屏保同步失败 (\(reason)): \(error.localizedDescription)")
            return false
        }
    }

    /// 设置页「立即同步」：强制重写配置，用于修复被手动改动/损坏的 screensaver.json。
    func syncNow() throws {
        guard let candidate = desktopCandidate() else {
            throw ScreenSaverError.noDesktopWallpaper
        }
        try apply(candidate)
    }

    /// 当前桌面壁纸 → 屏保候选。主屏优先，其次任意活跃屏。
    func desktopCandidate() -> Candidate? {
        var paths: [String] = []
        if let mainURL = CurrentWallpaperService.shared.activeURL(for: String(CGMainDisplayID())) {
            paths.append(mainURL.path)
        }
        paths.append(contentsOf: CurrentWallpaperService.shared.activeFilePaths.sorted())
        if let videoURL = VideoWallpaperManager.shared.currentVideoURL {
            paths.append(videoURL.path)
        }
        if let wePath = WallpaperEngineXBridge.shared.currentWallpaperPathForDesign {
            paths.append(wePath)
        }
        for path in paths {
            if let candidate = resolveCandidate(fromDesktopPath: path) { return candidate }
        }
        return nil
    }

    /// 桌面活跃路径 → Candidate：
    /// ① 命中下载记录（精确/父子目录）→ 走 record 解析（scene/web 用烘焙产物）；
    /// ② 路径本身是某条记录的烘焙产物（桌面正在播烘焙 MP4）→ 同样走 record；
    /// ③ 库外裸文件 → 视频/静图直接可用；库外工程目录（无烘焙）无法离屏渲染，放弃。
    private func resolveCandidate(fromDesktopPath path: String) -> Candidate? {
        if let record = Self.downloadRecord(matchingPath: path) {
            if case .ready(let candidate) = candidate(from: record) { return candidate }
            // 记录在库但暂不可用（如 Scene 未烘焙）：返回 nil 保留现有配置，等烘焙完成后自动再同步
            return nil
        }
        if let record = MediaLibraryService.shared.downloadRecords.first(
            where: { $0.sceneBakeArtifact?.videoPath == path }) {
            if case .ready(let candidate) = candidate(from: record) { return candidate }
            return nil
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        let url = URL(fileURLWithPath: path)
        let kind: Candidate.Kind
        if Self.videoExtensions.contains(ext) { kind = .video }
        else if Self.imageExtensions.contains(ext) { kind = .image }
        else { return nil }
        return Candidate(id: "desktop:\(path)",
                         title: url.deletingPathExtension().lastPathComponent,
                         kind: kind, renderURL: url, sourceURL: url)
    }

    /// 已写入的配置是否就是这张。命中则跳过重写，避免每次壁纸信号都打断屏保。
    private func isConfigured(as candidate: Candidate) -> Bool {
        guard let data = try? Data(contentsOf: configurationURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? Int) == Self.configurationVersion else { return false }
        return (object["itemID"] as? String) == candidate.id
            && (object["renderPath"] as? String) == candidate.renderURL.path
    }

    // MARK: - 路径

    var installedURL: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers", isDirectory: true)
            .appendingPathComponent(Self.saverBundleName)
    }

    var configurationURL: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WaifuX", isDirectory: true)
            .appendingPathComponent("screensaver.json")
    }

    /// App 内随包分发的屏保组件（由 project.yml 的 Run Script 放进资源目录）。
    var bundledSaverURL: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Screen Savers/\(Self.saverBundleName)"),
            Bundle.main.resourceURL?.appendingPathComponent(Self.saverBundleName),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/Screen Savers", isDirectory: true)
                .appendingPathComponent(Self.saverBundleName)
        ]
        return candidates.compactMap { $0 }.first { fm.fileExists(atPath: $0.path) }
    }

    // MARK: - 安装

    func install() throws {
        guard let bundledURL = bundledSaverURL else { throw ScreenSaverError.bundledComponentMissing }
        let directory = installedURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let stagingURL = directory.appendingPathComponent(".\(UUID().uuidString).saver")
        defer { try? fm.removeItem(at: stagingURL) }
        try fm.copyItem(at: bundledURL, to: stagingURL)
        let expectedFingerprint = try fingerprint(of: stagingURL)

        // ScreenSaverEngine / legacyScreenSaver 会把已加载的 bundle 与二进制留在内存里，
        // 即使磁盘上已经换掉。先停掉宿主，再原子替换，下一次预览/激活才会加载新代码。
        try terminateScreenSaverHosts()

        if fm.fileExists(atPath: installedURL.path) {
            _ = try fm.replaceItemAt(installedURL, withItemAt: stagingURL)
        } else {
            try fm.moveItem(at: stagingURL, to: installedURL)
        }
        guard try fingerprint(of: installedURL) == expectedFingerprint else {
            throw ScreenSaverError.installationVerificationFailed
        }

        // 替换完成后可能已有宿主被系统拉起并映射了新二进制，这里再停一次，
        // 保证下一次启动的宿主一定加载完整的新组件。
        try terminateScreenSaverHosts()
        isInstalled = true
        // 开启即跟随：装好立刻把当前桌面壁纸写成屏保配置，激活屏保就能看到
        syncFromDesktop(reason: "install")
    }

    func uninstall() throws {
        if fm.fileExists(atPath: installedURL.path) {
            try fm.removeItem(at: installedURL)
        }
        try terminateScreenSaverHosts()
        isInstalled = false
    }

    /// App 升级（或开发期重编）后同步已安装组件。.saver 是从 App 包里拷出去的，
    /// 只替换 App 不会更新用户目录里的那份；版本号在开发期不变，
    /// 所以像 Mirage 一样比对组件指纹（Info.plist + 可执行文件 + CodeResources）而不是版本号。
    func refreshInstalledVersionIfNeeded() {
        isInstalled = fm.fileExists(atPath: installedURL.path)
        guard isInstalled, let bundledURL = bundledSaverURL else { return }
        let needsRefresh: Bool = {
            guard let installedFingerprint = try? fingerprint(of: installedURL),
                  let bundledFingerprint = try? fingerprint(of: bundledURL) else {
                // 指纹算不出来（组件损坏/被删）时按版本号兜底判断
                let installedBuild = Bundle(url: installedURL)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                let bundledBuild = Bundle(url: bundledURL)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                return installedBuild != bundledBuild
            }
            return installedFingerprint != bundledFingerprint
        }()
        guard needsRefresh else { return }
        do {
            try install()
            let build = Bundle(url: bundledURL)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            print("[ScreenSaverService] 已安装的屏保组件已刷新到最新构建 \(build)")
        } catch {
            print("[ScreenSaverService] 更新已安装屏保组件失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 配置

    /// 把一张壁纸写成屏保配置。屏保立即热重载；未安装组件时也会写，
    /// 用户之后安装组件即生效。
    func apply(_ candidate: Candidate) throws {
        guard fm.fileExists(atPath: candidate.renderURL.path) else {
            throw ScreenSaverError.mediaMissing(candidate.title)
        }
        var object: [String: Any] = [
            "version": Self.configurationVersion,
            "configuredAt": Date().timeIntervalSince1970,
            "itemID": candidate.id,
            "title": candidate.title,
            "kind": candidate.kind.isStillImage ? "image" : "video",
            "sourceKind": candidate.kind.rawValue,
            "sourcePath": candidate.sourceURL.path,
            "renderPath": candidate.renderURL.path,
            "fps": Self.animationFrameRate,
            "muted": true,
            "playbackRate": 1.0,
            "enableHDRVideo": false,
            "language": LocalizationService.shared.currentLanguage.rawValue
        ]
        object["cropByDisplay"] = try cropPayload()
        if let defaultKey = Self.mainDisplayCropKey() {
            object["defaultCropDisplayKey"] = defaultKey
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            throw ScreenSaverError.installationVerificationFailed
        }
        try fm.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configurationURL, options: .atomic)
        refreshConfiguredState()
        notifyConfigurationChanged()
    }

    /// 实时裁剪由 App Group 的 waifux-crop-prefs.json 承担（屏保按秒轮询），
    /// 这里只保留写入配置时的快照作为兜底，所以不需要额外的同步队列。
    func refreshConfiguredState() {
        guard let data = try? Data(contentsOf: configurationURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? Int) == Self.configurationVersion else {
            configuredItemID = nil
            configuredTitle = nil
            return
        }
        configuredItemID = object["itemID"] as? String
        configuredTitle = object["title"] as? String
    }

    private func notifyConfigurationChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.configurationChangedNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// 屏保端动画回调频率。视频由 AVPlayer 自己驱动，
    /// 这个值只决定裁剪热更新的轮询粒度，所以固定 30 即可。
    private static let animationFrameRate = 30

    private func cropPayload() throws -> [String: Any] {
        var dict: [String: DisplayCropSettings] = [:]
        for (screenID, settings) in DisplayCropSettingsStore.shared.settingsByScreen {
            // screenID 就是 CGDirectDisplayID 的十进制字符串；fallback 格式的屏扩展/屏保都读不到，跳过。
            guard UInt32(screenID) != nil else { continue }
            dict["display-\(screenID)"] = settings
        }
        guard !dict.isEmpty else { return [:] }
        let data = try JSONEncoder().encode(dict)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func mainDisplayCropKey() -> String? {
        let displayID = CGMainDisplayID()
        return displayID != 0 ? "display-\(displayID)" : nil
    }

    // MARK: - 候选壁纸

    func candidate(from record: MediaDownloadRecord) -> Resolution {
        let title = record.item.title
        let localURL = record.localFileURL
        guard fm.fileExists(atPath: localURL.path) else {
            return .unavailable(UnavailableItem(id: record.id, title: title, reason: t("screensaver.unavailable.missing")))
        }

        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
        if !isDirectory.boolValue {
            let ext = localURL.pathExtension.lowercased()
            if Self.videoExtensions.contains(ext) {
                return .ready(Candidate(id: record.id, title: title, kind: .video,
                                        renderURL: localURL, sourceURL: localURL))
            }
            if Self.imageExtensions.contains(ext) {
                return .ready(Candidate(id: record.id, title: title, kind: .image,
                                        renderURL: localURL, sourceURL: localURL))
            }
            return .unavailable(UnavailableItem(id: record.id, title: title, reason: t("screensaver.unavailable.unsupported")))
        }

        // Workshop 工程目录：按 project.json 的 type 分流。
        let projectRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: localURL)
        let projectType = Self.projectType(at: projectRoot)
        switch projectType {
        case "scene", "web":
            let kind: Candidate.Kind = projectType == "web" ? .web : .scene
            guard let artifact = SceneOfflineBakeService.usableArtifact(from: record),
                  SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: artifact.videoPath)) else {
                return .unavailable(UnavailableItem(id: record.id, title: title, reason: t("screensaver.unavailable.needsBake")))
            }
            let bakedURL = URL(fileURLWithPath: artifact.videoPath)
            return .ready(Candidate(id: record.id, title: title, kind: kind,
                                    renderURL: bakedURL, sourceURL: projectRoot))
        case "video":
            guard let videoURL = record.resolvedVideoFileURL else {
                return .unavailable(UnavailableItem(id: record.id, title: title, reason: t("screensaver.unavailable.missing")))
            }
            return .ready(Candidate(id: record.id, title: title, kind: .video,
                                    renderURL: videoURL, sourceURL: projectRoot))
        default:
            if let imageURL = Self.backgroundImageURL(in: projectRoot) {
                return .ready(Candidate(id: record.id, title: title, kind: .image,
                                        renderURL: imageURL, sourceURL: projectRoot))
            }
            return .unavailable(UnavailableItem(id: record.id, title: title, reason: t("screensaver.unavailable.unsupported")))
        }
    }

    /// 精确匹配 → 父子目录匹配（工程目录 vs 目录内视频文件）。
    private static func downloadRecord(matchingPath path: String) -> MediaDownloadRecord? {
        if let exact = MediaLibraryService.shared.downloadRecord(forLocalFilePath: path) {
            return exact
        }
        let standardized = (path as NSString).standardizingPath
        var bestMatch: MediaDownloadRecord?
        for record in MediaLibraryService.shared.downloadRecords {
            let recorded = (record.localFilePath as NSString).standardizingPath
            if standardized.hasPrefix(recorded + "/") || recorded.hasPrefix(standardized + "/") {
                // 取路径最长（最具体）的那条，避免外层下载根目录抢匹配。
                if bestMatch == nil || recorded.count > (bestMatch!.localFilePath as NSString).standardizingPath.count {
                    bestMatch = record
                }
            }
        }
        return bestMatch
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "avi", "mkv"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "gif", "webp", "tga", "tif", "tiff"]

    private static func projectType(at contentRoot: URL) -> String? {
        let projectURL = contentRoot.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        return type.lowercased()
    }

    /// 无 type 字段的静图壁纸：project.json 的 background 指向的真实图片文件。
    private static func backgroundImageURL(in contentRoot: URL) -> URL? {
        let projectURL = contentRoot.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let background = json["background"] as? String else { return nil }
        let url = contentRoot.appendingPathComponent(background)
        guard imageExtensions.contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - 组件校验与宿主进程

    private func fingerprint(of saverURL: URL) throws -> String {
        guard let bundle = Bundle(url: saverURL),
              bundle.bundleIdentifier == Self.saverBundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String != nil else {
            throw ScreenSaverError.invalidBundle
        }
        var hasher = SHA256()
        let paths = ["Contents/Info.plist", "Contents/MacOS/\(Self.saverExecutableName)"]
        for relativePath in paths {
            let fileURL = saverURL.appendingPathComponent(relativePath)
            guard fm.isReadableFile(atPath: fileURL.path) else { throw ScreenSaverError.invalidBundle }
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: try Data(contentsOf: fileURL, options: [.mappedIfSafe]))
        }
        let codeResourcesPath = "Contents/_CodeSignature/CodeResources"
        let codeResourcesURL = saverURL.appendingPathComponent(codeResourcesPath)
        if fm.isReadableFile(atPath: codeResourcesURL.path) {
            hasher.update(data: Data(codeResourcesPath.utf8))
            hasher.update(data: try Data(contentsOf: codeResourcesURL, options: [.mappedIfSafe]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 只终止系统屏保宿主。这里刻意不重启 `com.apple.wallpaper.agent`：
    /// 本仓库的壁纸扩展由该 agent 托管，重启它会让扩展实例被回收且不保证立刻重新拉载
    /// （见 AGENTS.md「macOS 27 扩展 reload 自杀陷阱」）。
    private func terminateScreenSaverHosts() throws {
        let identifiers = [
            "com.apple.ScreenSaver.Engine",
            "com.apple.ScreenSaver.Engine.legacyScreenSaver"
        ]
        let running = identifiers.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }
        guard !running.isEmpty else { return }

        running.forEach { _ = $0.terminate() }
        if waitForTermination(of: running, timeout: 2) { return }
        running.filter { !hasExited($0) }.forEach {
            if !$0.forceTerminate() {
                _ = Darwin.kill($0.processIdentifier, SIGKILL)
            }
        }
        guard waitForTermination(of: running, timeout: 2) else {
            throw ScreenSaverError.screenSaverHostDidNotTerminate
        }
    }

    private func waitForTermination(of applications: [NSRunningApplication], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if applications.allSatisfy(hasExited) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return applications.allSatisfy(hasExited)
    }

    private func hasExited(_ application: NSRunningApplication) -> Bool {
        if application.isTerminated { return true }
        guard application.processIdentifier > 0 else { return true }
        return Darwin.kill(application.processIdentifier, 0) == -1 && errno == ESRCH
    }

    // MARK: - 系统设置

    func openSystemSettings() {
        // macOS 14 起「屏保」是墙纸设置里的一个区块，独立 ScreenSaver 面板会跳错页。
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
