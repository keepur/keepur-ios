import SwiftUI
import SwiftData

struct WorkspacePickerView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Workspace.lastUsed, order: .reverse) private var recentWorkspaces: [Workspace]

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
                        .listRowBackground(Color.tertiarySystemFill)

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

                if !viewModel.workspaceSessions.isEmpty {
                    Section("Session History") {
                        ForEach(viewModel.workspaceSessions, id: \.sessionId) { ws in
                            Button {
                                if ws.active {
                                    viewModel.currentSessionId = ws.sessionId
                                    viewModel.currentPath = viewModel.browsePath
                                } else {
                                    viewModel.resumeSession(sessionId: ws.sessionId, path: viewModel.browsePath)
                                }
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: ws.active ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                                        .foregroundStyle(ws.active ? .green : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ws.preview)
                                            .font(.subheadline)
                                            .lineLimit(2)
                                        Text(ws.lastActiveAt, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if ws.active {
                                        Text("Active")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.2))
                                            .clipShape(Capsule())
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Select Workspace")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
                viewModel.workspaceSessions = []
                viewModel.browse()
            }
        }
    }

    private var isHome: Bool {
        viewModel.browsePath == "/" || viewModel.browsePath.hasSuffix("/~") || viewModel.browsePath == "~"
    }
}
