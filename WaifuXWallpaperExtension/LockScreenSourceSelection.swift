import Foundation

/// Per-display assignments take precedence over the legacy global source.
/// A missing display entry must never borrow another display's wallpaper.
enum LockScreenSourceSelection {
    enum Kind {
        case video
        case image
    }

    static func hasPerDisplayAssignments(
        videoPaths: [String: String]?,
        imagePaths: [String: String]?
    ) -> Bool {
        !(videoPaths?.isEmpty ?? true) || !(imagePaths?.isEmpty ?? true)
    }

    static func path(
        for kind: Kind,
        displayID: UInt32,
        videoPaths: [String: String]?,
        imagePaths: [String: String]?,
        legacyVideoPath: String?,
        legacyImagePath: String?
    ) -> String? {
        let key = "display-\(displayID)"
        let assigned = kind == .video ? videoPaths?[key] : imagePaths?[key]
        if let assigned, !assigned.isEmpty {
            return assigned
        }
        guard !hasPerDisplayAssignments(videoPaths: videoPaths, imagePaths: imagePaths) else {
            return nil
        }
        let legacy = kind == .video ? legacyVideoPath : legacyImagePath
        return legacy?.isEmpty == false ? legacy : nil
    }
}
