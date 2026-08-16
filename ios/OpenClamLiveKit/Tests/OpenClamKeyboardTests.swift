import Foundation
import XCTest
@testable import OpenClamLiveKit

final class OpenClamKeyboardTests: XCTestCase {
    func testAppleKeyboardConstraintsRemainExplicit() {
        XCTAssertFalse(OpenClamKeyboardCapability.microphoneAvailableInExtension)
        XCTAssertTrue(OpenClamKeyboardCapability.requiresFullAccessForSharedHandoff)
        XCTAssertFalse(OpenClamKeyboardCapability.canLaunchContainingAppFromExtension)
        XCTAssertFalse(OpenClamKeyboardCapability.requiresVisibleContainingAppForVoiceInput)
        XCTAssertTrue(
            OpenClamKeyboardCapability.supportsBoundedForegroundStartedBackgroundCapture
        )
    }

    func testWarmEarReadinessRequiresEnabledLiveHeartbeatAndFutureDeadline() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(
            OpenClamKeyboardWarmEarState.isReady(
                enabled: true,
                readyUntil: now.addingTimeInterval(30).timeIntervalSince1970,
                heartbeat: now.addingTimeInterval(-1).timeIntervalSince1970,
                at: now
            )
        )
        XCTAssertFalse(
            OpenClamKeyboardWarmEarState.isReady(
                enabled: false,
                readyUntil: now.addingTimeInterval(30).timeIntervalSince1970,
                heartbeat: now.timeIntervalSince1970,
                at: now
            )
        )
        XCTAssertFalse(
            OpenClamKeyboardWarmEarState.isReady(
                enabled: true,
                readyUntil: now.addingTimeInterval(30).timeIntervalSince1970,
                heartbeat: now.addingTimeInterval(-4).timeIntervalSince1970,
                at: now
            )
        )
        XCTAssertFalse(
            OpenClamKeyboardWarmEarState.isReady(
                enabled: true,
                readyUntil: now.addingTimeInterval(-1).timeIntervalSince1970,
                heartbeat: now.timeIntervalSince1970,
                at: now
            )
        )
    }

    @MainActor
    func testWarmEarLeaseIsStrictlyBoundedToNinetySeconds() {
        XCTAssertEqual(OpenClamWarmEarControl.foregroundLeaseDuration, 90)
    }

    func testHandoffURLRoundTripsOnlyOneExactRequestID() {
        let id = UUID()
        let url = OpenClamKeyboardHandoffURL.make(requestID: id)
        XCTAssertTrue(OpenClamKeyboardHandoffURL.isKeyboardHandoff(url))
        XCTAssertEqual(OpenClamKeyboardHandoffURL.requestID(from: url), id)
        XCTAssertNil(
            OpenClamKeyboardHandoffURL.requestID(
                from: URL(string: "https://example.com/keyboard-dictation?request=\(id)")!
            )
        )
        XCTAssertNil(
            OpenClamKeyboardHandoffURL.requestID(
                from: URL(
                    string: "openclam-livekit-pilot://keyboard-dictation?request=\(id)&request=\(UUID())"
                )!
            )
        )
    }

    func testInsertionPlanTrimsAndAddsOnlyNecessarySpace() {
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(
                for: "  hello world\n",
                contextBeforeInput: "Existing"
            ),
            " hello world"
        )
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(for: "hello", contextBeforeInput: "Existing "),
            "hello"
        )
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(for: ".", contextBeforeInput: "Existing"),
            "."
        )
        XCTAssertNil(
            OpenClamKeyboardInsertionPlan.text(for: " \n ", contextBeforeInput: "Existing")
        )
    }

    func testSharedResultIsConsumedExactlyOnceAndDeleted() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let request = try fixture.store.beginRequest(at: start)

        XCTAssertEqual(try fixture.store.activeRequest(at: start), request)
        try fixture.store.write(
            .completed(requestID: request.id, transcript: "one private transcript", at: start),
            at: start
        )

        XCTAssertEqual(
            try fixture.store.takeActiveResult(at: start)?.transcript,
            "one private transcript"
        )
        XCTAssertNil(try fixture.store.takeActiveResult(at: start))
        XCTAssertNil(try fixture.store.activeRequest(at: start))

        let remainingNames = try FileManager.default.contentsOfDirectory(
            at: fixture.container.appendingPathComponent("OpenClamKeyboard"),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertFalse(remainingNames.contains { $0.contains(request.id.uuidString.lowercased()) })
    }

    func testExpiredRequestIsRejectedAndRemoved() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try fixture.store.beginRequest(at: start)

        XCTAssertThrowsError(
            try fixture.store.activeRequest(
                at: start.addingTimeInterval(OpenClamKeyboardRequest.maximumAge + 1)
            )
        ) { error in
            XCTAssertEqual(error as? OpenClamKeyboardStoreError, .staleRequest)
        }
        XCTAssertNil(try fixture.store.activeRequest(at: start))
    }

    @MainActor
    func testAppRouteAcceptsOnlyCurrentStoredKeyboardRequest() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let now = Date()
        let request = try fixture.store.beginRequest(at: now)
        let host = OpenClamKeyboardDictationHostController(store: fixture.store)

        XCTAssertTrue(host.handle(OpenClamKeyboardHandoffURL.make(requestID: request.id), at: now))
        XCTAssertEqual(host.activeRequest, request)
        XCTAssertFalse(host.handle(URL(string: "openclam-livekit-pilot://command?action=clipboard_read")!))

        try host.complete(request, transcript: "dictated text")
        XCTAssertEqual(try fixture.store.result(for: request.id)?.state, .completed)
    }

    @MainActor
    func testVisibleAppRestoresPendingRequestWithoutAnExtensionLaunchURL() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let now = Date()
        let request = try fixture.store.beginRequest(at: now)
        let host = OpenClamKeyboardDictationHostController(store: fixture.store)

        host.restorePendingRequest(at: now)

        XCTAssertEqual(host.activeRequest, request)
    }

    func testExtensionInfoRequestsSharedAccessWithoutClaimingMicrophoneCapture() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = project.appendingPathComponent("KeyboardExtension/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let extensionDictionary = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        let attributes = try XCTUnwrap(
            extensionDictionary["NSExtensionAttributes"] as? [String: Any]
        )

        XCTAssertEqual(
            extensionDictionary["NSExtensionPointIdentifier"] as? String,
            "com.apple.keyboard-service"
        )
        XCTAssertEqual(attributes["RequestsOpenAccess"] as? Bool, true)
        XCTAssertEqual(attributes["IsASCIICapable"] as? Bool, false)
        XCTAssertEqual(attributes["PrimaryLanguage"] as? String, "en-US")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "OpenClam LiveKit Keyboard")
        XCTAssertEqual(
            extensionDictionary["NSExtensionPrincipalClass"] as? String,
            "$(PRODUCT_MODULE_NAME).KeyboardViewController"
        )
        XCTAssertNil(info["NSMicrophoneUsageDescription"])
    }

    private func makeStoreFixture() throws -> (
        container: URL,
        store: OpenClamKeyboardHandoffStore
    ) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenClamKeyboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        return (container, OpenClamKeyboardHandoffStore(containerURL: container))
    }
}
