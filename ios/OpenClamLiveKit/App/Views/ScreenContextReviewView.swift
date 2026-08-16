import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Main-app review UI for context from the Action Button, Share extension, Shortcuts, or a
/// user-selected screenshot. Its callback should add the bounded payload to the composer; the
/// existing Send control remains the separate provider consent boundary.
struct ScreenContextReviewView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var session: ScreenContextReviewSession
    let onAddToComposer: (ScreenContextSubmission) -> Void
    let setupMessages: [String]
    let externalCommand: AssistantCommand?
    let isConfirmingExternalCommand: Bool
    let externalActionResult: String?
    let onCancelExternalCommand: () -> Void
    let onConfirmExternalCommand: (AssistantCommand) -> Void

    @State private var editedInstruction = ""
    @State private var includeText = false
    @State private var includeURL = false
    @State private var includeImage = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedPhotoData: Data?
    @State private var selectedPhotoTypeIdentifier: String?
    @State private var isLoadingPhoto = false
    @State private var isExtractingText = false
    @State private var errorMessage: String?
    @State private var didAttemptRestore = false

    init(
        session: ScreenContextReviewSession,
        onAddToComposer: @escaping (ScreenContextSubmission) -> Void,
        setupMessages: [String] = [],
        externalCommand: AssistantCommand? = nil,
        isConfirmingExternalCommand: Bool = false,
        externalActionResult: String? = nil,
        onCancelExternalCommand: @escaping () -> Void = {},
        onConfirmExternalCommand: @escaping (AssistantCommand) -> Void = { _ in }
    ) {
        self.session = session
        self.onAddToComposer = onAddToComposer
        self.setupMessages = setupMessages
        self.externalCommand = externalCommand
        self.isConfirmingExternalCommand = isConfirmingExternalCommand
        self.externalActionResult = externalActionResult
        self.onCancelExternalCommand = onCancelExternalCommand
        self.onConfirmExternalCommand = onConfirmExternalCommand
    }

    var body: some View {
        Form {
            if let externalCommand {
                externalCommandSection(externalCommand)
            } else if let externalActionResult {
                Section("Latest external action") {
                    Text(externalActionResult)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if !setupMessages.isEmpty {
                setupSection
            }
            if let review = session.review {
                reviewSections(review)
            } else {
                intakeSections
            }
        }
        .navigationTitle("Screen Context")
        .task {
            guard !didAttemptRestore else { return }
            didAttemptRestore = true
            await restorePending()
        }
        .onChange(of: session.review?.id) { _, _ in
            configureForCurrentReview()
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await loadSelectedPhoto(item) }
        }
        .alert(
            "Screen Context error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "The context could not be prepared.")
        }
    }

    private var setupSection: some View {
        Section {
            Label("Some context features need setup", systemImage: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
            Text(setupMessages.joined(separator: " "))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func externalCommandSection(_ command: AssistantCommand) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: command.action.systemImage)
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 32)
                    .frame(minHeight: 44, alignment: .top)
                VStack(alignment: .leading, spacing: 5) {
                    Text(command.action.title)
                        .font(.headline)
                    Text(command.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(command.source.label)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    confirmExternalButton(command)
                    cancelExternalButton
                }
            } else {
                HStack(spacing: 12) {
                    cancelExternalButton
                    confirmExternalButton(command)
                }
            }
        } header: {
            Text("External action awaiting confirmation")
        } footer: {
            Text("Everything this action will do is shown above. Confirmed runs it now; Cancel discards it.")
        }
    }

    private var cancelExternalButton: some View {
        Button(role: .cancel, action: onCancelExternalCommand) {
            Text("Cancel")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
            .buttonStyle(.bordered)
            .disabled(isConfirmingExternalCommand)
    }

    private func confirmExternalButton(_ command: AssistantCommand) -> some View {
        Button {
            onConfirmExternalCommand(command)
        } label: {
            if isConfirmingExternalCommand {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Label("Confirmed", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isConfirmingExternalCommand)
        .accessibilityLabel(isConfirmingExternalCommand ? "Running confirmed action" : "Confirmed")
    }

    @ViewBuilder
    private func reviewSections(_ review: ScreenContextReview) -> some View {
        Section("What should OpenClam do?") {
            TextField("Instruction", text: $editedInstruction, axis: .vertical)
                .lineLimit(3 ... 7)
                .accessibilityLabel("Screen context instruction")
        }

        Section("Choose exactly what to include") {
            if let text = review.locallyExtractedText ?? review.sharedText,
               !text.isEmpty {
                Toggle(isOn: $includeText) {
                    Label(
                        review.locallyExtractedText == nil ? "Shared text" : "Locally extracted text",
                        systemImage: "text.quote"
                    )
                }
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
            if let url = review.sharedURL {
                Toggle("Web link", isOn: $includeURL)
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let imageData = review.imageData {
                Toggle("Selected image", isOn: $includeImage)
                if let image = LocalAttachmentPreviewFactory.makePreview(from: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Selected screen context image")
                }
                if review.locallyExtractedText == nil {
                    Button {
                        isExtractingText = true
                        Task {
                            do {
                                try await session.extractTextAfterUserConfirmation(reviewID: review.id)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                            isExtractingText = false
                        }
                    } label: {
                        Label("Extract text locally", systemImage: "text.viewfinder")
                    }
                    .disabled(isExtractingText)
                }
            }
            if review.source == .actionButton,
               review.sharedText == nil,
               review.sharedURL == nil,
               review.imageData == nil {
                Text("The Action Button opened this intake; it did not capture the previous app. Choose a screenshot below or use that app's Share sheet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                screenshotPicker
            }
        }

        Section {
            Button {
                do {
                    let submission = try session.consumeForOneRequest(
                        reviewID: review.id,
                        editedInstruction: editedInstruction,
                        includeText: includeText,
                        includeURL: includeURL,
                        includeImage: includeImage
                    )
                    onAddToComposer(submission)
                } catch {
                    errorMessage = error.localizedDescription
                }
            } label: {
                Label("Add to one request", systemImage: "text.badge.plus")
            }

            Button("Discard", role: .destructive) {
                session.discard()
            }
        } footer: {
            Text("Adding context does not contact your AI provider. Review the finished composer, then tap Send separately.")
        }
    }

    private var intakeSections: some View {
        Group {
            Section {
                Text("Choose a screenshot yourself or share content from another app. OpenClam cannot silently inspect another app's screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("What should OpenClam do?") {
                TextField("For example: suggest two replies", text: $editedInstruction, axis: .vertical)
                    .lineLimit(3 ... 7)
                    .accessibilityLabel("Screen context instruction")
            }

            Section {
                screenshotPicker
                if isLoadingPhoto {
                    ProgressView("Reading your selected image…")
                } else if let selectedPhotoData {
                    Text("Selected image: \(ByteCountFormatter.string(fromByteCount: Int64(selectedPhotoData.count), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Prepare for review") {
                        do {
                            try session.stageSelectedScreenshot(
                                data: selectedPhotoData,
                                typeIdentifier: selectedPhotoTypeIdentifier ?? UTType.image.identifier,
                                instruction: editedInstruction
                            )
                            self.selectedPhotoData = nil
                            selectedPhoto = nil
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            } header: {
                Text("Choose a screenshot")
            } footer: {
                Text("Selecting an image does not run OCR. Text extraction is a separate button in the next review step.")
            }

            Section {
                Button("Check for shared context") {
                    Task { await restorePending() }
                }
            }
        }
    }

    private var screenshotPicker: some View {
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
            Label("Choose image from Photos", systemImage: "photo.on.rectangle")
        }
    }

    private func configureForCurrentReview() {
        editedInstruction = session.review?.originalInstruction ?? editedInstruction
        includeText = false
        includeURL = false
        includeImage = false
    }

    private func restorePending() async {
        do {
            if try await session.restorePendingIntake() {
                configureForCurrentReview()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSelectedPhoto(_ item: PhotosPickerItem) async {
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  !data.isEmpty else {
                throw ScreenContextError.noSelectedImage
            }
            guard data.count <= ScreenContextInbox.maximumImageBytes else {
                throw ScreenContextError.imageTooLarge
            }
            let metadata: BoundedImageMetadata
            do {
                metadata = try BoundedImageData.validate(
                    data,
                    maximumDimension: ScreenContextInbox.maximumShortcutImageDimension,
                    maximumPixelCount: ScreenContextInbox.maximumShortcutImagePixels
                )
            } catch BoundedImageValidationError.dimensionsExceeded {
                throw ScreenContextError.shortcutImageDimensionsTooLarge
            } catch {
                throw ScreenContextError.invalidImageMetadata
            }
            selectedPhotoData = data
            selectedPhotoTypeIdentifier = metadata.typeIdentifier
        } catch {
            selectedPhotoData = nil
            selectedPhotoTypeIdentifier = nil
            errorMessage = error.localizedDescription
        }
    }
}
