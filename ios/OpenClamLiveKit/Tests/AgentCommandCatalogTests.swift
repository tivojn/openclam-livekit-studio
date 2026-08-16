import XCTest
@testable import OpenClamLiveKit

final class AgentCommandCatalogTests: XCTestCase {
    func testCatalogHasStableUniqueCommandsAcrossEveryGroup() {
        let commands = AgentCommandCatalog.commands

        XCTAssertGreaterThanOrEqual(commands.count, 20)
        XCTAssertEqual(Set(commands.map(\.id)).count, commands.count)
        XCTAssertEqual(Set(AgentCommandCatalog.groups.map(\.id)).count, AgentCommandCatalog.groups.count)
        XCTAssertTrue(AgentCommandCatalog.groups.allSatisfy { !$0.commands.isEmpty })
        XCTAssertTrue(commands.allSatisfy { !$0.title.isEmpty && !$0.example.isEmpty && !$0.detail.isEmpty })
    }

    func testConsequentialExamplesNeverClaimAutomaticCompletion() {
        let consequential = AgentCommandCatalog.commands.filter { $0.boundary != .answer }
        let forbiddenClaims = ["automatically sends", "automatically books", "runs silently"]

        for command in consequential {
            for claim in forbiddenClaims {
                XCTAssertFalse(
                    command.detail.localizedCaseInsensitiveContains(claim),
                    "\(command.id) contains the forbidden completion claim \(claim)"
                )
            }
        }
    }

    func testCatalogIncludesCoreVoiceAgentFlows() {
        let ids = Set(AgentCommandCatalog.commands.map(\.id))

        for required in [
            "answer", "email", "message", "reply", "nearby", "maps", "uber",
            "calendar", "dated-alarm", "timer-start", "clock-alarm", "flashlight",
            "low-power", "control-center", "home-screen", "phone-call",
        ] {
            XCTAssertTrue(ids.contains(required), "Missing command catalog entry: \(required)")
        }
    }
}
