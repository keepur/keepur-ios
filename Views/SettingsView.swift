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
                Section("Device") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(KeychainManager.deviceName ?? "Unknown")
                            .foregroundStyle(.secondary)
                    }

                    if let deviceId = KeychainManager.deviceId {
                        HStack {
                            Text("Device ID")
                            Spacer()
                            Text(String(deviceId.prefix(8)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Connection") {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.ws.isConnected ? .green : .red)
                                .frame(width: 8, height: 8)
                            Text(viewModel.ws.isConnected ? "Connected" : "Disconnected")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let sessionId = viewModel.currentSessionId {
                        HStack {
                            Text("Session")
                            Spacer()
                            Text(String(sessionId.prefix(8)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !viewModel.currentPath.isEmpty {
                        HStack {
                            Text("Workspace")
                            Spacer()
                            Text(viewModel.currentPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                if !savedWorkspaces.isEmpty {
                    Section("Saved Workspaces") {
                        ForEach(savedWorkspaces, id: \.path) { workspace in
                            VStack(alignment: .leading) {
                                Text(workspace.displayName)
                                    .font(.body)
                                Text(workspace.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                modelContext.delete(savedWorkspaces[index])
                            }
                            try? modelContext.save()
                        }
                    }
                }

                Section("Voice") {
                    ForEach(englishVoices, id: \.identifier) { voice in
                        voiceRow(voice)
                    }
                }

                Section {
                    Button(viewModel.ws.isConnected ? "Disconnect" : "Reconnect") {
                        if viewModel.ws.isConnected {
                            viewModel.ws.disconnect()
                        } else {
                            viewModel.ws.connect()
                        }
                    }

                    Button("Unpair Device", role: .destructive) {
                        showUnpairConfirmation = true
                    }
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
                        .font(.body)
                    Text(qualityLabel(voice.quality))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.speechManager.selectedVoiceId == voice.identifier {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }
}
