import SwiftUI
import UIKit

enum OpenClamAvatarFacePlateScope: Equatable, Sendable {
    case fullHead
    case speechPatch
}

struct OpenClamAvatarFacePlateLayer: Equatable, Sendable {
    let viseme: OpenClamAvatarViseme
    let opacity: Double
    let scope: OpenClamAvatarFacePlateScope
}

/// One opaque back plate with, at most, one source-over front plate. The view
/// applies the feathered mouth mask to this assembled patch exactly once.
/// Keeping the transition as one value prevents the old plate from leaking
/// through the feather when the blend reaches its endpoint.
struct OpenClamAvatarSpeechPatchPlan: Equatable, Sendable {
    let back: OpenClamAvatarFacePlateLayer
    let front: OpenClamAvatarFacePlateLayer?
}

struct OpenClamAvatarFacePlatePlan: Equatable, Sendable {
    let base: OpenClamAvatarFacePlateLayer
    let speechPatch: OpenClamAvatarSpeechPatchPlan?
}

/// The face is composited over the body with Porter-Duff source-atop. This
/// lets its color replace the matching body pixels while preserving the
/// body's alpha exactly, including at partially transparent hair edges.
enum OpenClamAvatarStageFaceBlendRule: Equatable, Sendable {
    case sourceAtopPreservingBodyAlpha
}

struct OpenClamAvatarStageOpacityPlan: Equatable, Sendable {
    let bodyOpacity: Double
    let faceBlendRule: OpenClamAvatarStageFaceBlendRule
    let userOpacityApplicationCount: Int
    let requiresWholeStageRasterization: Bool
}

enum OpenClamAvatarStageOpacityPolicy {
    static func plan(for requestedOpacity: Double) -> OpenClamAvatarStageOpacityPlan {
        OpenClamAvatarStageOpacityPlan(
            bodyOpacity: min(1, max(0, requestedOpacity)),
            faceBlendRule: .sourceAtopPreservingBodyAlpha,
            userOpacityApplicationCount: 1,
            requiresWholeStageRasterization: false
        )
    }

    /// Alpha produced by the stage's source-atop composition. Keeping the
    /// formula here makes the renderer invariant deterministic and testable:
    /// face animation may change color, but it can never darken or brighten
    /// the assembled avatar's silhouette.
    static func composedAlpha(
        bodyAlpha: Double,
        faceAlpha: Double,
        requestedOpacity: Double
    ) -> Double {
        let destinationAlpha = min(1, max(0, bodyAlpha))
            * plan(for: requestedOpacity).bodyOpacity
        let sourceAlpha = min(1, max(0, faceAlpha))

        // Porter-Duff source-atop: As * Ad + Ad * (1 - As) == Ad.
        return sourceAlpha * destinationAlpha
            + destinationAlpha * (1 - sourceAlpha)
    }
}

enum OpenClamAvatarSpeechPatchTransition {
    /// A linear source-over blend minimizes per-frame luminance deltas for the
    /// published plates. Clamping keeps malformed render states harmless.
    static func opacity(for linearBlend: Double) -> Double {
        min(1, max(0, linearBlend))
    }
}

enum OpenClamAvatarFaceAnimationPolicy {
    /// The body remains outside the timeline. Advancing only the face at the
    /// display cadence gives short 45-105 ms mouth transitions enough frames
    /// to remain smooth without repainting hands or clothing.
    static let minimumInterval: TimeInterval = 1.0 / 60.0
}

enum OpenClamAvatarEyelidPlatePlan: Equatable, Sendable {
    case interpolatedStrip
    case canonicalOpen
    case semanticClosed(frame: Int)
}

enum OpenClamAvatarEyelidPlatePolicy {
    /// Photographs retain the production eight-frame eyelid interpolation.
    /// Stylized packages instead contain seven transparent frames followed by
    /// one full semantic-eye replacement; a late opaque switch prevents a
    /// human-sized lid from ever appearing inside an oversized cartoon eye.
    static func plan(
        for eye: CaptainAyerEyeReactionState,
        frameCount: Int,
        sourceMedium: OpenClamAvatarSourceMedium
    ) -> OpenClamAvatarEyelidPlatePlan {
        guard sourceMedium.isStylized else { return .interpolatedStrip }
        let closedFrame = max(0, frameCount - 1)
        guard frameCount > 1,
              eye.upperFrame >= closedFrame,
              eye.upperOpacity >= 0.78 else {
            return .canonicalOpen
        }
        return .semanticClosed(frame: closedFrame)
    }
}

/// A catalog avatar face is registered into its authored body plate. Moving
/// that face surface independently from the body makes it drift inside
/// otherwise stationary hair and also asks Core Animation to resample the
/// already-composited face on every speech frame. Full-expression packages
/// therefore keep the surface rigidly registered and express head intent with
/// their gaze, eyelid, brow, forehead, cheek, and mouth banks instead. Legacy
/// packages retain their historical pose behavior until they are rebuilt with
/// the body-locked v4 contract.
struct OpenClamAvatarFaceRegistrationPlan: Equatable, Sendable {
    let pitchDegrees: Double
    let yawDegrees: Double
    let rotationDegrees: Double
    let translationX: CGFloat
    let translationY: CGFloat
    /// Dynamic 3D/affine passes applied after the photographic face has been
    /// assembled. A body-locked v4 face must stay at zero so speech cannot
    /// repeatedly filter the skin texture.
    let dynamicResamplingPassCount: Int
}

enum OpenClamAvatarFaceRegistrationPolicy {
    static func plan(
        canonicalRotationDegrees: Double,
        reaction: CaptainAyerFaceMirrorHeadPose,
        bodyLocked: Bool,
        sourceMedium: OpenClamAvatarSourceMedium,
        bodyScale: CGFloat
    ) -> OpenClamAvatarFaceRegistrationPlan {
        guard !bodyLocked else {
            return OpenClamAvatarFaceRegistrationPlan(
                pitchDegrees: 0,
                yawDegrees: 0,
                // This angle comes from the approved face-to-body affine,
                // not a detected landmark roll or an animated head pose.
                // Keep it paired with that affine's scale and mapped centre:
                // zeroing only rotation misaligns the moving face with the
                // already-composited head/body, even for a one-degree angle.
                // Body locking disables dynamic tilt, not static registration.
                rotationDegrees: canonicalRotationDegrees,
                translationX: 0,
                translationY: 0,
                dynamicResamplingPassCount: 0
            )
        }
        return OpenClamAvatarFaceRegistrationPlan(
            pitchDegrees: reaction.pitch * 3.2,
            yawDegrees: -reaction.yaw * 4.0,
            rotationDegrees: canonicalRotationDegrees + reaction.roll * 3.4,
            translationX: reaction.yaw * 2.4 * bodyScale,
            translationY: reaction.pitch * 1.8 * bodyScale,
            dynamicResamplingPassCount: reaction == .zero ? 0 : 1
        )
    }
}

/// Keeps identity-bearing pixels stable while speech changes. The full head is
/// always the published silence plate; viseme changes are permitted only in a
/// feathered lower-face patch. This avoids re-crossfading hair, eyes, skin,
/// and JPEG noise at every 58-105 ms phoneme cue.
enum OpenClamAvatarFacePlatePolicy {
    static func plan(
        for state: CaptainAyerAvatarRenderState,
        sourceMedium: OpenClamAvatarSourceMedium = .photograph
    ) -> OpenClamAvatarFacePlatePlan {
        let base = OpenClamAvatarFacePlateLayer(
            viseme: .silence,
            opacity: 1,
            scope: .fullHead
        )
        let previous = state.previous.catalogViseme
        let current = state.current.catalogViseme
        let blend = OpenClamAvatarSpeechPatchTransition.opacity(for: state.blend)

        if sourceMedium.isStylized, previous != current {
            // Provider-painted cartoon line art must never be crossfaded: two
            // opaque mouth drawings at once read as a doubled lip/nose even
            // when their geometry is correctly registered. Switch at the
            // midpoint while the immutable silence head remains underneath.
            let selected = blend < 0.5 ? previous : current
            guard selected != .silence else {
                return OpenClamAvatarFacePlatePlan(base: base, speechPatch: nil)
            }
            return OpenClamAvatarFacePlatePlan(
                base: base,
                speechPatch: OpenClamAvatarSpeechPatchPlan(
                    back: OpenClamAvatarFacePlateLayer(
                        viseme: selected,
                        opacity: 1,
                        scope: .speechPatch
                    ),
                    front: nil
                )
            )
        }

        if previous == current {
            guard current != .silence else {
                return OpenClamAvatarFacePlatePlan(base: base, speechPatch: nil)
            }
            return OpenClamAvatarFacePlatePlan(
                base: base,
                speechPatch: OpenClamAvatarSpeechPatchPlan(
                    back: OpenClamAvatarFacePlateLayer(
                        viseme: current,
                        opacity: 1,
                        scope: .speechPatch
                    ),
                    front: nil
                )
            )
        }

        // Assemble the opaque previous plate and the source-over current
        // plate before applying the feathered mask. This is valid for
        // silence-to-speech and speech-to-silence as well: the silence plate
        // matches the immutable base exactly at both endpoints.
        return OpenClamAvatarFacePlatePlan(
            base: base,
            speechPatch: OpenClamAvatarSpeechPatchPlan(
                back: OpenClamAvatarFacePlateLayer(
                    viseme: previous,
                    opacity: 1,
                    scope: .speechPatch
                ),
                front: OpenClamAvatarFacePlateLayer(
                    viseme: current,
                    opacity: blend,
                    scope: .speechPatch
                )
            )
        )
    }
}

struct OpenClamAvatarSpeechPatchGeometry: Equatable, Sendable {
    static let canonicalSize = CGSize(width: 1_024, height: 1_024)
    static let photographicFeatherRadius: CGFloat = 18
    static let stylizedFeatherRadius: CGFloat = 6

    let coreBounds: CGRect
    let conservativeDynamicBounds: CGRect
    let featherRadius: CGFloat
    let clipsFeatherToCoreBounds: Bool
    let visemeXOffsets: [String: Double]
    let skinMatch: OpenClamAvatarMouthSkinMatchMetadata?

    init(
        rig: OpenClamAvatarRigGeometry,
        sourceMedium: OpenClamAvatarSourceMedium = .photograph,
        expressionMouthBounds: CGRect? = nil,
        speechPatch: OpenClamAvatarSpeechPatchMetadata? = nil
    ) {
        skinMatch = sourceMedium == .rendered3D ? speechPatch?.skinMatch : nil
        let canonicalBounds = CGRect(origin: .zero, size: Self.canonicalSize)
        let authoredMouth = speechPatch?.box.cgRect ?? expressionMouthBounds
        let canonicalMouth = authoredMouth?.intersection(canonicalBounds)
        if sourceMedium.isStylized,
           let declaredMouth = canonicalMouth,
           !declaredMouth.isNull,
           declaredMouth.width > 0,
           declaredMouth.height > 0 {
            visemeXOffsets = speechPatch?.visemeXOffsets ?? [:]
            featherRadius = Self.stylizedFeatherRadius
            clipsFeatherToCoreBounds = true

            // New v4 packages publish an already nose-safe lip box. Legacy v4
            // expression packages have no such metadata, so retain the bounded
            // lower-four-fifths fallback for explicit stylized media only.
            let top = speechPatch == nil
                ? declaredMouth.minY + declaredMouth.height * 0.20
                : declaredMouth.minY
            coreBounds = CGRect(
                x: declaredMouth.minX,
                y: top,
                width: declaredMouth.width,
                height: max(1, declaredMouth.maxY - top)
            )
            conservativeDynamicBounds = coreBounds
            return
        }

        visemeXOffsets = [:]
        featherRadius = Self.photographicFeatherRadius
        clipsFeatherToCoreBounds = false
        let eyeBottom = max(rig.leftEye.box.cgRect.maxY, rig.rightEye.box.cgRect.maxY)
        // Three feather radii plus an eight-pixel guard keeps even the soft
        // edge below the published eye plates. There is deliberately no upper
        // cap: an imported rig with unusually low eyes must never let speech
        // repaint those eyes merely to preserve a larger mouth patch.
        let coreTop = max(630, eyeBottom + Self.photographicFeatherRadius * 3 + 8)
        let coreBottom: CGFloat = 916
        coreBounds = CGRect(
            x: 352,
            y: coreTop,
            width: 320,
            height: max(1, coreBottom - coreTop)
        )
        conservativeDynamicBounds = coreBounds
            .insetBy(dx: -featherRadius * 3, dy: -featherRadius * 3)
            .intersection(canonicalBounds)
    }

    func translationX(for viseme: OpenClamAvatarViseme) -> CGFloat {
        CGFloat(visemeXOffsets[viseme.rawValue] ?? 0)
    }

    var stylizedVisibleBounds: CGRect {
        guard clipsFeatherToCoreBounds else { return coreBounds }
        return CGRect(
            x: coreBounds.minX + coreBounds.width * 0.03,
            y: coreBounds.minY + coreBounds.height * 0.09,
            width: coreBounds.width * 0.94,
            height: coreBounds.height * 0.72
        )
    }
}

enum OpenClamAvatarStylizedSpeechPatchPixelPolicy {
    static func spatialAlpha(
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> Double {
        let nx = ((Double(x) + 0.5) / Double(max(1, width)) - 0.5) / 0.5
        let ny = ((Double(y) + 0.5) / Double(max(1, height)) - 0.5) / 0.5
        // Match the approved desktop mouth ownership, not the old ellipse
        // whose feather started inside the canonical upturned lip corners.
        let radius = pow(pow(nx, 6) + pow(ny, 6), 1.0 / 6.0)
        return 1 - smoothStep((radius - 0.85) / 0.13)
    }

    static func differenceAlpha(
        maximumChannelDelta: Int,
        spatialAlpha: Double
    ) -> Double {
        min(1, max(0, spatialAlpha))
            * smoothStep((Double(maximumChannelDelta) - 6) / 36)
    }

    static func ownershipAlpha(
        maximumChannelDelta: Int,
        spatialAlpha: Double
    ) -> Double {
        let coverage = min(1, max(0, spatialAlpha))
        // Replacement skin must erase the old mouth even when its contrast
        // is small. Only the exterior skin feather is difference-matted.
        return max(
            differenceAlpha(
                maximumChannelDelta: maximumChannelDelta,
                spatialAlpha: coverage
            ),
            coverage * smoothStep((coverage - 0.72) / 0.28)
        )
    }

    private static func smoothStep(_ value: Double) -> Double {
        let amount = min(1, max(0, value))
        return amount * amount * (3 - 2 * amount)
    }
}

/// The desktop's measured-contour skin correction, limited to explicit soft
/// 3D metadata. Lips/teeth stay original, and a deterministic held-out skin
/// sample must improve before any correction is applied.
enum OpenClamAvatarStylizedMouthSkinPolicy {
    // Imported v4 mouth bounds may legally span the entire canonical image.
    // Do not allocate spatial fields or run contour fitting at that size on
    // the UI actor. Larger plates retain the bounded annulus-tone fallback.
    static let maximumCorrectionPixels = 65_536

    static func correct(
        source: inout [UInt8], neutral: [UInt8], width: Int, height: Int,
        oldContour: [CGPoint]?, newContour: [CGPoint]?, fallbackShift: [Double]
    ) -> Bool {
        guard width > 0, height > 0, width <= 1_024, height <= 1_024,
              width * height <= maximumCorrectionPixels,
              let oldContour, let newContour,
              (8 ... 64).contains(oldContour.count), (8 ... 64).contains(newContour.count),
              (oldContour + newContour).allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              source.count == width * height * 4, neutral.count == source.count,
              fallbackShift.count == 3, fallbackShift.allSatisfy(\.isFinite) else { return false }
        var fields = [Double](repeating: 0, count: source.count)
        var protection = [Double](repeating: 0, count: width * height)
        var validation: [Int] = []
        var samples = 0
        let span = Double(width)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let pixel = y * width + x, index = pixel * 4
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                let previous = distance(point, contour: oldContour)
                let selected = distance(point, contour: newContour)
                protection[pixel] = smoothStep((selected - 0.07 * span) / (0.025 * span))
                guard min(previous, selected) > 0.08 * span,
                      source[index + 3] >= 240, neutral[index + 3] >= 240 else { continue }
                let deltas = (0 ..< 3).map { Double(neutral[index + $0]) - Double(source[index + $0]) }
                guard (deltas.map(abs).max() ?? 0) <= 72 else { continue }
                if (x * 3 + y * 5) % 7 == 0 {
                    validation.append(pixel)
                    continue
                }
                for channel in 0 ..< 3 { fields[index + channel] = deltas[channel] }
                fields[index + 3] = 1
                samples += 1
            }
        }
        guard Double(samples) >= max(12, Double(width * height) * 0.04) else { return false }
        let field = blur(fields, width: width, height: height, radius: max(3, Int((span * 0.06).rounded())))
        var baselineError = 0.0, candidateError = 0.0, validationWeight = 0.0
        for pixel in validation {
            let index = pixel * 4
            guard field[index + 3] >= 0.001 else { continue }
            let weight = OpenClamAvatarStylizedSpeechPatchPixelPolicy.spatialAlpha(
                x: pixel % width, y: pixel / width, width: width, height: height
            )
            guard weight >= 0.2 else { continue }
            for channel in 0 ..< 3 {
                let correction = min(48, max(-48, field[index + channel] / field[index + 3]))
                let baseline = min(255, max(0, Double(source[index + channel]) + fallbackShift[channel]))
                let candidate = min(255, max(0, Double(source[index + channel]) + correction * protection[pixel]))
                baselineError += weight * abs(baseline - Double(neutral[index + channel]))
                candidateError += weight * abs(candidate - Double(neutral[index + channel]))
                validationWeight += weight
            }
        }
        guard validationWeight >= 12,
              (baselineError - candidateError) / validationWeight >= 0.35,
              candidateError <= baselineError * 0.92 else { return false }
        for pixel in protection.indices {
            let index = pixel * 4
            guard protection[pixel] > 0, field[index + 3] >= 0.001 else { continue }
            for channel in 0 ..< 3 {
                let correction = min(48, max(-48, field[index + channel] / field[index + 3]))
                source[index + channel] = UInt8(min(255, max(0,
                    (Double(source[index + channel]) + correction * protection[pixel]).rounded()
                )))
            }
        }
        return true
    }

    static func distance(_ point: CGPoint, contour: [CGPoint]) -> Double {
        guard !contour.isEmpty else { return .infinity }
        var inside = false, squared = Double.infinity
        for index in contour.indices {
            let a = contour[(index + contour.count - 1) % contour.count], b = contour[index]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            let vx = b.x - a.x, vy = b.y - a.y
            let along = min(1, max(0,
                ((point.x - a.x) * vx + (point.y - a.y) * vy) / max(1e-8, vx * vx + vy * vy)
            ))
            squared = min(squared, pow(point.x - a.x - along * vx, 2) + pow(point.y - a.y - along * vy, 2))
        }
        return inside ? 0 : sqrt(squared)
    }

    private static func smoothStep(_ value: Double) -> Double {
        let amount = min(1, max(0, value))
        return amount * amount * (3 - 2 * amount)
    }

    private static func blur(_ values: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        var input = values
        let diameter = Double(radius * 2 + 1)
        // Six separable running-sum passes: the cached state build is linear
        // in pixel count, not a blur kernel on every display frame.
        for pass in 0 ..< 6 {
            let horizontal = pass % 2 == 0
            let length = horizontal ? width : height
            let lines = horizontal ? height : width
            let step = horizontal ? 4 : width * 4
            var output = [Double](repeating: 0, count: input.count)
            for line in 0 ..< lines {
                let base = horizontal ? line * width * 4 : line * 4
                for channel in 0 ..< 4 {
                    var sum = 0.0
                    for offset in -radius ... radius {
                        sum += input[base + max(0, min(length - 1, offset)) * step + channel]
                    }
                    for point in 0 ..< length {
                        output[base + point * step + channel] = sum / diameter
                        sum -= input[base + max(0, point - radius) * step + channel]
                        sum += input[base + min(length - 1, point + radius + 1) * step + channel]
                    }
                }
            }
            input = output
        }
        return input
    }
}

/// A single authored expression cell. Its transparent pixels are resolved
/// over the selected phoneme, never over a second mouth on the neutral head.
struct OpenClamAvatarStylizedEmotionMouthSample {
    let image: UIImage
    let frame: Int
    let geometry: OpenClamAvatarSpriteGeometry
    var contourFamily: String? = nil
    var contourState: Int? = nil
}

/// Builds one resolved, colour-matched mouth with an opaque lip interior and
/// a bounded skin feather. No second SwiftUI ellipse is applied afterwards.
/// Photographic avatars never call this renderer.
@MainActor
enum OpenClamAvatarStylizedSpeechPatchRenderer {
    private static let cache: NSCache<NSString, UIImage> = {
        let value = NSCache<NSString, UIImage>()
        value.countLimit = 96
        value.totalCostLimit = 24 * 1_024 * 1_024
        return value
    }()

    static func image(
        selected: UIImage?,
        neutral: UIImage?,
        geometry: OpenClamAvatarSpeechPatchGeometry,
        viseme: OpenClamAvatarViseme,
        sourceMedium: OpenClamAvatarSourceMedium = .illustration,
        emotion: OpenClamAvatarStylizedEmotionMouthSample? = nil
    ) -> UIImage? {
        guard sourceMedium.isStylized, geometry.clipsFeatherToCoreBounds,
              let selected, let neutral,
              let selectedCG = selected.cgImage,
              let neutralCG = neutral.cgImage else { return nil }
        let bounds = geometry.coreBounds
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0,
              bounds.width <= 1_024, bounds.height <= 1_024,
              geometry.translationX(for: viseme).isFinite else { return nil }
        let registration = min(bounds.width * 0.35, max(-bounds.width * 0.35,
            geometry.translationX(for: viseme)))
        let width = max(1, Int(bounds.width.rounded()))
        let height = max(1, Int(bounds.height.rounded()))
        let selectedBounds = bounds.offsetBy(dx: -registration, dy: 0)
        let oldContour = lipContour(
            geometry: geometry, viseme: .silence, registration: 0, emotion: nil
        )
        let newContour = lipContour(
            geometry: geometry, viseme: viseme,
            registration: registration, emotion: emotion
        )
        var contourHasher = Hasher()
        for contour in [oldContour, newContour] {
            contourHasher.combine(contour?.count ?? 0)
            for point in contour ?? [] {
                contourHasher.combine(point.x)
                contourHasher.combine(point.y)
            }
        }
        let key = [
            String(selected.hash), String(neutral.hash), viseme.rawValue,
            sourceMedium.rawValue,
            String(describing: bounds), String(Double(registration)),
            String(width), String(height),
            emotion.map { String($0.image.hash) } ?? "plain",
            emotion.map { String($0.frame) } ?? "",
            emotion.map { String(describing: $0.geometry) } ?? "",
            String(contourHasher.finalize()),
        ].joined(separator: ":") as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard var selectedPixels = sampledPixels(
                  selectedCG, bounds: selectedBounds, width: width, height: height),
              let neutralPixels = sampledPixels(
                  neutralCG, bounds: bounds, width: width, height: height) else { return nil }

        if let emotion {
            guard resolve(
                emotion: emotion, over: &selectedPixels,
                bounds: bounds, width: width, height: height,
                registration: registration
            ) else { return nil }
        }
        // Pixel readers use premultiplied RGBA. The colour/difference work is
        // straight RGB; premultiply exactly once after applying ownership.
        unpremultiply(&selectedPixels)
        var neutralRGB = neutralPixels
        unpremultiply(&neutralRGB)
        let shift = annulusToneShift(
            source: selectedPixels, neutral: neutralRGB,
            width: width, height: height
        )
        let matched = sourceMedium == .rendered3D
            && OpenClamAvatarStylizedMouthSkinPolicy.correct(
                source: &selectedPixels, neutral: neutralRGB,
                width: width, height: height,
                oldContour: oldContour, newContour: newContour,
                fallbackShift: shift
            )
        if !matched {
            for index in stride(from: 0, to: selectedPixels.count, by: 4) {
                for channel in 0 ..< 3 {
                    selectedPixels[index + channel] = UInt8(min(255, max(0,
                        (Double(selectedPixels[index + channel]) + shift[channel]).rounded()
                    )))
                }
            }
        }

        var deltas = [UInt8](repeating: 0, count: width * height)
        for pixel in deltas.indices {
            let index = pixel * 4
            let red = abs(
                Int(selectedPixels[index]) - Int(neutralRGB[index])
            )
            let green = abs(
                Int(selectedPixels[index + 1]) - Int(neutralRGB[index + 1])
            )
            let blue = abs(
                Int(selectedPixels[index + 2]) - Int(neutralRGB[index + 2])
            )
            deltas[pixel] = UInt8(max(red, max(green, blue)))
        }

        var output = selectedPixels
        for y in 0 ..< height {
            for x in 0 ..< width {
                var localDelta = 0
                for offsetY in -1 ... 1 {
                    let sampleY = y + offsetY
                    guard sampleY >= 0, sampleY < height else { continue }
                    for offsetX in -1 ... 1 {
                        let sampleX = x + offsetX
                        guard sampleX >= 0, sampleX < width else { continue }
                        localDelta = max(
                            localDelta,
                            Int(deltas[sampleY * width + sampleX])
                        )
                    }
                }
                let pixel = y * width + x
                let index = pixel * 4
                let alpha = OpenClamAvatarStylizedSpeechPatchPixelPolicy
                    .ownershipAlpha(
                        maximumChannelDelta: localDelta,
                        spatialAlpha: OpenClamAvatarStylizedSpeechPatchPixelPolicy
                            .spatialAlpha(
                                x: x, y: y, width: width, height: height
                            )
                    )
                let outputAlpha = Int(
                    (Double(selectedPixels[index + 3]) * alpha).rounded()
                )
                output[index] = UInt8(
                    Int(selectedPixels[index]) * outputAlpha / 255
                )
                output[index + 1] = UInt8(
                    Int(selectedPixels[index + 1]) * outputAlpha / 255
                )
                output[index + 2] = UInt8(
                    Int(selectedPixels[index + 2]) * outputAlpha / 255
                )
                output[index + 3] = UInt8(outputAlpha)
            }
        }
        guard let rendered = image(
            pixels: output, width: width, height: height
        ) else { return nil }
        cache.setObject(rendered, forKey: key, cost: width * height * 4)
        return rendered
    }

    private static func resolve(
        emotion: OpenClamAvatarStylizedEmotionMouthSample,
        over selected: inout [UInt8],
        bounds: CGRect,
        width: Int,
        height: Int,
        registration: CGFloat
    ) -> Bool {
        guard let atlas = emotion.image.cgImage else { return false }
        let spec = emotion.geometry
        guard spec.columns > 0, spec.rows > 0,
              spec.columns <= 1_024, spec.rows <= 1_024,
              emotion.frame >= 0, emotion.frame < spec.frameCount,
              spec.box.width > 0, spec.box.height > 0 else { return false }
        let columns = spec.storage == .verticalStrip ? 1 : spec.columns
        let rows = spec.storage == .verticalStrip ? spec.frameCount : spec.rows
        guard atlas.width % columns == 0, atlas.height % rows == 0 else { return false }
        let cellWidth = atlas.width / columns
        let cellHeight = atlas.height / rows
        guard cellWidth > 0, cellHeight > 0 else { return false }
        let column = spec.storage == .verticalStrip ? 0 : emotion.frame % columns
        let row = spec.storage == .verticalStrip ? emotion.frame : emotion.frame / columns
        guard let cell = pixels(
            atlas, x: column * cellWidth, y: row * cellHeight,
            width: cellWidth, height: cellHeight
        ) else { return false }

        // Sampling is constrained to ONE atlas cell. A mouth box extending
        // beyond that cell must not borrow skin/ink from the next expression.
        for y in 0 ..< height {
            for x in 0 ..< width {
                let localX = bounds.minX + (CGFloat(x) + 0.5) * bounds.width / CGFloat(width)
                    - registration - spec.box.x
                let localY = bounds.minY + (CGFloat(y) + 0.5) * bounds.height / CGFloat(height) - spec.box.y
                guard localX >= 0, localY >= 0,
                      localX < spec.box.width, localY < spec.box.height else { continue }
                let sx = Double(localX / spec.box.width) * Double(cellWidth) - 0.5
                let sy = Double(localY / spec.box.height) * Double(cellHeight) - 0.5
                let x0 = Int(floor(sx)), y0 = Int(floor(sy))
                let wx = sx - Double(x0), wy = sy - Double(y0)
                var sample = [Double](repeating: 0, count: 4)
                for dy in 0 ... 1 {
                    for dx in 0 ... 1 {
                        let ix = min(cellWidth - 1, max(0, x0 + dx))
                        let iy = min(cellHeight - 1, max(0, y0 + dy))
                        let weight = (dx == 0 ? 1 - wx : wx) * (dy == 0 ? 1 - wy : wy)
                        let index = (iy * cellWidth + ix) * 4
                        for channel in 0 ..< 4 {
                            sample[channel] += Double(cell[index + channel]) * weight
                        }
                    }
                }
                let index = (y * width + x) * 4
                let remainder = 1 - sample[3] / 255
                for channel in 0 ..< 4 {
                    selected[index + channel] = UInt8(min(255, max(0,
                        (sample[channel] + Double(selected[index + channel]) * remainder).rounded()
                    )))
                }
            }
        }
        return true
    }

    private static func unpremultiply(_ pixels: inout [UInt8]) {
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0 ..< 3 {
                pixels[index + channel] = UInt8(min(255,
                    (Int(pixels[index + channel]) * 255 + alpha / 2) / alpha
                ))
            }
        }
    }

    private static func lipContour(
        geometry: OpenClamAvatarSpeechPatchGeometry,
        viseme: OpenClamAvatarViseme,
        registration: CGFloat,
        emotion: OpenClamAvatarStylizedEmotionMouthSample?
    ) -> [CGPoint]? {
        guard let spec = geometry.skinMatch,
              spec.version == 1, spec.space == "canonical-pixels" else { return nil }
        var points = spec.contours[viseme.rawValue]
        if let emotion {
            guard let family = emotion.contourFamily,
                  let state = emotion.contourState,
                  let states = spec.emotionContours[family]?[viseme.rawValue],
                  state >= 0, state < states.count else { return nil }
            points = states[state]
        }
        guard let points, (8 ... 64).contains(points.count),
              registration.isFinite else { return nil }
        let box = geometry.coreBounds
        var result: [CGPoint] = []
        for point in points {
            guard point.count == 2, point.allSatisfy(\.isFinite) else { return nil }
            let x = (point[0] - box.minX + registration) * box.width.rounded() / box.width
            let y = (point[1] - box.minY) * box.height.rounded() / box.height
            guard x >= -0.15 * box.width, x <= 1.15 * box.width,
                  y >= -0.15 * box.height, y <= 1.15 * box.height else { return nil }
            result.append(CGPoint(x: x, y: y))
        }
        return result
    }

    private static func annulusToneShift(
        source: [UInt8], neutral: [UInt8], width: Int, height: Int
    ) -> [Double] {
        var selectedSamples = [[Int]](repeating: [], count: 3)
        var neutralSamples = [[Int]](repeating: [], count: 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let coverage = OpenClamAvatarStylizedSpeechPatchPixelPolicy
                    .spatialAlpha(x: x, y: y, width: width, height: height)
                guard coverage >= 0.08, coverage <= 0.42 else { continue }
                let index = (y * width + x) * 4
                guard source[index + 3] >= 240, neutral[index + 3] >= 240 else { continue }
                let sourceLuma = (0 ..< 3).reduce(0) { $0 + Int(source[index + $1]) } / 3
                let neutralLuma = (0 ..< 3).reduce(0) { $0 + Int(neutral[index + $1]) } / 3
                let delta = (0 ..< 3).map { abs(Int(source[index + $0]) - Int(neutral[index + $0])) }.max() ?? 0
                guard sourceLuma >= 35, neutralLuma >= 35, delta <= 72 else { continue }
                for channel in 0 ..< 3 {
                    selectedSamples[channel].append(Int(source[index + channel]))
                    neutralSamples[channel].append(Int(neutral[index + channel]))
                }
            }
        }
        guard selectedSamples[0].count >= 12 else { return [0, 0, 0] }
        func median(_ input: [Int]) -> Double {
            let sorted = input.sorted(), middle = input.count / 2
            return input.count % 2 == 1 ? Double(sorted[middle])
                : Double(sorted[middle - 1] + sorted[middle]) / 2
        }
        return (0 ..< 3).map {
            min(24, max(-24, median(neutralSamples[$0]) - median(selectedSamples[$0])))
        }
    }

    private static func pixels(
        _ image: CGImage,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        guard x >= 0, y >= 0, x + width <= image.width,
              y + height <= image.height,
              let crop = image.cropping(to: CGRect(
                  x: x, y: y, width: width, height: height
              )) else { return nil }
        var result = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &result,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        return result
    }

    private static func sampledPixels(
        _ image: CGImage, bounds: CGRect, width: Int, height: Int
    ) -> [UInt8]? {
        guard bounds.minX >= 0, bounds.minY >= 0,
              bounds.maxX <= CGFloat(image.width), bounds.maxY <= CGFloat(image.height) else { return nil }
        let left = Int(floor(bounds.minX)), top = Int(floor(bounds.minY))
        let cropWidth = Int(ceil(bounds.maxX)) - left
        let cropHeight = Int(ceil(bounds.maxY)) - top
        guard let crop = pixels(image, x: left, y: top, width: cropWidth, height: cropHeight) else { return nil }
        if bounds.minX == CGFloat(left), bounds.minY == CGFloat(top),
           bounds.width == CGFloat(width), bounds.height == CGFloat(height) { return crop }
        // Do not round the measured viseme registration. Ordinary speech and
        // its expression cell must share the same subpixel coordinate frame.
        var result = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            let sy = bounds.minY - CGFloat(top) + (CGFloat(y) + 0.5) * bounds.height / CGFloat(height) - 0.5
            let y0 = Int(floor(sy)), wy = Double(sy - CGFloat(y0))
            for x in 0 ..< width {
                let sx = bounds.minX - CGFloat(left) + (CGFloat(x) + 0.5) * bounds.width / CGFloat(width) - 0.5
                let x0 = Int(floor(sx)), wx = Double(sx - CGFloat(x0))
                for channel in 0 ..< 4 {
                    var value = 0.0
                    for dy in 0 ... 1 {
                        for dx in 0 ... 1 {
                            let ix = min(cropWidth - 1, max(0, x0 + dx))
                            let iy = min(cropHeight - 1, max(0, y0 + dy))
                            let weight = (dx == 0 ? 1 - wx : wx) * (dy == 0 ? 1 - wy : wy)
                            value += Double(crop[(iy * cropWidth + ix) * 4 + channel]) * weight
                        }
                    }
                    result[(y * width + x) * 4 + channel] = UInt8(min(255, max(0, value.rounded())))
                }
            }
        }
        return result
    }

    private static func image(
        pixels: [UInt8],
        width: Int,
        height: Int
    ) -> UIImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }
}

private struct OpenClamAvatarSpeechPatchMask: View {
    let geometry: OpenClamAvatarSpeechPatchGeometry

    var body: some View {
        GeometryReader { proxy in
            let scaleX = proxy.size.width
                / OpenClamAvatarSpeechPatchGeometry.canonicalSize.width
            let scaleY = proxy.size.height
                / OpenClamAvatarSpeechPatchGeometry.canonicalSize.height
            let bounds = geometry.coreBounds
            let feather = geometry.featherRadius

            if geometry.clipsFeatherToCoreBounds {
                let visible = geometry.stylizedVisibleBounds
                Ellipse()
                .fill(Color.white)
                .frame(
                    width: max(1, visible.width - feather * 2) * scaleX,
                    height: max(1, visible.height - feather * 2) * scaleY
                )
                .position(
                    x: visible.midX * scaleX,
                    y: visible.midY * scaleY
                )
                .blur(radius: feather * min(scaleX, scaleY))
                .mask {
                    Rectangle()
                        .fill(Color.white)
                        .frame(
                            width: bounds.width * scaleX,
                            height: bounds.height * scaleY
                        )
                        .position(
                            x: bounds.midX * scaleX,
                            y: bounds.midY * scaleY
                        )
                }
            } else {
                RoundedRectangle(
                    cornerRadius: min(bounds.width, bounds.height) * 0.34,
                    style: .continuous
                )
                .fill(Color.white)
                .frame(
                    width: bounds.width * scaleX,
                    height: bounds.height * scaleY
                )
                .position(
                    x: bounds.midX * scaleX,
                    y: bounds.midY * scaleY
                )
                .blur(radius: feather * min(scaleX, scaleY))
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// A conservative local interaction silhouette in body-image coordinates.
/// Avatar packages deliberately contain only rendering and face-rig metadata;
/// they do not expose a pixel alpha hit mask. These regions are therefore
/// derived from the validated face bounds and body size, and intentionally
/// leave the surrounding transparent canvas (and the gaps between limbs)
/// available to the conversation underneath.
enum OpenClamAvatarStageInteractionGeometry {
    static func bodyRegions(
        for geometry: OpenClamAvatarRigGeometry
    ) -> [CGRect] {
        let body = geometry.bodySize.cgSize
        let bodyBounds = CGRect(origin: .zero, size: body)
        let face = geometry.faceBoundsInBody.cgRect
        guard body.width > 0, body.height > 0,
              bodyBounds.contains(face) else {
            return []
        }

        // Imported and bundled rigs keep the face near the visual center.
        // Clamp it defensively so malformed but otherwise displayable metadata
        // can never expand the interaction surface across the whole stage.
        let centerX = min(max(face.midX, body.width * 0.42), body.width * 0.58)
        let headWidth = max(face.width * 1.90, body.width * 0.16)
        let headHeight = max(face.height * 1.72, body.height * 0.095)
        let head = CGRect(
            x: centerX - headWidth / 2,
            y: face.minY - face.height * 0.34,
            width: headWidth,
            height: headHeight
        )

        let shoulderTop = max(head.maxY - face.height * 0.20, body.height * 0.11)
        let shoulders = CGRect(
            x: centerX - body.width * 0.23,
            y: shoulderTop,
            width: body.width * 0.46,
            height: body.height * 0.16
        )
        let torso = CGRect(
            x: centerX - body.width * 0.19,
            y: shoulders.minY + body.height * 0.08,
            width: body.width * 0.38,
            height: body.height * 0.30
        )
        let armTop = shoulders.minY + body.height * 0.035
        let leftArm = CGRect(
            x: centerX - body.width * 0.26,
            y: armTop,
            width: body.width * 0.10,
            height: body.height * 0.32
        )
        let rightArm = CGRect(
            x: centerX + body.width * 0.16,
            y: armTop,
            width: body.width * 0.10,
            height: body.height * 0.32
        )
        let hips = CGRect(
            x: centerX - body.width * 0.19,
            y: torso.maxY - body.height * 0.045,
            width: body.width * 0.38,
            height: body.height * 0.14
        )
        let legTop = hips.maxY - body.height * 0.020
        let leftLeg = CGRect(
            x: centerX - body.width * 0.20,
            y: legTop,
            width: body.width * 0.17,
            height: body.height * 0.39
        )
        let rightLeg = CGRect(
            x: centerX + body.width * 0.03,
            y: legTop,
            width: body.width * 0.17,
            height: body.height * 0.39
        )

        return [head, shoulders, torso, leftArm, rightArm, hips, leftLeg, rightLeg]
            .map { $0.intersection(bodyBounds) }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }
}

@MainActor
private final class OpenClamAvatarStageInteractionUIView: UIView {
    var interactionPath: CGPath?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event),
              let interactionPath else { return false }
        return interactionPath.contains(
            point,
            using: .winding,
            transform: .identity
        )
    }
}

/// UIKit owns this one narrow surface because SwiftUI's `DragGesture` does
/// not expose its touch count. Keeping all four recognizers on the same view
/// gives one finger and two fingers unambiguous, non-overlapping jobs while
/// preserving the stage's descriptor-derived silhouette hit testing.
@MainActor
private struct OpenClamAvatarStageInteractionView: UIViewRepresentable {
    let interactionPath: CGPath
    let onSinglePanBegan: () -> Void
    let onSinglePanChanged: (_ translation: CGSize, _ location: CGPoint) -> Void
    let onSinglePanEnded: (
        _ translation: CGSize,
        _ location: CGPoint,
        _ cancelled: Bool
    ) -> Void
    let onTap: (_ location: CGPoint) -> Void
    let onTransformBegan: () -> Void
    let onTransformChanged: (_ magnification: CGFloat, _ translation: CGSize) -> Void
    let onTransformEnded: (_ cancelled: Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSinglePanBegan: onSinglePanBegan,
            onSinglePanChanged: onSinglePanChanged,
            onSinglePanEnded: onSinglePanEnded,
            onTap: onTap,
            onTransformBegan: onTransformBegan,
            onTransformChanged: onTransformChanged,
            onTransformEnded: onTransformEnded
        )
    }

    func makeUIView(context: Context) -> OpenClamAvatarStageInteractionUIView {
        let view = OpenClamAvatarStageInteractionUIView(frame: .zero)
        view.interactionPath = interactionPath
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(
        _ uiView: OpenClamAvatarStageInteractionUIView,
        context: Context
    ) {
        uiView.interactionPath = interactionPath
        context.coordinator.update(
            onSinglePanBegan: onSinglePanBegan,
            onSinglePanChanged: onSinglePanChanged,
            onSinglePanEnded: onSinglePanEnded,
            onTap: onTap,
            onTransformBegan: onTransformBegan,
            onTransformChanged: onTransformChanged,
            onTransformEnded: onTransformEnded
        )
    }

    static func dismantleUIView(
        _ uiView: OpenClamAvatarStageInteractionUIView,
        coordinator: Coordinator
    ) {
        coordinator.uninstall(from: uiView)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var onSinglePanBegan: () -> Void
        private var onSinglePanChanged: (CGSize, CGPoint) -> Void
        private var onSinglePanEnded: (CGSize, CGPoint, Bool) -> Void
        private var onTap: (CGPoint) -> Void
        private var onTransformBegan: () -> Void
        private var onTransformChanged: (CGFloat, CGSize) -> Void
        private var onTransformEnded: (Bool) -> Void

        private weak var installedView: UIView?
        private weak var singlePan: UIPanGestureRecognizer?
        private weak var tap: UITapGestureRecognizer?
        private weak var twoFingerPan: UIPanGestureRecognizer?
        private weak var pinch: UIPinchGestureRecognizer?

        private var activeTransformRecognizers: Set<ObjectIdentifier> = []
        private var transformMagnification: CGFloat = 1
        private var transformTranslation = CGSize.zero
        private var transformWasCancelled = false
        private var isSinglePanActive = false
        private var didBeginSinglePanCallbacks = false
        private var singlePanWasSupersededByTransform = false
        private var latestSinglePanTranslation = CGSize.zero
        private var latestSinglePanLocation = CGPoint.zero

        init(
            onSinglePanBegan: @escaping () -> Void,
            onSinglePanChanged: @escaping (CGSize, CGPoint) -> Void,
            onSinglePanEnded: @escaping (CGSize, CGPoint, Bool) -> Void,
            onTap: @escaping (CGPoint) -> Void,
            onTransformBegan: @escaping () -> Void,
            onTransformChanged: @escaping (CGFloat, CGSize) -> Void,
            onTransformEnded: @escaping (Bool) -> Void
        ) {
            self.onSinglePanBegan = onSinglePanBegan
            self.onSinglePanChanged = onSinglePanChanged
            self.onSinglePanEnded = onSinglePanEnded
            self.onTap = onTap
            self.onTransformBegan = onTransformBegan
            self.onTransformChanged = onTransformChanged
            self.onTransformEnded = onTransformEnded
        }

        func update(
            onSinglePanBegan: @escaping () -> Void,
            onSinglePanChanged: @escaping (CGSize, CGPoint) -> Void,
            onSinglePanEnded: @escaping (CGSize, CGPoint, Bool) -> Void,
            onTap: @escaping (CGPoint) -> Void,
            onTransformBegan: @escaping () -> Void,
            onTransformChanged: @escaping (CGFloat, CGSize) -> Void,
            onTransformEnded: @escaping (Bool) -> Void
        ) {
            self.onSinglePanBegan = onSinglePanBegan
            self.onSinglePanChanged = onSinglePanChanged
            self.onSinglePanEnded = onSinglePanEnded
            self.onTap = onTap
            self.onTransformBegan = onTransformBegan
            self.onTransformChanged = onTransformChanged
            self.onTransformEnded = onTransformEnded
        }

        func install(on view: UIView) {
            guard installedView !== view else { return }
            if let installedView { uninstall(from: installedView) }

            let singlePan = UIPanGestureRecognizer(
                target: self,
                action: #selector(singlePanChanged(_:))
            )
            singlePan.minimumNumberOfTouches = 1
            // Let this recognizer observe finger two instead of ending its
            // one-finger session (and potentially committing opacity) before
            // the transform recognizers have reached `.began`. Its callback
            // path below immediately cancels one-finger behavior at 2 touches;
            // the exact-two-finger recognizers remain the sole transform owner.
            singlePan.maximumNumberOfTouches = 2
            configure(singlePan)

            let tap = UITapGestureRecognizer(
                target: self,
                action: #selector(tapped(_:))
            )
            tap.numberOfTouchesRequired = 1
            tap.numberOfTapsRequired = 1
            configure(tap)
            tap.require(toFail: singlePan)

            let twoFingerPan = UIPanGestureRecognizer(
                target: self,
                action: #selector(transformRecognizerChanged(_:))
            )
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            configure(twoFingerPan)

            let pinch = UIPinchGestureRecognizer(
                target: self,
                action: #selector(transformRecognizerChanged(_:))
            )
            configure(pinch)

            view.addGestureRecognizer(singlePan)
            view.addGestureRecognizer(tap)
            view.addGestureRecognizer(twoFingerPan)
            view.addGestureRecognizer(pinch)

            installedView = view
            self.singlePan = singlePan
            self.tap = tap
            self.twoFingerPan = twoFingerPan
            self.pinch = pinch
        }

        func uninstall(from view: UIView) {
            // SwiftUI can dismantle a representable while reconciling state.
            // Do not synchronously call back into that state from here; the
            // owning overlay already cancels previews when it disappears or
            // switches to Thread-in-front.
            [singlePan, tap, twoFingerPan, pinch]
                .compactMap { $0 }
                .forEach(view.removeGestureRecognizer)
            installedView = nil
            singlePan = nil
            tap = nil
            twoFingerPan = nil
            pinch = nil
            activeTransformRecognizers.removeAll()
            isSinglePanActive = false
            didBeginSinglePanCallbacks = false
            singlePanWasSupersededByTransform = false
            latestSinglePanTranslation = .zero
            latestSinglePanLocation = .zero
            resetTransformValues()
        }

        private func configure(_ recognizer: UIGestureRecognizer) {
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
        }

        @objc private func singlePanChanged(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            // The representable lives inside the avatar's scaleEffect. Use
            // window points for gesture thresholds and opacity travel so a
            // four-times zoom does not make the same finger drag four times
            // less effective. Gaze location remains local to the stage.
            let point = recognizer.translation(in: view.window ?? view)
            let translation = CGSize(width: point.x, height: point.y)
            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                isSinglePanActive = true
                latestSinglePanTranslation = translation
                latestSinglePanLocation = location
                guard recognizer.numberOfTouches == 1,
                      activeTransformRecognizers.isEmpty else {
                    didBeginSinglePanCallbacks = false
                    singlePanWasSupersededByTransform = true
                    return
                }
                didBeginSinglePanCallbacks = true
                singlePanWasSupersededByTransform = false
                onSinglePanBegan()
                onSinglePanChanged(translation, location)
            case .changed:
                latestSinglePanTranslation = translation
                latestSinglePanLocation = location
                if recognizer.numberOfTouches >= 2 {
                    supersedeSinglePanForTransform()
                    return
                }
                if didBeginSinglePanCallbacks,
                   !singlePanWasSupersededByTransform {
                    onSinglePanChanged(translation, location)
                }
            case .ended:
                finishSinglePan(
                    translation: translation,
                    location: location,
                    recognizerWasCancelled: false
                )
            case .cancelled:
                finishSinglePan(
                    translation: translation,
                    location: location,
                    recognizerWasCancelled: true
                )
            default:
                break
            }
        }

        private func finishSinglePan(
            translation: CGSize,
            location: CGPoint,
            recognizerWasCancelled: Bool
        ) {
            if didBeginSinglePanCallbacks {
                onSinglePanEnded(
                    translation,
                    location,
                    recognizerWasCancelled
                        || singlePanWasSupersededByTransform
                )
            }
            isSinglePanActive = false
            didBeginSinglePanCallbacks = false
            singlePanWasSupersededByTransform = false
            latestSinglePanTranslation = .zero
            latestSinglePanLocation = .zero
        }

        /// Ends a one-finger preview as a cancellation at the instant finger
        /// two is observed. This closes the ordering hole where maxTouches=1
        /// could emit `.ended` and commit opacity before pinch/two-pan began.
        /// Clearing the delivery flag makes the recognizer's later terminal
        /// state a no-op, so cancellation is reported exactly once.
        private func supersedeSinglePanForTransform() {
            singlePanWasSupersededByTransform = true
            guard isSinglePanActive, didBeginSinglePanCallbacks else { return }
            onSinglePanEnded(
                latestSinglePanTranslation,
                latestSinglePanLocation,
                true
            )
            didBeginSinglePanCallbacks = false
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let view = recognizer.view else { return }
            onTap(recognizer.location(in: view))
        }

        @objc private func transformRecognizerChanged(
            _ recognizer: UIGestureRecognizer
        ) {
            let identifier = ObjectIdentifier(recognizer)
            switch recognizer.state {
            case .began:
                if activeTransformRecognizers.isEmpty {
                    resetTransformValues()
                    // A second finger upgrades the interaction to a transform.
                    // Stop and cancel the earlier one-finger preview now, and
                    // prevent a pending tap from firing when the fingers lift.
                    supersedeSinglePanForTransform()
                    tap?.isEnabled = false
                    onTransformBegan()
                }
                activeTransformRecognizers.insert(identifier)
                updateTransformValue(from: recognizer)
                publishTransform()
            case .changed:
                guard activeTransformRecognizers.contains(identifier) else {
                    return
                }
                updateTransformValue(from: recognizer)
                publishTransform()
            case .ended, .cancelled:
                guard activeTransformRecognizers.contains(identifier) else {
                    return
                }
                updateTransformValue(from: recognizer)
                publishTransform()
                activeTransformRecognizers.remove(identifier)
                if recognizer.state == .cancelled {
                    transformWasCancelled = true
                }
                if activeTransformRecognizers.isEmpty {
                    let cancelled = transformWasCancelled
                    onTransformEnded(cancelled)
                    tap?.isEnabled = true
                    resetTransformValues()
                }
            default:
                break
            }
        }

        private func updateTransformValue(from recognizer: UIGestureRecognizer) {
            if let pinch = recognizer as? UIPinchGestureRecognizer {
                transformMagnification = pinch.scale
            } else if let pan = recognizer as? UIPanGestureRecognizer,
                      let view = pan.view {
                let point = pan.translation(in: view.window ?? view)
                transformTranslation = CGSize(width: point.x, height: point.y)
            }
        }

        private func publishTransform() {
            onTransformChanged(transformMagnification, transformTranslation)
        }

        private func resetTransformValues() {
            transformMagnification = 1
            transformTranslation = .zero
            transformWasCancelled = false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            let firstIsTransform = isTransformRecognizer(gestureRecognizer)
            let secondIsTransform = isTransformRecognizer(otherGestureRecognizer)
            if firstIsTransform, secondIsTransform { return true }

            // The first pan may already be recognized when finger two lands.
            // Let the exact-two-finger recognizers begin, then their `.began`
            // path supersedes (and ultimately cancels) the one-finger action.
            return (gestureRecognizer === singlePan && secondIsTransform)
                || (otherGestureRecognizer === singlePan && firstIsTransform)
        }

        private func isTransformRecognizer(
            _ recognizer: UIGestureRecognizer
        ) -> Bool {
            recognizer === pinch || recognizer === twoFingerPan
        }
    }
}

/// Descriptor-driven counterpart to CaptainAyerAvatarStage. It classifies
/// face gaze, taps, and vertical opacity drags, while the overlay owns scale,
/// pinch arbitration, persisted opacity, and true hide/pass-through.
@MainActor
struct OpenClamCatalogAvatarStage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragSession = CaptainAyerAvatarDragSession()

    enum Presentation: Sendable {
        case compact
        case expanded

        func crop(for avatar: OpenClamAvatarDescriptor) -> CGRect {
            let body = avatar.geometry.bodySize.cgSize
            switch self {
            case .expanded:
                return CGRect(origin: .zero, size: body)
            case .compact:
                let face = avatar.geometry.faceBoundsInBody.cgRect
                // A true head-and-shoulders plate. The old compact crop kept
                // almost half the body and the conversation overlay then
                // magnified that full-body plate 3.4x. Besides making the
                // preset avatar-specific, that could crop the forehead while
                // still showing the waist. Deriving this crop from the face
                // registration keeps hair, shoulders, and upper chest for
                // every validated catalog avatar.
                let height = min(body.height, face.height * 3.5)
                let width = min(
                    body.width,
                    max(face.width * 3.2, height * 0.72)
                )
                let x = min(max(0, face.midX - width / 2), max(0, body.width - width))
                let y = min(
                    max(0, face.minY - face.height * 0.75),
                    max(0, body.height - height)
                )
                return CGRect(x: x, y: y, width: width, height: height)
            }
        }
    }

    let avatar: OpenClamAvatarDescriptor
    @ObservedObject var controller: CaptainAyerLipSyncController
    @ObservedObject var reactions: CaptainAyerFaceReactionController
    @ObservedObject var faceMirror: CaptainAyerFaceMirrorController
    let presentation: Presentation
    let allowsGazeTracking: Bool
    /// Motion clips replace only the artwork. The stage's narrow interaction
    /// silhouette remains mounted so tap, gaze, opacity, and pinch can
    /// deterministically interrupt motion and return to the live face rig.
    let showsArtwork: Bool
    /// Kept separate from the interaction surface. The overlay intentionally
    /// opens at a subtle alpha, and visual alpha must not alter the available
    /// body area for a vertical opacity gesture.
    let renderOpacity: Double
    let onVerticalOpacityChanged: ((CGFloat) -> Void)?
    let onVerticalOpacityEnded: (() -> Void)?
    let onVerticalOpacityCancelled: (() -> Void)?
    /// The overlay owns persisted scale/position and transform arbitration;
    /// the stage owns exact touch counts and the narrow hit region.
    let onTransformBegan: (() -> Void)?
    let onTransformChanged: ((_ magnification: CGFloat, _ translation: CGSize) -> Void)?
    let onTransformEnded: ((_ cancelled: Bool) -> Void)?
    /// A discrete tap callback, kept separate from drag/pinch interaction so
    /// an overlay such as the opacity panel can dismiss without disappearing
    /// while its avatar is actively being adjusted.
    let onTapInteraction: (() -> Void)?
    let onInteraction: () -> Void
    private let imageStore: OpenClamAvatarAssetStore

    init(
        avatar: OpenClamAvatarDescriptor,
        controller: CaptainAyerLipSyncController,
        reactions: CaptainAyerFaceReactionController,
        faceMirror: CaptainAyerFaceMirrorController,
        presentation: Presentation = .expanded,
        allowsGazeTracking: Bool = true,
        showsArtwork: Bool = true,
        renderOpacity: Double = 1,
        onVerticalOpacityChanged: ((CGFloat) -> Void)? = nil,
        onVerticalOpacityEnded: (() -> Void)? = nil,
        onVerticalOpacityCancelled: (() -> Void)? = nil,
        onTransformBegan: (() -> Void)? = nil,
        onTransformChanged: ((CGFloat, CGSize) -> Void)? = nil,
        onTransformEnded: ((Bool) -> Void)? = nil,
        onTapInteraction: (() -> Void)? = nil,
        imageStore: OpenClamAvatarAssetStore? = nil,
        onInteraction: @escaping () -> Void = {}
    ) {
        self.avatar = avatar
        self.controller = controller
        self.reactions = reactions
        self.faceMirror = faceMirror
        self.presentation = presentation
        self.allowsGazeTracking = allowsGazeTracking
        self.showsArtwork = showsArtwork
        self.renderOpacity = min(1, max(0, renderOpacity))
        self.onVerticalOpacityChanged = onVerticalOpacityChanged
        self.onVerticalOpacityEnded = onVerticalOpacityEnded
        self.onVerticalOpacityCancelled = onVerticalOpacityCancelled
        self.onTransformBegan = onTransformBegan
        self.onTransformChanged = onTransformChanged
        self.onTransformEnded = onTransformEnded
        self.onTapInteraction = onTapInteraction
        self.imageStore = imageStore ?? .shared
        self.onInteraction = onInteraction
    }

    var body: some View {
        let crop = presentation.crop(for: avatar)
        let opacityPlan = OpenClamAvatarStageOpacityPolicy.plan(for: renderOpacity)
        GeometryReader { proxy in
            ZStack {
                if showsArtwork {
                    ZStack {
                    // The full body is deliberately outside TimelineView. It
                    // remains a stable texture while only the much smaller
                    // face surface advances on the speech clock.
                    OpenClamCatalogAvatarBodyArtwork(
                        avatar: avatar,
                        imageStore: imageStore,
                        crop: crop
                    )
                    .opacity(opacityPlan.bodyOpacity)

                    TimelineView(
                        .animation(
                            minimumInterval: OpenClamAvatarFaceAnimationPolicy.minimumInterval,
                            paused: reduceMotion || !(
                                controller.isExpressionAnimating
                                    || reactions.isAnimating
                                    || reactions.isGazeAnimating
                                    || reactions.isAmbientAnimating
                                    || faceMirror.isCapturing
                            )
                        )
                    ) { context in
                        let mirrorsFace = faceMirror.isCapturing
                        let mirroredExpression = faceMirror.expression
                        let localReaction = reduceMotion
                            ? reactions.reducedMotionRenderState(at: context.date)
                            : reactions.renderState(at: context.date)
                        let spokenReaction = controller.expressionRenderState(
                            at: context.date,
                            reduceMotion: reduceMotion
                        )
                        OpenClamCatalogAvatarFaceArtwork(
                            avatar: avatar,
                            imageStore: imageStore,
                            state: mirrorsFace
                                ? mirroredExpression.mouthRenderState
                                : (reduceMotion ? .idle : controller.renderState(at: context.date)),
                            reaction: mirrorsFace
                                ? CaptainAyerFaceMirrorRenderMapper.renderState(
                                    for: mirroredExpression,
                                    reduceMotion: reduceMotion
                                )
                                : localReaction.mergingSpeech(spokenReaction),
                            showsReactionMouth: !mirrorsFace
                                && !controller.isExpressionAnimating,
                            crop: crop
                        )
                        // The static body is the destination. Source-atop
                        // changes only its color, never its alpha, so the head
                        // and mouth cannot become more opaque than the body.
                        .blendMode(.sourceAtop)
                    }
                    }
                    // A regular compositing group isolates source-atop from the
                    // conversation behind the avatar without rasterizing the
                    // whole stage. Body and hair therefore remain native-sharp
                    // when the overlay magnifies this view.
                    .clipped()
                    .compositingGroup()
                    .allowsHitTesting(false)
                }

                // This surface deliberately stays outside visual alpha and
                // claims only the avatar silhouette. Blank canvas therefore
                // remains a native thread-scroll target.
                OpenClamAvatarStageInteractionView(
                    interactionPath: interactionPath(
                        stageSize: proxy.size,
                        crop: crop
                    ),
                    onSinglePanBegan: beginSinglePan,
                    onSinglePanChanged: { translation, location in
                        updateSinglePan(
                            translation: translation,
                            location: location,
                            stageSize: proxy.size,
                            crop: crop
                        )
                    },
                    onSinglePanEnded: { translation, location, cancelled in
                        endSinglePan(
                            translation: translation,
                            location: location,
                            cancelled: cancelled,
                            stageSize: proxy.size,
                            crop: crop
                        )
                    },
                    onTap: { location in
                        handleTap(
                            at: location,
                            stageSize: proxy.size,
                            crop: crop
                        )
                    },
                    onTransformBegan: {
                        reactions.cancelGaze()
                        onTransformBegan?()
                    },
                    onTransformChanged: { magnification, translation in
                        onTransformChanged?(magnification, translation)
                    },
                    onTransformEnded: { cancelled in
                        onTransformEnded?(cancelled)
                    }
                )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(crop.width / crop.height, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(avatar.displayName)
        .accessibilityValue(accessibilityValue)
        .accessibilityAction(named: "React") {
            reactions.flourish()
            onInteraction()
        }
        .onAppear(perform: synchronizeAmbientMotion)
        .onChange(of: reduceMotion) { _, _ in
            synchronizeAmbientMotion()
        }
        .onChange(of: faceMirror.isCapturing) { _, _ in
            synchronizeAmbientMotion()
        }
        .onChange(of: allowsGazeTracking) { _, enabled in
            if !enabled { reactions.cancelGaze() }
        }
        .onDisappear {
            reactions.stopAmbientMotion()
            reactions.cancelGaze()
        }
    }

    private func beginSinglePan() {
        dragSession = CaptainAyerAvatarDragSession()
    }

    private func updateSinglePan(
        translation: CGSize,
        location: CGPoint,
        stageSize: CGSize,
        crop: CGRect
    ) {
        dragSession.update(
            translation: translation,
            supportsOpacity: onVerticalOpacityChanged != nil
                && onVerticalOpacityEnded != nil
                && onVerticalOpacityCancelled != nil
        )
        if dragSession.intent == .opacity {
            reactions.cancelGaze()
            onVerticalOpacityChanged?(translation.height)
            onInteraction()
            return
        }
        guard dragSession.intent == .gaze else {
            reactions.cancelGaze()
            return
        }
        guard allowsGazeTracking else {
            reactions.cancelGaze()
            return
        }
        reactions.updateGaze(
            toward: normalizedGazeDirection(
                for: location,
                stageSize: stageSize,
                crop: crop
            )
        )
        onInteraction()
    }

    private func endSinglePan(
        translation _: CGSize,
        location _: CGPoint,
        cancelled: Bool,
        stageSize _: CGSize,
        crop _: CGRect
    ) {
        let completion = dragSession.completion
        dragSession = CaptainAyerAvatarDragSession()
        if completion == .opacity {
            reactions.cancelGaze()
            if cancelled {
                onVerticalOpacityCancelled?()
            } else {
                onVerticalOpacityEnded?()
            }
            onInteraction()
            return
        }
        if cancelled {
            reactions.cancelGaze()
            return
        }
        guard allowsGazeTracking else {
            reactions.cancelGaze()
            return
        }
        reactions.releaseGaze(reduceMotion: reduceMotion)
        onInteraction()
    }

    private func handleTap(
        at location: CGPoint,
        stageSize: CGSize,
        crop: CGRect
    ) {
        onTapInteraction?()
        guard allowsGazeTracking else {
            reactions.cancelGaze()
            onInteraction()
            return
        }
        let didReactToFace = reactions.react(
            atNormalizedFacePoint: normalizedFacePoint(
                for: location,
                stageSize: stageSize,
                crop: crop
            )
        )
        if !didReactToFace {
            reactions.react(
                atNormalizedBodyPoint: normalizedBodyPoint(
                    for: location,
                    stageSize: stageSize,
                    crop: crop
                )
            )
        }
        onInteraction()
    }

    private func normalizedGazeDirection(
        for location: CGPoint,
        stageSize: CGSize,
        crop: CGRect
    ) -> CGPoint {
        guard let placement = placement(stageSize: stageSize, crop: crop) else { return .zero }
        let anchor = avatar.geometry.eyeAnchorInBody.cgPoint
        let eye = CGPoint(
            x: placement.origin.x + anchor.x * placement.scale,
            y: placement.origin.y + anchor.y * placement.scale
        )
        return CGPoint(
            x: tanh((location.x - eye.x) / 90),
            y: tanh((location.y - eye.y) / 130)
        )
    }

    private func normalizedFacePoint(
        for location: CGPoint,
        stageSize: CGSize,
        crop: CGRect
    ) -> CGPoint {
        guard let placement = placement(stageSize: stageSize, crop: crop) else {
            return CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        }
        let bodyPoint = CGPoint(
            x: (location.x - placement.origin.x) / placement.scale,
            y: (location.y - placement.origin.y) / placement.scale
        )
        let face = avatar.geometry.faceBoundsInBody.cgRect
        return CGPoint(
            x: (bodyPoint.x - face.minX) / face.width,
            y: (bodyPoint.y - face.minY) / face.height
        )
    }

    private func normalizedBodyPoint(
        for location: CGPoint,
        stageSize: CGSize,
        crop: CGRect
    ) -> CGPoint {
        guard let placement = placement(stageSize: stageSize, crop: crop) else {
            return CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        }
        let body = avatar.geometry.bodySize.cgSize
        let bodyPoint = CGPoint(
            x: (location.x - placement.origin.x) / placement.scale,
            y: (location.y - placement.origin.y) / placement.scale
        )
        return CGPoint(
            x: bodyPoint.x / max(1, body.width),
            y: bodyPoint.y / max(1, body.height)
        )
    }

    private func placement(stageSize: CGSize, crop: CGRect) -> (origin: CGPoint, scale: CGFloat)? {
        let scale = min(stageSize.width / crop.width, stageSize.height / crop.height)
        guard scale.isFinite, scale > 0 else { return nil }
        return (
            CGPoint(
                x: (stageSize.width - crop.width * scale) / 2 - crop.minX * scale,
                y: (stageSize.height - crop.height * scale) / 2 - crop.minY * scale
            ),
            scale
        )
    }

    private func interactionPath(stageSize: CGSize, crop: CGRect) -> CGPath {
        guard let placement = placement(stageSize: stageSize, crop: crop) else {
            return CGMutablePath()
        }
        let regions = OpenClamAvatarStageInteractionGeometry.bodyRegions(
            for: avatar.geometry
        )
        let path = CGMutablePath()
        for (index, bodyRegion) in regions.enumerated() {
            let stageRegion = CGRect(
                x: placement.origin.x + bodyRegion.minX * placement.scale,
                y: placement.origin.y + bodyRegion.minY * placement.scale,
                width: bodyRegion.width * placement.scale,
                height: bodyRegion.height * placement.scale
            )
            guard stageRegion.width > 0, stageRegion.height > 0 else { continue }
            if index == 0 {
                path.addEllipse(in: stageRegion)
            } else {
                let radius = min(stageRegion.width, stageRegion.height) * 0.30
                path.addRoundedRect(
                    in: stageRegion,
                    cornerWidth: radius,
                    cornerHeight: radius
                )
            }
        }
        return path
    }

    private var accessibilityValue: String {
        if faceMirror.isCapturing {
            return faceMirror.isTrackingFace ? "Mirroring your face" : "Looking for your face"
        }
        if controller.isSpeaking { return "Speaking" }
        if reactions.isAnimating { return "Reacting" }
        return "Idle"
    }

    private func synchronizeAmbientMotion() {
        if reduceMotion || faceMirror.isCapturing {
            reactions.stopAmbientMotion()
        } else {
            reactions.startAmbientMotion()
        }
    }
}

@MainActor
private struct OpenClamCatalogAvatarBodyArtwork: View {
    let avatar: OpenClamAvatarDescriptor
    let imageStore: OpenClamAvatarAssetStore
    let crop: CGRect

    var body: some View {
        GeometryReader { proxy in
            let body = avatar.geometry.bodySize.cgSize
            let scale = min(proxy.size.width / crop.width, proxy.size.height / crop.height)
            let origin = CGPoint(
                x: (proxy.size.width - crop.width * scale) / 2 - crop.minX * scale,
                y: (proxy.size.height - crop.height * scale) / 2 - crop.minY * scale
            )

            OpenClamAvatarAssetImage(
                image: imageStore.image(for: avatar, role: .body)
            )
            .frame(width: body.width * scale, height: body.height * scale)
            .offset(x: origin.x, y: origin.y)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}

@MainActor
private struct OpenClamCatalogAvatarFaceArtwork: View {
    let avatar: OpenClamAvatarDescriptor
    let imageStore: OpenClamAvatarAssetStore
    let state: CaptainAyerAvatarRenderState
    let reaction: CaptainAyerFaceReactionRenderState
    let showsReactionMouth: Bool
    let crop: CGRect

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / crop.width, proxy.size.height / crop.height)
            let origin = CGPoint(
                x: (proxy.size.width - crop.width * scale) / 2 - crop.minX * scale,
                y: (proxy.size.height - crop.height * scale) / 2 - crop.minY * scale
            )
            let transform = avatar.geometry.faceTransform
            let faceCenter = avatar.geometry.faceCenterInBody.cgPoint
            let registration = OpenClamAvatarFaceRegistrationPolicy.plan(
                canonicalRotationDegrees: transform.rotationDegrees,
                reaction: reaction.headPose,
                bodyLocked: avatar.expressionGeometry != nil,
                sourceMedium: avatar.sourceMedium,
                bodyScale: scale
            )

            facePlates
                .frame(
                    width: 1_024 * transform.uniformScale * scale,
                    height: 1_024 * transform.uniformScale * scale
                )
                .rotation3DEffect(
                    .degrees(registration.pitchDegrees),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.22
                )
                .rotation3DEffect(
                    .degrees(registration.yawDegrees),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.22
                )
                .rotationEffect(
                    .degrees(registration.rotationDegrees)
                )
                .offset(
                    x: registration.translationX,
                    y: registration.translationY
                )
                .position(
                    x: origin.x + faceCenter.x * scale,
                    y: origin.y + faceCenter.y * scale
                )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }

    private var facePlates: some View {
        let plan = OpenClamAvatarFacePlatePolicy.plan(
            for: state,
            sourceMedium: avatar.sourceMedium
        )
        let patchGeometry = OpenClamAvatarSpeechPatchGeometry(
            rig: avatar.geometry,
            sourceMedium: avatar.sourceMedium,
            expressionMouthBounds: avatar.expressionGeometry?.smile.box.cgRect,
            speechPatch: avatar.speechPatch
        )

        return ZStack {
            // This is the only identity-bearing full-head plate. It never
            // changes during speech, so hair, eyes, and skin cannot flicker.
            assetImage(.viseme(plan.base.viseme))

            if OpenClamAvatarStylizedMouthResolutionPolicy.usesResolvedPatch(
                sourceMedium: avatar.sourceMedium, geometry: patchGeometry
            ) {
                OpenClamCatalogStylizedMouthLayer(
                    avatar: avatar,
                    imageStore: imageStore,
                    speechState: state,
                    expressionState: reaction.expressionLayers,
                    geometry: patchGeometry,
                    fallbackWideAmount: showsReactionMouth ? reaction.wideMouthOpacity : 0
                )
            } else {
                if plan.speechPatch != nil
                    || (showsReactionMouth && reaction.wideMouthOpacity > 0) {
                    // Preserve the photographic renderer and valid legacy
                    // stylized v2/v3 packs without authored lip bounds. Those
                    // older packs must not silently lose speech because the
                    // new bounded replacement compositor cannot fit them.
                    ZStack {
                        if let patch = plan.speechPatch {
                            assetImage(.viseme(patch.back.viseme))
                            if let front = patch.front {
                                assetImage(.viseme(front.viseme))
                                .opacity(front.opacity)
                            }
                        }

                        if showsReactionMouth, reaction.wideMouthOpacity > 0 {
                            assetImage(.viseme(.wide))
                            .opacity(reaction.wideMouthOpacity)
                        }
                    }
                    .compositingGroup()
                    .mask {
                        OpenClamAvatarSpeechPatchMask(geometry: patchGeometry)
                    }
                }
            }

            if !avatar.sourceMedium.isStylized, let expression = avatar.expressionGeometry {
                OpenClamCatalogExpressionMouthLayers(
                    avatar: avatar,
                    imageStore: imageStore,
                    speechState: state,
                    state: reaction.expressionLayers,
                    geometry: expression
                )
            }

            OpenClamCatalogReactionLayers(
                avatar: avatar,
                imageStore: imageStore,
                state: reaction
            )
        }
        .mask {
            assetImage(.headMask)
        }
        .compositingGroup()
    }

    private func assetImage(_ role: OpenClamAvatarAssetRole) -> some View {
        OpenClamAvatarAssetImage(image: imageStore.image(for: avatar, role: role))
    }

}

struct OpenClamAvatarStylizedMouthResolutionPlan: Equatable, Sendable {
    let viseme: OpenClamAvatarViseme
    let emotion: OpenClamAvatarExpressionMouthKind?
    let frame: Int?
}

enum OpenClamAvatarStylizedMouthResolutionPolicy {
    static func usesResolvedPatch(
        sourceMedium: OpenClamAvatarSourceMedium,
        geometry: OpenClamAvatarSpeechPatchGeometry
    ) -> Bool {
        sourceMedium.isStylized && geometry.clipsFeatherToCoreBounds
    }

    static func plan(
        speech: CaptainAyerAvatarRenderState,
        expression: CaptainAyerExpressionLayerRenderState,
        geometry: OpenClamAvatarExpressionGeometry?,
        sourceMedium: OpenClamAvatarSourceMedium,
        fallbackWideAmount: Double = 0
    ) -> OpenClamAvatarStylizedMouthResolutionPlan? {
        guard sourceMedium.isStylized else { return nil }
        let selected = speech.blend < 0.5
            ? speech.previous.catalogViseme : speech.current.catalogViseme
        if let geometry,
           let active = OpenClamAvatarExpressionMouthPolicy.dominant(expression, geometry: geometry),
           let sample = OpenClamAvatarExpressionMouthPolicy.samples(
               kind: active.kind, amount: active.amount,
               previous: speech.previous.catalogViseme,
               current: speech.current.catalogViseme,
               speechBlend: speech.blend, geometry: geometry,
               sourceMedium: sourceMedium
           ).first {
            return .init(
                viseme: OpenClamAvatarExpressionMouthPolicy.viseme(
                    forFrame: sample.frame, kind: active.kind, geometry: geometry
                ),
                emotion: active.kind,
                frame: sample.frame
            )
        }
        // A legacy broad-mouth reaction also selects one complete drawing;
        // it must not add another semi-transparent mouth on top of speech.
        let viseme: OpenClamAvatarViseme = fallbackWideAmount >= 0.5 ? .wide : selected
        guard viseme != .silence else { return nil }
        return .init(viseme: viseme, emotion: nil, frame: nil)
    }
}

@MainActor
private struct OpenClamCatalogStylizedMouthLayer: View {
    let avatar: OpenClamAvatarDescriptor
    let imageStore: OpenClamAvatarAssetStore
    let speechState: CaptainAyerAvatarRenderState
    let expressionState: CaptainAyerExpressionLayerRenderState
    let geometry: OpenClamAvatarSpeechPatchGeometry
    let fallbackWideAmount: Double

    var body: some View {
        GeometryReader { proxy in
            if let plan = OpenClamAvatarStylizedMouthResolutionPolicy.plan(
                speech: speechState, expression: expressionState,
                geometry: avatar.expressionGeometry,
                sourceMedium: avatar.sourceMedium,
                fallbackWideAmount: fallbackWideAmount
            ), let image = resolvedImage(plan) {
                let bounds = geometry.coreBounds
                let scaleX = proxy.size.width / 1_024
                let scaleY = proxy.size.height / 1_024
                OpenClamAvatarAssetImage(image: image)
                    .frame(width: bounds.width * scaleX, height: bounds.height * scaleY)
                    .position(x: bounds.midX * scaleX, y: bounds.midY * scaleY)
                // Ownership and feather were applied once to the resolved
                // pixels. A second ellipse would expose the old corners again.
            }
        }
        .allowsHitTesting(false)
    }

    private func resolvedImage(_ plan: OpenClamAvatarStylizedMouthResolutionPlan) -> UIImage? {
        var emotion: OpenClamAvatarStylizedEmotionMouthSample?
        if let kind = plan.emotion, let frame = plan.frame,
           let expression = avatar.expressionGeometry {
            let role: OpenClamAvatarAssetRole
            let sprite: OpenClamAvatarSpriteGeometry
            let family: String
            let strengthCount: Int
            switch kind {
            case .smile:
                role = .smileAtlas
                sprite = expression.smile
                family = "smile"
                strengthCount = expression.smileStrengths.count
            case let .emotion(name, _):
                role = .emotionMouthAtlas
                sprite = expression.emotionMouth
                family = name
                strengthCount = expression.emotionMouthStrengths.count
            }
            if let image = imageStore.image(for: avatar, role: role), strengthCount > 0 {
                emotion = .init(
                    image: image, frame: frame, geometry: sprite,
                    contourFamily: family, contourState: frame % strengthCount
                )
            }
        }
        let selected = imageStore.image(for: avatar, role: .viseme(plan.viseme))
        let neutral = imageStore.image(for: avatar, role: .viseme(.silence))
        return OpenClamAvatarStylizedSpeechPatchRenderer.image(
            selected: selected, neutral: neutral, geometry: geometry,
            viseme: plan.viseme, sourceMedium: avatar.sourceMedium, emotion: emotion
        )
    }
}

enum OpenClamAvatarExpressionMouthKind: Equatable, Sendable {
    case smile
    case emotion(name: String, index: Int)
}

enum OpenClamAvatarBrowFramePolicy {
    static let legacyOffsets = [
        -3.0, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0,
        1.75, 2.5, 3.5, 5.0, 6.5, 8.0, 9.5,
    ]
    static let legacySqueezeOffsets = [-3.0, 0.0, 4.0]

    static func frame(
        fallback: Int?,
        offset: Double?,
        squeeze: Double?,
        expression: OpenClamAvatarExpressionGeometry?
    ) -> Int? {
        guard let offset else { return fallback }
        let offsets = expression?.browOffsets ?? legacyOffsets
        let squeezes = expression?.browSqueezeOffsets ?? legacySqueezeOffsets
        guard !offsets.isEmpty, !squeezes.isEmpty else { return fallback }
        let column = nearestIndex(in: offsets, to: offset)
        let row = nearestIndex(in: squeezes, to: squeeze ?? 0)
        return row * offsets.count + column
    }

    private static func nearestIndex(in values: [Double], to target: Double) -> Int {
        values.indices.min { left, right in
            abs(values[left] - target) < abs(values[right] - target)
        } ?? 0
    }
}

enum OpenClamAvatarExpressionCalibrationPolicy {
    static func browOffset(
        _ offset: Double?,
        expression: OpenClamAvatarExpressionGeometry?
    ) -> Double? {
        offset.map { $0 * (expression?.browGain ?? 1) }
    }

    static func foreheadOffset(
        _ offset: Double?,
        expression: OpenClamAvatarExpressionGeometry?
    ) -> Double? {
        offset.map {
            $0 * (expression?.browGain ?? 1)
                * (expression?.foreheadGain ?? 1)
        }
    }

    static func underEyeAmount(
        _ amount: Double,
        expression: OpenClamAvatarExpressionGeometry?
    ) -> Double {
        amount * (expression?.underEyeGain ?? 1)
    }
}

struct OpenClamAvatarExpressionSpriteSample: Equatable, Sendable {
    let frame: Int
    let opacity: Double
}

enum OpenClamAvatarExpressionMouthCompositeOperation: Equatable, Sendable {
    case additiveWithinPatch
    case sourceOverBaseFace
}

enum OpenClamAvatarExpressionMouthCompositingPolicy {
    static let sampleOperation: OpenClamAvatarExpressionMouthCompositeOperation =
        .additiveWithinPatch
    static let finishedPatchOperation: OpenClamAvatarExpressionMouthCompositeOperation =
        .sourceOverBaseFace

    static func blendMode(
        for operation: OpenClamAvatarExpressionMouthCompositeOperation
    ) -> BlendMode {
        switch operation {
        case .additiveWithinPatch:
            .plusLighter
        case .sourceOverBaseFace:
            .normal
        }
    }
}

enum OpenClamAvatarExpressionMouthMaskPolicy {
    /// Expression-mouth atlases for stylized avatars contain provider-painted
    /// pixels around the lips. Restrict those pixels to the same authored,
    /// nose-safe matte used by ordinary stylized speech. Photographs retain
    /// the established unmasked expression-mouth renderer.
    static func maskGeometry(
        for speechPatchGeometry: OpenClamAvatarSpeechPatchGeometry,
        sourceMedium: OpenClamAvatarSourceMedium
    ) -> OpenClamAvatarSpeechPatchGeometry? {
        guard sourceMedium.isStylized else { return nil }
        return speechPatchGeometry
    }
}

enum OpenClamAvatarExpressionMouthPolicy {
    static func dominant(
        _ state: CaptainAyerExpressionLayerRenderState,
        geometry: OpenClamAvatarExpressionGeometry
    ) -> (kind: OpenClamAvatarExpressionMouthKind, amount: Double)? {
        var candidates: [(OpenClamAvatarExpressionMouthKind, Double)] = [
            (.smile, state.smile),
        ]
        let values = [state.sorrowMouth, state.horrorMouth, state.angerMouth]
        for (index, name) in geometry.emotionMouthEmotions.enumerated()
            where index < values.count {
            candidates.append((.emotion(name: name, index: index), values[index]))
        }
        guard let winner = candidates.max(by: { $0.1 < $1.1 }), winner.1 > 0.004 else {
            return nil
        }
        return winner
    }

    static func samples(
        kind: OpenClamAvatarExpressionMouthKind,
        amount: Double,
        previous: OpenClamAvatarViseme,
        current: OpenClamAvatarViseme,
        speechBlend: Double,
        geometry: OpenClamAvatarExpressionGeometry,
        sourceMedium: OpenClamAvatarSourceMedium = .photograph
    ) -> [OpenClamAvatarExpressionSpriteSample] {
        let strengths: [Double]
        let visemes: [OpenClamAvatarViseme]
        let emotionOffset: Int
        switch kind {
        case .smile:
            strengths = geometry.smileStrengths
            visemes = geometry.smileVisemes
            emotionOffset = 0
        case let .emotion(_, index):
            strengths = geometry.emotionMouthStrengths
            visemes = geometry.emotionMouthVisemes
            emotionOffset = max(0, index) * visemes.count
        }
        guard strengths.count >= 2, !visemes.isEmpty else { return [] }
        let strength = bracket(values: strengths, target: amount)
        let fallback = visemes.firstIndex(of: .silence) ?? 0
        let boundedBlend = min(1, max(0, speechBlend))
        if sourceMedium.isStylized {
            // Drawn lips are complete authored cells, not photographic
            // deformation samples. Blending either neighbouring visemes or
            // neighbouring strength states paints two ink/teeth contours at
            // once and recreates the blurred, double-lip artifact. Select one
            // cell at the timing midpoint and keep the photo interpolation
            // path below unchanged.
            let selected = boundedBlend < 0.5 ? previous : current
            let row = emotionOffset
                + (visemes.firstIndex(of: selected) ?? fallback)
            let state = strength.mix > 0.5 ? strength.high : strength.low
            return [
                .init(frame: row * strengths.count + state, opacity: 1),
            ]
        }
        let previousRow = emotionOffset
            + (visemes.firstIndex(of: previous) ?? fallback)
        let currentRow = emotionOffset
            + (visemes.firstIndex(of: current) ?? fallback)
        let blend = boundedBlend
        let raw = [
            (previousRow * strengths.count + strength.low, (1 - blend) * (1 - strength.mix)),
            (previousRow * strengths.count + strength.high, (1 - blend) * strength.mix),
            (currentRow * strengths.count + strength.low, blend * (1 - strength.mix)),
            (currentRow * strengths.count + strength.high, blend * strength.mix),
        ]
        var merged: [Int: Double] = [:]
        for (frame, opacity) in raw where opacity > 0.0001 {
            merged[frame, default: 0] += opacity
        }
        return merged.keys.sorted().map {
            .init(frame: $0, opacity: min(1, merged[$0] ?? 0))
        }
    }

    static func viseme(
        forFrame frame: Int,
        kind: OpenClamAvatarExpressionMouthKind,
        geometry: OpenClamAvatarExpressionGeometry
    ) -> OpenClamAvatarViseme {
        let strengths: [Double]
        let visemes: [OpenClamAvatarViseme]
        switch kind {
        case .smile:
            strengths = geometry.smileStrengths
            visemes = geometry.smileVisemes
        case .emotion:
            strengths = geometry.emotionMouthStrengths
            visemes = geometry.emotionMouthVisemes
        }
        guard frame >= 0, !strengths.isEmpty, !visemes.isEmpty else {
            return .silence
        }
        let row = frame / strengths.count
        return visemes[row % visemes.count]
    }

    static func bracket(
        values: [Double],
        target: Double
    ) -> (low: Int, high: Int, mix: Double) {
        guard values.count >= 2 else { return (0, 0, 0) }
        if target <= values[0] { return (0, 0, 0) }
        if target >= values[values.count - 1] {
            return (values.count - 1, values.count - 1, 0)
        }
        let high = values.firstIndex(where: { $0 >= target }) ?? values.count - 1
        let low = max(0, high - 1)
        let span = max(0.000_001, values[high] - values[low])
        return (low, high, min(1, max(0, (target - values[low]) / span)))
    }
}

@MainActor
private struct OpenClamCatalogExpressionMouthLayers: View {
    let avatar: OpenClamAvatarDescriptor
    let imageStore: OpenClamAvatarAssetStore
    let speechState: CaptainAyerAvatarRenderState
    let state: CaptainAyerExpressionLayerRenderState
    let geometry: OpenClamAvatarExpressionGeometry

    var body: some View {
        GeometryReader { proxy in
            let scaleX = proxy.size.width / 1_024
            let scaleY = proxy.size.height / 1_024
            let active = OpenClamAvatarExpressionMouthPolicy.dominant(
                state,
                geometry: geometry
            )
            let speechPatchGeometry = OpenClamAvatarSpeechPatchGeometry(
                rig: avatar.geometry,
                sourceMedium: avatar.sourceMedium,
                expressionMouthBounds: geometry.smile.box.cgRect,
                speechPatch: avatar.speechPatch
            )
            let maskGeometry = OpenClamAvatarExpressionMouthMaskPolicy.maskGeometry(
                for: speechPatchGeometry,
                sourceMedium: avatar.sourceMedium
            )
            let mouthLayers = ZStack(alignment: .topLeading) {
                if let active {
                    let layer = layer(for: active.kind)
                    let samples = OpenClamAvatarExpressionMouthPolicy.samples(
                        kind: active.kind,
                        amount: active.amount,
                        previous: speechState.previous.catalogViseme,
                        current: speechState.current.catalogViseme,
                        speechBlend: speechState.blend,
                        geometry: geometry,
                        sourceMedium: avatar.sourceMedium
                    )
                    ZStack {
                        ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                            OpenClamAvatarSpriteFrame(
                                image: imageStore.image(for: avatar, role: layer.role),
                                frame: sample.frame,
                                geometry: layer.sprite
                            )
                            .frame(
                                width: layer.sprite.box.width * scaleX,
                                height: layer.sprite.box.height * scaleY
                            )
                            .offset(
                                x: speechPatchGeometry.translationX(
                                    for: OpenClamAvatarExpressionMouthPolicy.viseme(
                                        forFrame: sample.frame,
                                        kind: active.kind,
                                        geometry: geometry
                                    )
                                ) * scaleX
                            )
                            .opacity(sample.opacity)
                            .blendMode(
                                OpenClamAvatarExpressionMouthCompositingPolicy.blendMode(
                                    for: OpenClamAvatarExpressionMouthCompositingPolicy
                                        .sampleOperation
                                )
                            )
                        }
                    }
                    .compositingGroup()
                    .blendMode(
                        OpenClamAvatarExpressionMouthCompositingPolicy.blendMode(
                            for: OpenClamAvatarExpressionMouthCompositingPolicy
                                .finishedPatchOperation
                        )
                    )
                    .offset(
                        x: layer.sprite.box.x * scaleX,
                        y: layer.sprite.box.y * scaleY
                    )
                    .frame(
                        width: layer.sprite.box.width * scaleX,
                        height: layer.sprite.box.height * scaleY,
                        alignment: .topLeading
                    )
                }
            }
            Group {
                if let maskGeometry {
                    mouthLayers
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height,
                            alignment: .topLeading
                        )
                        .compositingGroup()
                        .mask {
                            OpenClamAvatarSpeechPatchMask(geometry: maskGeometry)
                        }
                } else {
                    // Keep the reviewed photographic expression renderer
                    // unchanged. Only explicit stylized media receives the
                    // nose-safe clipping matte above.
                    mouthLayers
                        .compositingGroup()
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func layer(
        for kind: OpenClamAvatarExpressionMouthKind
    ) -> (role: OpenClamAvatarAssetRole, sprite: OpenClamAvatarSpriteGeometry) {
        switch kind {
        case .smile:
            (.smileAtlas, geometry.smile)
        case .emotion:
            (.emotionMouthAtlas, geometry.emotionMouth)
        }
    }
}

@MainActor
private struct OpenClamCatalogReactionLayers: View {
    let avatar: OpenClamAvatarDescriptor
    let imageStore: OpenClamAvatarAssetStore
    let state: CaptainAyerFaceReactionRenderState

    var body: some View {
        GeometryReader { proxy in
            let expression = avatar.expressionGeometry
            let leftBrowFrame = OpenClamAvatarBrowFramePolicy.frame(
                fallback: state.leftBrowFrame,
                offset: OpenClamAvatarExpressionCalibrationPolicy.browOffset(
                    state.leftBrowOffset,
                    expression: expression
                ),
                squeeze: state.browSqueezeOffset,
                expression: expression
            )
            let rightBrowFrame = OpenClamAvatarBrowFramePolicy.frame(
                fallback: state.rightBrowFrame,
                offset: OpenClamAvatarExpressionCalibrationPolicy.browOffset(
                    state.rightBrowOffset,
                    expression: expression
                ),
                squeeze: state.browSqueezeOffset,
                expression: expression
            )
            let leftForeheadFrame = OpenClamAvatarBrowFramePolicy.frame(
                fallback: state.leftBrowFrame,
                offset: OpenClamAvatarExpressionCalibrationPolicy.foreheadOffset(
                    state.leftBrowOffset,
                    expression: expression
                ),
                squeeze: state.browSqueezeOffset,
                expression: expression
            )
            let rightForeheadFrame = OpenClamAvatarBrowFramePolicy.frame(
                fallback: state.rightBrowFrame,
                offset: OpenClamAvatarExpressionCalibrationPolicy.foreheadOffset(
                    state.rightBrowOffset,
                    expression: expression
                ),
                squeeze: state.browSqueezeOffset,
                expression: expression
            )
            ZStack(alignment: .topLeading) {
                if let expression {
                    if let frame = leftForeheadFrame {
                        verticalSprite(
                            role: .foreheadLeft,
                            frame: frame,
                            geometry: expression.leftForehead,
                            in: proxy.size
                        )
                    }
                    if let frame = rightForeheadFrame {
                        verticalSprite(
                            role: .foreheadRight,
                            frame: frame,
                            geometry: expression.rightForehead,
                            in: proxy.size
                        )
                    }
                }
                if let frame = leftBrowFrame {
                    verticalSprite(
                        role: .browLeft,
                        frame: frame,
                        geometry: avatar.geometry.leftBrow,
                        in: proxy.size
                    )
                }
                if let frame = rightBrowFrame {
                    verticalSprite(
                        role: .browRight,
                        frame: frame,
                        geometry: avatar.geometry.rightBrow,
                        in: proxy.size
                    )
                }
                if let expression = avatar.expressionGeometry {
                    continuousSprite(
                        role: .cheekLeft,
                        amount: state.expressionLayers.cheek
                            * (1 - state.expressionLayers.asymmetry * 0.55),
                        offsets: expression.cheekOffsets,
                        geometry: expression.leftCheek,
                        in: proxy.size
                    )
                    continuousSprite(
                        role: .cheekRight,
                        amount: state.expressionLayers.cheek
                            * (1 + state.expressionLayers.asymmetry * 0.55),
                        offsets: expression.cheekOffsets,
                        geometry: expression.rightCheek,
                        in: proxy.size
                    )
                }
                if let frame = state.gazeFrame {
                    gridSprite(
                        role: .gazeLeftAtlas,
                        frame: frame,
                        geometry: avatar.geometry.leftGaze,
                        in: proxy.size
                    )
                    gridSprite(
                        role: .gazeRightAtlas,
                        frame: frame,
                        geometry: avatar.geometry.rightGaze,
                        in: proxy.size
                    )
                }
                if let expression = avatar.expressionGeometry {
                    continuousSprite(
                        role: .underEyeLeft,
                        amount: OpenClamAvatarExpressionCalibrationPolicy
                            .underEyeAmount(
                                state.expressionLayers.underEye,
                                expression: expression
                            )
                            * (1 - state.expressionLayers.asymmetry),
                        offsets: expression.underEyeOffsets,
                        geometry: expression.leftUnderEye,
                        in: proxy.size
                    )
                    continuousSprite(
                        role: .underEyeRight,
                        amount: OpenClamAvatarExpressionCalibrationPolicy
                            .underEyeAmount(
                                state.expressionLayers.underEye,
                                expression: expression
                            )
                            * (1 + state.expressionLayers.asymmetry),
                        offsets: expression.underEyeOffsets,
                        geometry: expression.rightUnderEye,
                        in: proxy.size
                    )
                }
                if let eye = state.leftEye {
                    eyeLayers(
                        eye,
                        role: .eyeLeft,
                        geometry: avatar.geometry.leftEye,
                        sourceMedium: avatar.sourceMedium,
                        in: proxy.size
                    )
                }
                if let eye = state.rightEye {
                    eyeLayers(
                        eye,
                        role: .eyeRight,
                        geometry: avatar.geometry.rightEye,
                        sourceMedium: avatar.sourceMedium,
                        in: proxy.size
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func continuousSprite(
        role: OpenClamAvatarAssetRole,
        amount: Double,
        offsets: [Double],
        geometry: OpenClamAvatarSpriteGeometry,
        in size: CGSize
    ) -> some View {
        if amount > 0.004, let maximum = offsets.last, maximum > 0 {
            let sample = OpenClamAvatarExpressionMouthPolicy.bracket(
                values: offsets,
                target: min(1, max(0, amount)) * maximum
            )
            ZStack(alignment: .topLeading) {
                verticalSprite(
                    role: role,
                    frame: sample.low,
                    geometry: geometry,
                    in: size
                )
                .opacity(1 - sample.mix)
                .blendMode(.plusLighter)
                if sample.high != sample.low {
                    verticalSprite(
                        role: role,
                        frame: sample.high,
                        geometry: geometry,
                        in: size
                    )
                    .opacity(sample.mix)
                    .blendMode(.plusLighter)
                }
            }
            .compositingGroup()
        }
    }

    @ViewBuilder
    private func eyeLayers(
        _ eye: CaptainAyerEyeReactionState,
        role: OpenClamAvatarAssetRole,
        geometry: OpenClamAvatarSpriteGeometry,
        sourceMedium: OpenClamAvatarSourceMedium,
        in size: CGSize
    ) -> some View {
        switch OpenClamAvatarEyelidPlatePolicy.plan(
            for: eye,
            frameCount: geometry.frameCount,
            sourceMedium: sourceMedium
        ) {
        case .interpolatedStrip:
            if let lowerFrame = eye.lowerFrame {
                verticalSprite(
                    role: role,
                    frame: lowerFrame,
                    geometry: geometry,
                    in: size
                )
            }
            verticalSprite(
                role: role,
                frame: eye.upperFrame,
                geometry: geometry,
                in: size
            )
            .opacity(eye.upperOpacity)
        case .canonicalOpen:
            EmptyView()
        case let .semanticClosed(frame):
            verticalSprite(
                role: role,
                frame: frame,
                geometry: geometry,
                in: size
            )
        }
    }

    private func verticalSprite(
        role: OpenClamAvatarAssetRole,
        frame: Int,
        geometry: OpenClamAvatarSpriteGeometry,
        in size: CGSize
    ) -> some View {
        let scaleX = size.width / 1_024
        let scaleY = size.height / 1_024
        return OpenClamAvatarVerticalSpriteFrame(
            image: imageStore.image(for: avatar, role: role),
            frame: frame,
            frameCount: geometry.frameCount
        )
        .frame(width: geometry.box.width * scaleX, height: geometry.box.height * scaleY)
        .offset(x: geometry.box.x * scaleX, y: geometry.box.y * scaleY)
    }

    private func gridSprite(
        role: OpenClamAvatarAssetRole,
        frame: Int,
        geometry: OpenClamAvatarSpriteGeometry,
        in size: CGSize
    ) -> some View {
        let scaleX = size.width / 1_024
        let scaleY = size.height / 1_024
        return OpenClamAvatarGridSpriteFrame(
            image: imageStore.image(for: avatar, role: role),
            frame: frame,
            columns: geometry.columns,
            rows: geometry.rows
        )
        .frame(width: geometry.box.width * scaleX, height: geometry.box.height * scaleY)
        .offset(x: geometry.box.x * scaleX, y: geometry.box.y * scaleY)
    }
}

@MainActor
private struct OpenClamAvatarAssetImage: View {
    let image: UIImage?

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Color.clear
        }
    }
}

struct OpenClamAvatarSpriteFrameAddress: Equatable, Sendable {
    let frame: Int
    let column: Int
    let row: Int
}

enum OpenClamAvatarSpriteFramePolicy {
    static func address(
        frame: Int,
        columns: Int,
        rows: Int
    ) -> OpenClamAvatarSpriteFrameAddress {
        let safeColumns = max(1, columns)
        let safeRows = max(1, rows)
        let count = safeColumns * safeRows
        let clamped = min(max(0, frame), count - 1)
        return .init(
            frame: clamped,
            column: clamped % safeColumns,
            row: clamped / safeColumns
        )
    }
}

@MainActor
private struct OpenClamAvatarSpriteFrame: View {
    let image: UIImage?
    let frame: Int
    let geometry: OpenClamAvatarSpriteGeometry

    @ViewBuilder
    var body: some View {
        switch geometry.storage {
        case .verticalStrip:
            OpenClamAvatarVerticalSpriteFrame(
                image: image,
                frame: frame,
                frameCount: geometry.frameCount
            )
        case .gridAtlas:
            OpenClamAvatarGridSpriteFrame(
                image: image,
                frame: frame,
                columns: geometry.columns,
                rows: geometry.rows
            )
        }
    }
}

@MainActor
private struct OpenClamAvatarVerticalSpriteFrame: View {
    let image: UIImage?
    let frame: Int
    let frameCount: Int

    var body: some View {
        GeometryReader { proxy in
            OpenClamAvatarAssetImage(image: image)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height * CGFloat(frameCount),
                    alignment: .top
                )
                .offset(y: -CGFloat(clampedFrame) * proxy.size.height)
        }
        .clipped()
    }

    private var clampedFrame: Int {
        min(max(0, frame), max(0, frameCount - 1))
    }
}

@MainActor
private struct OpenClamAvatarGridSpriteFrame: View {
    let image: UIImage?
    let frame: Int
    let columns: Int
    let rows: Int

    var body: some View {
        GeometryReader { proxy in
            let address = OpenClamAvatarSpriteFramePolicy.address(
                frame: frame,
                columns: columns,
                rows: rows
            )
            OpenClamAvatarAssetImage(image: image)
                .frame(
                    width: proxy.size.width * CGFloat(max(1, columns)),
                    height: proxy.size.height * CGFloat(max(1, rows)),
                    alignment: .topLeading
                )
                .offset(
                    x: -CGFloat(address.column) * proxy.size.width,
                    y: -CGFloat(address.row) * proxy.size.height
                )
        }
        .clipped()
    }
}

private extension CaptainAyerViseme {
    var catalogViseme: OpenClamAvatarViseme {
        switch self {
        case .silence: .silence
        case .bilabial: .bilabial
        case .labiodental: .labiodental
        case .dental: .dental
        case .alveolar: .alveolar
        case .velar: .velar
        case .postalveolar: .postalveolar
        case .sibilant: .sibilant
        case .nasal: .nasal
        case .rhotic: .rhotic
        case .open: .open
        case .wide: .wide
        case .narrow: .nearClose
        case .openRounded: .openRounded
        case .rounded: .rounded
        }
    }
}
