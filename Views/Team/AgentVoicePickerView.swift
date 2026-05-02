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
                                .font(KeepurTheme.Font.body)
                                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            Text("Falls back to the app's selected voice")
                                .font(KeepurTheme.Font.caption)
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                        Spacer()
                        if selectedVoiceId == nil {
                            Image(systemName: KeepurTheme.Symbol.check)
                                .foregroundStyle(KeepurTheme.Color.honey500)
                        }
                    }
                }
                .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
            }

            Section {
                ForEach(voices, id: \.identifier) { voice in
                    voiceRow(voice)
                        .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                }
            } header: {
                eyebrowHeader("VOICES")
            }
        }
        .scrollContentBackground(.hidden)
        .background(KeepurTheme.Color.bgPageDynamic)
        .navigationTitle("Voice for \(agent.name)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

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
            speechManager.setVoice(voice.identifier, forAgent: agent.id)
            let preview = "Hello, I'm \(agent.name)."
            speechManager.speak(preview, voice: voice)
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
                if selectedVoiceId == voice.identifier {
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
