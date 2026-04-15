import SwiftUI

struct HivesGridView: View {
    @ObservedObject var capabilityManager: CapabilityManager
    @ObservedObject var teamViewModel: TeamViewModel
    @State private var navigateToHive = false

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        Group {
            if capabilityManager.hives.isEmpty {
                ContentUnavailableView {
                    Label("No hives available", systemImage: "hexagon")
                } description: {
                    Text("Pull to refresh.")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(capabilityManager.hives, id: \.self) { hive in
                            Button {
                                capabilityManager.selectedHive = hive
                                teamViewModel.connectIfPossible()
                                navigateToHive = true
                            } label: {
                                HiveCard(name: hive)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Hives")
        .refreshable {
            await capabilityManager.refresh()
        }
        .task {
            await capabilityManager.refresh()
            if let last = capabilityManager.selectedHive,
               capabilityManager.hives.contains(last) {
                teamViewModel.connectIfPossible()
                navigateToHive = true
            }
        }
        .navigationDestination(isPresented: $navigateToHive) {
            TeamRootView(viewModel: teamViewModel, capabilityManager: capabilityManager)
                .onDisappear {
                    capabilityManager.selectedHive = nil
                    teamViewModel.disconnect()
                }
        }
    }
}

private struct HiveCard: View {
    let name: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            Text(name)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
