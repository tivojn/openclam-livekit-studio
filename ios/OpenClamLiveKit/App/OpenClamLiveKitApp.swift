import SwiftUI

/// The product palette is deliberately achromatic. Semantic colors remain at
/// their call sites for real success, warning, and error states; ordinary
/// selection, navigation, and progress UI uses these graphite tokens.
enum OpenClamTheme {
    static let accent = Color.accentColor
    static let active = Color.primary
    static let inactive = Color.secondary
    static let subtleFill = Color.primary.opacity(0.06)
    static let emphasizedFill = Color.primary.opacity(0.10)
    static let subtleStroke = Color.primary.opacity(0.18)
    static let emphasizedStroke = Color.primary.opacity(0.24)
}

@main
struct OpenClamLiveKitApp: App {
    @StateObject private var model = AssistantModel()
    @StateObject private var conversation = ConversationModel()
    @StateObject private var aiConfiguration = AIConfigurationModel()
    @StateObject private var agentConnections = AgentConnectionModel()
    @StateObject private var avatarLibrary = OpenClamAvatarLibrary.shared
    @StateObject private var keyboardDictationHost = OpenClamKeyboardDictationHostController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(OpenClamTheme.accent)
                .environmentObject(model)
                .environmentObject(conversation)
                .environmentObject(aiConfiguration)
                .environmentObject(agentConnections)
                .environmentObject(avatarLibrary)
                .environmentObject(keyboardDictationHost)
                .sheet(item: $keyboardDictationHost.activeRequest) { request in
                    OpenClamKeyboardDictationHostView(
                        request: request,
                        host: keyboardDictationHost,
                        aiConfiguration: aiConfiguration
                    )
                }
                .onOpenURL { url in
                    if !keyboardDictationHost.handle(url) {
                        model.stage(url: url)
                    }
                }
                .onAppear {
                    avatarLibrary.reconcileCommittedDeletions(
                        configuration: aiConfiguration
                    )
                    aiConfiguration.reconcileAvatarCatalog(avatarLibrary.identities)
                    keyboardDictationHost.configure(aiConfiguration: aiConfiguration)
                    keyboardDictationHost.setCompetingAppAudioActive(
                        conversation.isSpeechOutputActive
                            || conversation.isPronunciationOutputActive,
                        owner: .speechOutput
                    )
                    model.restoreStagedCommand()
                    conversation.restorePendingShortcutPrompt()
                    keyboardDictationHost.restorePendingRequest()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .pendingAgentPromptDidChange)
                ) { _ in
                    conversation.restorePendingShortcutPrompt()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .pendingCommandDidChange)
                ) { _ in
                    model.restoreStagedCommand()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        keyboardDictationHost.applicationDidBecomeActive()
                        model.restoreStagedCommand()
                        conversation.restorePendingShortcutPrompt()
                        keyboardDictationHost.restorePendingRequest()
                    }
                }
                .onChange(
                    of: conversation.isSpeechOutputActive
                        || conversation.isPronunciationOutputActive
                ) { _, active in
                    keyboardDictationHost.setCompetingAppAudioActive(
                        active,
                        owner: .speechOutput
                    )
                }
        }
    }
}
