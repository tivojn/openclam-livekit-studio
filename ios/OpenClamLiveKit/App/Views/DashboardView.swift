import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AssistantModel
    @State private var urlText = "https://example.com"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    statusCard
                    if let command = model.pendingCommand {
                        reviewCard(command)
                    }
                    quickActions
                    resultCard
                    activitySection
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("OpenClam")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Confirm-first command surface")
                        .font(.headline)
                    Text("Deep links and App Intents show the exact action first. Tap Confirmed to run it directly, or Cancel to discard it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }

    private func reviewCard(_ command: AssistantCommand) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Command awaiting review", systemImage: "hand.raised.square.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: command.action.systemImage)
                    .font(.title2)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(command.action.title).font(.headline)
                    Text(command.summary).font(.subheadline).foregroundStyle(.secondary)
                    Text(command.source.label).font(.caption).foregroundStyle(.tertiary)
                }
            }
            HStack {
                Button("Cancel", role: .cancel) { model.cancelPending() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Confirmed") {
                    Task { await model.runPending() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .cardStyle(stroke: .orange.opacity(0.45))
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try the native layer").font(.headline)

            TextField("Reviewed web URL", text: $urlText)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                quickButton("Open URL", icon: "safari") {
                    .init(action: .openURL, parameters: ["url": urlText])
                }
                quickButton("Copy text", icon: "doc.on.clipboard") {
                    .init(action: .clipboardCopy, parameters: ["text": "Hello from OpenClam"])
                }
                quickButton("Directions", icon: "map") {
                    .init(action: .mapsDestination, parameters: ["destination": "Ferry Building, San Francisco"])
                }
                quickButton("Uber to SFO", icon: "car.side.fill") {
                    .init(
                        action: .uberDestination,
                        parameters: [
                            "destination": "San Francisco International Airport",
                            "latitude": "37.6213",
                            "longitude": "-122.3790",
                        ]
                    )
                }
                quickButton("Draft message", icon: "message") {
                    .init(
                        action: .messageDraft,
                        parameters: ["recipient": "+1 555 010 0110", "body": "Looking forward to seeing you"]
                    )
                }
                quickButton("Alarm in 2 min", icon: "alarm") {
                    .init(
                        action: .alarmSet,
                        parameters: [
                            "date": ISO8601DateFormatter().string(from: Date().addingTimeInterval(120)),
                            "label": "OpenClam test",
                        ]
                    )
                }
                quickButton("Home Screen", icon: "house") {
                    .init(
                        action: .shortcutFallback,
                        parameters: DeviceActionShortcut.commandParameters("hola homescreen")
                    )
                }
            }
        }
        .cardStyle()
    }

    private func quickButton(
        _ title: String,
        icon: String,
        command: @escaping () -> AssistantCommand
    ) -> some View {
        Button {
            model.stage(command())
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.bordered)
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latest result").font(.headline)
            Text(model.lastResult)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    @ViewBuilder
    private var activitySection: some View {
        if !model.activity.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Activity on this launch").font(.headline)
                ForEach(model.activity.prefix(8)) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.state.systemImage)
                            .foregroundStyle(item.state == .failed ? .red : .indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if item.id != model.activity.prefix(8).last?.id { Divider() }
                }
            }
            .cardStyle()
        }
    }
}

private extension View {
    func cardStyle(stroke: Color = .clear) -> some View {
        self
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
    }
}
