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
            "pointer": options.pointers[avatar.id].map { ["x": $0.x, "y": $0.y] as Any } ?? NSNull(),
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
    var hasChoices: Bool { !poses.isEmpty || !outfits.isEmpty || !props.isEmpty }
}

@MainActor
final class OpenClam3DOptionsStore: ObservableObject {
    static let shared = OpenClam3DOptionsStore()
    @Published private(set) var catalogues: [String: OpenClam3DCatalogue] = [:]
    @Published private(set) var pointers: [String: CGPoint] = [:]
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
        guard ["playTransitions", "followCursor"].contains(key) else { return }
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
                        } else {
                            Text("This avatar has no wardrobe or poses available.")
                            .accessibilityIdentifier("openclam-3d-library-missing")
                        }
                    }
                    Section {
                        behavior("Play transitions", key: "playTransitions")
                        behavior("Follow cursor", key: "followCursor")
                    }
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
