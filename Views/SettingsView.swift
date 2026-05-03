import SwiftUI
import SwiftData
import AVFoundation

struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showUnpairConfirmation = false
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workspace.lastUsed, order: .reverse) private var savedWorkspaces: [Workspace]

    private var englishVoices: [AVSpeechSynthesisVoice] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("en") }
        return voices.sorted { (lhs: AVSpeechSynthesisVoice, rhs: AVSpeechSynthesisVoice) -> Bool in
            if lhs.quality.rawValue != rhs.quality.rawValue {
                return lhs.quality.rawValue > rhs.quality.rawValue
            }
            return lhs.name < rhs.name
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: KeepurTheme.Spacing.s5) {
                    deviceSection
                    connectionSection
                    if !savedWorkspaces.isEmpty {
                        savedWorkspacesSection
                    }
                    voiceSection
                    footerSection
                }
                .padding(.horizontal, KeepurTheme.Spacing.s4)
                .padding(.vertical, KeepurTheme.Spacing.s5)
            }
            .background(KeepurTheme.Color.bgPageDynamic)
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
            eyebrowHeader("DEVICE")
            KeepurCard(bordered: true) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Name").foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                        Spacer()
                        Text(KeychainManager.deviceName ?? "Unknown")
                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    }
                    .padding(.vertical, KeepurTheme.Spacing.s3)

                    if let deviceId = KeychainManager.deviceId {
                        Divider()
                        HStack {
                            Text("Device ID").foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            Spacer()
                            Text(String(deviceId.prefix(8)))
                                .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                        .padding(.vertical, KeepurTheme.Spacing.s3)
                    }
                }
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
            eyebrowHeader("CONNECTION")
            KeepurCard(bordered: true) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Status").foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.ws.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
                                .frame(width: 8, height: 8)
                            Text(viewModel.ws.isConnected ? "Connected" : "Disconnected")
                                .foregroundStyle(viewModel.ws.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
                        }
                    }
                    .padding(.vertical, KeepurTheme.Spacing.s3)

                    if let sessionId = viewModel.currentSessionId {
                        Divider()
                        HStack {
                            Text("Session").foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            Spacer()
                            Text(String(sessionId.prefix(8)))
                                .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                        .padding(.vertical, KeepurTheme.Spacing.s3)
                    }

                    if !viewModel.currentPath.isEmpty {
                        Divider()
                        HStack {
                            Text("Workspace").foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            Spacer()
                            Text(viewModel.currentPath)
                                .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                                .lineLimit(1)
                        }
                        .padding(.vertical, KeepurTheme.Spacing.s3)
                    }
                }
            }
        }
    }

    private var savedWorkspacesSection: some View {
        VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
            eyebrowHeader("SAVED WORKSPACES")
            KeepurCard(bordered: true) {
                VStack(spacing: 0) {
                    ForEach(Array(savedWorkspaces.enumerated()), id: \.element.path) { index, workspace in
                        NavigationLink {
                            SavedWorkspacesPlaceholderView()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(workspace.displayName)
                                    .font(KeepurTheme.Font.body)
                                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                                Text(workspace.path)
                                    .font(KeepurTheme.Font.caption)
                                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, KeepurTheme.Spacing.s3)
                        }
                        .buttonStyle(.plain)

                        if index < savedWorkspaces.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
            eyebrowHeader("VOICE")
            KeepurCard(bordered: true) {
                VStack(spacing: 0) {
                    ForEach(Array(englishVoices.enumerated()), id: \.element.identifier) { index, voice in
                        voiceRow(voice)
                        if index < englishVoices.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var footerSection: some View {
        KeepurCard(bordered: true) {
            VStack(spacing: 0) {
                Button(viewModel.ws.isConnected ? "Disconnect" : "Reconnect") {
                    if viewModel.ws.isConnected {
                        viewModel.ws.disconnect()
                    } else {
                        viewModel.ws.connect()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, KeepurTheme.Spacing.s3)

                Divider()

                Button("Unpair Device", role: .destructive) {
                    showUnpairConfirmation = true
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, KeepurTheme.Spacing.s3)
                .confirmationDialog(
                    "Unpair this device?",
                    isPresented: $showUnpairConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Unpair", role: .destructive) {
                        viewModel.unpair()
                        dismiss()
                    }
                } message: {
                    Text("You will need a new pairing code from your admin to reconnect.")
                }
            }
        }
    }

    // MARK: - Eyebrow header

    private func eyebrowHeader(_ title: String) -> some View {
        Text(title)
            .font(KeepurTheme.Font.eyebrow)
            .tracking(KeepurTheme.Font.lsEyebrow)
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            .textCase(nil)
    }

    @ViewBuilder
    private func voiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        Button {
            viewModel.speechManager.selectedVoiceId = voice.identifier
            let preview = "Hello, I'm " + voice.name + "."
            viewModel.speechManager.speak(preview)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name)
                        .font(KeepurTheme.Font.body)
                        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    Text(qualityLabel(voice.quality))
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                }
                Spacer()
                if viewModel.speechManager.selectedVoiceId == voice.identifier {
                    Image(systemName: KeepurTheme.Symbol.check)
                        .foregroundStyle(KeepurTheme.Color.honey500)
                }
            }
            .padding(.vertical, KeepurTheme.Spacing.s3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }
}

struct SavedWorkspacesPlaceholderView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: KeepurTheme.Spacing.s5) {
                KeepurCard(bordered: true) {
                    Text("Saved workspace details coming soon.")
                        .font(KeepurTheme.Font.body)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                }
            }
            .padding(KeepurTheme.Spacing.s4)
        }
        .background(KeepurTheme.Color.bgPageDynamic)
        .navigationTitle("Saved Workspaces")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
