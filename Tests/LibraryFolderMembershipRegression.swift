import Foundation

@main
struct LibraryFolderMembershipRegression {
    static func main() {
        let persistedFolderIDs: [String?] = [
            "folder-a",
            "folder-a",
            "folder-from-another-build",
            nil
        ]
        let validFolderIDs = Set(["folder-a"])

        let audit = LibraryFolderMembershipPolicy.audit(
            folderIDs: persistedFolderIDs,
            validFolderIDs: validFolderIDs
        )

        precondition(audit.invalidCount == 1)
        precondition(audit.invalidFolderIDs == Set(["folder-from-another-build"]))
        precondition(persistedFolderIDs[0] == "folder-a")
        precondition(persistedFolderIDs[2] == "folder-from-another-build")

        print("Library folder membership regression passed: invalid memberships are reported, not cleared")
    }
}
