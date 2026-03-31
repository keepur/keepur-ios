import SwiftUI
import SwiftData

struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workspace.lastUsed, order: .reverse) private var savedWorkspaces: [Workspace]

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.ws.isConnected ? .green : .red)
                                .frame(width: 8, height: 8)
                            Text(viewModel.ws.isConnected ? "Connected" : "Disconnected")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let sessionId = viewModel.currentSessionId {
                        HStack {
                            Text("Session")
                            Spacer()
                            Text(String(sessionId.prefix(8)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !savedWorkspaces.isEmpty {
                    Section("Saved Workspaces") {
                        ForEach(savedWorkspaces, id: \.path) { workspace in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace.displayName)
                                        .font(.body)
                                    Text(workspace.path)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text(workspace.lastUsed, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                modelContext.delete(savedWorkspaces[index])
                            }
                            try? modelContext.save()
                        }
                    }
                }

                Section {
                    Button(viewModel.ws.isConnected ? "Disconnect" : "Reconnect") {
                        if viewModel.ws.isConnected {
                            viewModel.ws.disconnect()
                        } else {
                            viewModel.ws.connect()
                        }
                    }

                    Button("Clear Token & Disconnect", role: .destructive) {
                        viewModel.clearToken()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
