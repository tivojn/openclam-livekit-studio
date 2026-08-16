import Combine
import Foundation

/// No-crash owner for Root integration. Missing App Group/profile capabilities become visible
/// setup messages; manual screenshot review remains usable and no `try!` is needed.
@MainActor
final class ScreenContextFeatureModel: ObservableObject {
    #if OPENCLAM_LIVE_SCREEN_CONTEXT
    static let liveCaptureCompiledIn = true
    #else
    static let liveCaptureCompiledIn = false
    #endif

    let reviewSession: ScreenContextReviewSession

    @Published private(set) var setupMessages: [String]

    private let captureManagerStorage: AnyObject?

    private init(
        reviewSession: ScreenContextReviewSession,
        captureManagerStorage: AnyObject?,
        setupMessages: [String]
    ) {
        self.reviewSession = reviewSession
        self.captureManagerStorage = captureManagerStorage
        self.setupMessages = setupMessages
    }

    static func make() -> ScreenContextFeatureModel {
        var messages: [String] = []
        let reviewSession: ScreenContextReviewSession
        do {
            reviewSession = try .appGroupBacked()
        } catch {
            reviewSession = ScreenContextReviewSession()
            messages.append(
                "Shared Screen Context is unavailable until the App Group capability and matching profile are installed. You can still choose a screenshot inside OpenClam."
            )
        }

        let captureStorage: AnyObject?
#if OPENCLAM_LIVE_SCREEN_CONTEXT && compiler(>=6.4) && canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) {
            do {
                captureStorage = try ScreenCaptureKitManager.appGroupBacked()
            } catch {
                captureStorage = nil
                messages.append(
                    "Live Screen Context is unavailable until the shared App Group and Screen Recording capability are provisioned."
                )
            }
        } else {
            captureStorage = nil
            messages.append("Live Screen Context requires iOS 27 or later.")
        }
#else
        captureStorage = nil
#endif

        return ScreenContextFeatureModel(
            reviewSession: reviewSession,
            captureManagerStorage: captureStorage,
            setupMessages: messages
        )
    }

#if OPENCLAM_LIVE_SCREEN_CONTEXT && compiler(>=6.4) && canImport(ScreenCaptureKit)
    @available(iOS 27.0, *)
    var captureManager: ScreenCaptureKitManager? {
        captureManagerStorage as? ScreenCaptureKitManager
    }
#else
    var captureManager: ScreenCaptureKitManager? { nil }
#endif
}
