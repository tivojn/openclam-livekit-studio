import Foundation

struct ActivityRecord: Identifiable {
    enum State {
        case staged
        case dispatched
        case completed
        case cancelled
        case failed

        var systemImage: String {
            switch self {
            case .staged: "clock.badge.questionmark"
            case .dispatched: "arrow.up.forward.circle.fill"
            case .completed: "checkmark.circle.fill"
            case .cancelled: "xmark.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            }
        }
    }

    let id = UUID()
    let date: Date
    let title: String
    let detail: String
    let state: State
}

struct MessageDraft: Identifiable, Equatable {
    let id = UUID()
    let recipient: String
    let body: String
}
