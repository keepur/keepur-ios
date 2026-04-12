import Foundation

/// Builds a Whisper initial_prompt string from static developer vocabulary
/// and dynamic workspace-specific terms (agent names, channel names, commands).
///
/// Whisper's `promptTokens` are capped at 224 tokens and only influence the
/// first 30-second segment. OpenAI recommends embedding terms in natural
/// sentences rather than comma lists — the decoder follows the *style* of
/// the prompt, so prose produces better results than raw word dumps.
enum WhisperPromptBuilder {

    // MARK: - Static Vocabulary

    /// Compact prompt with highest-confusion developer terms only.
    /// Must stay well under 50 tokens after tokenization — prompt tokens
    /// compete with output tokens in Whisper's ~448-token context window.
    /// Priority: terms Whisper commonly misinterprets (docs→dogs, git→get,
    /// enum→in um, async→a sink, cron→chrome, kubectl→kube cuddle, regex→rejects).
    static let staticPrompt: String = """
        Discussing code with Keepur, a Dodi Hive assistant. \
        Using git, PRs, regex, async, enums, kubectl, cron, docs, SwiftUI, npm.
        """

    // MARK: - Prompt Assembly

    /// Build the full prompt by appending dynamic workspace terms to the static base.
    /// - Parameters:
    ///   - agentNames: Agent display names from `agent_list` (e.g. "Rae", "Jasper")
    ///   - channelNames: Channel names from `channel_list` (e.g. "general", "engineering")
    ///   - commandNames: Slash command names from `command_list` (e.g. "new", "rename")
    /// - Returns: A prompt string ready for tokenization.
    static func buildPrompt(
        agentNames: [String] = [],
        channelNames: [String] = [],
        commandNames: [String] = []
    ) -> String {
        let dynamicTerms = (agentNames + channelNames + commandNames)
            .filter { !$0.isEmpty }

        guard !dynamicTerms.isEmpty else { return staticPrompt }

        let suffix = " Workspace members and channels include \(dynamicTerms.joined(separator: ", "))."
        return staticPrompt + suffix
    }
}
