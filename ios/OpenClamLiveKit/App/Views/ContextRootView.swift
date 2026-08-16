import SwiftUI
#if OPENCLAM_LIVE_SCREEN_CONTEXT
import UIKit
#endif

/// A single, reachable home for explicit screen context, live iOS 27 capture, and the uncommon
/// externally staged command-review surface.
struct ContextRootView: View {
    @EnvironmentObject private var commandModel: AssistantModel
    @EnvironmentObject private var conversation: ConversationModel
    @EnvironmentObject private var aiConfiguration: AIConfigurationModel

    @ObservedObject var feature: ScreenContextFeatureModel
    let onShowAssistant: () -> Void

    @State private var restoreError: String?
    @State private var externalActionResult: String?

    var body: some View {
        ScreenContextReviewView(
            session: feature.reviewSession,
            onAddToComposer: stageForComposer,
            setupMessages: feature.setupMessages,
            externalCommand: commandModel.pendingCommand,
            isConfirmingExternalCommand: commandModel.isExecuting,
            externalActionResult: externalActionResult,
            onCancelExternalCommand: cancelExternalCommand,
            onConfirmExternalCommand: confirmExternalCommand
        )
        .toolbar {
#if OPENCLAM_LIVE_SCREEN_CONTEXT
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    liveScreenDestination
                } label: {
                    Label("Live Screen Context", systemImage: "rectangle.inset.filled.and.person.filled")
                        .labelStyle(.iconOnly)
                }
            }
#endif
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .pendingScreenContextDidChange)
        ) { _ in
            Task { await restorePendingContext() }
        }
        .task {
            await restorePendingContext()
        }
        .alert(
            "Screen Context setup",
            isPresented: Binding(
                get: { restoreError != nil },
                set: { if !$0 { restoreError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreError ?? "Shared context could not be restored.")
        }
    }

#if OPENCLAM_LIVE_SCREEN_CONTEXT
    @ViewBuilder
    private var liveScreenDestination: some View {
        if !AIProviderRegistry.supportsAttachmentInput(
            provider: aiConfiguration.settings.llm.provider
        ) {
            ContentUnavailableView(
                "Choose a media-capable model",
                systemImage: "photo.badge.exclamationmark",
                description: Text(
                    "Live Screen Context sends one reviewed frame. Choose OpenAI or xAI as the language-model provider in AI Settings first; Anthropic and Gemini are text-only in this build."
                )
            )
            .navigationTitle("Live Screen Context")
        } else if #available(iOS 27.0, *), let manager = feature.captureManager {
            ScreenCaptureSessionView(
                manager: manager,
                onQuestionReadyForOneRequest: submitLiveScreenQuestion
            )
        } else {
            ContentUnavailableView(
                "Live Screen Context unavailable",
                systemImage: "rectangle.slash",
                description: Text(
                    feature.setupMessages.first
                        ?? "Live full-display context requires iOS 27 and a build provisioned for Screen Recording."
                )
            )
            .navigationTitle("Live Screen Context")
        }
    }

    private func submitLiveScreenQuestion(_ question: ScreenContextQuestion) {
        Task { @MainActor in
            let succeeded = await conversation.submitLiveScreenQuestion(
                question,
                using: aiConfiguration
            )
            if succeeded,
               UIApplication.shared.applicationState != .active {
                conversation.speakLatestAssistantReply(using: aiConfiguration)
            }
        }
    }
#endif

    private func stageForComposer(_ submission: ScreenContextSubmission) {
        conversation.stageScreenContextSubmission(submission)
        onShowAssistant()
    }

    private func restorePendingContext() async {
        do {
            _ = try await feature.reviewSession.restorePendingIntake()
        } catch {
            restoreError = error.localizedDescription
        }
    }

    private func cancelExternalCommand() {
        commandModel.cancelPending()
        externalActionResult = commandModel.lastResult
    }

    private func confirmExternalCommand(_ command: AssistantCommand) {
        guard commandModel.pendingCommand?.id == command.id else { return }
        Task { @MainActor in
            await commandModel.runPending()
            externalActionResult = commandModel.lastResult
        }
    }
}
