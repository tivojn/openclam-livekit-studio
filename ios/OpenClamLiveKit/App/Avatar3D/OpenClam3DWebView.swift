import SwiftUI
import WebKit

/// An adapter around the same renderer sources used by macOS. UIKit owns
/// touch gestures; WebKit receives only presentation and expression values.
@MainActor
struct OpenClam3DWebView: UIViewRepresentable {
    let avatar: OpenClamAvatarDescriptor
    let pose: OpenClam3DAvatarPose
    let orbit: OpenClam3DOrbit
    let visibleRect: CGRect
    @ObservedObject private var options = OpenClam3DOptionsStore.shared

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator.assets, forURLScheme: "openclam-avatar")
        config.userContentController.add(context.coordinator, name: "avatarStatus")
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
        view.navigationDelegate = context.coordinator
        view.accessibilityIdentifier = "openclam-shared-3d-renderer"
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard case let .installedFile(url)? = avatar.asset(.model) else { return }
        let coordinator = context.coordinator
        coordinator.avatarID = avatar.id
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
            coordinator.pageReady = false
            view.load(URLRequest(url: URL(string: "openclam-avatar://local/index.html")!))
        }
        let frame = avatar.geometry.bodySize.cgSize
        coordinator.latest = [
            "frame": ["width": frame.width, "height": frame.height],
            "crop": ["x": visibleRect.minX, "y": visibleRect.minY,
                     "w": visibleRect.width, "h": visibleRect.height],
            "orbit": ["yaw": orbit.yaw, "pitch": orbit.pitch],
            "state": pose.webState,
            "options": options.selection(for: avatar.id),
        ]
        coordinator.flush(view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "avatarStatus")
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let assets = OpenClam3DWebAssets()
        var avatarID = ""
        var modelURL: URL?
        var modelRevision = ""
        var lastRevisionCheck: TimeInterval = 0
        var pageReady = false
        var updating = false
        var latest: [String: Any]?

        func flush(_ view: WKWebView) {
            guard pageReady, !updating, let latest else { return }
            self.latest = nil
            updating = true
            view.callAsyncJavaScript("window.updateAvatar(frame)", arguments: ["frame": latest],
                                     in: nil, in: .page) { [weak self, weak view] result in
                guard let self else { return }
                self.updating = false
                if case .failure(let error) = result { print("3D bridge: \(error.localizedDescription)") }
                if let view { self.flush(view) }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            if body["event"] as? String == "page-ready" {
                pageReady = true
                if let view = message.webView { flush(view) }
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
            pageReady = false
            updating = false
            webView.reload()
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
        "/vendor/three/three.module.js": "three.module.js",
        "/vendor/three/three.core.js": "three.core.js",
        "/vendor/three/GLTFLoader.js": "GLTFLoader.js",
        "/vendor/three/RoomEnvironment.js": "RoomEnvironment.js",
        "/vendor/three/BufferGeometryUtils.js": "BufferGeometryUtils.js",
        "/vendor/three/SkeletonUtils.js": "SkeletonUtils.js",
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let request = task.request.url, request.host == "local" else {
            task.didFailWithError(URLError(.unsupportedURL)); return
        }
        let path = request.path
        let url: URL?
        if path == "/model.glb" { url = modelURL }
        else if let name = Self.resources[path] { url = Bundle.main.url(forResource: name, withExtension: nil) }
        else { url = nil }
        guard let url else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            let type = path.hasSuffix(".js") ? "text/javascript" : path.hasSuffix(".glb") ? "model/gltf-binary" : "text/html"
            let response = HTTPURLResponse(url: request, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": type, "Content-Length": String(length), "Cache-Control": "no-store", "Access-Control-Allow-Origin": "*"])!
            task.didReceive(response)
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { task.didReceive(chunk) }
            task.didFinish()
        } catch { task.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
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
}

struct OpenClam3DCatalogue: Codable, Equatable {
    var poses: [OpenClam3DChoice] = []
    var outfits: [OpenClam3DChoice] = []
    var props: [OpenClam3DChoice] = []
}

@MainActor
final class OpenClam3DOptionsStore: ObservableObject {
    static let shared = OpenClam3DOptionsStore()
    @Published private(set) var catalogues: [String: OpenClam3DCatalogue] = [:]
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
              catalogue.poses.count <= 256, catalogue.outfits.count <= 64, catalogue.props.count <= 64
        else { return }
        if catalogues[avatarID] != catalogue { catalogues[avatarID] = catalogue }
    }

    func select(_ id: String, group: String, for avatarID: String) {
        guard let catalogue = catalogues[avatarID] else { return }
        let choices = group == "outfit" ? catalogue.outfits : group == "prop" ? catalogue.props
            : catalogue.poses.filter { $0.group == group }
        guard id.isEmpty || choices.contains(where: { $0.id == id }) else { return }
        var next = selection(for: avatarID)
        next[group] = id.isEmpty ? nil : id
        if group == "body" || (group == "prop" && !id.isEmpty) {
            for hand in ["hands", "leftHand", "rightHand"] { next[hand] = nil }
        }
        if group == "prop", !id.isEmpty { next["body"] = choices.first(where: { $0.id == id })?.pose }
        selections[avatarID] = next
        save()
    }

    func reset(_ avatarID: String) { selections[avatarID] = [:]; save() }
    private func save() { if let data = try? JSONEncoder().encode(selections) { defaults.set(data, forKey: key) } }
}
