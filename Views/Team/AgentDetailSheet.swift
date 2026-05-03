import SwiftUI
import AVFoundation

struct AgentDetailSheet: View {
    let agent: TeamAgentInfo
    @ObservedObject var speechManager: SpeechManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: KeepurTheme.Spacing.s5) {
                    headerSection
                    metricGridSection
                    if !agent.tools.isEmpty {
                        eyebrowSection(title: "TOOLS") {
                            KeepurChipCluster(agent.tools, maxVisible: 6)
                        }
                    }
                    if !agent.channels.isEmpty {
                        eyebrowSection(title: "CHANNELS") {
                            KeepurChipCluster(agent.channels.map { "#\($0)" }, maxVisible: 6)
                        }
                    }
                    if !agent.schedule.isEmpty {
                        eyebrowSection(title: "SCHEDULE") {
                            VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
                                ForEach(Array(agent.schedule.enumerated()), id: \.offset) { _, entry in
                                    if let cron = entry["cron"], let task = entry["task"] {
                                        HStack(alignment: .firstTextBaseline, spacing: KeepurTheme.Spacing.s2) {
                                            cronChip(cron)
                                            Text(task)
                                                .font(KeepurTheme.Font.bodySm)
                                                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                                        }
                                    }
                                }
                            }
                        }
                    }
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

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: KeepurTheme.Spacing.s2) {
            KeepurAvatar(
                size: 60,
                content: AgentDetailSheet.headerAvatarContent(for: agent)
            )
            Text(agent.name)
                .font(KeepurTheme.Font.h2)
                .tracking(KeepurTheme.Font.lsH3)
                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
            if let title = agent.title, !title.isEmpty {
                Text(title)
                    .font(KeepurTheme.Font.bodySm)
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            }
            KeepurStatusPill(
                AgentDetailSheet.statusDisplay(for: agent.status),
                tint: AgentDetailSheet.statusTint(for: agent.status)
            )
        }
        .padding(.top)
    }

    private var metricGridSection: some View {
        KeepurMetricGrid([
            .init(label: "MODEL",       value: AgentDetailSheet.modelDisplay(for: agent)),
            .init(label: "MESSAGES",    value: "\(agent.messagesProcessed)"),
            .init(label: "LAST ACTIVE", value: AgentDetailSheet.lastActiveDisplay(from: agent.lastActivity)),
        ])
    }

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
            KeepurCard {
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
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - View helpers

    @ViewBuilder
    private func eyebrowSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
            Text(title)
                .font(KeepurTheme.Font.eyebrow)
                .tracking(KeepurTheme.Font.lsEyebrow)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                .textCase(nil)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cronChip(_ cron: String) -> some View {
        Text(cron)
            .font(.custom(KeepurTheme.FontName.mono, size: 12))
            .foregroundStyle(KeepurTheme.Color.fgSecondary)
            .padding(.horizontal, KeepurTheme.Spacing.s2)
            .padding(.vertical, KeepurTheme.Spacing.s1)
            .background(KeepurTheme.Color.wax100)
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.xs))
    }

    // MARK: - Pure helpers (testable)

    static func statusTint(for status: String) -> KeepurStatusPill.Tint {
        switch status {
        case "idle":             return .success
        case "processing":       return .warning
        case "error", "stopped": return .danger
        default:                 return .muted
        }
    }

    static func statusDisplay(for status: String) -> String {
        status.prefix(1).uppercased() + status.dropFirst()
    }

    static func lastActiveDisplay(from iso: String?) -> String {
        guard let iso, let date = parseISO8601(iso) else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func parseISO8601(_ str: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: str) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: str)
    }

    static func headerAvatarContent(for agent: TeamAgentInfo) -> KeepurAvatar.Content {
        if !agent.icon.isEmpty {
            return .emoji(agent.icon)
        }
        if !agent.name.isEmpty {
            return .letter(agent.name)
        }
        return .letter("?")
    }

    static func modelDisplay(for agent: TeamAgentInfo) -> String {
        agent.model.isEmpty ? "—" : agent.model
    }
}
