import SwiftUI

struct OpenClam3DMotionBrowser: View {
    let avatarID: String
    let clips: [OpenClam3DChoice]
    let onPlay: () -> Void
    @ObservedObject private var options = OpenClam3DOptionsStore.shared
    @State private var search = ""
    @State private var category = "All motions"

    private var categories: [String] { Array(Set(clips.map { $0.category ?? "Other" })).sorted() }
    private var filtered: [OpenClam3DChoice] {
        clips.filter { (category == "All motions" || $0.category == category)
            && (search.isEmpty || $0.label.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        List {
            Picker("Category", selection: $category) {
                Text("All motions").tag("All motions")
                ForEach(categories, id: \.self) { Text($0).tag($0) }
            }
            if let status = options.motionStatuses[avatarID] {
                Text(status).font(.footnote).accessibilityIdentifier("openclam-3d-motion-status")
            }
            ForEach(filtered) { clip in
                Button {
                    onPlay()
                    Task { _ = await options.command("clip:" + clip.id, for: avatarID) }
                } label: {
                    Label(clip.label, systemImage: "play.circle")
                }
                .accessibilityIdentifier("openclam-3d-motion-" + clip.id)
                .disabled(options.loadStates[avatarID] != .ready)
            }
            Button("Stop motion") { Task { _ = await options.command("stay", for: avatarID) } }
        }
        .searchable(text: $search, prompt: "Dances, greetings, kung fu…")
        .navigationTitle("Dynamic motions")
    }
}
