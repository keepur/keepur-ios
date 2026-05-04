import SwiftUI
import SwiftData

struct SessionListView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.createdAt, order: .reverse) private var sessions: [Session]
    @State private var selectedSessionId: String?
    @State private var daysRemaining: Int?
    @State private var showWorkspacePicker = false
    @State private var renamingSession: Session?
    @State private var renameText = ""

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    // MARK: - Session List Content

    private var sessionList: some View {
        List(selection: $selectedSessionId) {
            if let daysRemaining, daysRemaining >= 0, daysRemaining <= 7 {
                HStack(spacing: KeepurTheme.Spacing.s2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(KeepurTheme.Color.warning)
                    Text(daysRemaining == 0
                        ? "Device pairing expires today"
                        : daysRemaining == 1
                            ? "Device pairing expires in 1 day"
                            : "Device pairing expires in \(daysRemaining) days")
                        .font(KeepurTheme.Font.bodySm)
                        .fontWeight(.medium)
                        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, KeepurTheme.Spacing.s1)
                .listRowBackground(KeepurTheme.Color.honey100)
            }

            ForEach(sessions, id: \.id) { session in
                SessionRow(
                    session: session,
                    isActive: session.id == viewModel.currentSessionId,
                    modelContext: modelContext
                )
                .opacity(session.isStale ? 0.5 : 1.0)
                .tag(session.id)
                .contentShape(Rectangle())
                #if os(iOS)
                .onTapGesture {
                    guard !session.isStale else { return }
                    viewModel.currentSessionId = session.id
                    viewModel.currentPath = session.path
                    selectedSessionId = session.id
                }
                #endif
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
                    Button(role: .destructive) {
                        viewModel.clearSession(sessionId: session.id)
                        if selectedSessionId == session.id {
                            selectedSessionId = nil
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(KeepurTheme.Color.bgPageDynamic)
    }

    private var sessionToolbar: some ToolbarContent {
        Group {
            ToolbarItem(placement: .navigation) {
                Circle()
                    .fill(viewModel.ws.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
                    .frame(width: 8, height: 8)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showWorkspacePicker = true
                } label: {
                    Image(systemName: KeepurTheme.Symbol.compose)
                        .font(.title3)
                }
            }
        }
    }

    private var sessionOverlay: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Sessions", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a new session to chat with Claude Code")
                } actions: {
                    Button("New Session") { showWorkspacePicker = true }
                        .buttonStyle(KeepurPrimaryButtonStyle())
                        .padding(.horizontal, KeepurTheme.Spacing.s7)
                }
            }
        }
    }

    private var sessionSheets: some View {
        EmptyView()
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

    // MARK: - macOS Layout

    #if os(macOS)
    private var macOSBody: some View {
        NavigationSplitView {
            sessionList
                .navigationTitle("Sessions")
                .toolbar { sessionToolbar }
                .overlay { sessionOverlay }
        } detail: {
            if let selectedSessionId {
                ChatView(viewModel: viewModel, sessionId: selectedSessionId)
            } else {
                ContentUnavailableView {
                    Label("No Session Selected", systemImage: "bubble.left")
                } description: {
                    Text("Select a session from the sidebar")
                }
            }
        }
        .onChange(of: selectedSessionId) {
            if let selectedSessionId,
               let session = sessions.first(where: { $0.id == selectedSessionId }),
               !session.isStale {
                viewModel.currentSessionId = session.id
                viewModel.currentPath = session.path
            }
        }
        .onChange(of: viewModel.currentSessionId) { _, newValue in
            // Mirror VM → local nav state so that when the server hands us a new
            // session id (e.g. after /clear), the sidebar selection and detail
            // pane follow without a flash back to "No Session Selected".
            if let newValue, selectedSessionId != nil, selectedSessionId != newValue {
                selectedSessionId = newValue
            }
        }
        .onAppear {
            if let expiry = KeychainManager.tokenExpiryDate {
                daysRemaining = Calendar.current.dateComponents([.day], from: .now, to: expiry).day
            }
        }
        .sheet(isPresented: $showWorkspacePicker) {
            WorkspacePickerView(viewModel: viewModel)
                .frame(minWidth: 500, minHeight: 550)
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
    #endif

    // MARK: - iOS Layout

    #if os(iOS)
    private var iOSBody: some View {
        NavigationStack {
            sessionList
                .navigationTitle("Sessions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(selectedSessionId == nil ? .visible : .hidden, for: .tabBar)
                .toolbar { sessionToolbar }
                .overlay { sessionOverlay }
                // `isPresented:` (not `item:`) so that when the session id swaps
                // mid-chat during a /clear handoff (HIVE-113), the ChatView stays
                // mounted instead of being popped & re-pushed.
                .navigationDestination(
                    isPresented: Binding(
                        get: { selectedSessionId != nil },
                        set: { if !$0 { selectedSessionId = nil } }
                    )
                ) {
                    if let sessionId = selectedSessionId {
                        ChatView(viewModel: viewModel, sessionId: sessionId)
                    }
                }
        }
        .onAppear {
            if let expiry = KeychainManager.tokenExpiryDate {
                daysRemaining = Calendar.current.dateComponents([.day], from: .now, to: expiry).day
            }
        }
        .onChange(of: viewModel.currentSessionId) { _, newValue in
            // Mirror VM → local nav state so that when the server hands us a new
            // session id (e.g. after /clear), the navigation follows without a pop.
            if let newValue, selectedSessionId != nil, selectedSessionId != newValue {
                selectedSessionId = newValue
            }
        }
        .background { sessionSheets }
    }
    #endif
}

// MARK: - Session Row

struct SessionRow: View {
    let session: Session
    let isActive: Bool
    let modelContext: ModelContext
    @Query private var latestMessages: [Message]

    init(session: Session, isActive: Bool, modelContext: ModelContext) {
        self.session = session
        self.isActive = isActive
        self.modelContext = modelContext
        let sid = session.id
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.sessionId == sid },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        _latestMessages = Query(descriptor)
    }

    var body: some View {
        HStack(alignment: .center, spacing: KeepurTheme.Spacing.s3) {
            KeepurAvatar(
                size: 56,
                content: .letter(session.displayName),
                statusOverlay: isActive ? .success : nil
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: KeepurTheme.Spacing.s2) {
                    Text(session.displayName)
                        .font(KeepurTheme.Font.body)
                        .fontWeight(isActive ? .semibold : .medium)
                        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                        .lineLimit(1)
                    if session.isStale {
                        KeepurStatusPill("Stale", tint: .warning)
                    }
                }

                Text(session.path)
                    .font(.custom(KeepurTheme.FontName.mono, size: 12))
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    .lineLimit(1)

                if let preview = lastMessagePreview {
                    Text(preview)
                        .font(KeepurTheme.Font.bodySm)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(session.createdAt, style: .relative)
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgTertiary)
        }
        .padding(.vertical, KeepurTheme.Spacing.s2)
        .contentShape(Rectangle())
    }

    private var lastMessagePreview: String? {
        guard let msg = latestMessages.first else { return nil }
        return msg.role == "user" ? msg.text : "Claude: \(msg.text)"
    }
}
