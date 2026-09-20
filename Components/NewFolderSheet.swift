import SwiftUI

struct NewFolderSheet: View {
    var title: String = t("new.folder")
    var confirmTitle: String = t("create")
    @Binding var folderName: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        GlassSheetShell(title: title, width: 360, contentPadding: 28) {
            VStack(spacing: 20) {
                TextField(t("folder.name.placeholder"), text: $folderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit {
                        onConfirm()
                    }

                HStack(spacing: 12) {
                    Button(t("cancel"), action: onCancel)
                        .buttonStyle(.borderless)

                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
