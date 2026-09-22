import Foundation

/// Source-level regression guard for the sleep/wake + battery interaction.
/// The renderer can be replaced while a display is asleep; these checks keep
/// the recovery path from silently dropping an automatic pause or skipping the
/// paused renderer entirely.
@main
struct WakeBatteryRecoveryRegression {
    static func main() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let autoPause = read("Services/DynamicWallpaperAutoPauseManager.swift", root: root)
        let bridge = read("Services/WallpaperEngineXBridge.swift", root: root)
        let lockScreen = read("Services/LockScreenWallpaperService.swift", root: root)

        precondition(
            autoPause.contains("PowerSourceMonitor.shared.refreshState()")
                && autoPause.contains("applyGlobalPauseIfNeeded()"),
            "wake re-evaluation must refresh power state and reapply battery pause"
        )
        precondition(
            autoPause.contains("batteryPauseRequested = pauseOnBatteryPower")
                && autoPause.contains("PowerSourceMonitor.shared.isOnBatteryPower"),
            "a transient empty renderer set must not clear the battery pause fact"
        )
        precondition(
            bridge.contains("A paused screen still owns a renderer")
                && !bridge.contains("guard !isPaused(screenID: screenID),"),
            "wake recovery must rebuild paused renderers so stale Metal surfaces are replaced"
        )
        precondition(
            bridge.contains("if !preserveAutoPauseState")
                && bridge.contains("perScreenPausedScreenIDs.subtract(effectiveScreenIDs)"),
            "normal switches may clear pause state, wake recovery must preserve it"
        )
        precondition(
            lockScreen.contains("schedulePlaybackStateReconciliation(source: source)"),
            "dynamic lock screen must reconcile state after wake instead of trusting one notification"
        )

        print("Wake/battery recovery regression passed")
    }

    private static func read(_ path: String, root: URL) -> String {
        guard let content = try? String(
            contentsOf: root.appendingPathComponent(path),
            encoding: .utf8
        ) else {
            preconditionFailure("unable to read \(path)")
        }
        return content
    }
}
