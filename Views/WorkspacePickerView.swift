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
                    Section {
                        ForEach(recentWorkspaces.prefix(5), id: \.path) { workspace in
                            Button {
                                viewModel.newSession(path: workspace.path)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                                    VStack(alignment: .leading) {
                                        Text(workspace.displayName)
                                            .font(KeepurTheme.Font.body)
                                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                                        Text(workspace.path)
                                            .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                                    }
                                }
                            }
                            .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                        }
                    } header: {
                        eyebrowHeader("RECENT WORKSPACES")
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
                            .buttonStyle(KeepurPrimaryButtonStyle())
                            .padding(.horizontal, KeepurTheme.Spacing.s7)
                        }
                    } else if let error = viewModel.browseError {
                        ContentUnavailableView {
                            Label("Error", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Retry") { viewModel.browse() }
                                .buttonStyle(KeepurPrimaryButtonStyle())
                                .padding(.horizontal, KeepurTheme.Spacing.s7)
                        }
                    } else if viewModel.browsePath.isEmpty {
                        ProgressView("Loading…")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    } else {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                            Text(viewModel.browsePath)
                                .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                        .listRowBackground(KeepurTheme.Color.bgSunkenDynamic)

                        if !isHome {
                            Button {
                                let parent = (viewModel.browsePath as NSString).deletingLastPathComponent
                                viewModel.browse(path: parent)
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.up.doc")
                                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                                    Text("..")
                                        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                                }
                            }
                            .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
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
                                        .foregroundStyle(KeepurTheme.Color.honey700)
                                    Text(entry.name)
                                        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                                }
                            }
                            .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                        }
                    }
                } header: {
                    eyebrowHeader("BROWSE")
                }

                if !viewModel.workspaceSessions.isEmpty {
                    Section {
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
                                        .foregroundStyle(ws.active ? KeepurTheme.Color.success : KeepurTheme.Color.fgSecondaryDynamic)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ws.preview)
                                            .font(KeepurTheme.Font.bodySm)
                                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                                            .lineLimit(2)
                                        Text(ws.lastActiveAt, style: .relative)
                                            .font(KeepurTheme.Font.caption)
                                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                                    }
                                    Spacer()
                                    if ws.active {
                                        semanticBadge("Active", tint: KeepurTheme.Color.success)
                                    }
                                }
                            }
                            .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                        }
                    } header: {
                        eyebrowHeader("SESSION HISTORY")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(KeepurTheme.Color.bgPageDynamic)
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

    // MARK: - Eyebrow header

    private func eyebrowHeader(_ title: String) -> some View {
        Text(title)
            .font(KeepurTheme.Font.eyebrow)
            .tracking(KeepurTheme.Font.lsEyebrow)
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            .textCase(nil)
    }

    private func semanticBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(KeepurTheme.Font.caption)
            .padding(.horizontal, KeepurTheme.Spacing.s2)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .clipShape(Capsule())
            .foregroundStyle(tint)
    }
}
