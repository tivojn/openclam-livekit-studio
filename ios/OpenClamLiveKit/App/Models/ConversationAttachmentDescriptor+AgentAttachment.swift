import Foundation

extension ConversationAttachmentDescriptor {
    /// Converts a staged item to display metadata without retaining its Data or temporary URL.
    init(stagedAttachment attachment: StagedAgentAttachment) {
        let mimeType: String?
        switch attachment.source {
        case .imageData(_, let sourceMIMEType):
            mimeType = sourceMIMEType
        case .stagedFile(_, let sourceMIMEType), .stagedVideo(_, let sourceMIMEType):
            mimeType = sourceMIMEType
        }
        self.init(
            id: attachment.id,
            kind: Self.historyKind(for: attachment.kind),
            displayName: attachment.displayName,
            mimeType: mimeType,
            sourceByteCount: attachment.sourceByteCount
        )
    }

    /// Converts a prepared request item to display metadata; request-ready contentParts are
    /// deliberately ignored so base64 data can never cross into chat history.
    init(preparedAttachment attachment: PreparedAgentAttachment) {
        self.init(
            id: attachment.id,
            kind: Self.historyKind(for: attachment.kind),
            displayName: attachment.displayName,
            sourceByteCount: attachment.sourceByteCount
        )
    }

    private static func historyKind(for kind: AgentAttachmentKind) -> Kind {
        switch kind {
        case .image: .image
        case .file: .file
        case .video: .video
        }
    }
}
