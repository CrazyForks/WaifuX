import CoreGraphics
import Foundation

// 屏保端可视区域调节支持。
//
// 与 `WaifuXWallpaperExtension/ExtensionCropSupport.swift` 同构：App 端
// (DisplayCropSettingsStore) 把每屏 crop 写进 App Group JSON
// (waifux-crop-prefs.json, key = "display-<displayID>")，屏保宿主在此读取并计算。
// 屏保不被沙盒约束，直接按路径读容器即可，不需要 entitlement。
//
// 类型字段与 App 端 Models/DisplayCropSettings.swift + Services/CropLayoutEngine.swift 保持一致，
// 因此 JSON 可以直接互通。

/// 归一化矩形（原点左上，y 向下）。
struct SaverUnitRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    static let full = SaverUnitRect(x: 0, y: 0, w: 1, h: 1)
}

enum SaverAspectPreset: String, Codable, CaseIterable {
    case autoFill, ratio16x9, ratio16x10, ratio21x9, ratio32x9, ratio4x3, ratio1x1, custom

    var aspectRatio: Double? {
        switch self {
        case .autoFill, .custom: return nil
        case .ratio16x9:  return 16.0 / 9.0
        case .ratio16x10: return 16.0 / 10.0
        case .ratio21x9:  return 21.0 / 9.0
        case .ratio32x9:  return 32.0 / 9.0
        case .ratio4x3:   return 4.0 / 3.0
        case .ratio1x1:   return 1.0
        }
    }
}

/// 单屏裁剪设置。字段名与 App 端 `DisplayCropSettings` 完全一致（含 `pan` 的 [x, y] 编码），
/// 因此同一份 JSON 既能来自屏保配置快照，也能来自 App Group 实时文件。
struct SaverCropSettings: Codable, Equatable {
    var aspectPreset: SaverAspectPreset = .autoFill
    var customAspect: Double? = nil
    var pan: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var zoom: Double = 1.0
    var letterboxColorHex: String = "000000"
    var isEnabled: Bool = true

    var effectiveAspect: Double? {
        switch aspectPreset {
        case .autoFill: return nil
        case .custom:
            guard let customAspect, customAspect.isFinite, customAspect > 0 else { return nil }
            return customAspect
        default: return aspectPreset.aspectRatio
        }
    }

    static let `default` = SaverCropSettings()
}

struct SaverCropLayout {
    var wallpaperCropRect: SaverUnitRect
    var viewportRect: SaverUnitRect
    var letterboxColor: CGColor
}

/// CALayer 坐标系中的裁切结果。`mediaFrame` 可以超出 rootLayer.bounds，
/// rootLayer 负责裁掉溢出部分，因此媒体层始终按原始比例渲染。
struct SaverLayerGeometry {
    var viewportRect: CGRect
    var mediaFrame: CGRect
}

enum SaverCropEngine {
    static func compute(
        wallpaperSize: CGSize,
        screenSize: CGSize,
        settings: SaverCropSettings
    ) -> SaverCropLayout {
        let letterboxColor = parseColorHex(settings.letterboxColorHex)
        guard settings.isEnabled else {
            return SaverCropLayout(wallpaperCropRect: .full, viewportRect: .full, letterboxColor: letterboxColor)
        }
        let screenAspect = screenSize.height > 0 ? screenSize.width / screenSize.height : 1.0
        let targetAspect = settings.effectiveAspect ?? screenAspect
        let viewport: SaverUnitRect
        if targetAspect > screenAspect {
            let h = screenAspect / targetAspect
            viewport = SaverUnitRect(x: 0, y: (1 - h) / 2, w: 1, h: h)
        } else {
            let w = targetAspect / screenAspect
            viewport = SaverUnitRect(x: (1 - w) / 2, y: 0, w: w, h: 1)
        }
        // 用像素几何而不是归一化比例：auto-fill 时 viewport.w / viewport.h 恒为 1，
        // 若拿它当目标比例，16:9 画面会被拉伸到 16:10 屏。
        let vpW = viewport.w * screenSize.width
        let vpH = viewport.h * screenSize.height
        let wpW = wallpaperSize.width
        let wpH = wallpaperSize.height
        let coverScale = max(
            wpW > 0 ? vpW / wpW : 1.0,
            wpH > 0 ? vpH / wpH : 1.0
        )
        let zoom = max(1.0, min(4.0, settings.zoom))
        let scale = coverScale * zoom
        let displayWidth = wpW * scale
        let displayHeight = wpH * scale
        let winW = displayWidth > 0 ? vpW / displayWidth : 1.0
        let winH = displayHeight > 0 ? vpH / displayHeight : 1.0
        let panX = max(0, min(1, settings.pan.x))
        let panY = max(0, min(1, settings.pan.y))
        let originX = max(0, min(1 - winW, panX - winW / 2))
        let originY = max(0, min(1 - winH, panY - winH / 2))
        return SaverCropLayout(
            wallpaperCropRect: SaverUnitRect(x: originX, y: originY, w: winW, h: winH),
            viewportRect: viewport,
            letterboxColor: letterboxColor)
    }

    static func parseColorHex(_ hex: String) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            return CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        return CGColor(red: CGFloat((v >> 16) & 0xFF) / 255.0,
                       green: CGFloat((v >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(v & 0xFF) / 255.0, alpha: 1)
    }
}

enum SaverCropGeometry {
    /// 把归一化 crop/viewport 转为 CALayer 几何。
    /// SaverUnitRect 使用左上原点，CALayer 使用左下原点，所以这里翻转 y。
    static func layerGeometry(layout: SaverCropLayout, in bounds: CGRect) -> SaverLayerGeometry {
        let viewport = layout.viewportRect
        let crop = layout.wallpaperCropRect
        let viewportRect = CGRect(
            x: viewport.x * bounds.width,
            y: (1 - viewport.y - viewport.h) * bounds.height,
            width: viewport.w * bounds.width,
            height: viewport.h * bounds.height
        )

        let cropWidth = max(crop.w, 0.0001)
        let cropHeight = max(crop.h, 0.0001)
        let mediaWidth = viewportRect.width / cropWidth
        let mediaHeight = viewportRect.height / cropHeight
        let mediaFrame = CGRect(
            x: viewportRect.minX - crop.x * mediaWidth,
            y: viewportRect.minY - (1 - crop.y - crop.h) * mediaHeight,
            width: mediaWidth,
            height: mediaHeight
        )
        return SaverLayerGeometry(viewportRect: viewportRect, mediaFrame: mediaFrame)
    }
}

/// 屏保端读取 App Group 里的实时 crop 配置。
/// 屏保进程没有沙盒，`containerURL(forSecurityApplicationGroupIdentifier:)` 拿不到容器，
/// 因此直接按 Group Containers 路径读取；文件不存在时返回 nil，由调用方回退到配置快照。
enum SaverSharedCropPrefs {
    private static let appGroupID = "group.com.waifux.app"
    private static let jsonName = "waifux-crop-prefs.json"

    static func settings(forDisplayKey key: String) -> SaverCropSettings? {
        guard let url = containerURL()?.appendingPathComponent(jsonName),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: SaverCropSettings].self, from: data) else {
            return nil
        }
        return dict[key]
    }

    static func containerURL() -> URL? {
        let home = SaverHomeDirectory.url
        let url = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

/// 屏保宿主可能在没有 App 环境的情况下启动，这里统一解析真实用户主目录。
enum SaverHomeDirectory {
    static var url: URL {
        if let record = getpwuid(getuid()), let path = String(validatingUTF8: record.pointee.pw_dir) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// 屏幕号 → crop 配置键。与 App 端 `NSScreen.wallpaperScreenIdentifier` 同源，
/// 都是 CGDirectDisplayID 的十进制字符串。
func saverDisplayKey(_ displayID: UInt32) -> String {
    "display-\(displayID)"
}
