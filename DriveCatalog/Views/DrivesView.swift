import SwiftUI

struct DrivesView: View {
    var body: some View {
        NavigationStack {
            DriveListView()
                .navigationTitle("Drives")
        }
    }
}

#Preview {
    DrivesView()
}
