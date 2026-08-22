import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AssistantModel
    @EnvironmentObject private var aiConfiguration: AIConfigurationModel
    @EnvironmentObject private var conversation: ConversationModel
    @EnvironmentObject private var agentConnections: AgentConnectionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var screenContextFeature = ScreenContextFeatureModel.make()
    @State private var navigationPath: [OpenClamRoute] = []
    @State private var showsSidebar = false
    @State private var avatarSwitchTask: Task<Void, Never>?
    @State private var connectorRouteChangeTask: Task<Void, Never>?
    @State private var connectorDeletionNotice: String?

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack(path: $navigationPath) {
                ConversationView(
                    onShowSidebar: showSidebar,
                    onSelectAvatar: switchAvatarFromCarousel,
                    onShowSettings: { show(.settings) },
                    onShowAISettings: { show(.aiServices) }
                )
                .navigationDestination(for: OpenClamRoute.self) { route in
                    destination(for: route)
                }
            }
            .allowsHitTesting(!showsSidebar)
            .accessibilityHidden(showsSidebar)

            if showsSidebar {
                sidebarOverlay
                    .zIndex(10)
                    .transition(.opacity)
            }
        }
        .sheet(item: $model.messageDraft) { draft in
            MessageComposer(draft: draft) { result in
                model.finishMessageDraft(result)
                if result == .sent {
                    conversation.dismissSMSDraft()
                }
            }
        }
        .sheet(item: $model.mailDraft) { draft in
            MailComposeView(draft: draft) { event in
                model.finishMailDraft(event)
                switch event {
                case .fallbackCopied, .finished(.saved), .finished(.submitted):
                    conversation.dismissEmailDraft()
                case .unavailable, .finished(.cancelled), .finished(.failed):
                    break
                }
            }
        }
        .onChange(of: conversation.pendingShortcutPrompt) { _, prompt in
            guard prompt != nil else { return }
            showsSidebar = false
            navigationPath.removeAll()
        }
        .onChange(of: model.pendingCommand?.id) { _, commandID in
            if commandID != nil {
                showContextReview()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .pendingScreenContextDidChange)
        ) { _ in
            showContextReview()
        }
        .task {
            await conversation.ensureHistoryReady()
            await agentConnections.reconcileArtifacts(
                referencedBy: conversation.historyController.allMessages
            )
            await restoreActiveAvatarThread()
            await routePendingScreenContextIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
                Task {
                    await conversation.ensureHistoryReady()
                    await restoreActiveAvatarThread()
                    await routePendingScreenContextIfNeeded()
            }
        }
        .alert(
            "OpenClaw chat",
            isPresented: Binding(
                get: { connectorDeletionNotice != nil },
                set: { if !$0 { connectorDeletionNotice = nil } }
            )
        ) {
            Button("OK") { connectorDeletionNotice = nil }
        } message: {
            Text(connectorDeletionNotice ?? "This chat cannot be deleted yet.")
        }
    }

    @ViewBuilder
    private func destination(for route: OpenClamRoute) -> some View {
        switch route {
        case .settings:
            OpenClamSettingsView(configuration: aiConfiguration)
        case .aiServices:
            AISettingsView(configuration: aiConfiguration)
        case .avatarAgents:
            AvatarAgentSettingsView(
                configuration: aiConfiguration,
                onActivate: switchAvatar,
                onConnectorRouteChanged: connectorRouteChanged
            )
        case .agentConnections:
            AgentConnectionsSettingsView()
        case .screenContext:
            ContextRootView(
                feature: screenContextFeature,
                onShowAssistant: showAssistant
            )
        case .appAliases:
            AppAliasSettingsView(registry: conversation.appAliasRegistry)
        case .shortcutsAndIntegrations:
            SetupView()
        case .capabilitiesAndPermissions:
            CapabilitiesView()
        }
    }

    private var sidebarOverlay: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Button {
                    hideSidebar()
                } label: {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close sidebar")

                OpenClamSidebarView(
                    historyController: conversation.historyController,
                    canChangeChat: conversation.canChangeChat,
                    onClose: hideSidebar,
                    onNewChat: {
                        Task {
                            await conversation.newChat()
                            registerSelectedThreadForActiveAvatar()
                            showAssistant()
                        }
                    },
                    onSelectChat: { id in
                        Task {
                            await selectChatAndAgent(id: id)
                            showAssistant()
                        }
                    },
                    onRenameChat: { id, title in
                        Task { await conversation.renameChat(id: id, title: title) }
                    },
                    onDeleteChat: { id in
                        Task {
                            do {
                                if let reason = try agentConnections
                                    .threadDeletionBlockReason(for: id) {
                                    connectorDeletionNotice = reason
                                    return
                                }
                            } catch {
                                connectorDeletionNotice = error.localizedDescription
                                return
                            }
                            let deletedMessages = conversation.historyController.messages(in: id)
                            aiConfiguration.removeThread(id)
                            await conversation.deleteChat(id: id)
                            if !conversation.historyController.summaries.contains(where: {
                                $0.id == id
                            }) {
                                await agentConnections.deleteArtifacts(
                                    referencedBy: deletedMessages
                                )
                            }
                            registerSelectedThreadForActiveAvatar()
                        }
                    },
                    onShowSettings: {
                        hideSidebar()
                        show(.settings)
                    }
                )
                .frame(width: min(360, geometry.size.width * 0.88))
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 24, x: 8)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }

    private func showSidebar() {
        withOptionalAnimation {
            showsSidebar = true
        }
    }

    private func switchAvatar(id: String, displayName: String) {
        switchAvatar(id: id, displayName: displayName, preservesAvatarOverlay: false)
    }

    private func switchAvatarFromCarousel(id: String, displayName: String) {
        switchAvatar(id: id, displayName: displayName, preservesAvatarOverlay: true)
    }

    private func switchAvatar(
        id: String,
        displayName: String,
        preservesAvatarOverlay: Bool
    ) {
        // Avatar changes, including deletion fallback, must silence the old
        // avatar immediately. A reply may still be finishing, so retain the
        // newest requested switch and apply it as soon as chat mutation is safe.
        conversation.stopSpeechOutput()
        avatarSwitchTask?.cancel()
        avatarSwitchTask = Task { @MainActor in
            await conversation.ensureHistoryReady()
            while !conversation.canChangeChat {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            // A reply that was already working may have started read-aloud
            // after the first stop while this task waited. Silence it again
            // at the exact handoff boundary before changing conversations.
            conversation.stopSpeechOutput()
            aiConfiguration.activateAvatar(id: id, displayName: displayName)

            if let targetThreadID = aiConfiguration.activeThreadID(for: id) {
                await conversation.selectChat(id: targetThreadID)
            }
            if aiConfiguration.activeThreadID(for: id) == nil
                || conversation.historyController.selectedThreadID
                    != aiConfiguration.activeThreadID(for: id) {
                await conversation.newChat()
            }
            registerSelectedThreadForActiveAvatar()
            await conversation.recoverPendingRemoteTurnIfNeeded(
                aiConfiguration: aiConfiguration,
                agentConnections: agentConnections
            )
            if preservesAvatarOverlay {
                withOptionalAnimation {
                    showsSidebar = false
                    navigationPath.removeAll()
                }
            } else {
                showAssistant()
            }
        }
    }

    private func selectChatAndAgent(id: UUID) async {
        let avatarID = aiConfiguration.avatarID(for: id) ?? AvatarAgentIdentity.defaultID
        aiConfiguration.activateAvatar(
            id: avatarID,
            displayName: aiConfiguration.profile(for: avatarID).displayName
        )
        await conversation.selectChat(id: id)
        if conversation.historyController.selectedThreadID == id {
            aiConfiguration.registerThread(id, for: avatarID)
            await conversation.recoverPendingRemoteTurnIfNeeded(
                aiConfiguration: aiConfiguration,
                agentConnections: agentConnections
            )
        }
    }

    private func registerSelectedThreadForActiveAvatar() {
        guard let threadID = conversation.historyController.selectedThreadID else { return }
        aiConfiguration.registerThread(
            threadID,
            for: aiConfiguration.activeAvatarID,
            route: aiConfiguration.activeAvatarProfile.preferredConversationRoute
        )
    }

    private func connectorRouteChanged(avatarID: String) {
        aiConfiguration.requireNewThreadForRouteChange(avatarID: avatarID)
        guard aiConfiguration.activeAvatarID == avatarID else { return }
        connectorRouteChangeTask?.cancel()
        connectorRouteChangeTask = Task { @MainActor in
            conversation.stopSpeechOutput()
            while !conversation.canChangeChat {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled,
                  aiConfiguration.activeAvatarID == avatarID else { return }
            await conversation.newChat()
            registerSelectedThreadForActiveAvatar()
        }
    }

    private func restoreActiveAvatarThread() async {
        if let threadID = aiConfiguration.activeThreadID(for: aiConfiguration.activeAvatarID),
           conversation.historyController.selectedThreadID != threadID {
            await conversation.selectChat(id: threadID)
        }
        registerSelectedThreadForActiveAvatar()
        if aiConfiguration.activeThreadID(for: aiConfiguration.activeAvatarID) == nil,
           conversation.canChangeChat {
            await conversation.newChat()
            registerSelectedThreadForActiveAvatar()
        }
        await conversation.recoverPendingRemoteTurnIfNeeded(
            aiConfiguration: aiConfiguration,
            agentConnections: agentConnections
        )
    }

    private func hideSidebar() {
        withOptionalAnimation {
            showsSidebar = false
        }
    }

    private func show(_ route: OpenClamRoute) {
        hideSidebar()
        guard navigationPath.last != route else { return }
        navigationPath.append(route)
    }

    private func showAssistant() {
        withOptionalAnimation {
            showsSidebar = false
            navigationPath.removeAll()
        }
    }

    private func showContextReview() {
        withOptionalAnimation {
            showsSidebar = false
            navigationPath = [.screenContext]
        }
    }

    /// App Intents and extensions may stage context before this process starts, so their
    /// in-process notification is not a durable cold-launch signal. Peek keeps review as the
    /// sole consumer while still routing the user to it whenever the app becomes active.
    private func routePendingScreenContextIfNeeded() async {
        do {
            let inbox = try ScreenContextInbox.appGroup()
            if try await inbox.peek() != nil {
                showContextReview()
            }
        } catch {
            // A missing or unavailable app-group container is not evidence that a
            // pending item exists. Do not block a normal launch with a speculative
            // alert; an actual in-process intake notification still routes directly
            // to the review screen, which owns its own visible error handling.
        }
    }

    private func withOptionalAnimation(_ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(.easeInOut(duration: 0.2), updates)
        }
    }
}
