import SwiftUI
import SwiftData

struct WorkspacePickerView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Workspace.lastUsed, order: .reverse) private var recentWorkspaces: [Workspace]
    @Query(sort: \Session.createdAt, order: .reverse) private var allSessions: [Session]

    private var sessionsAtPath: [Session] {
        guard !viewModel.browsePath.isEmpty else { return [] }
        return allSessions.filter { $0.path == viewModel.browsePath && !$0.isStale }
    }

    var body: some View {
        NavigationStack {
            List {
                if !recentWorkspaces.isEmpty {
                    Section("Recent Workspaces") {
                        ForEach(recentWorkspaces, id: \.path) { workspace in
                            Button {
                                viewModel.newSession(path: workspace.path)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading) {
                                        Text(workspace.displayName)
                                            .font(.body)
                                        Text(workspace.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                Section {
                    if !viewModel.ws.isConnected {
                        ContentUnavailableView {
                            Label("Disconnected", systemImage: "wifi.slash")
                        } description: {
                            Text("Connect to browse directories")
                        } actions: {
                            Button("Reconnect") {
                                viewModel.browseError = nil
                                viewModel.ws.connect()
                                viewModel.browse()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else if let error = viewModel.browseError {
                        ContentUnavailableView {
                            Label("Error", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Retry") { viewModel.browse() }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if viewModel.browsePath.isEmpty {
                        ProgressView("Loading…")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    } else {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
                            Text(viewModel.browsePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .listRowBackground(Color(.systemGray6))

                        if !isHome {
                            Button {
                                let parent = (viewModel.browsePath as NSString).deletingLastPathComponent
                                viewModel.browse(path: parent)
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.up.doc")
                                        .foregroundStyle(.secondary)
                                    Text("..")
                                        .foregroundStyle(.primary)
                                }
                            }
                        }

                        ForEach(viewModel.browseEntries.filter(\.isDirectory), id: \.name) { entry in
                            Button {
                                let base = viewModel.browsePath
                                let childPath = base == "/" ? "/\(entry.name)"
                                    : base.hasSuffix("/") ? "\(base)\(entry.name)"
                                    : "\(base)/\(entry.name)"
                                viewModel.browse(path: childPath)
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.blue)
                                    Text(entry.name)
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Browse")
                }

                if !sessionsAtPath.isEmpty {
                    Section("Existing Sessions") {
                        ForEach(sessionsAtPath, id: \.id) { session in
                            Button {
                                viewModel.currentSessionId = session.id
                                viewModel.currentPath = session.path
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "bubble.left.and.bubble.right")
                                        .foregroundStyle(.green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.id.prefix(8) + "…")
                                            .font(.body)
                                        Text(session.createdAt, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Select Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Session Here") {
                        viewModel.newSession(path: viewModel.browsePath)
                        dismiss()
                    }
                    .disabled(viewModel.browsePath.isEmpty)
                }
            }
            .onAppear {
                viewModel.browsePath = ""
                viewModel.browseEntries = []
                viewModel.browseError = nil
                viewModel.browse()
            }
        }
    }

    private var isHome: Bool {
        viewModel.browsePath == "/" || viewModel.browsePath.hasSuffix("/~") || viewModel.browsePath == "~"
    }
}
