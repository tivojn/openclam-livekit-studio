import Foundation

/// Speech announcements remain append-only. Visual decisions also need later
/// revisions of a finalized Live Talk segment and coalesced assistant sentences.
struct AvatarReplyDeliverySnapshot: Equatable {
    struct Message: Equatable {
        let id: UUID
        let role: ConversationMessage.Role
        let text: String
    }
    let threadID: UUID?
    let messages: [Message]

    init(threadID: UUID?, messages: [ConversationMessage]) {
        self.threadID = threadID
        self.messages = messages.map { .init(id: $0.id, role: $0.role, text: $0.text) }
    }
}

struct AvatarReplyDeliveryBoundary {
    private var previous: AvatarReplyDeliverySnapshot?

    mutating func prime(with snapshot: AvatarReplyDeliverySnapshot) { previous = snapshot }

    mutating func observe(_ snapshot: AvatarReplyDeliverySnapshot) -> UUID? {
        defer { previous = snapshot }
        guard let previous, previous.threadID == snapshot.threadID,
              snapshot.messages.count >= previous.messages.count,
              Array(snapshot.messages.prefix(previous.messages.count).map(\.id)) == previous.messages.map(\.id)
        else { return nil }
        let old = Dictionary(uniqueKeysWithValues: previous.messages.map { ($0.id, $0.text) })
        // A later user turn owns intent. Do not start a late motion belonging to
        // an interrupted answer when both arrive in the same UI transaction.
        return snapshot.messages.reversed().prefix(while: { $0.role == .assistant })
            .first(where: { old[$0.id] != $0.text })?.id
    }
}
