import Foundation
import SwiftUI

#if canImport(AlarmKit)
import AlarmKit

@available(iOS 26.0, *)
private struct CompanionAlarmMetadata: AlarmMetadata {
    let label: String
}
#endif

enum AlarmService {
    static func schedule(date: Date, label: String) async throws {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            try await scheduleWithAlarmKit(date: date, label: label)
            return
        }
        #endif
        throw CommandValidationError.unavailable(
            "Native prominent alarms require iOS 26 or newer. Use the upstream Shortcut on earlier iOS versions."
        )
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private static func scheduleWithAlarmKit(date: Date, label: String) async throws {
        let authorization = AlarmManager.shared.authorizationState
        if authorization == .notDetermined {
            _ = try await AlarmManager.shared.requestAuthorization()
        }
        guard AlarmManager.shared.authorizationState == .authorized else {
            throw CommandValidationError.unavailable("Alarm access is not authorized in Settings.")
        }

        let stopButton = AlarmButton(
            text: "Dismiss",
            textColor: .white,
            systemImageName: "stop.circle.fill"
        )
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: label),
            stopButton: stopButton
        )
        let attributes = AlarmAttributes<CompanionAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: CompanionAlarmMetadata(label: label),
            tintColor: .indigo
        )
        let configuration = AlarmManager.AlarmConfiguration<CompanionAlarmMetadata>.alarm(
            schedule: .fixed(date),
            attributes: attributes
        )
        _ = try await AlarmManager.shared.schedule(id: UUID(), configuration: configuration)
    }
    #endif
}
