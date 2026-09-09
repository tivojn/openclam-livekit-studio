import CryptoKit
import Foundation
import XCTest
import WebKit
@testable import OpenClamLiveKit

@MainActor
final class OpenClamDynamicMotionsTests: XCTestCase {
    func testAvatarDeliveryIncludesRevisedFinalsAndCoalescedSentences() throws {
        let thread = UUID()
        let user = ConversationMessage(role: .user, text: "Can you sit?")
        let first = ConversationMessage(role: .assistant, text: "Of course!")
        var boundary = AvatarReplyDeliveryBoundary()
        boundary.prime(with: .init(threadID: thread, messages: [user]))
        XCTAssertEqual(boundary.observe(.init(threadID: thread, messages: [user, first])), first.id)
        var revised = ConversationMessage(id: first.id, role: .assistant, text: "Of course! I'll sit cross-legged for you right now.")
        let followup = ConversationMessage(role: .assistant, text: "Anything else you'd like to see?")
        XCTAssertEqual(boundary.observe(.init(threadID: thread, messages: [user, revised, followup])), followup.id)
        XCTAssertNil(boundary.observe(.init(threadID: thread, messages: [user, revised, followup])))
        revised = ConversationMessage(id: first.id, role: .assistant, text: revised.text + " I'll wave too.")
        XCTAssertEqual(boundary.observe(.init(threadID: thread, messages: [user, revised, followup])), revised.id,
            "An updated earlier segment must survive an unchanged closing sentence")
        XCTAssertNil(boundary.observe(.init(threadID: UUID(), messages: [user, revised, followup])), "History navigation does not replay")
        boundary.prime(with: .init(threadID: thread, messages: [user]))
        let interruption = ConversationMessage(role: .user, text: "Stop")
        XCTAssertNil(boundary.observe(.init(threadID: thread, messages: [user, revised, interruption])), "Barge-in cancels late intent")
    }

    func testLiveTalkVisualReplyCombinesSegmentsAndRevisesOneTurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationModel(historyController: ConversationHistoryController(store:
            ConversationHistoryStore(fileURL: directory.appendingPathComponent("history.json"))))
        for _ in 0..<100 where !model.isHistoryReady { await Task.yield() }
        XCTAssertTrue(model.beginLiveTalkTranscriptSession())
        model.ingestLiveTalkTranscripts([
            .init(id: "user", role: .user, text: "Can you smile Can you sit?", isFinal: true),
            .init(id: "action", role: .agent, text: "Of course! I'll sit cross-legged for you right now.", isFinal: true),
            .init(id: "followup", role: .agent, text: "Anything else you'd like to see?", isFinal: true)
        ])
        let last = try XCTUnwrap(model.messages.last)
        let combined = model.avatarReactionReplyText(for: last.id)
        XCTAssertTrue(combined.contains("I'll sit cross-legged"))
        XCTAssertTrue(combined.contains("Anything else"))
        let name = "AvatarDelivery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OpenClam3DOptionsStore(defaults: defaults)
        let turnID = model.avatarReactionTurnID(for: last.id)
        store.conversation(last, user: "Can you sit?", for: "tia", deliveredAt: Date(), turnID: turnID, replyText: combined)
        let first = try XCTUnwrap(store.conversations["tia"])
        store.conversation(last, user: "Can you sit?", for: "tia", deliveredAt: Date(), turnID: turnID, replyText: combined)
        XCTAssertEqual(store.conversations["tia"], first, "Repeated SwiftUI delivery is a no-op")
        store.conversation(last, user: "Can you sit?", for: "tia", deliveredAt: Date(), turnID: turnID, replyText: combined + " I'll stand now.")
        XCTAssertNotEqual(store.conversations["tia"]?["id"], first["id"])
        XCTAssertEqual(store.conversations["tia"]?["turnID"], first["turnID"], "Revisions share one logical action boundary")
    }

    func testLiveTalkReactionContextStartsAtTheCallBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = ConversationHistoryController(store: ConversationHistoryStore(
            fileURL: directory.appendingPathComponent("history.json")))
        let model = ConversationModel(historyController: history)
        for _ in 0..<100 where !model.isHistoryReady { await Task.yield() }
        XCTAssertTrue(model.beginLiveTalkTranscriptSession())
        model.ingestLiveTalkTranscripts([
            .init(id: "old-user", role: .user, text: "Tia, wave", isFinal: true)
        ])
        model.endLiveTalkTranscriptSession()
        XCTAssertTrue(model.beginLiveTalkTranscriptSession())
        model.ingestLiveTalkTranscripts([
            .init(id: "greeting", role: .agent, text: "Hello!", isFinal: true)
        ])
        let greeting = try XCTUnwrap(model.messages.last)
        XCTAssertEqual(model.avatarReactionUserText(for: greeting.id), "",
            "The greeting must not inherit a motion command from the previous call")
        model.ingestLiveTalkTranscripts([
            .init(id: "user-a", role: .user, text: "I got", isFinal: true),
            .init(id: "user-b", role: .user, text: "the job!", isFinal: true),
            .init(id: "reply", role: .agent, text: "Congratulations!", isFinal: true),
            .init(id: "barge-in", role: .user, text: "Do not celebrate", isFinal: true),
        ])
        let reply = try XCTUnwrap(model.messages.first(where: { $0.text == "Congratulations!" }))
        XCTAssertEqual(model.avatarReactionUserText(for: reply.id), "I got the job!",
            "Coalesced updates must pair the reply with its preceding multi-segment user turn")
    }

    func testLongLiveTalkReplyUsesCompletionTimeWithoutReplayingHistory() throws {
        let name = "OpenClamLiveTalkReactions.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OpenClam3DOptionsStore(defaults: defaults)
        let thread = UUID()
        let user = ConversationMessage(role: .user, text: "I got the job!")
        // Live Talk preserves the first partial's timestamp when finalizing.
        let reply = ConversationMessage(role: .assistant, text: "Congratulations!",
            date: Date(timeIntervalSinceNow: -60), isEligibleForAIContext: false)
        var boundary = AssistantReplyDeliveryBoundary()
        boundary.prime(with: .init(threadID: thread, messages: [user]))
        let final = AssistantReplyDeliverySnapshot(threadID: thread, messages: [user, reply])
        XCTAssertEqual(boundary.observe(final), reply.id)
        let completed = Date()
        store.conversation(reply, user: user.text, for: "tia", deliveredAt: completed)
        let turn = try XCTUnwrap(store.conversations["tia"])
        XCTAssertEqual(turn["reply"], "Congratulations!")
        XCTAssertEqual(try XCTUnwrap(Double(try XCTUnwrap(turn["created"]))),
            completed.timeIntervalSince1970 * 1000, accuracy: 1)
        XCTAssertNil(boundary.observe(final), "Repeated final transcripts must not replay motions")
        XCTAssertNil(boundary.observe(.init(threadID: UUID(), messages: [user, reply])),
            "Restored history must not become a fresh completion")
    }

    func testInitialLiveTalkGreetingCanReactWithoutAUserTurn() throws {
        let name = "OpenClamLiveTalkGreeting.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OpenClam3DOptionsStore(defaults: defaults)
        let reply = ConversationMessage(role: .assistant, text: "Hello! How are you?",
            isEligibleForAIContext: false)
        store.conversation(reply, user: "", for: "tia", deliveredAt: Date())
        XCTAssertEqual(store.conversations["tia"]?["user"], "")
        XCTAssertEqual(store.conversations["tia"]?["reply"], reply.text)
    }

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
        XCTAssertEqual(reply, "Played wave", "Manual controls must await the actual renderer result")
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

    func testLLMMotionChoicesAreHiddenAndBounded() {
        for cue in ["clip:kung-fu-punch", "action:follow", "action:stay", "action:closer", "action:back", "action:walk-around", "action:run-around", "action:go-upper-right", "action:go-center"] {
            let directive = "<<openclam:motion \(cue)>>"
            for length in 1...directive.count {
                XCTAssertEqual(OpenClam3DReaction.extract("My reply.\n" + directive.prefix(length), partial: true).text, "My reply.")
            }
            let result = OpenClam3DReaction.extract("My reply.\n" + directive)
            XCTAssertEqual(result.text, "My reply.")
            XCTAssertEqual(result.suggestion, cue)
        }
        for cue in ["action:open-url", "clip:../../file", "clip:https://example.com"] {
            XCTAssertNil(OpenClam3DReaction.extract("Reply. <<openclam:motion \(cue)>>").suggestion)
        }
        XCTAssertTrue(OpenClam3DReaction.prompt(motions: []).contains("Conversation comes first"))
        let manualOnly = OpenClam3DReaction.prompt(motions: [], automaticReactions: false)
        XCTAssertTrue(manualOnly.contains("Automatic mood reactions are off"))
        XCTAssertTrue(manualOnly.contains("walk-around and run-around"))
        XCTAssertFalse(manualOnly.contains("user enabled expressive reactions"))
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
        store.conversation(.init(role: .assistant, text: "I'll come closer."), user: "Come closer", for: "tia")
        XCTAssertEqual(store.conversations["tia"]?["reply"], "I'll come closer.",
            "Explicit LLM-led requests still reach the shared controller when automatic reactions are off")
        XCTAssertFalse(store.enabled("dynamicMotions", for: "tia"))
        let delivered = store.conversations["tia"]
        store.setEnabled(true, key: "dynamicMotions", for: "tia")
        store.conversation(.init(role: .assistant, text: "Hello!", date: Date(timeIntervalSinceNow: -60)), user: "Hi", for: "tia")
        XCTAssertEqual(store.conversations["tia"], delivered, "Reopening history must not replay reactions")
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
