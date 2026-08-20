import XCTest
@testable import OpenClamLiveKit

final class OpenClamCatalogAvatarStageTests: XCTestCase {
    func testCaptainTransformMatchesMigratedStageGeometry() throws {
        let captain = try XCTUnwrap(OpenClamAvatarCatalog.avatar(id: "captain-ayer"))
        XCTAssertEqual(captain.geometry.faceTransform.uniformScale, 0.2375036, accuracy: 0.000001)
        XCTAssertEqual(captain.geometry.faceTransform.rotationDegrees, -0.1452, accuracy: 0.0001)
        XCTAssertEqual(captain.geometry.faceCenterInBody.x, 482.55, accuracy: 0.02)
        XCTAssertEqual(captain.geometry.faceCenterInBody.y, 150.64, accuracy: 0.02)
        XCTAssertEqual(captain.geometry.eyeAnchorInBody.x, 482.6803, accuracy: 0.001)
        XCTAssertEqual(captain.geometry.eyeAnchorInBody.y, 155.2689, accuracy: 0.001)
    }

    func testEveryExpandedCropIsTheFullBody() {
        for avatar in OpenClamAvatarCatalog.avatars {
            XCTAssertEqual(
                OpenClamCatalogAvatarStage.Presentation.expanded.crop(for: avatar),
                CGRect(origin: .zero, size: avatar.geometry.bodySize.cgSize),
                avatar.displayName
            )
        }
    }

    func testEveryCompactCropStaysInBodyAndContainsFaceCenter() {
        for avatar in OpenClamAvatarCatalog.avatars {
            let crop = OpenClamCatalogAvatarStage.Presentation.compact.crop(for: avatar)
            let body = CGRect(origin: .zero, size: avatar.geometry.bodySize.cgSize)
            let faceCenter = avatar.geometry.faceBoundsInBody.cgRect.center
            XCTAssertTrue(body.contains(crop), avatar.displayName)
            XCTAssertTrue(crop.contains(faceCenter), avatar.displayName)
        }
    }

    func testEveryEyeAnchorFallsInsideDeclaredFaceBounds() {
        for avatar in OpenClamAvatarCatalog.avatars {
            XCTAssertTrue(
                avatar.geometry.faceBoundsInBody.cgRect.contains(
                    avatar.geometry.eyeAnchorInBody.cgPoint
                ),
                avatar.displayName
            )
        }
    }

    func testInteractionGeometryFollowsTheBodyWithoutClaimingTheStageCanvas() {
        for avatar in OpenClamAvatarCatalog.avatars {
            let body = CGRect(origin: .zero, size: avatar.geometry.bodySize.cgSize)
            let regions = OpenClamAvatarStageInteractionGeometry.bodyRegions(
                for: avatar.geometry
            )
            let union = regions.dropFirst().reduce(regions.first ?? .null) { partial, region in
                partial.union(region)
            }

            XCTAssertFalse(regions.isEmpty, avatar.displayName)
            XCTAssertTrue(
                regions.allSatisfy { body.contains($0) },
                "Interaction regions must remain in the body image for \(avatar.displayName)"
            )
            XCTAssertTrue(
                regions.contains { $0.contains(avatar.geometry.faceBoundsInBody.cgRect.center) },
                "Face taps and gaze must remain reachable for \(avatar.displayName)"
            )
            XCTAssertGreaterThan(
                regions.map(\.maxY).max() ?? 0,
                body.height * 0.85,
                "Full-body opacity drags need a reachable lower-body region for \(avatar.displayName)"
            )
            XCTAssertFalse(
                regions.contains {
                    $0.contains(
                        CGPoint(x: body.width * 0.04, y: body.height * 0.50)
                    )
                },
                "The left transparent canvas must stay outside the avatar surface for \(avatar.displayName)"
            )
            XCTAssertLessThan(
                union.width,
                body.width * 0.60,
                "Transparent canvas on either side must remain scrollable for \(avatar.displayName)"
            )
        }
    }

    func testSourceAtopFacePreservesBodyAlphaWithoutRasterizingTheStage() {
        for (requested, expected) in [
            (-0.5, 0.0),
            (0.0, 0.0),
            (0.34, 0.34),
            (1.0, 1.0),
            (1.5, 1.0),
        ] {
            let plan = OpenClamAvatarStageOpacityPolicy.plan(for: requested)

            XCTAssertEqual(plan.bodyOpacity, expected, accuracy: 0.0001)
            XCTAssertEqual(plan.faceBlendRule, .sourceAtopPreservingBodyAlpha)
            XCTAssertEqual(plan.userOpacityApplicationCount, 1)
            XCTAssertFalse(plan.requiresWholeStageRasterization)

            for bodyAlpha in [0.0, 0.15, 0.50, 1.0] {
                for faceAlpha in [0.0, 0.10, 0.50, 1.0] {
                    XCTAssertEqual(
                        OpenClamAvatarStageOpacityPolicy.composedAlpha(
                            bodyAlpha: bodyAlpha,
                            faceAlpha: faceAlpha,
                            requestedOpacity: requested
                        ),
                        bodyAlpha * expected,
                        accuracy: 0.0001,
                        "Animated face alpha must not change assembled alpha"
                    )
                }
            }
        }
    }

    func testSpeechPatchTransitionIsClampedLinearAndEndpointContinuous() {
        XCTAssertEqual(
            OpenClamAvatarSpeechPatchTransition.opacity(for: -1),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            OpenClamAvatarSpeechPatchTransition.opacity(for: 0),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            OpenClamAvatarSpeechPatchTransition.opacity(for: 0.25),
            0.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            OpenClamAvatarSpeechPatchTransition.opacity(for: 0.5),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            OpenClamAvatarSpeechPatchTransition.opacity(for: 0.75),
            0.75,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            OpenClamAvatarSpeechPatchTransition.opacity(for: 1),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            OpenClamAvatarSpeechPatchTransition.opacity(for: 2),
            1,
            accuracy: 0.0001
        )

        var previous = 0.0
        for index in 1...100 {
            let value = OpenClamAvatarSpeechPatchTransition.opacity(
                for: Double(index) / 100
            )
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testCatalogFaceAdvancesAtSixtyHertzWithoutMovingBodyIntoTimeline() {
        XCTAssertEqual(
            OpenClamAvatarFaceAnimationPolicy.minimumInterval,
            1.0 / 60.0,
            accuracy: 0.000_001
        )
    }

    func testSpeechAlwaysKeepsOneImmutableSilenceHead() {
        for previous in CaptainAyerViseme.allCases {
            for current in CaptainAyerViseme.allCases {
                for blend in [0.0, 0.25, 0.50, 0.75, 1.0] {
                    let plan = OpenClamAvatarFacePlatePolicy.plan(
                        for: CaptainAyerAvatarRenderState(
                            previous: previous,
                            current: current,
                            blend: blend
                        )
                    )

                    XCTAssertEqual(plan.base.viseme, .silence)
                    XCTAssertEqual(plan.base.opacity, 1, accuracy: 0.0001)
                    XCTAssertEqual(plan.base.scope, .fullHead)
                    if let patch = plan.speechPatch {
                        XCTAssertEqual(patch.back.scope, .speechPatch)
                        XCTAssertTrue(
                            patch.front.map { $0.scope == .speechPatch } ?? true,
                            "No speech cue may replace the full head"
                        )
                    } else {
                        XCTAssertEqual(previous, .silence)
                        XCTAssertEqual(current, .silence)
                    }
                }
            }
        }
    }

    func testSpeechPatchNeverReachesEyesOrHairForEveryAvatarRig() {
        for avatar in OpenClamAvatarCatalog.avatars {
            let geometry = OpenClamAvatarSpeechPatchGeometry(rig: avatar.geometry)
            let eyeBottom = max(
                avatar.geometry.leftEye.box.cgRect.maxY,
                avatar.geometry.rightEye.box.cgRect.maxY
            )

            XCTAssertGreaterThan(
                geometry.conservativeDynamicBounds.minY,
                eyeBottom,
                "Speech must not repaint the eye line for \(avatar.displayName)"
            )
            XCTAssertFalse(
                geometry.conservativeDynamicBounds.contains(
                    avatar.geometry.eyeAnchorInFaceSource.cgPoint
                ),
                "Speech must not repaint the eyes for \(avatar.displayName)"
            )
            XCTAssertFalse(
                geometry.conservativeDynamicBounds.contains(CGPoint(x: 512, y: 200)),
                "Speech must not repaint hair for \(avatar.displayName)"
            )
            XCTAssertTrue(
                geometry.conservativeDynamicBounds.contains(CGPoint(x: 512, y: 800)),
                "Speech must retain the canonical mouth for \(avatar.displayName)"
            )
        }
    }

    func testSpeechPatchStaysBelowAnImportedRigWithUnusuallyLowEyes() throws {
        let source = try XCTUnwrap(OpenClamAvatarCatalog.avatar(id: "captain-ayer"))
        let lowLeftEye = OpenClamAvatarSpriteGeometry(
            box: OpenClamAvatarRect(x: 300, y: 760, width: 120, height: 60),
            columns: 1,
            rows: 8,
            storage: .verticalStrip
        )
        let lowRightEye = OpenClamAvatarSpriteGeometry(
            box: OpenClamAvatarRect(x: 604, y: 760, width: 120, height: 60),
            columns: 1,
            rows: 8,
            storage: .verticalStrip
        )
        let importedRig = OpenClamAvatarRigGeometry(
            bodySize: source.geometry.bodySize,
            faceTransform: source.geometry.faceTransform,
            faceBoundsInBody: source.geometry.faceBoundsInBody,
            leftEye: lowLeftEye,
            rightEye: lowRightEye,
            leftBrow: source.geometry.leftBrow,
            rightBrow: source.geometry.rightBrow,
            leftGaze: source.geometry.leftGaze,
            rightGaze: source.geometry.rightGaze
        )

        let geometry = OpenClamAvatarSpeechPatchGeometry(rig: importedRig)
        XCTAssertGreaterThan(
            geometry.conservativeDynamicBounds.minY,
            max(lowLeftEye.box.cgRect.maxY, lowRightEye.box.cgRect.maxY)
        )
    }

    func testSpeechPatchUsesOneMaskedGroupAndStaysContinuousAtCueEndpoints() throws {
        let entering = OpenClamAvatarFacePlatePolicy.plan(
            for: .init(previous: .silence, current: .open, blend: 0.4)
        )
        XCTAssertEqual(entering.speechPatch?.back.viseme, .silence)
        XCTAssertEqual(entering.speechPatch?.back.opacity ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(entering.speechPatch?.front?.viseme, .open)
        XCTAssertEqual(
            entering.speechPatch?.front?.opacity ?? -1,
            OpenClamAvatarSpeechPatchTransition.opacity(for: 0.4),
            accuracy: 0.0001
        )

        let changing = OpenClamAvatarFacePlatePolicy.plan(
            for: .init(previous: .open, current: .wide, blend: 0.4)
        )
        XCTAssertEqual(changing.speechPatch?.back.viseme, .open)
        XCTAssertEqual(changing.speechPatch?.back.opacity ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(changing.speechPatch?.front?.viseme, .wide)
        XCTAssertEqual(
            changing.speechPatch?.front?.opacity ?? -1,
            OpenClamAvatarSpeechPatchTransition.opacity(for: 0.4),
            accuracy: 0.0001
        )

        let exactEnd = OpenClamAvatarFacePlatePolicy.plan(
            for: .init(previous: .open, current: .wide, blend: 1)
        )
        let nextCue = OpenClamAvatarFacePlatePolicy.plan(
            for: .init(previous: .wide, current: .wide, blend: 0)
        )
        XCTAssertEqual(exactEnd.speechPatch?.front?.viseme, nextCue.speechPatch?.back.viseme)
        XCTAssertEqual(exactEnd.speechPatch?.front?.opacity ?? -1, 1, accuracy: 0.0001)
        XCTAssertNil(nextCue.speechPatch?.front)

        let exactSilenceEnd = OpenClamAvatarFacePlatePolicy.plan(
            for: .init(previous: .wide, current: .silence, blend: 1)
        )
        let idle = OpenClamAvatarFacePlatePolicy.plan(
            for: .init(previous: .silence, current: .silence, blend: 0)
        )
        XCTAssertEqual(exactSilenceEnd.speechPatch?.front?.viseme, .silence)
        XCTAssertEqual(exactSilenceEnd.speechPatch?.front?.opacity ?? -1, 1, accuracy: 0.0001)
        XCTAssertNil(idle.speechPatch)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
