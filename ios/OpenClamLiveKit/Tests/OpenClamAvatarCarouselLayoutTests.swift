import XCTest
@testable import OpenClamLiveKit

final class OpenClamAvatarCarouselLayoutTests: XCTestCase {
    func testOverlaySafeAreaFallbackClearsStatusBarAndComposer() {
        XCTAssertEqual(
            OpenClamAvatarCarouselLayout.topControlPadding(
                reportedSafeAreaInset: 0
            ),
            168
        )
        XCTAssertEqual(
            OpenClamAvatarCarouselLayout.topControlPadding(
                reportedSafeAreaInset: 59
            ),
            168
        )
        XCTAssertEqual(
            OpenClamAvatarCarouselLayout.detailBarBottomPadding(
                reportedSafeAreaInset: 0
            ),
            116
        )
        XCTAssertEqual(
            OpenClamAvatarCarouselLayout.detailBarBottomPadding(
                reportedSafeAreaInset: 120
            ),
            134
        )
    }

    func testRearCardTapFocusesAndFrontCardTapActivates() {
        XCTAssertEqual(
            OpenClamAvatarCarouselLayout.actionForCardTap(index: 1, frontIndex: 0),
            .focus(1)
        )
        XCTAssertEqual(
            OpenClamAvatarCarouselLayout.actionForCardTap(index: 1, frontIndex: 1),
            .activate
        )
    }

    func testAvatarActivationRemainsBlockedForEveryActiveLiveTalkPhase() {
        XCTAssertTrue(LiveTalkAvatarSwitchPolicy.allowsSwitch(during: .idle))
        XCTAssertTrue(LiveTalkAvatarSwitchPolicy.allowsSwitch(during: .failed("Try again")))

        for phase in [
            LiveTalkConnectionPhase.starting,
            .connected,
            .reconnecting,
            .ending,
        ] {
            XCTAssertFalse(
                LiveTalkAvatarSwitchPolicy.allowsSwitch(during: phase),
                "Avatar activation must remain blocked during \(phase)"
            )
        }
    }

    func testNoirMatchesVivieenCascade() {
        let front = OpenClamAvatarCarouselLayout.card(
            index: 2,
            frontIndex: 2,
            count: 6,
            style: .noir
        )
        XCTAssertEqual(front.x, 0)
        XCTAssertEqual(front.y, 0)
        XCTAssertEqual(front.rotationDegrees, 0)
        XCTAssertEqual(front.scale, 1.16)
        XCTAssertEqual(front.opacity, 1)

        let next = OpenClamAvatarCarouselLayout.card(
            index: 3,
            frontIndex: 2,
            count: 6,
            style: .noir
        )
        XCTAssertEqual(next.x, 64)
        XCTAssertEqual(next.y, -20)
        XCTAssertEqual(next.rotationDegrees, -7)
        XCTAssertEqual(next.scale, 0.96)
        XCTAssertEqual(next.opacity, 0.84)
    }

    func testSorbetMatchesVivieenArc() {
        let front = OpenClamAvatarCarouselLayout.card(
            index: 0,
            frontIndex: 0,
            count: 6,
            style: .sorbet
        )
        XCTAssertEqual(front.y, -24)
        XCTAssertEqual(front.scale, 1.12)

        let previous = OpenClamAvatarCarouselLayout.card(
            index: 5,
            frontIndex: 0,
            count: 6,
            style: .sorbet
        )
        XCTAssertEqual(previous.x, -58)
        XCTAssertEqual(previous.y, 26)
        XCTAssertEqual(previous.rotationDegrees, -13)
        XCTAssertEqual(previous.scale, 0.94)
    }

    func testDragSpinsOneCardPerFortySixPointsAndWraps() {
        XCTAssertEqual(
            OpenClamAvatarCarouselLayout.frontIndex(
                from: 0,
                horizontalTranslation: 45,
                count: 6
            ),
            0
        )
        XCTAssertEqual(
            OpenClamAvatarCarouselLayout.frontIndex(
                from: 0,
                horizontalTranslation: 46,
                count: 6
            ),
            5
        )
        XCTAssertEqual(
            OpenClamAvatarCarouselLayout.frontIndex(
                from: 5,
                horizontalTranslation: -92,
                count: 6
            ),
            1
        )
    }

    func testRelativeDistanceWrapsBothWays() {
        XCTAssertEqual(
            OpenClamAvatarCarouselLayout.relativeDistance(
                cardIndex: 5,
                frontIndex: 0,
                count: 6
            ),
            -1
        )
        XCTAssertEqual(
            OpenClamAvatarCarouselLayout.relativeDistance(
                cardIndex: 0,
                frontIndex: 5,
                count: 6
            ),
            1
        )
    }
}
