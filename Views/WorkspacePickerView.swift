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
                    if viewModel.browsePath.isEmpty {
                        ContentUnavailableView {
                            Label("Loading...", systemImage: "folder")
                        }
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
                                let childPath = viewModel.browsePath == "/"
                                    ? "/\(entry.name)"
                                    : "\(viewModel.browsePath)/\(entry.name)"
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
                viewModel.browse()
            }
        }
    }

    private var isHome: Bool {
        viewModel.browsePath == "/" || viewModel.browsePath.hasSuffix("/~") || viewModel.browsePath == "~"
    }
}
