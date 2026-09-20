//  系统壁纸选择权威探测
//
//  递归扫描 ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist，
//  判断用户是否在系统设置中选择了我们的壁纸扩展实例（Provider == 扩展 bundleID）。
//  此前 App 只能靠扩展 state 的 isActive 行为推断"用户已选择"，扩展未拉载时
//  无法区分「没选过」和「选了但扩展没启动」。
//
//  只读访问，永不写入该文件（与 WallpaperSystemCacheJanitor 的禁令一致）。
//  参考 Mirage (GPL-3.0) 的 WallpaperExtensionController.selectionState()。
//
//  本文件保持自包含（仅 Foundation），供回归脚本单独编译。

import Foundation

enum WallpaperStoreSelectionProbe {
    enum Selection: Equatable {
        case selected
        case notSelected
        case unknown
    }

    static let extensionBundleID = "com.waifux.app.wallpaperextension"

    static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedResult: (mtime: Date, selection: Selection)?

    /// 探测当前选择状态。按文件 mtime 缓存，避免设置页高频刷新反复解析 plist。
    static func currentSelection() -> Selection {
        let url = storeURL
        guard FileManager.default.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let mtime = values.contentModificationDate else {
            // 文件不存在或不可读：macOS < 14 或沙箱不可见 → 未知，不做行为推断
            return .unknown
        }
        cacheLock.lock()
        if let cached = cachedResult, cached.mtime == mtime {
            cacheLock.unlock()
            return cached.selection
        }
        cacheLock.unlock()

        let selection = selectionState(at: url)
        cacheLock.lock()
        cachedResult = (mtime, selection)
        cacheLock.unlock()
        return selection
    }

    /// 读取并判定指定 store 文件。根结构缺 Displays/Spaces/SystemDefault 视为 unknown
    /// （系统版本升级后结构变化时宁可报未知，不做误判）。
    static func selectionState(at url: URL) -> Selection {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return .unknown }
        return selectionState(root: root)
    }

    static func selectionState(root: Any) -> Selection {
        guard let dictionary = root as? [String: Any],
              ["Displays", "Spaces", "SystemDefault"].contains(where: { dictionary[$0] != nil })
        else { return .unknown }
        return containsProvider(root, identifier: extensionBundleID) ? .selected : .notSelected
    }

    /// 递归查找任意层级的 Provider 字段等于 identifier 的 choice。
    /// 结构随系统版本变化，因此只认字段名不认路径。
    static func containsProvider(_ value: Any, identifier: String) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary["Provider"] as? String == identifier { return true }
            return dictionary.values.contains { containsProvider($0, identifier: identifier) }
        }
        if let array = value as? [Any] {
            return array.contains { containsProvider($0, identifier: identifier) }
        }
        return false
    }
}
