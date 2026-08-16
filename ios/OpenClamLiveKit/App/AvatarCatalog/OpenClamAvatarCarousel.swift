import SwiftUI

/// A local-only avatar picker. Present it as its own sheet/cover from the rail;
/// do not attach this view's drag gesture to the live avatar stage. The stage
/// keeps ownership of its existing vertical 10–100% opacity gesture and true
/// eye-button hide state.
@MainActor
struct OpenClamAvatarCarousel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("openclam.avatar.carousel.style") private var storedStyle = "noir"

    private let avatars: [OpenClamAvatarDescriptor]
    private let activeAvatarID: String
    private let imageStore: OpenClamAvatarAssetStore
    private let onActivate: (_ id: String, _ displayName: String) -> Void
    private let onDismiss: () -> Void

    @State private var frontIndex: Int
    @State private var dragStartingIndex: Int?

    init(
        avatars: [OpenClamAvatarDescriptor] = OpenClamAvatarCatalog.avatars,
        activeAvatarID: String,
        imageStore: OpenClamAvatarAssetStore? = nil,
        onActivate: @escaping (_ id: String, _ displayName: String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.avatars = avatars
        self.activeAvatarID = activeAvatarID
        self.imageStore = imageStore ?? .shared
        self.onActivate = onActivate
        self.onDismiss = onDismiss
        _frontIndex = State(
            initialValue: avatars.firstIndex { $0.id == activeAvatarID } ?? 0
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                scrim
                    .ignoresSafeArea()

                if avatars.isEmpty {
                    ContentUnavailableView(
                        "No avatars installed",
                        systemImage: "person.crop.circle.badge.questionmark"
                    )
                } else {
                    cardDeck(in: proxy.size)
                    detailBar
                        .padding(
                            .bottom,
                            OpenClamAvatarCarouselLayout.detailBarBottomPadding(
                                reportedSafeAreaInset: proxy.safeAreaInsets.bottom
                            )
                        )
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }

                topControls
                    .padding(
                        .top,
                        OpenClamAvatarCarouselLayout.topControlPadding(
                            reportedSafeAreaInset: proxy.safeAreaInsets.top
                        )
                    )
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .zIndex(100)
            }
        }
        .onAppear(perform: selectActiveAvatar)
        .onChange(of: activeAvatarID) { _, _ in selectActiveAvatar() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openclam-avatar-carousel")
    }

    private var style: OpenClamAvatarCarouselStyle {
        get { OpenClamAvatarCarouselStyle(rawValue: storedStyle) ?? .noir }
        nonmutating set { storedStyle = newValue.rawValue }
    }

    private var scrim: some View {
        Group {
            if colorScheme == .dark {
                Color(red: 5 / 255, green: 7 / 255, blue: 10 / 255).opacity(0.82)
            } else {
                Color(uiColor: .systemBackground).opacity(0.88)
            }
        }
        .background(.ultraThinMaterial)
    }

    private var topControls: some View {
        HStack {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel("Close avatar carousel")

            Spacer()

            Button {
                withCarouselAnimation {
                    style = style.alternate
                }
            } label: {
                Text(style.alternate.rawValue.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .padding(.horizontal, 16)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(.thinMaterial, in: Capsule())
            }
            .accessibilityLabel("Switch carousel style")
            .accessibilityValue(style.rawValue)
        }
        .foregroundStyle(.primary)
    }

    private func cardDeck(in size: CGSize) -> some View {
        ZStack {
            ForEach(Array(avatars.enumerated()), id: \.element.id) { index, avatar in
                let layout = OpenClamAvatarCarouselLayout.card(
                    index: index,
                    frontIndex: frontIndex,
                    count: avatars.count,
                    style: style
                )
                avatarCard(avatar, index: index)
                    .frame(
                        width: OpenClamAvatarCarouselLayout.cardWidth,
                        height: OpenClamAvatarCarouselLayout.cardWidth
                            / OpenClamAvatarCarouselLayout.cardAspectRatio
                    )
                    .scaleEffect(layout.scale)
                    .rotationEffect(.degrees(layout.rotationDegrees))
                    .opacity(layout.opacity)
                    .position(
                        x: size.width / 2 + layout.x,
                        y: size.height * 0.44 - 7 + layout.y
                    )
                    .zIndex(layout.zIndex)
                    .allowsHitTesting(layout.opacity > 0)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .highPriorityGesture(horizontalSpinGesture)
        .animation(carouselAnimation, value: frontIndex)
        .animation(carouselAnimation, value: style)
    }

    private func avatarCard(
        _ avatar: OpenClamAvatarDescriptor,
        index: Int
    ) -> some View {
        Button {
            switch OpenClamAvatarCarouselLayout.actionForCardTap(
                index: index,
                frontIndex: frontIndex
            ) {
            case let .focus(index):
                withCarouselAnimation {
                    frontIndex = index
                }
            case .activate:
                onActivate(avatar.id, avatar.displayName)
            }
        } label: {
            ZStack(alignment: style == .sorbet ? .top : .bottom) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(cardColor(index: index))

                thumbnail(for: avatar)

                Text(avatar.displayName)
                    .font(.system(size: style == .sorbet ? 14.5 : 13.5, weight: .semibold))
                    .foregroundStyle(style == .sorbet ? Color.black.opacity(0.82) : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, style == .sorbet ? 0 : 10)
                    .background {
                        if style == .noir {
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.72)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 58)
                        }
                    }
                    .padding(.top, style == .sorbet ? 150 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(style == .noir ? 0.16 : 0), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.36), radius: 24, y: 14)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("openclam-avatar-carousel-card-\(avatar.id)")
        .accessibilityLabel(avatar.displayName)
        .accessibilityValue(
            index == frontIndex
                ? (avatar.id == activeAvatarID ? "Selected, on stage" : "Selected")
                : "Not selected"
        )
        .accessibilityHint(
            index == frontIndex
                ? (avatar.id == activeAvatarID
                    ? "Tap to return to this avatar"
                    : "Tap to use this avatar")
                : "Tap to bring this avatar forward"
        )
    }

    @ViewBuilder
    private func thumbnail(for avatar: OpenClamAvatarDescriptor) -> some View {
        if let image = imageStore.image(for: avatar, role: .thumbnail) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(
                    width: style == .sorbet ? 112 : OpenClamAvatarCarouselLayout.cardWidth,
                    height: style == .sorbet
                        ? 112
                        : OpenClamAvatarCarouselLayout.cardWidth
                            / OpenClamAvatarCarouselLayout.cardAspectRatio
                )
                .clipShape(style == .sorbet ? AnyShape(Circle()) : AnyShape(Rectangle()))
                .overlay {
                    if style == .sorbet {
                        Circle().stroke(.white.opacity(0.85), lineWidth: 4)
                    }
                }
                .padding(.top, style == .sorbet ? 26 : 0)
        } else {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 72, weight: .thin))
                .foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var detailBar: some View {
        let front = avatars[OpenClamAvatarCarouselLayout.wrappedIndex(
            frontIndex,
            count: avatars.count
        )]
        let isActive = front.id == activeAvatarID
        return HStack(spacing: 12) {
            Text(front.displayName)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)

            Spacer(minLength: 4)

            Text(isActive ? "On stage" : "Tap avatar to choose")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("openclam-avatar-carousel-selection-guidance")
    }

    private var horizontalSpinGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if dragStartingIndex == nil {
                    dragStartingIndex = frontIndex
                }
                guard let dragStartingIndex else { return }
                frontIndex = OpenClamAvatarCarouselLayout.frontIndex(
                    from: dragStartingIndex,
                    horizontalTranslation: value.translation.width,
                    count: avatars.count
                )
            }
            .onEnded { _ in
                dragStartingIndex = nil
            }
    }

    private var carouselAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.42)
    }

    private func withCarouselAnimation(_ changes: () -> Void) {
        guard let carouselAnimation else {
            changes()
            return
        }
        withAnimation(carouselAnimation, changes)
    }

    private func selectActiveAvatar() {
        guard let index = avatars.firstIndex(where: { $0.id == activeAvatarID }) else { return }
        frontIndex = index
    }

    private func cardColor(index: Int) -> Color {
        guard style == .sorbet else {
            return Color(red: 22 / 255, green: 24 / 255, blue: 29 / 255)
        }
        let colors: [Color] = [
            Color(red: 142 / 255, green: 207 / 255, blue: 212 / 255),
            Color(red: 242 / 255, green: 167 / 255, blue: 179 / 255),
            Color(red: 185 / 255, green: 167 / 255, blue: 232 / 255),
            Color(red: 244 / 255, green: 192 / 255, blue: 127 / 255),
            Color(red: 159 / 255, green: 216 / 255, blue: 164 / 255),
            Color(red: 240 / 255, green: 224 / 255, blue: 138 / 255),
        ]
        return colors[index % colors.count]
    }
}
