import XCTest

@testable import Dayflow

final class ChatStreamingRegressionTests: XCTestCase {
  @MainActor
  func testSessionRecoveryOnlyRetriesMissingSessions() {
    XCTAssertTrue(ChatService.isMissingSessionError("no rollout found for thread id abc"))
    XCTAssertTrue(ChatService.isMissingSessionError("No conversation found with session ID: abc"))
    XCTAssertFalse(ChatService.isMissingSessionError("Rate limit exceeded"))
    XCTAssertFalse(ChatService.isMissingSessionError("Authentication failed"))
  }

  func testCodexReportsStructuredFailureInsteadOfStdinNotice() throws {
    let detail = "The 'gpt-5.4' model is not supported when using Codex with a ChatGPT account."
    let nested = String(
      decoding: try JSONSerialization.data(withJSONObject: [
        "type": "error", "error": ["message": detail],
      ]), as: UTF8.self)
    for event: [String: Any] in [
      ["type": "error", "message": nested],
      ["type": "turn.failed", "error": ["message": nested]],
    ] {
      let data = try JSONSerialization.data(withJSONObject: event)
      guard case .error(let message) = ChatCLIProcessRunner().parseCodexEvent(data) else {
        return XCTFail("The API failure must reach the chat UI")
      }
      XCTAssertEqual(message, detail)
    }
  }

  func testStreamingMetadataIsHiddenAtEveryTokenBoundary() {
    let answer = "Dayflow chat test OK."
    let suffix =
      "\n\n```suggestions\n[\"Follow up?\"]\n```\n\n```memory\nProfile: example\nStyle: brief\n```"
    for length in 1...suffix.count {
      let visible = ChatMetadataParser.visibleStreamingText(answer + suffix.prefix(length))
      XCTAssertEqual(visible.trimmingCharacters(in: .whitespacesAndNewlines), answer)
    }
  }

  func testStreamingKeepsOrdinaryCodeAndCharts() {
    for text in ["Answer\n```swift\nlet value = 1\n```\nDone", "```chart type=bar\n{}\n```\n"] {
      XCTAssertEqual(ChatMetadataParser.visibleStreamingText(text), text)
    }
  }
}
