import SwiftUI

struct SettingsView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Settings coming in Phase 20")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .navigationTitle("Settings")
    }
}

#Preview {
    SettingsView()
}
