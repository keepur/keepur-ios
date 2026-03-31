import SwiftUI
import SwiftData

struct SessionListView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.createdAt, order: .reverse) private var sessions: [Session]
    @State private var selectedSessionId: String?
    @State private var daysRemaining: Int?
    @State private var showSettings = false

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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.currentSessionId = session.id
                        viewModel.currentWorkspace = session.workspace
                        selectedSessionId = session.id
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteSession(session)
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
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title3)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if viewModel.availableWorkspaces.isEmpty {
                            Button {
                                viewModel.newSession()
                            } label: {
                                Label("New Session", systemImage: "plus")
                            }
                        } else {
                            ForEach(viewModel.availableWorkspaces, id: \.self) { (ws: String) in
                                Button {
                                    viewModel.newSession(workspace: ws)
                                } label: {
                                    Label(ws, systemImage: "folder")
                                }
                            }
                        }
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
                        Button("New Session") { viewModel.newSession() }
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
        }
    }

    private func deleteSession(_ session: Session) {
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
                    Text(session.workspace)
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
                }

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
