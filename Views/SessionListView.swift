import SwiftUI
import SwiftData

struct SessionListView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.createdAt, order: .reverse) private var sessions: [Session]
    @State private var selectedSessionId: String?
    @State private var daysRemaining: Int?
    @State private var showSettings = false
    @State private var showWorkspacePicker = false
    @State private var renamingSession: Session?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                if let daysRemaining, daysRemaining >= 0, daysRemaining <= 7 {
                    Button {
                        showSettings = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(daysRemaining == 0
                                ? "Device pairing expires today"
                                : daysRemaining == 1
                                    ? "Device pairing expires in 1 day"
                                    : "Device pairing expires in \(daysRemaining) days")
                                .font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.orange.opacity(0.1))
                }

                ForEach(sessions, id: \.id) { session in
                    SessionRow(
                        session: session,
                        isActive: session.id == viewModel.currentSessionId,
                        modelContext: modelContext
                    )
                    .opacity(session.isStale ? 0.5 : 1.0)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !session.isStale else { return }
                        viewModel.currentSessionId = session.id
                        viewModel.currentPath = session.path
                        selectedSessionId = session.id
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            viewModel.clearSession(sessionId: session.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            renameText = session.name ?? ""
                            renamingSession = session
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Circle()
                        .fill(viewModel.ws.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title3)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showWorkspacePicker = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.title3)
                    }
                }
            }
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No Sessions", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Start a new session to chat with Claude Code")
                    } actions: {
                        Button("New Session") { showWorkspacePicker = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationDestination(item: $selectedSessionId) { sessionId in
                ChatView(viewModel: viewModel, sessionId: sessionId)
            }
            .onAppear {
                if let expiry = KeychainManager.tokenExpiryDate {
                    daysRemaining = Calendar.current.dateComponents([.day], from: .now, to: expiry).day
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(viewModel: viewModel)
            }
            .sheet(isPresented: $showWorkspacePicker) {
                WorkspacePickerView(viewModel: viewModel)
            }
            .alert("Rename Session", isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            )) {
                TextField("Session name", text: $renameText)
                Button("Save") {
                    if let session = renamingSession {
                        session.name = renameText.isEmpty ? nil : renameText
                        try? modelContext.save()
                    }
                    renamingSession = nil
                }
                Button("Cancel", role: .cancel) {
                    renamingSession = nil
                }
            }
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: Session
    let isActive: Bool
    let modelContext: ModelContext

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(isActive ? Color.green : Color.accentColor.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: isActive ? "bolt.fill" : "bubble.left.fill")
                        .foregroundStyle(isActive ? .white : Color.accentColor)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                    if isActive {
                        Text("Active")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .clipShape(Capsule())
                            .foregroundStyle(.green)
                    }
                    if session.isStale {
                        Text("Stale")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(Capsule())
                            .foregroundStyle(.orange)
                    }
                }

                Text(session.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let preview = lastMessagePreview {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(session.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var lastMessagePreview: String? {
        let sid = session.id
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.sessionId == sid },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let msg = try? modelContext.fetch(descriptor).first else { return nil }
        return msg.role == "user" ? msg.text : "Claude: \(msg.text)"
    }
}
