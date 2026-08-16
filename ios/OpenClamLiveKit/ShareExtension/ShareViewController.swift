import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareExtensionModel(extensionContext: extensionContext)
        let controller = UIHostingController(rootView: ScreenContextShareView(model: model))
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.load(items: items) }
    }
}

@MainActor
private final class ShareExtensionModel: ObservableObject {
    @Published var instruction = ""
    @Published var includeText = false
    @Published var includeURL = false
    @Published var includeImage = false
    @Published private(set) var sharedText: String?
    @Published private(set) var sharedURL: URL?
    @Published private(set) var imageData: Data?
    @Published private(set) var imageTypeIdentifier: String?
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    private weak var extensionContext: NSExtensionContext?

    init(extensionContext: NSExtensionContext?) {
        self.extensionContext = extensionContext
    }

    var hasSupportedContent: Bool {
        sharedText != nil || sharedURL != nil || imageData != nil
    }

    var hasSelectedContent: Bool {
        (includeText && sharedText != nil)
            || (includeURL && sharedURL != nil)
            || (includeImage && imageData != nil)
    }

    func load(items: [NSExtensionItem]) async {
        defer { isLoading = false }
        do {
            let providers = items.compactMap(\.attachments).flatMap { $0 }
            for provider in providers {
                if sharedURL == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try await Self.loadURL(from: provider) {
                    sharedURL = url
                }
                if sharedText == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try await Self.loadText(from: provider) {
                    sharedText = text
                }
                if imageData == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let image = try await Self.loadBoundedImage(from: provider) {
                    imageData = image.data
                    imageTypeIdentifier = image.typeIdentifier
                }
            }
            if !hasSupportedContent {
                errorMessage = "Share one image, text selection, or web link."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveForReview() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let inbox = try ScreenContextInbox.appGroup()
            _ = try await inbox.stage(
                .init(
                    source: .shareExtension,
                    instruction: instruction,
                    sharedText: includeText ? sharedText : nil,
                    sharedURL: includeURL ? sharedURL : nil,
                    imageData: includeImage ? imageData : nil,
                    imageTypeIdentifier: includeImage ? imageTypeIdentifier : nil
                )
            )
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private static func loadURL(from provider: NSItemProvider) async throws -> URL? {
        let item = try await loadItem(from: provider, typeIdentifier: UTType.url.identifier)
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let text = item as? String { return URL(string: text) }
        if let data = item as? Data,
           let text = String(data: data, encoding: .utf8) {
            return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func loadText(from provider: NSItemProvider) async throws -> String? {
        let item = try await loadItem(from: provider, typeIdentifier: UTType.plainText.identifier)
        if let text = item as? String { return text }
        if let text = item as? NSString { return text as String }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    private static func loadItem(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: item)
                }
            }
        }
    }

    private static func loadBoundedImage(
        from provider: NSItemProvider
    ) async throws -> (data: Data, typeIdentifier: String)? {
        let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) ?? UTType.image.identifier
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard let size = attributes[.size] as? NSNumber,
                          size.int64Value > 0,
                          size.int64Value <= Int64(ScreenContextInbox.maximumImageBytes) else {
                        throw ScreenContextError.imageTooLarge
                    }
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    guard data.count == size.intValue,
                          data.count <= ScreenContextInbox.maximumImageBytes else {
                        throw ScreenContextError.imageTooLarge
                    }
                    continuation.resume(returning: (data, typeIdentifier))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct ScreenContextShareView: View {
    @ObservedObject var model: ShareExtensionModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "For example: suggest two replies",
                        text: $model.instruction,
                        axis: .vertical
                    )
                    .lineLimit(3 ... 6)
                } header: {
                    Text("What should OpenClam do?")
                } footer: {
                    Text("Nothing is analyzed, captured, or sent while you type.")
                }

                Section("Include in the review") {
                    if model.isLoading {
                        ProgressView("Reading the items you chose…")
                    }
                    if let text = model.sharedText {
                        Toggle(isOn: $model.includeText) {
                            Label("Shared text", systemImage: "text.quote")
                        }
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    if let url = model.sharedURL {
                        Toggle(isOn: $model.includeURL) {
                            Label("Web link", systemImage: "link")
                        }
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    if model.imageData != nil {
                        Toggle(isOn: $model.includeImage) {
                            Label("Selected image", systemImage: "photo")
                        }
                        Text("No OCR or automatic image task will run.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !model.isLoading && !model.hasSupportedContent {
                        ContentUnavailableView(
                            "No supported context",
                            systemImage: "square.and.arrow.up.trianglebadge.exclamationmark",
                            description: Text("Choose one image, text selection, or web link.")
                        )
                    }
                }

                Section {
                    Text("Saving puts one expiring item in OpenClam. Open the app to review exactly what will go to your selected AI provider, then tap Send.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Share for review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await model.saveForReview() }
                    }
                    .disabled(
                        model.isLoading
                            || model.isSaving
                            || model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !model.hasSelectedContent
                    )
                }
            }
            .alert(
                "Could not save context",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "The shared context could not be saved.")
            }
        }
    }
}
