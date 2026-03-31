import SwiftUI
import SwiftData

struct SessionListView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.createdAt, order: .reverse) private var sessions: [Session]
    @State private var selectedSessionId: String?
    @State private var showWorkspacePicker = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions, id: \.id) { session in
                    SessionRow(
                        session: session,
                        isActive: session.id == viewModel.currentSessionId,
                        modelContext: modelContext
                    )
                    .opacity(session.isStale ? 0.5 : 1.0)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.currentSessionId = session.id
                        selectedSessionId = session.id
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            if session.isStale {
                                deleteLocalSession(session)
                            } else {
                                viewModel.clearSession(sessionId: session.id)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
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
            .sheet(isPresented: $showWorkspacePicker) {
                WorkspacePickerView(viewModel: viewModel)
            }
        }
    }

    private func deleteLocalSession(_ session: Session) {
        let sid = session.id
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.sessionId == sid }
        )
        if let messages = try? modelContext.fetch(descriptor) {
            for msg in messages { modelContext.delete(msg) }
        }
        modelContext.delete(session)
        try? modelContext.save()
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
                    if session.isStale {
                        Text("Stale")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(Capsule())
                            .foregroundStyle(.orange)
                    } else if isActive {
                        Text("Active")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .clipShape(Capsule())
                            .foregroundStyle(.green)
                    }
                }

                Text(session.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
