import Foundation

/// Non-destructive validation for persisted folder memberships.
///
/// Folder definitions and item records are stored independently. A missing or
/// temporarily incompatible folder list must never be treated as permission to
/// rewrite an item's persisted folderID.
enum LibraryFolderMembershipPolicy {
    struct Audit: Equatable {
        let invalidCount: Int
        let invalidFolderIDs: Set<String>
    }

    static func audit(
        folderIDs: [String?],
        validFolderIDs: Set<String>
    ) -> Audit {
        var invalidCount = 0
        var invalidIDs = Set<String>()

        for folderID in folderIDs {
            guard let folderID else { continue }
            guard validFolderIDs.contains(folderID) else {
                invalidCount += 1
                invalidIDs.insert(folderID)
                continue
            }
        }

        return Audit(
            invalidCount: invalidCount,
            invalidFolderIDs: invalidIDs
        )
    }
}
