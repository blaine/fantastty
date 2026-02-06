import SwiftUI

struct SettingsView: View {
    @AppStorage("tabsInSidebar") private var tabsInSidebar = false

    var body: some View {
        Form {
            Section("Sidebar") {
                Toggle("Show tab thumbnails in sidebar", isOn: $tabsInSidebar)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize()
    }
}
