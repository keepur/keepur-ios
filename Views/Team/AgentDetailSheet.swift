import SwiftUI
import AVFoundation

struct AgentDetailSheet: View {
    let agent: TeamAgentInfo
    @ObservedObject var speechManager: SpeechManager

    private var statusColor: Color {
        switch agent.status {
        case "idle": return KeepurTheme.Color.success
        case "processing": return KeepurTheme.Color.warning
        case "error", "stopped": return KeepurTheme.Color.danger
        default: return KeepurTheme.Color.fgMuted
        }
    }

    private var iconText: String {
        agent.icon.isEmpty ? "🤖" : agent.icon
    }

    private var lastActivityDate: Date? {
        guard let str = agent.lastActivity else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: str) { return date }
        // Fallback: server may omit fractional seconds
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: str)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: KeepurTheme.Spacing.s5) {
                    // Header
                    VStack(spacing: KeepurTheme.Spacing.s2) {
                        Text(iconText)
                            .font(.system(size: 48))
                        Text(agent.name)
                            .font(KeepurTheme.Font.h3)
                            .tracking(KeepurTheme.Font.lsH3)
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                            Text(agent.status)
                                .font(KeepurTheme.Font.bodySm)
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                    }
                    .padding(.top)

                    // Info grid
                    VStack(spacing: 0) {
                        if let title = agent.title, !title.isEmpty {
                            infoRow(label: "Title", value: title)
                        }
                        if !agent.model.isEmpty {
                            infoRow(label: "Model", value: agent.model)
                        }
                        infoRow(label: "Messages", value: "\(agent.messagesProcessed)")
                        infoRow(label: "Last Active", date: lastActivityDate)
                    }
                    .background(KeepurTheme.Color.bgSurfaceDynamic)
                    .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))

                    // Tools
                    if !agent.tools.isEmpty {
                        sectionCard(title: "TOOLS") {
                            Text(agent.tools.joined(separator: ", "))
                                .font(KeepurTheme.Font.bodySm)
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                    }

                    // Schedule
                    if !agent.schedule.isEmpty {
                        sectionCard(title: "SCHEDULE") {
                            VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1 + 2) {
                                ForEach(Array(agent.schedule.enumerated()), id: \.offset) { _, entry in
                                    if let cron = entry["cron"], let task = entry["task"] {
                                        HStack(alignment: .top, spacing: KeepurTheme.Spacing.s2) {
                                            Text(cron)
                                                .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                                            Text("— \(task)")
                                                .font(KeepurTheme.Font.bodySm)
                                                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Channels
                    if !agent.channels.isEmpty {
                        sectionCard(title: "CHANNELS") {
                            Text(agent.channels.map { "#\($0)" }.joined(separator: ", "))
                                .font(KeepurTheme.Font.bodySm)
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                    }

                    // Voice
                    voiceSection
                }
                .padding(.horizontal)
            }
            .background(KeepurTheme.Color.bgPageDynamic)
            .navigationTitle("Agent Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    // MARK: - Subviews

    private var currentVoiceLabel: String {
        if let voiceId = speechManager.agentVoiceIds[agent.id],
           let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            return voice.name
        }
        return "Default"
    }

    private var voiceSection: some View {
        NavigationLink {
            AgentVoicePickerView(agent: agent, speechManager: speechManager)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1) {
                    Text("VOICE")
                        .font(KeepurTheme.Font.eyebrow)
                        .tracking(KeepurTheme.Font.lsEyebrow)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        .textCase(nil)
                    Text(currentVoiceLabel)
                        .font(KeepurTheme.Font.bodySm)
                        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(KeepurTheme.Font.bodySm)
                    .foregroundStyle(KeepurTheme.Color.fgTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(KeepurTheme.Spacing.s4)
            .background(KeepurTheme.Color.bgSurfaceDynamic)
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
        }
        .buttonStyle(.plain)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            Spacer()
            Text(value)
                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
        }
        .font(KeepurTheme.Font.bodySm)
        .padding(.horizontal, KeepurTheme.Spacing.s4)
        .padding(.vertical, KeepurTheme.Spacing.s2 + 2)
    }

    private func infoRow(label: String, date: Date?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            Spacer()
            if let date {
                Text(date, style: .relative)
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
            } else {
                Text("Never")
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
            }
        }
        .font(KeepurTheme.Font.bodySm)
        .padding(.horizontal, KeepurTheme.Spacing.s4)
        .padding(.vertical, KeepurTheme.Spacing.s2 + 2)
    }

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
            Text(title)
                .font(KeepurTheme.Font.eyebrow)
                .tracking(KeepurTheme.Font.lsEyebrow)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                .textCase(nil)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(KeepurTheme.Spacing.s4)
        .background(KeepurTheme.Color.bgSurfaceDynamic)
        .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
    }
}
