import SwiftUI

private enum WorkspaceSection: String, CaseIterable, Hashable, Identifiable {
    case devices
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .devices: "Devices"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .devices: "rectangle.connected.to.line.below"
        case .settings: "gearshape"
        }
    }
}

struct WorkspaceView: View {
    @State private var selection: WorkspaceSection? = .devices

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(WorkspaceSection.allCases) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.symbol)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Hidhogg")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            Group {
                switch selection {
                case .devices:
                    DevicesView()
                case .settings:
                    SettingsView()
                case nil:
                    ContentUnavailableView("Select a section", systemImage: "sidebar.left")
                }
            }
        }
        .tint(Color(red: 0.76, green: 0.57, blue: 0.27))
    }
}
