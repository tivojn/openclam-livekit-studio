import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// An adapter around the same renderer sources used by macOS. UIKit owns
/// touch gestures; WebKit receives only presentation and expression values.
@MainActor
struct OpenClam3DWebView: UIViewRepresentable {
    let avatar: OpenClamAvatarDescriptor
    let pose: OpenClam3DAvatarPose
    let orbit: OpenClam3DOrbit
    let visibleRect: CGRect
    var isActive = true
    @ObservedObject private var options = OpenClam3DOptionsStore.shared

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        Self.makeWebView(coordinator: context.coordinator)
    }

    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(coordinator.assets, forURLScheme: "openclam-avatar")
        config.userContentController.add(coordinator, name: "avatarStatus")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        // SwiftUI already places this canvas inside the conversation's safe
        // area. A second WebKit inset shortens its CSS viewport and squeezes
        // the logical camera crop vertically (728pt became 654pt on iPhone).
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isUserInteractionEnabled = false
        view.navigationDelegate = coordinator
        view.accessibilityIdentifier = "openclam-shared-3d-renderer"
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard case let .installedFile(url)? = avatar.asset(.model) else { return }
        let coordinator = context.coordinator
        if coordinator.avatarID != avatar.id,
           options.renderers[coordinator.avatarID] === coordinator { options.renderers[coordinator.avatarID] = nil }
        coordinator.avatarID = avatar.id
        coordinator.view = view
        options.renderers[avatar.id] = coordinator
        let now = ProcessInfo.processInfo.systemUptime
        var revision = coordinator.modelRevision
        if coordinator.modelURL != url || now - coordinator.lastRevisionCheck > 1 {
            coordinator.lastRevisionCheck = now
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            revision = "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(values?.fileSize ?? 0)"
        }
        if coordinator.modelURL != url || coordinator.modelRevision != revision {
            coordinator.modelRevision = revision
            coordinator.modelURL = url
            coordinator.assets.modelURL = url
            coordinator.assets.revision = revision
            coordinator.recoveryCount = 0
            coordinator.start(view)
        }
        let frame = avatar.geometry.bodySize.cgSize
        coordinator.latest = [
            "frame": ["width": frame.width, "height": frame.height],
            "crop": ["x": visibleRect.minX, "y": visibleRect.minY,
                     "w": visibleRect.width, "h": visibleRect.height],
            "orbit": ["yaw": orbit.yaw, "pitch": orbit.pitch],
            "state": pose.webState,
            "performance": ["active": isActive,
                "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "thermal": ProcessInfo.processInfo.thermalState.rawValue],
            "conversation": options.conversations[avatar.id] ?? [:],
            "options": options.selection(for: avatar.id),
            "pointer": options.pointers[avatar.id].map { ["x": $0.x, "y": $0.y] as Any } ?? NSNull(),
        ]
        if coordinator.retryID != options.retryIDs[avatar.id, default: 0] {
            coordinator.retryID = options.retryIDs[avatar.id, default: 0]
            coordinator.recoveryCount = 0
            coordinator.start(view)
        }
        coordinator.needsFlush = true
        coordinator.flush(view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("window.disposeAvatar?.()", completionHandler: nil)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "avatarStatus")
        if OpenClam3DOptionsStore.shared.renderers[coordinator.avatarID] === coordinator {
            OpenClam3DOptionsStore.shared.renderers[coordinator.avatarID] = nil
        }
        coordinator.startup?.cancel()
        coordinator.timeout?.cancel()
        coordinator.assets.cancelAll()
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let assets = OpenClam3DWebAssets()
        var avatarID = ""
        weak var view: WKWebView?

        func command(_ value: String, isText: Bool) async throws -> String? {
            guard pageReady, !hasFailed, let view else { return nil }
            return try await view.callAsyncJavaScript(
                "return await window.avatarCommand(value, isText)",
                arguments: ["value": value, "isText": isText], in: nil, contentWorld: .page) as? String
        }
        var modelURL: URL?
        var modelRevision = ""
        var lastRevisionCheck: TimeInterval = 0
        var pageReady = false
        var updating = false
        var latest: [String: Any]?
        private var lastFrame: NSDictionary?
        var needsFlush = false
        var hasFailed = false
        var generation = 0
        var recoveryCount = 0
        var retryID = 0
        var timeout: Task<Void, Never>?
        var startup: Task<Void, Never>?
        var preparing = false
        var activeNavigation: WKNavigation?
        static let recoveryDelays: [Duration] = [.seconds(2), .seconds(5)]

        func start(_ view: WKWebView, delay: Duration = .zero) {
            generation += 1
            hasFailed = false
            view.accessibilityValue = "Loading"
            let current = generation
            pageReady = false
            updating = false
            lastFrame = nil
            needsFlush = true
            startup?.cancel()
            timeout?.cancel()
            assets.cancelAll()
            activeNavigation = nil
            view.stopLoading()
            preparing = true
            assets.maximumTextureSize = recoveryCount == 0 ? 2048 : recoveryCount == 1 ? 768 : 512
            assets.onCatalogue = { [weak self] catalogue in
                guard let self, self.generation == current else { return }
                OpenClam3DOptionsStore.shared.receive(catalogue, for: self.avatarID)
            }
            // Defer publication out of UIViewRepresentable's update transaction.
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, !self.hasFailed else { return }
                OpenClam3DOptionsStore.shared.setLoadState(.loading, for: self.avatarID)
            }
            armTimeout(view, generation: current, seconds: 120)
            startup = Task { @MainActor [weak self, weak view] in
                do {
                    // A terminated WebKit process needs time to release its resources.
                    // Do not launch a replacement while the app is in the background.
                    try await Task.sleep(for: delay)
                    guard let self, let view, self.generation == current else { return }
                    while UIApplication.shared.applicationState != .active {
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    try Task.checkCancellation()
                    try await self.assets.prepare()
                    while UIApplication.shared.applicationState != .active {
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    try Task.checkCancellation()
                    guard self.generation == current, !self.hasFailed else { return }
                    self.preparing = false
                    self.armTimeout(view, generation: current, seconds: 60)
                    self.activeNavigation = view.load(URLRequest(url: URL(string:
                        "openclam-avatar://local/index.html?generation=\(current)")!))
                } catch is CancellationError {
                    // A newer model, retry, or dismantle superseded this preparation.
                } catch {
                    guard let self, let view, self.generation == current, !self.hasFailed else { return }
                    self.fail(error.localizedDescription, view: view)
                }
            }
        }

        private func armTimeout(_ view: WKWebView, generation current: Int, seconds: Int) {
            timeout?.cancel()
            timeout = Task { @MainActor [weak self, weak view] in
                // Count foreground time: locking the phone is not a load failure.
                for _ in 0..<seconds {
                    do {
                        repeat { try await Task.sleep(for: .seconds(1)) }
                        while UIApplication.shared.applicationState != .active
                    } catch { return }
                }
                guard let self, let view, self.generation == current else { return }
                self.fail("The 3D avatar took too long to load. Try loading it again.", view: view)
            }
        }

        func fail(_ message: String, view: WKWebView) {
            hasFailed = true
            startup?.cancel()
            preparing = false
            view.accessibilityValue = "Failed"
            timeout?.cancel()
            pageReady = false
            assets.cancelAll()
            view.stopLoading()
            OpenClam3DOptionsStore.shared.setLoadState(.failed(message), for: avatarID)
            view.callAsyncJavaScript("window.showAvatarError?.(message)", arguments: ["message": message],
                                     in: nil, in: .page, completionHandler: nil)
        }

        func flush(_ view: WKWebView) {
            guard pageReady, !updating, needsFlush, let latest else { return }
            needsFlush = false
            // An idle TimelineView tick often produces identical state. Avoid
            // serializing the whole conversation and crossing processes again.
            let frame = latest as NSDictionary
            guard lastFrame?.isEqual(to: latest) != true else { return }
            lastFrame = frame
            let current = generation
            updating = true
            view.callAsyncJavaScript("window.updateAvatar(frame)", arguments: ["frame": latest],
                                     in: nil, in: .page) { [weak self, weak view] result in
                guard let self, self.generation == current else { return }
                self.updating = false
                if case .failure(let error) = result, let view {
                    if (error as NSError).domain == WKError.errorDomain,
                       (error as NSError).code == WKError.webContentProcessTerminated.rawValue {
                        self.webViewWebContentProcessDidTerminate(view)
                    } else { self.fail(error.localizedDescription, view: view) }
                    return
                }
                if let view { self.flush(view) }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  body["generation"] as? Int == generation, !hasFailed else { return }
            if body["event"] as? String == "page-ready" {
                pageReady = true
                if let view = message.webView { flush(view) }
            }
            if body["event"] as? String == "rendered" {
                message.webView?.accessibilityValue = "Ready"
                timeout?.cancel()
                OpenClam3DOptionsStore.shared.setLoadState(.ready, for: avatarID)
            }
            if body["event"] as? String == "renderer-lost", let view = message.webView {
                webViewWebContentProcessDidTerminate(view)
                return
            }
            if body["event"] as? String == "motion-framing" {
                OpenClam3DOptionsStore.shared.motionPresentationRequests[avatarID, default: 0] += 1
            }
            if body["event"] as? String == "motion-status" {
                OpenClam3DOptionsStore.shared.motionStatuses[avatarID] = String((body["text"] as? String ?? "").prefix(160))
            }
            if body["event"] as? String == "preference", let key = body["key"] as? String,
               let value = body["value"] as? Bool {
                OpenClam3DOptionsStore.shared.setEnabled(value, key: key, for: avatarID)
            }
            if body["event"] as? String == "pose", let id = body["id"] as? String {
                OpenClam3DOptionsStore.shared.select(id, group: "body", for: avatarID)
            }
            if let error = body["error"] as? String, let view = message.webView {
                fail(error, view: view)
            }
            if body["event"] as? String == "catalogue", let catalogue = body["catalogue"] {
                OpenClam3DOptionsStore.shared.receive(catalogue, for: avatarID)
            } else { print("3D renderer: \(body)") }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            decisionHandler(url?.scheme == "openclam-avatar" && url?.host == "local" ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // Ignore duplicate callbacks from the dead page during preparation.
            guard !preparing, !hasFailed else { return }
            if recoveryCount < Self.recoveryDelays.count {
                let delay = Self.recoveryDelays[recoveryCount]
                recoveryCount += 1
                start(webView, delay: delay)
            } else {
                fail("iOS stopped the 3D renderer. Open 3D controls to try again.", view: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !preparing, !hasFailed, navigation === activeNavigation,
                  (error as NSError).code != NSURLErrorCancelled else { return }
            if (error as NSError).domain == WKError.errorDomain,
               (error as NSError).code == WKError.webContentProcessTerminated.rawValue {
                webViewWebContentProcessDidTerminate(webView)
            } else { fail(error.localizedDescription, view: webView) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.webView(webView, didFail: navigation, withError: error)
        }
    }
}

/// The scheme exposes only the selected model and these bundled resources.
/// There is no local server, arbitrary file access, or network dependency.
@MainActor
final class OpenClam3DWebAssets: NSObject, WKURLSchemeHandler {
    var modelURL: URL?
    static let resources: [String: String] = [
        "/index.html": "avatar-ios.html", "/avatar-ios.js": "avatar-ios.js",
        "/avatar3d.js": "avatar3d.js",
        "/avatar3d-options.js": "avatar3d-options.js",
        "/avatar3d-motion.js": "avatar3d-motion.js",
        "/avatar3d-companion.js": "avatar3d-companion.js",
        "/vendor/three/three.module.js": "three.module.js",
        "/vendor/three/three.core.js": "three.core.js",
        "/vendor/three/GLTFLoader.js": "GLTFLoader.js",
        "/vendor/three/RoomEnvironment.js": "RoomEnvironment.js",
        "/vendor/three/BufferGeometryUtils.js": "BufferGeometryUtils.js",
        "/vendor/three/SkeletonUtils.js": "SkeletonUtils.js",
    ]

    var revision = ""
    var maximumTextureSize = 2048
    var onCatalogue: (([String: Any]) -> Void)?
    private var requests: [ObjectIdentifier: UUID] = [:]
    private let worker = ModelResourceWorker()
    private var preparation: UUID?

    func cancelAll() { requests.removeAll(); preparation = nil }

    func prepare() async throws {
        guard let modelURL else { throw URLError(.fileDoesNotExist) }
        let token = UUID(), revision = revision, maximum = maximumTextureSize
        preparation = token
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.queue.async { [worker, weak self] in
                let cancelled = { DispatchQueue.main.sync { self?.preparation != token } }
                let result = Result<Void, Error> {
                    if cancelled() { throw CancellationError() }
                    let model = try worker.model(url: modelURL, revision: revision, maximum: maximum)
                    DispatchQueue.main.sync {
                        guard let self, self.preparation == token, let model else { return }
                        self.onCatalogue?(worker.catalogue(model))
                    }
                    try model?.prepareImages(isCancelled: cancelled)
                    if cancelled() { throw CancellationError() }
                }
                DispatchQueue.main.async {
                    if self?.preparation == token { self?.preparation = nil }
                    continuation.resume(with: result)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let request = task.request.url, request.host == "local" else {
            task.didFailWithError(URLError(.unsupportedURL)); return
        }
        let key = ObjectIdentifier(task), token = UUID()
        requests[key] = token
        let modelURL = modelURL, revision = revision, maximum = maximumTextureSize
        let bundled = Self.resources[request.path].flatMap { Bundle.main.url(forResource: $0, withExtension: nil) }
        worker.queue.async { [worker, weak self] in
            let active = DispatchQueue.main.sync { self?.requests[key] == token }
            guard active else { return }
            let result: Result<(Data, String, [String: Any]?), Error> = Result {
                try autoreleasepool {
                    if let bundled {
                        return (try Data(contentsOf: bundled), request.path.hasSuffix(".js") ? "text/javascript" : "text/html", nil)
                    }
                    guard let modelURL else { throw URLError(.fileDoesNotExist) }
                    let prepared = try worker.model(url: modelURL, revision: revision, maximum: maximum)
                    if request.path.hasPrefix("/motions/") {
                        if let pack = worker.motionPack { return (try pack.resource(path: request.path), "application/json", nil) }
                        if request.path == "/motions/library.json" {
                            return (Data("{\"version\":1,\"clips\":[]}".utf8), "application/json", nil)
                        }
                        throw URLError(.fileDoesNotExist)
                    }
                    guard let model = prepared else {
                        guard request.path == "/model.gltf" else { throw URLError(.fileDoesNotExist) }
                        return (try Data(contentsOf: modelURL, options: .mappedIfSafe), "model/gltf-binary", nil)
                    }
                    if request.path == "/model.gltf" { return (model.document, "model/gltf+json", worker.catalogue(model)) }
                    let parts = request.path.split(separator: "/")
                    guard parts.count == 2, let digits = parts[1].split(separator: ".").first,
                          let index = Int(digits), index >= 0 else {
                        throw URLError(.fileDoesNotExist)
                    }
                    if request.path == "/buffers/\(index).bin" { return (try model.buffer(at: index), "application/octet-stream", nil) }
                    if request.path == "/images/\(index).png" { return (try model.image(at: index), "image/png", nil) }
                    throw URLError(.fileDoesNotExist)
                }
            }
            // Finish each delivery before decoding the next image. This bounds
            // native memory and lets WebKit's stop callback cancel queued work.
            DispatchQueue.main.sync {
                guard let self, self.requests[key] == token else { return }
                self.requests[key] = nil
                switch result {
                case let .success((data, type, catalogue)):
                    if let catalogue { self.onCatalogue?(catalogue) }
                    let response = HTTPURLResponse(url: request, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": type, "Content-Length": String(data.count),
                            "Cache-Control": "no-store", "Access-Control-Allow-Origin": "*"])!
                    task.didReceive(response)
                    task.didReceive(data)
                    task.didFinish()
                case let .failure(error): task.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        requests[ObjectIdentifier(task)] = nil
    }
}

/// Accessed only on its serial queue. Holding the source handle also keeps an
/// in-flight load consistent if the package is atomically replaced.
private final class ModelResourceWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.openclam.3d-resources", qos: .userInitiated)
    private var key = ""
    private var source: OpenClam3DModelResources?
    private(set) var motionPack: OpenClam3DMotionPack?
    func catalogue(_ model: OpenClam3DModelResources) -> [String: Any] {
        var value = model.catalogue
        value["motions"] = motionPack?.choices ?? []
        return value
    }

    func model(url: URL, revision: String, maximum: Int) throws -> OpenClam3DModelResources? {
        let next = "\(url.path):\(revision):\(maximum)"
        if next == key { return source }
        do {
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("OpenClam/3DTextures", isDirectory: true)
            let model = try OpenClam3DModelResources(url: url, maximumTextureSize: maximum, cacheRoot: cache)
            source = model
            motionPack = try OpenClam3DMotionPack.load(modelSHA256: model.modelSHA256)
            key = next
            print("3D textures: \(model.originalTextureBytes) → \(model.decodedTextureBytes) bytes; limit \(model.textureLimit)")
            return model
        } catch OpenClam3DModelError.externalResources {
            // Imported GLBs containing inline data URIs remain supported by
            // the original loader. The bounded path covers packed BIN assets.
            source = nil
            motionPack = nil
            key = next
            return nil
        }
    }
}

extension OpenClam3DAvatarPose {
    var webState: [String: Any] {
        ["visemeWeights": Dictionary(uniqueKeysWithValues: visemeWeights.map { ($0.key.rawValue, $0.value) }),
         "intensity": articulation, "blink": ["l": blinkLeft, "r": blinkRight],
         "gaze": ["x": gazeX, "y": gazeY], "brow": brow,
         "expression": ["smile": smile, "sad": sad, "surprise": surprise, "anger": anger],
         "head": ["yaw": headYaw, "pitch": headPitch, "roll": headRoll],
         "speaking": speaking, "reduce": reduceMotion]
    }
}

struct OpenClam3DChoice: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    var group: String?
    var pose: String?
    var category: String?
}

struct OpenClam3DCatalogue: Codable, Equatable {
    var poses: [OpenClam3DChoice] = []
    var outfits: [OpenClam3DChoice] = []
    var props: [OpenClam3DChoice] = []
    var motions: [OpenClam3DChoice]?
    var hasChoices: Bool { !poses.isEmpty || !outfits.isEmpty || !props.isEmpty }
}

enum OpenClam3DLoadState: Equatable {
    case loading
    case ready
    case failed(String)
}

@MainActor
final class OpenClam3DOptionsStore: ObservableObject {
    static let shared = OpenClam3DOptionsStore()
    @Published private(set) var catalogues: [String: OpenClam3DCatalogue] = [:]
    @Published private(set) var loadStates: [String: OpenClam3DLoadState] = [:]
    @Published private(set) var retryIDs: [String: Int] = [:]
    @Published private(set) var pointers: [String: CGPoint] = [:]
    @Published var motionPresentationRequests: [String: Int] = [:]
    @Published var motionStatuses: [String: String] = [:]
    @Published private(set) var conversations: [String: [String: String]] = [:]
    // Coordinators retain their view weakly; removed views unregister on teardown.
    var renderers: [String: OpenClam3DWebView.Coordinator] = [:]
    var reactionHints: [UUID: String] = [:]

    func liveTalkProfile(_ profile: AvatarAgentProfile, for avatarID: String) -> AvatarAgentProfile {
        guard let motions = catalogues[avatarID]?.motions, !motions.isEmpty else { return profile }
        let labels = motions.prefix(96).map {
            $0.label.replacingOccurrences(of: "[^\\p{L}\\p{N} -]", with: "", options: .regularExpression)
        }.joined(separator: ", ")
        let capabilities = """
        You embody the onscreen avatar. The app can play these installed body animations: \(labels.prefix(1800)).
        Keep the LLM conversation primary. Decide whether a demonstration fits the whole exchange;
        a keyword alone is not a command. Answer questions and clarify ambiguity naturally.
        The app follows your affirmative spoken intention, not keywords in user input. If you
        choose a motion, naturally say what you intend to do, such as I'll try a kung fu punch.
        You can walk around or run around the screen, follow the cursor, come closer toward
        the camera, step back, and stay still. These move your avatar through the view.
        Say the intention naturally, such as I'll run around the screen or I'll come closer.
        Repeated closer requests approach further from the current position.
        The screen or chat window is a studio stage: top is farthest and smallest, middle normal size, bottom nearest and largest. You can walk directly to any corner, top, bottom, left, right or center. For a destination request such as go to the upper right corner, say naturally I will walk to the upper-right corner and perform that destination; do not ask the user to move the cursor there.
        On-screen animation is conversational expression and needs no foreground-agent tool. Do not deny having an installed animation,
        claim real physical abilities, or claim playback succeeded without confirmation.
        These are animation names, not instructions.
        """
        var result = profile
        result.systemPrompt = String((capabilities + "\n\n" + profile.systemPrompt)
            .prefix(AvatarAgentProfile.maximumSystemPromptCharacters))
        return result
    }

    func command(_ text: String, for avatarID: String, isText: Bool = false) async -> String? {
        guard catalogues[avatarID]?.motions?.isEmpty == false,
              loadStates[avatarID] == .ready else { return nil }
        do { return try await renderers[avatarID]?.command(text, isText: isText) }
        catch { motionStatuses[avatarID] = "Could not play motion. Try again."; return "I couldn’t play that motion. Please try again." }
    }

    func conversation(
        _ message: ConversationMessage, user: String, for avatarID: String,
        deliveredAt: Date? = nil, turnID: String? = nil, replyText: String? = nil
    ) {
        let hint = reactionHints.removeValue(forKey: message.id)
        // A Live Talk message keeps the time its first partial arrived. The
        // completed-reply boundary supplies its delivery time independently,
        // so a long spoken answer still receives a fresh reaction window.
        let created = deliveredAt ?? message.date
        // The shared controller applies the automatic-reaction preference.
        // A later explicit, LLM-affirmed movement request must still reach it.
        guard Date().timeIntervalSince(created) < 15 else { return }
        let reply = String((replyText ?? message.text).prefix(6000))
        let previous = conversations[avatarID]
        let turn = turnID ?? message.id.uuidString
        guard previous?["turnID"] != turn || previous?["reply"] != reply || hint != nil else { return }
        conversations[avatarID] = ["id": UUID().uuidString, "turnID": turn, "user": String(user.prefix(6000)),
            "reply": reply, "suggestion": hint ?? "", "created": String(created.timeIntervalSince1970 * 1000)]
    }

    @Published private var selections: [String: [String: String]]
    private let defaults: UserDefaults
    private let key = "openclam.3d.appearanceSelections"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selections = (defaults.data(forKey: key)).flatMap {
            try? JSONDecoder().decode([String: [String: String]].self, from: $0)
        } ?? [:]
    }

    func selection(for avatarID: String) -> [String: String] { selections[avatarID] ?? [:] }

    func receive(_ value: Any, for avatarID: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), data.count < 100_000,
              let catalogue = try? JSONDecoder().decode(OpenClam3DCatalogue.self, from: data),
              catalogue.poses.count <= 256, catalogue.outfits.count <= 64, catalogue.props.count <= 64, (catalogue.motions?.count ?? 0) <= 96
        else { return }
        if catalogues[avatarID] != catalogue { catalogues[avatarID] = catalogue }
    }

    func setLoadState(_ state: OpenClam3DLoadState, for avatarID: String) {
        if loadStates[avatarID] != state { loadStates[avatarID] = state }
    }

    func retry(_ avatarID: String) {
        loadStates[avatarID] = .loading
        retryIDs[avatarID, default: 0] += 1
    }

    func point(_ location: CGPoint?, in size: CGSize, for avatarID: String) {
        guard enabled("followCursor", for: avatarID), let location,
              size.width > 0, size.height > 0, location.x.isFinite, location.y.isFinite else {
            pointers[avatarID] = nil
            return
        }
        pointers[avatarID] = CGPoint(x: location.x / size.width, y: location.y / size.height)
    }

    func enabled(_ key: String, for avatarID: String) -> Bool {
        selection(for: avatarID)[key] != "false"
    }

    func setEnabled(_ enabled: Bool, key: String, for avatarID: String) {
        guard ["playTransitions", "followCursor", "dynamicMotions"].contains(key) else { return }
        var next = selection(for: avatarID)
        next[key] = enabled ? nil : "false"
        if key == "followCursor", !enabled { pointers[avatarID] = nil }
        selections[avatarID] = next
        save()
    }

    func select(_ id: String, group: String, for avatarID: String) {
        guard let catalogue = catalogues[avatarID] else { return }
        let choices = group == "outfit" ? catalogue.outfits : group == "prop" ? catalogue.props
            : catalogue.poses.filter { $0.group == group }
        guard id.isEmpty || choices.contains(where: { $0.id == id }) else { return }
        var next = selection(for: avatarID)
        next[group] = id.isEmpty ? nil : id
        if ["body", "hands", "leftHand", "rightHand"].contains(group) {
            next["playTransitions"] = "false"
        }
        if group == "body" || (group == "prop" && !id.isEmpty) {
            for hand in ["hands", "leftHand", "rightHand"] { next[hand] = nil }
        }
        if group == "prop", !id.isEmpty { next["body"] = choices.first(where: { $0.id == id })?.pose }
        selections[avatarID] = next
        save()
    }

    func reset(_ avatarID: String) {
        var next = ["playTransitions": "false"]
        next["followCursor"] = selection(for: avatarID)["followCursor"]
        next["dynamicMotions"] = selection(for: avatarID)["dynamicMotions"]
        selections[avatarID] = next
        save()
    }
    private func save() { if let data = try? JSONEncoder().encode(selections) { defaults.set(data, forKey: key) } }
}


@MainActor
struct OpenClam3DWardrobeSheet: View {
    let avatarID: String
    let name: String
    let allowsImport: Bool
    let onImport: (String, String) -> Void
    let onBodyPose: () -> Void
    @ObservedObject private var options = OpenClam3DOptionsStore.shared
    @ObservedObject private var avatarLibrary = OpenClamAvatarLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showsImporter = false
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let clips = options.catalogues[avatarID]?.motions, !clips.isEmpty {
                    Section("Dynamic motions") {
                        behavior("React to conversation", key: "dynamicMotions")
                        Button("Stop motion") { playMotion("stay") }
                        NavigationLink("Browse motions (\(clips.count))") {
                            OpenClam3DMotionBrowser(avatarID: avatarID, clips: clips, onPlay: onBodyPose)
                        }.accessibilityIdentifier("openclam-3d-browse-motions")
                        Button("Random dance") { playMotion("random-dance") }
                        Button("Come closer") { playMotion("closer") }
                        Button("Step back") { playMotion("back") }
                        Button("Walk around") { playMotion("walk-around") }
                        Button("Run around") { playMotion("run-around") }
                        NavigationLink("Walk to…") {
                            OpenClam3DStageDestinations(onSelect: playMotion)
                        }
                        if let status = options.motionStatuses[avatarID], !status.isEmpty {
                            Text(status).font(.footnote).accessibilityIdentifier("openclam-3d-motion-status")
                        }
                    }
                }
                if let library = options.catalogues[avatarID], library.hasChoices {
                    choices("Outfit", group: "outfit", items: library.outfits, fallback: "Original appearance")
                    choices("Body Pose", group: "body", items: library.poses.filter { $0.group == "body" }, fallback: "Relaxed standing")
                    choices("Both Hands", group: "hands", items: library.poses.filter { $0.group == "hands" }, fallback: "From body pose")
                    choices("Left Hand", group: "leftHand", items: library.poses.filter { $0.group == "leftHand" }, fallback: "From body pose")
                    choices("Right Hand", group: "rightHand", items: library.poses.filter { $0.group == "rightHand" }, fallback: "From body pose")
                    choices("Prop", group: "prop", items: library.props, fallback: "None")
                    behavior("Play transitions", key: "playTransitions")
                    behavior("Follow cursor", key: "followCursor")
                    Button("Reset Appearance & Pose") { options.reset(avatarID) }
                        .accessibilityIdentifier("openclam-3d-appearance-reset")
                } else {
                    Section {
                        if avatarLibrary.updatingAvatarID == avatarID {
                            ProgressView("Adding clothing, props, and poses…")
                        } else if options.loadStates[avatarID] == .ready {
                            Text("This avatar has no wardrobe or poses available.")
                            .accessibilityIdentifier("openclam-3d-library-missing")
                        } else if case .failed = options.loadStates[avatarID] {
                            Text("The avatar could not finish loading.")
                        } else {
                            ProgressView("Loading avatar and wardrobe…")
                        }
                    }
                    Section {
                        behavior("Play transitions", key: "playTransitions")
                        behavior("Follow cursor", key: "followCursor")
                    }
                }
                if case let .failed(message) = options.loadStates[avatarID] {
                    Section {
                        Text(message)
                        Button("Retry 3D Avatar") { options.retry(avatarID) }
                            .accessibilityIdentifier("openclam-3d-retry")
                    }
                } else if options.loadStates[avatarID] == .loading,
                          options.catalogues[avatarID]?.hasChoices == true {
                    Section { ProgressView("Loading 3D avatar…") }
                }
                if let error = avatarLibrary.bundledUpdateErrors[avatarID] {
                    Section {
                        Text(error)
                        Button("Retry Wardrobe Update") {
                            Task { await avatarLibrary.applyBundledUpdates() }
                        }
                        .disabled(!allowsImport || avatarLibrary.isMutating)
                    } header: { Text("Wardrobe update couldn’t finish") }
                }
                Section {
                    Button("Import Wardrobe Package…", systemImage: "square.and.arrow.down") { showsImporter = true }
                        .disabled(isImporting || avatarLibrary.isMutating || !allowsImport || avatarLibrary.isProtected(id: avatarID))
                        .accessibilityIdentifier("openclam-3d-import-wardrobe")
                    if isImporting { ProgressView("Importing wardrobe…") }
                } footer: {
                    Text(!allowsImport ? "End Live Talk to import a different package."
                         : "You can also choose an updated avatar package from Files.")
                }
            }
            .navigationTitle("\(name) · Wardrobe & Poses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(isImporting) } }
        }
        .tint(.primary)
        .task {
            if allowsImport { await avatarLibrary.applyBundledUpdates() }
        }
        .interactiveDismissDisabled(isImporting)
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.openClamAvatarPackage],
                      allowsMultipleSelection: false, onCompletion: importWardrobe)
        .alert("Couldn’t import wardrobe", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) { Button("OK", role: .cancel) { importError = nil } }
        message: { Text(importError ?? "") }
    }

    private func importWardrobe(_ result: Result<[URL], Error>) {
        guard allowsImport, !isImporting else { return }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            Task { @MainActor in
                defer { isImporting = false }
                do {
                    let avatar = try await avatarLibrary.importAvatar(
                        from: url, expectedID: avatarID, replacingExisting: true)
                    onImport(avatar.id, avatar.displayName)
                    dismiss()
                } catch { importError = error.localizedDescription }
            }
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError { importError = error.localizedDescription }
        }
    }

    private func playMotion(_ action: String) {
        onBodyPose()
        Task { _ = await options.command(action, for: avatarID) }
    }

    private func behavior(_ title: String, key: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { options.enabled(key, for: avatarID) },
            set: { value in
                options.setEnabled(value, key: key, for: avatarID)
                if key == "playTransitions", value { onBodyPose() }
            }
        ))
        .accessibilityIdentifier("openclam-3d-\(key)")
    }

    private func choices(_ title: String, group: String, items: [OpenClam3DChoice], fallback: String) -> some View {
        Picker(title, selection: Binding(
            get: { options.selection(for: avatarID)[group] ?? "" },
            set: { value in
                options.select(value, group: group, for: avatarID)
                if group == "body" || group == "prop" { onBodyPose() }
            }
        )) {
            Text(fallback).tag("")
            ForEach(items) { Text($0.label).tag($0.id) }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("openclam-3d-choice-\(group)")
    }
}

/// Named stage positions share the same commands as LLM-directed travel.
/// A navigation page remains usable while the avatar animates behind the sheet.
private struct OpenClam3DStageDestinations: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void
    var body: some View {
        List {
            Section("Farther away · smaller") {
                destination("Upper left", "go-upper-left")
                destination("Top", "go-top")
                destination("Upper right", "go-upper-right")
            }
            Section("Middle · normal size") {
                destination("Left", "go-left")
                destination("Center", "go-center")
                destination("Right", "go-right")
            }
            Section("Closer · larger") {
                destination("Lower left", "go-lower-left")
                destination("Bottom", "go-bottom")
                destination("Lower right", "go-lower-right")
            }
        }.navigationTitle("Walk to").navigationBarTitleDisplayMode(.inline)
    }
    private func destination(_ name: String, _ action: String) -> some View {
        Button(name) { onSelect(action); dismiss() }
    }
}
