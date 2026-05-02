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
                    LazyVGrid(columns: columns, spacing: KeepurTheme.Spacing.s4) {
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
        .background(KeepurTheme.Color.bgPageDynamic)
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
        }
        .onChange(of: navigateToHive) { _, isActive in
            if !isActive {
                capabilityManager.selectedHive = nil
                teamViewModel.disconnect()
            }
        }
    }
}

private struct HiveCard: View {
    let name: String

    var body: some View {
        VStack(spacing: KeepurTheme.Spacing.s3) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 36))
                .foregroundStyle(KeepurTheme.Color.honey500)
            Text(name)
                .font(KeepurTheme.Font.h4)
                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(KeepurTheme.Color.bgSurfaceDynamic)
        .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.md))
        .keepurBorder(KeepurTheme.Color.borderDefaultDynamic, radius: KeepurTheme.Radius.md, width: 1)
    }
}
