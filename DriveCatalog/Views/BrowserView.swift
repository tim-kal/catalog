import SwiftUI

struct BrowserView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("File browser coming in Phase 16")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .navigationTitle("Browser")
    }
}

#Preview {
    BrowserView()
}
