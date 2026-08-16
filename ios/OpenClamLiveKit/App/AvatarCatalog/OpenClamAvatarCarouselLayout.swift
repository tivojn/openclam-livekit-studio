import CoreGraphics
import Foundation

enum OpenClamAvatarCarouselStyle: String, CaseIterable, Sendable {
    case noir
    case sorbet

    var alternate: Self { self == .noir ? .sorbet : .noir }
}

struct OpenClamAvatarCarouselCardLayout: Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let rotationDegrees: Double
    let scale: CGFloat
    let opacity: Double
    let zIndex: Double
}

enum OpenClamAvatarCarouselCardTapAction: Equatable, Sendable {
    case focus(Int)
    case activate
}

enum OpenClamAvatarCarouselLayout {
    static let dragStep: CGFloat = 46
    static let cardWidth: CGFloat = 200
    static let cardAspectRatio: CGFloat = 3 / 4

    /// The carousel is hosted inside the avatar overlay, where SwiftUI may
    /// report a zero safe-area inset even on Dynamic Island devices. It also
    /// sits beneath the conversation header, whose UIKit hit layer extends
    /// below its visible controls, so keep carousel controls clear of that
    /// whole region instead of merely clearing the status bar.
    static func topControlPadding(reportedSafeAreaInset: CGFloat) -> CGFloat {
        max(reportedSafeAreaInset + 48, 168)
    }

    /// Keeps the selected-avatar guidance clear of the conversation composer.
    static func detailBarBottomPadding(reportedSafeAreaInset: CGFloat) -> CGFloat {
        max(reportedSafeAreaInset + 14, 116)
    }

    static func actionForCardTap(
        index: Int,
        frontIndex: Int
    ) -> OpenClamAvatarCarouselCardTapAction {
        index == frontIndex ? .activate : .focus(index)
    }

    static func wrappedIndex(_ proposed: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((proposed % count) + count) % count
    }

    static func frontIndex(
        from startingIndex: Int,
        horizontalTranslation: CGFloat,
        count: Int
    ) -> Int {
        guard count > 0 else { return 0 }
        let steps = Int(horizontalTranslation / dragStep)
        return wrappedIndex(startingIndex - steps, count: count)
    }

    static func relativeDistance(
        cardIndex: Int,
        frontIndex: Int,
        count: Int
    ) -> Int {
        guard count > 0 else { return 0 }
        var distance = cardIndex - frontIndex
        if Double(distance) > Double(count) / 2 {
            distance -= count
        }
        if Double(distance) < -Double(count) / 2 {
            distance += count
        }
        return distance
    }

    static func card(
        index: Int,
        frontIndex: Int,
        count: Int,
        style: OpenClamAvatarCarouselStyle
    ) -> OpenClamAvatarCarouselCardLayout {
        let distance = relativeDistance(
            cardIndex: index,
            frontIndex: frontIndex,
            count: count
        )
        let magnitude = abs(distance)
        let opacity = magnitude > 3 ? 0 : 1 - Double(magnitude) * 0.16

        switch style {
        case .sorbet:
            return OpenClamAvatarCarouselCardLayout(
                x: CGFloat(distance) * 58,
                y: CGFloat(magnitude) * 26 + (distance == 0 ? -24 : 0),
                rotationDegrees: Double(distance) * 13,
                scale: distance == 0 ? 1.12 : 0.94,
                opacity: opacity,
                zIndex: Double(60 - magnitude)
            )
        case .noir:
            return OpenClamAvatarCarouselCardLayout(
                x: CGFloat(distance) * 64,
                y: CGFloat(distance) * -20,
                rotationDegrees: Double(distance) * -7,
                scale: distance == 0 ? 1.16 : 0.96,
                opacity: opacity,
                zIndex: Double(60 - magnitude)
            )
        }
    }
}
