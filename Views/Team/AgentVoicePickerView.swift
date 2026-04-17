import SwiftUI
import AVFoundation

struct AgentVoicePickerView: View {
    let agent: TeamAgentInfo
    @ObservedObject var speechManager: SpeechManager

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("en") }
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var selectedVoiceId: String? {
        speechManager.agentVoiceIds[agent.id]
    }

    var body: some View {
        List {
            Section {
                Button {
                    speechManager.setVoice(nil, forAgent: agent.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use default")
                                .font(.body)
                            Text("Falls back to the app's selected voice")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedVoiceId == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }

            Section("Voices") {
                ForEach(voices, id: \.identifier) { voice in
                    voiceRow(voice)
                }
            }
        }
        .navigationTitle("Voice for \(agent.name)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func voiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        Button {
            speechManager.setVoice(voice.identifier, forAgent: agent.id)
            let preview = "Hello, I'm \(agent.name)."
            speechManager.speak(preview, voice: voice)
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
                if selectedVoiceId == voice.identifier {
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
