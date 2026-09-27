import Foundation

@main
struct LockScreenMultiDisplaySourceRegression {
    static func main() throws {
        let videos = ["display-101": "/cache/left.mp4", "display-202": "/cache/right.mp4"]
        precondition(resolve(.video, 101, videos, nil, "/cache/right.mp4", nil) == "/cache/left.mp4")
        precondition(resolve(.video, 202, videos, nil, "/cache/right.mp4", nil) == "/cache/right.mp4")
        precondition(resolve(.video, 303, videos, nil, "/cache/right.mp4", nil) == nil,
                     "An unassigned display must not borrow the last global video")

        let mixedVideos = ["display-202": "/cache/right.mp4"]
        let mixedImages = ["display-101": "/cache/left.jpg"]
        precondition(resolve(.video, 101, mixedVideos, mixedImages, "/cache/right.mp4", nil) == nil,
                     "A display assigned an image must not play another display's video")
        precondition(resolve(.image, 101, mixedVideos, mixedImages, "/cache/right.mp4", nil) == "/cache/left.jpg")
        precondition(resolve(.image, 202, mixedVideos, mixedImages, nil, "/cache/left.jpg") == nil,
                     "A display assigned a video must not borrow the global image")
        precondition(resolve(.video, 303, mixedVideos, mixedImages, "/cache/right.mp4", "/cache/left.jpg") == nil)
        precondition(resolve(.image, 303, mixedVideos, mixedImages, "/cache/right.mp4", "/cache/left.jpg") == nil)

        precondition(resolve(.video, 101, nil, nil, "/legacy/video.mp4", nil) == "/legacy/video.mp4")
        precondition(resolve(.image, 101, [:], [:], nil, "/legacy/image.jpg") == "/legacy/image.jpg")

        // Guard the desktop sync entry point: its legacy videoURL(for:) accessor
        // falls back to currentVideoURL and assigned an active video to every screen.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let manager = try String(contentsOf: root.appendingPathComponent("Services/VideoWallpaperManager.swift"), encoding: .utf8)
        guard let start = manager.range(of: "private func syncAllDisplayVideosToExtension()"),
              let end = manager.range(of: "func syncCurrentVideosToActiveLockScreenPipeline", range: start.upperBound..<manager.endIndex) else {
            preconditionFailure("Cannot locate desktop lock-screen sync")
        }
        let sync = manager[start.lowerBound..<end.lowerBound]
        precondition(sync.contains("assignedVideoURL(for: screen)"),
                     "Desktop sync must use only explicit per-display video assignments")
        precondition(sync.contains("NSScreen.screens.count == 1"),
                     "The legacy global video fallback must be limited to one display")
        precondition(sync.contains("clearVideoCommands()"),
                     "Video resync must preserve other displays' pending image switches")

        let handler = try String(contentsOf: root.appendingPathComponent("WaifuXWallpaperExtension/WallpaperXPCHandler.swift"), encoding: .utf8)
        precondition(handler.contains("displayID = Self.requestDisplayGeometry(from: request).displayID"))
        precondition(handler.contains("displayID == nil, NSScreen.screens.count == 1"))
        precondition(!handler.contains("choiceConfiguration 为 nil，回退使用 currentVideoID"),
                     "An acquire must not inherit another display's last selected instance")

        print("PASS: LockScreenMultiDisplaySourceRegression")
    }

    private static func resolve(
        _ kind: LockScreenSourceSelection.Kind,
        _ displayID: UInt32,
        _ videoPaths: [String: String]?,
        _ imagePaths: [String: String]?,
        _ legacyVideoPath: String?,
        _ legacyImagePath: String?
    ) -> String? {
        LockScreenSourceSelection.path(
            for: kind,
            displayID: displayID,
            videoPaths: videoPaths,
            imagePaths: imagePaths,
            legacyVideoPath: legacyVideoPath,
            legacyImagePath: legacyImagePath
        )
    }
}
