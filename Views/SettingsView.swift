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
            List {
                Section {
                    HStack {
                        Text("Name")
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                        Spacer()
                        Text(KeychainManager.deviceName ?? "Unknown")
                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    }
                    .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)

                    if let deviceId = KeychainManager.deviceId {
                        HStack {
                            Text("Device ID")
                                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            Spacer()
                            Text(String(deviceId.prefix(8)))
                                .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                        .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                    }
                } header: {
                    eyebrowHeader("DEVICE")
                }

                Section {
                    HStack {
                        Text("Status")
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.ws.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
                                .frame(width: 8, height: 8)
                            Text(viewModel.ws.isConnected ? "Connected" : "Disconnected")
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                    }
                    .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)

                    if let sessionId = viewModel.currentSessionId {
                        HStack {
                            Text("Session")
                                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            Spacer()
                            Text(String(sessionId.prefix(8)))
                                .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                        .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                    }

                    if !viewModel.currentPath.isEmpty {
                        HStack {
                            Text("Workspace")
                                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            Spacer()
                            Text(viewModel.currentPath)
                                .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                                .lineLimit(1)
                        }
                        .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                    }
                } header: {
                    eyebrowHeader("CONNECTION")
                }

                if !savedWorkspaces.isEmpty {
                    Section {
                        ForEach(savedWorkspaces, id: \.path) { workspace in
                            VStack(alignment: .leading) {
                                Text(workspace.displayName)
                                    .font(KeepurTheme.Font.body)
                                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                                Text(workspace.path)
                                    .font(KeepurTheme.Font.caption)
                                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                            }
                            .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                modelContext.delete(savedWorkspaces[index])
                            }
                            try? modelContext.save()
                        }
                    } header: {
                        eyebrowHeader("SAVED WORKSPACES")
                    }
                }

                Section {
                    ForEach(englishVoices, id: \.identifier) { voice in
                        voiceRow(voice)
                            .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                    }
                } header: {
                    eyebrowHeader("VOICE")
                }

                Section {
                    Button(viewModel.ws.isConnected ? "Disconnect" : "Reconnect") {
                        if viewModel.ws.isConnected {
                            viewModel.ws.disconnect()
                        } else {
                            viewModel.ws.connect()
                        }
                    }
                    .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)

                    Button("Unpair Device", role: .destructive) {
                        showUnpairConfirmation = true
                    }
                    .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
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
            .scrollContentBackground(.hidden)
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
        }
    }

    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }
}
