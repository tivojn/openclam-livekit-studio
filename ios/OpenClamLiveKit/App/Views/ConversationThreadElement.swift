import SwiftUI

/// A concrete row boundary for the heterogeneous conversation timeline.
///
/// Keeping each card's opaque return type inside this boundary prevents SwiftUI
/// from recursively decoding every card and modifier while instantiating the
/// LazyVStack's tuple. That exhausted the 1 MB device main stack at launch in
/// builds 75–77 on iOS 27. Merely extracting `some View` helpers does not bound
/// that metadata graph. Keep message and scroll-anchor IDs outside this view.
struct ConversationThreadElement: View {
    private let content: AnyView

    init<Content: View>(@ViewBuilder content: () -> Content) {
        self.content = AnyView(content())
    }

    var body: some View { content }
}
