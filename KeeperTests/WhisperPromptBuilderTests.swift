import XCTest
@testable import Keepur

final class WhisperPromptBuilderTests: XCTestCase {

    func testStaticPromptIsNotEmpty() {
        XCTAssertFalse(WhisperPromptBuilder.staticPrompt.isEmpty)
    }

    func testBuildPromptWithNoNamesReturnsStaticOnly() {
        let result = WhisperPromptBuilder.buildPrompt()
        XCTAssertEqual(result, WhisperPromptBuilder.staticPrompt)
    }

    func testBuildPromptWithAgentNames() {
        let result = WhisperPromptBuilder.buildPrompt(agentNames: ["Rae", "Jasper"])
        XCTAssertTrue(result.hasPrefix(WhisperPromptBuilder.staticPrompt))
        XCTAssertTrue(result.contains("Rae"))
        XCTAssertTrue(result.contains("Jasper"))
    }

    func testBuildPromptWithAllSources() {
        let result = WhisperPromptBuilder.buildPrompt(
            agentNames: ["Mokie"],
            channelNames: ["general"],
            commandNames: ["new"]
        )
        XCTAssertTrue(result.contains("Mokie"))
        XCTAssertTrue(result.contains("general"))
        XCTAssertTrue(result.contains("new"))
    }

    func testBuildPromptFiltersEmptyStrings() {
        let result = WhisperPromptBuilder.buildPrompt(agentNames: ["", "Rae", ""])
        XCTAssertTrue(result.contains("Rae"))
        // Should not contain double commas from empty strings
        XCTAssertFalse(result.contains(", ,"))
    }

    func testBuildPromptWithAllEmptyReturnsStaticOnly() {
        let result = WhisperPromptBuilder.buildPrompt(
            agentNames: ["", ""],
            channelNames: [],
            commandNames: [""]
        )
        XCTAssertEqual(result, WhisperPromptBuilder.staticPrompt)
    }
}
