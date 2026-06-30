//  Settings provider for WallpaperAgent.
//
//  为每个显示器创建固定的锁屏实例设置项。
//  用户在系统设置里手动为每块显示器选择一次实例，之后实例本地解码对应桌面视频。

import AppKit
import Foundation

// MARK: - Public API

/// 构建完整的壁纸设置项列表并返回 XPC 对象。
func buildSettingsViewModelsXPC() async -> AnyObject? {
    let bundleID = Bundle.main.bundleIdentifier ?? "com.waifux.app.wallpaperextension"
    let groupID = GroupID(id: "waifux-display-wallpapers")
    let instances = loadDisplayInstances()

    var items = [SettingsItem]()

    for instance in instances {
        let choiceID = ChoiceID(
            id: instance.id,
            descriptor: ChoiceIDDescriptor(
                provider: ChoiceProviderID(rawValue: bundleID),
                identifier: instance.id,
                files: [],
                configuration: Data(instance.id.utf8)
            )
        )

        // 缩略图优先使用该显示器最近一次桌面帧/海报生成的缩略图。
        let thumb: Thumbnail
        if let thumbURL = thumbnailURL(for: instance) {
            thumb = .image(url: thumbURL)
        } else {
            thumb = .image(url: URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarDisplay.icns"))
        }

        let choiceDescriptor = ChoiceDescriptor(
            id: choiceID,
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: instance.id,
            name: instance.name,
            localizedDescription: "WaifuX 锁屏镜像实例",
            thumbnail: thumb,
            isDownloaded: true,
            options: []
        )

        let item = SettingsItem(
            id: choiceID,
            localizedName: instance.name,
            thumbnail: thumb,
            choice: choiceDescriptor,
            contentBadge: .video,
            showInTopLevel: true,
            sortOrder: Int(instance.displayID),
            disposability: .none
        )
        items.append(item)
    }

    let group = SettingsGroup(
        id: groupID,
        items: items,
        localizedName: "WaifuX — 锁屏显示器实例",
        disposability: .none,
        sortOrder: -100,
        sortID: GroupSortID(id: "com.apple.wallpaper.aerials"),
        allChoiceID: nil,
        shouldHideItemLabels: false,
        contextMenu: nil,
        thumbnail: nil
    )

    let viewModel = SettingsViewModel(
        groups: [group],
        refreshPolicy: .default,
        isModificationDisabled: false
    )

    let viewModels = SettingsViewModels(
        desktop: viewModel,
        screenSaver: nil
    )

    return remapToRealXPC(viewModels)
}

/// 返回空分组，适用于扩展尚未准备好时充当 fallback。
func makeEmptyGroupsResponse() -> AnyObject? {
    let viewModels = SettingsViewModels(
        desktop: SettingsViewModel(
            groups: [],
            refreshPolicy: .default,
            isModificationDisabled: false
        ),
        screenSaver: nil
    )
    return remapToRealXPC(viewModels)
}

// MARK: - 缩略图路径

private struct DisplayInstanceRecord: Codable {
    let id: String
    let displayID: UInt32
    let name: String
    let thumbnailPath: String?
}

private func loadDisplayInstances() -> [DisplayInstanceRecord] {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
        return []
    }
    let url = container.appendingPathComponent("waifux-display-instances.json")
    guard let data = try? Data(contentsOf: url),
          let instances = try? JSONDecoder().decode([DisplayInstanceRecord].self, from: data) else {
        return []
    }
    return instances
}

/// App 将显示器实例缩略图写入共享容器，扩展从中读取。
private func thumbnailURL(for instance: DisplayInstanceRecord) -> URL? {
    guard let path = instance.thumbnailPath, !path.isEmpty else { return nil }
    let url = URL(fileURLWithPath: path)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}
