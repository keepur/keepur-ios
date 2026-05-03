import SwiftUI

struct BeekeeperRootView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Beekeeper", systemImage: KeepurTheme.Symbol.bolt)
        } description: {
            Text("Direct interaction with the Beekeeper backend is coming soon.")
        }
        .background(KeepurTheme.Color.bgPageDynamic)
        .navigationTitle("Beekeeper")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
