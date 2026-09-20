import Foundation

/// 休眠唤醒 / 重启后多显示器自动切换配置（文件夹）互换的回归守卫。
///
/// 背景：displayConfigs 以 CGDirectDisplayID 为 key，唤醒/重启后该 ID 会被
/// 系统重新分配，relink 依赖持久化指纹找回旧配置。同型号无序列号显示器的
/// 指纹只差 `:position:XxY` 后缀，而 AppKit 原点相对当前主屏——主屏锚点
/// 一变，绝对坐标相等会把 A 屏配置精确命中到 B 屏上（用户反馈的两台显示器
/// 文件夹倒转/乱跳）。修复后：position 指纹只在同硬件唯一时参与精确匹配，
/// 其余走「组内相对次序」配对，且 relink 前必须等待排布两次采样一致。
@main
struct WakeDisplayRelinkRegression {
    static func main() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let identity = try source("Utilities/NSScreen+Wallpaper.swift", from: sourceRoot)
        let scheduler = try source("Services/WallpaperSchedulerService.swift", from: sourceRoot)
        let coordinator = try source("Services/ExternalDisplayConnectionCoordinator.swift", from: sourceRoot)

        precondition(
            identity.contains("static func position(fromFingerprint fingerprint: String) -> CGPoint?"),
            "fingerprint position suffix must be parseable"
        )
        precondition(
            identity.contains("static func pairByRelativeRank("),
            "same-hardware pairing must be rank-based, not absolute-coordinate-based"
        )

        precondition(
            scheduler.contains("private func resolveOrphanScreenIDs("),
            "orphan relink must go through the shared resolver"
        )
        precondition(
            scheduler.contains("if sameBaseIDs.count > 1 { return nil }"),
            "position fingerprints must not exactly match when multiple same-hardware screens are unclaimed"
        )
        precondition(
            scheduler.contains("guard orphanGroup.count == freeGroup.count, !orphanGroup.isEmpty else {"),
            "rank pairing must skip ambiguous hardware groups instead of blind-zipping"
        )
        precondition(
            scheduler.contains("private func awaitStableScreenArrangementThenProcess(generation: UInt64, attempt: Int)"),
            "screen-parameter changes must wait for a stable arrangement before relinking"
        )
        precondition(
            scheduler.contains("private var isScreenArrangementSettling = false"),
            "settling flag must gate UI-path migrations during the wake storm"
        )
        precondition(
            scheduler.contains("existingConfigScreenID(for: screen, allowPositionMatch: false)"),
            "settling-time resolutions must ignore position-suffix matches"
        )

        precondition(
            coordinator.contains("uniquingKeysWith:"),
            "external display snapshots must not trap on duplicate fingerprints"
        )

        print("Wake display relink regression passed: rank pairing + settle gate + safe snapshots")
    }

    private static func source(_ relativePath: String, from root: URL) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
