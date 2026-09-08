import CryptoKit
import Foundation
import XCTest
import WebKit
@testable import OpenClamLiveKit

@MainActor
final class OpenClamDynamicMotionsTests: XCTestCase {
    func testNativeCommandAwaitsTheJavaScriptResult() async throws {
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 200, height: 300))
        view.loadHTMLString("<script>window.avatarCommand = async (value,isText) => { await new Promise(r=>setTimeout(r,20)); return isText ? 'Played '+value : null; }</script>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof window.avatarCommand")) as? String == "function" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let coordinator = OpenClam3DWebView.Coordinator()
        coordinator.pageReady = true
        coordinator.view = view
        let reply = try await coordinator.command("wave", isText: true)
        XCTAssertEqual(reply, "Played wave", "The callback overload returns Void and would fall through to the AI route")
        let unmatched = try await coordinator.command("ordinary chat", isText: false)
        XCTAssertNil(unmatched)
        view.stopLoading()
    }

    func testPrivateSuggestionNeverAppearsInStreamingText() {
        let prefix = "Congratulations!\n", directive = "<<openclam:motion celebration>>"
        for length in 1...directive.count {
            XCTAssertEqual(OpenClam3DReaction.extract(prefix + directive.prefix(length), partial: true).text, "Congratulations!")
        }
        let parsed = OpenClam3DReaction.extract(prefix + directive)
        XCTAssertEqual(parsed.suggestion, "celebration")
        XCTAssertEqual(parsed.text, "Congratulations!")
        XCTAssertNil(OpenClam3DReaction.extract("Hello <<openclam:motion open-url>>").suggestion)
        XCTAssertEqual(OpenClam3DReaction.extract("2 < 3", partial: true).text, "2 < 3")
    }

    func testDefaultReactionsAndExplicitOffSurviveResetAndRelaunch() throws {
        let name = "OpenClamDynamicMotionsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OpenClam3DOptionsStore(defaults: defaults)
        XCTAssertTrue(store.enabled("dynamicMotions", for: "tia"))
        store.setEnabled(false, key: "dynamicMotions", for: "tia")
        store.reset("tia")
        XCTAssertFalse(OpenClam3DOptionsStore(defaults: defaults).enabled("dynamicMotions", for: "tia"))
        store.conversation(.init(role: .assistant, text: "Hello!"), user: "Hi", for: "tia")
        XCTAssertNil(store.conversations["tia"])
        store.setEnabled(true, key: "dynamicMotions", for: "tia")
        store.conversation(.init(role: .assistant, text: "Hello!", date: Date(timeIntervalSinceNow: -60)), user: "Hi", for: "tia")
        XCTAssertNil(store.conversations["tia"], "Reopening history must not replay reactions")
    }

    func testPackRequiresExactModelAndRejectsUnlistedOrDamagedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = String(repeating: "a", count: 64)
        let files: [String: Data] = ["library.json": Data("{\"version\":1,\"clips\":[{\"id\":\"wave\",\"file\":\"wave.json\"}]}".utf8), "wave.json": Data("{}".utf8)]
        var index: [String: OpenClam3DMotionPack.File] = [:]
        for (name, data) in files {
            try data.write(to: root.appendingPathComponent(name))
            index[name] = .init(sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), byteCount: data.count)
        }
        try JSONEncoder().encode(OpenClam3DMotionPack.Index(modelSHA256: model, files: index))
            .write(to: root.appendingPathComponent("index.local.json"))
        XCTAssertNil(try OpenClam3DMotionPack.load(modelSHA256: "different", root: root))
        let pack = try XCTUnwrap(OpenClam3DMotionPack.load(modelSHA256: model, root: root))
        XCTAssertEqual(try pack.resource(path: "/motions/wave.json"), files["wave.json"])
        XCTAssertThrowsError(try pack.resource(path: "/motions/../wave.json"))
        try Data("[]".utf8).write(to: root.appendingPathComponent("wave.json"))
        XCTAssertThrowsError(try pack.resource(path: "/motions/wave.json"))
    }
}
