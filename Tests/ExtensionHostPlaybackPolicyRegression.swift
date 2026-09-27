import Foundation

@main
struct ExtensionHostPlaybackPolicyRegression {
    static func main() {
        let appManagedDesktop = PlaybackPolicy.compute(
            presentationMode: "active",
            activityState: "active",
            userPaused: false,
            alwaysPauseDesktop: true,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: .nominal,
            isOnBattery: false,
            batteryLevel: 100,
            isGameModeActive: false,
            displayBrightness: 1.0
        )
        precondition(appManagedDesktop == .paused)

        let extensionOwnedDesktop = PlaybackPolicy.compute(
            presentationMode: "active",
            activityState: "active",
            userPaused: false,
            alwaysPauseDesktop: false,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: .nominal,
            isOnBattery: false,
            batteryLevel: 100,
            isGameModeActive: false,
            displayBrightness: 1.0
        )
        precondition(extensionOwnedDesktop == .full)

        let lockedWallpaper = PlaybackPolicy.compute(
            presentationMode: "locked",
            activityState: "active",
            userPaused: false,
            alwaysPauseDesktop: true,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: .nominal,
            isOnBattery: false,
            batteryLevel: 100,
            isGameModeActive: false,
            displayBrightness: 1.0
        )
        precondition(lockedWallpaper == .full)

        // WallpaperAgent may update the covered desktop instance immediately
        // after the lock-screen instance. That update must not pause the lock.
        let modeAfterDesktopUpdate = PlaybackPolicy.effectivePresentationMode(
            agentMode: "default", isScreenLocked: true, hostUnavailable: false
        )
        precondition(modeAfterDesktopUpdate == "locked")
        let policyAfterDesktopUpdate = PlaybackPolicy.compute(
            presentationMode: modeAfterDesktopUpdate,
            activityState: "active",
            userPaused: false,
            alwaysPauseDesktop: true,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: .nominal,
            isOnBattery: false,
            batteryLevel: 100,
            isGameModeActive: false,
            displayBrightness: 1.0
        )
        precondition(policyAfterDesktopUpdate == .full)
        precondition(PlaybackPolicy.effectivePresentationMode(
            agentMode: "default", isScreenLocked: false, hostUnavailable: false
        ) == "default")
        precondition(PlaybackPolicy.effectivePresentationMode(
            agentMode: "locked", isScreenLocked: false, hostUnavailable: false
        ) == "default")
        precondition(PlaybackPolicy.effectivePresentationMode(
            agentMode: "idle", isScreenLocked: false, hostUnavailable: true
        ) == "active")

        print("Extension host playback policy regression passed")
    }
}
