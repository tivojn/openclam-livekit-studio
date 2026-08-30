import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ScreenVoicePTTWidgetBundle: WidgetBundle {
    var body: some Widget {
        ScreenVoicePTTLiveActivityWidget()
    }
}
struct ScreenVoicePTTLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScreenVoicePTTActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.phase.symbolName)
                    .font(.title2)
                    .foregroundStyle(context.state.phase.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenClam")
                        .font(.headline)
                    Text(context.state.phase.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal)
            .activityBackgroundTint(.black.opacity(0.88))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.primary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("OpenClam")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Label(context.state.phase.label, systemImage: context.state.phase.symbolName)
                        .font(.subheadline)
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .foregroundStyle(.primary)
            } compactTrailing: {
                Image(systemName: context.state.phase.symbolName)
            } minimal: {
                Image(systemName: context.state.phase.symbolName)
                    .foregroundStyle(context.state.phase.tint)
            }
            .keylineTint(.gray)
        }
    }
}

private extension ScreenVoicePTTPhase {
    var label: String {
        switch self {
        case .preparing: "Preparing"
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .completed: "Answered"
        case .cancelled: "Cancelled"
        case .failed: "Needs attention"
        }
    }

    var symbolName: String {
        switch self {
        case .preparing: "ellipsis"
        case .listening: "mic.fill"
        case .transcribing: "waveform"
        case .thinking: "sparkles"
        case .speaking: "speaker.wave.2.fill"
        case .completed: "checkmark"
        case .cancelled: "xmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .failed: .orange
        case .cancelled: .secondary
        case .completed: .green
        default: .primary
        }
    }
}
