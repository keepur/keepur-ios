import SwiftUI
import SwiftData

struct WorkspacePickerView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Workspace.lastUsed, order: .reverse) private var recentWorkspaces: [Workspace]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Recent workspaces
                if !recentWorkspaces.isEmpty {
                    recentSection
                    Divider()
                }

                // Breadcrumb
                breadcrumb

                Divider()

                // Directory listing
                directoryList
            }
            .navigationTitle("Choose Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Start Here") {
                        startSession(path: viewModel.browsePath)
                    }
                    .fontWeight(.semibold)
                    .disabled(viewModel.browsePath.isEmpty)
                }
            }
            .onAppear {
                viewModel.browse()
            }
        }
    }

    // MARK: - Recent Workspaces

    private var recentSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recentWorkspaces, id: \.path) { workspace in
                    Button {
                        startSession(path: workspace.path)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                                .font(.caption2)
                            Text(workspace.displayName)
                                .font(.subheadline)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let components = breadcrumbComponents
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        let path = components[0...index].joined(separator: "/")
                        let fullPath = path.hasPrefix("/") ? path : "/\(path)"
                        viewModel.browse(path: fullPath)
                    } label: {
                        Text(index == 0 ? "~" : component)
                            .font(.subheadline)
                            .foregroundStyle(index == components.count - 1 ? .primary : .secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var breadcrumbComponents: [String] {
        guard !viewModel.browsePath.isEmpty else { return [] }
        return viewModel.browsePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    // MARK: - Directory Listing

    private var directoryList: some View {
        List {
            // Parent directory
            if breadcrumbComponents.count > 1 {
                Button {
                    let parent = (viewModel.browsePath as NSString).deletingLastPathComponent
                    viewModel.browse(path: parent)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.doc")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text("..")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(viewModel.browseEntries, id: \.name) { entry in
                Button {
                    if entry.isDirectory {
                        let childPath = viewModel.browsePath.hasSuffix("/")
                            ? viewModel.browsePath + entry.name
                            : viewModel.browsePath + "/" + entry.name
                        viewModel.browse(path: childPath)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                            .frame(width: 20)
                        Text(entry.name)
                            .foregroundStyle(entry.isDirectory ? .primary : .secondary)
                        Spacer()
                        if entry.isDirectory {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .disabled(!entry.isDirectory)
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Actions

    private func startSession(path: String) {
        viewModel.newSession(path: path)
        dismiss()
    }
}
