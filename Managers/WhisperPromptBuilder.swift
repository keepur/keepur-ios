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

    /// Sentence-style prompt embedding high-confusion developer terms.
    /// Priority: terms Whisper commonly misinterprets (docs→dogs, git→get,
    /// enum→in um, async→a sink, cron→chrome, kubectl→kube cuddle, regex→rejects).
    static let staticPrompt: String = """
        The developer is discussing code with Keepur, \
        a Hive workspace assistant built by Dodi. \
        They use git for version control with commits, branches, rebases, \
        pull requests, PRs, diffs, stashes, and worktrees. \
        Their stack includes Swift, SwiftUI, SwiftData, Xcode, and CocoaPods. \
        They mention npm, yarn, webpack, Vite, TypeScript, and JavaScript. \
        They discuss APIs, REST, GraphQL, JSON, YAML, regex, OAuth, JWT, \
        async, await, enums, structs, tuples, and nil values. \
        Infrastructure includes Docker, Kubernetes, kubectl, Redis, MongoDB, \
        PostgreSQL, Nginx, SSH, CORS, and CI/CD pipelines. \
        They use CLI tools like grep, curl, zsh, bash, vim, ESLint, and Prettier. \
        Testing with Jest, XCTest, pytest, and end-to-end tests. \
        Actions include deploy, refactor, debug, scaffold, lint, mock, \
        debounce, cron jobs, and reading the docs.
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
