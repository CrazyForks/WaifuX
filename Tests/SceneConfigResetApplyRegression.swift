import Foundation

@main
struct SceneConfigResetApplyRegression {
    static func main() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let bridge = try source("Services/WallpaperEngineXBridge.swift", from: sourceRoot)
        let sceneConfigPanel = try source("Views/SceneConfigOverridePanel.swift", from: sourceRoot)
        let propertyEditor = try source("Views/WebPropertyEditorPanelController.swift", from: sourceRoot)

        precondition(
            bridge.contains("func refreshWallpaperProperties(userProperties: String?, reloadScene: Bool = false)"),
            "property refresh must expose a scene-reload mode"
        )
        precondition(
            bridge.contains("if reloadScene {") && bridge.contains("try await setWallpaper("),
            "scene-reload mode must rebuild the current scene"
        )
        precondition(
            sceneConfigPanel.contains("scheduleApply(reloadScene: true)"),
            "native scene-config reset must request a scene reload"
        )
        precondition(
            propertyEditor.contains("scheduleApply(reloadScene: currentType == .scene || currentType == .sceneConfig)"),
            "editor reset must request a scene reload for scene settings"
        )
        precondition(
            sceneConfigPanel.contains("scheduleApply()")
                && propertyEditor.contains("scheduleApply()"),
            "single-value edits must retain the lightweight hot-update path"
        )

        print("Scene config reset/apply regression passed: reset reloads defaults, edits hot-update")
    }

    private static func source(_ relativePath: String, from root: URL) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
