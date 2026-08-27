import XCTest
@testable import OpenClamLiveKit

final class OpenClamCatalogAvatarStageTests: XCTestCase {
    func testFullExpressionFaceSurfaceStaysRegisteredForEverySpeechHeadPose() {
        let canonicalRotation = -0.343
        let bodyScale: CGFloat = 1.27
        // Sample ten seconds at the renderer's 60 Hz cadence. The authored
        // speech pose can change every frame, but the photographic surface's
        // body-space anchor and sampling transform must remain bit-stable.
        for frame in 0 ... 600 {
            let time = Double(frame) / 60
            let pose = CaptainAyerFaceMirrorHeadPose(
                yaw: sin(time * 1.7),
                pitch: cos(time * 1.3),
                roll: sin(time * 2.1 + 0.4)
            )
            let plan = OpenClamAvatarFaceRegistrationPolicy.plan(
                canonicalRotationDegrees: canonicalRotation,
                reaction: pose,
                bodyLocked: true,
                bodyScale: bodyScale
            )

            XCTAssertEqual(plan.pitchDegrees, 0, accuracy: 0.000_001)
            XCTAssertEqual(plan.yawDegrees, 0, accuracy: 0.000_001)
            XCTAssertEqual(plan.rotationDegrees, canonicalRotation, accuracy: 0.000_001)
            XCTAssertEqual(plan.translationX, 0, accuracy: 0.000_001)
            XCTAssertEqual(plan.translationY, 0, accuracy: 0.000_001)
            XCTAssertEqual(plan.dynamicResamplingPassCount, 0)
        }
    }

    func testLegacyFacePoseMappingRemainsBackwardCompatible() {
        let pose = CaptainAyerFaceMirrorHeadPose(
            yaw: 0.25,
            pitch: -0.50,
            roll: 0.75
        )
        let plan = OpenClamAvatarFaceRegistrationPolicy.plan(
            canonicalRotationDegrees: -0.25,
            reaction: pose,
            bodyLocked: false,
            bodyScale: 1.5
        )

        XCTAssertEqual(plan.pitchDegrees, -1.6, accuracy: 0.000_001)
        XCTAssertEqual(plan.yawDegrees, -1.0, accuracy: 0.000_001)
        XCTAssertEqual(plan.rotationDegrees, 2.3, accuracy: 0.000_001)
        XCTAssertEqual(plan.translationX, 0.9, accuracy: 0.000_001)
        XCTAssertEqual(plan.translationY, -1.35, accuracy: 0.000_001)
        XCTAssertEqual(plan.dynamicResamplingPassCount, 1)
    }

    func testExpressionMouthAddsSamplesButSourceOverCompositesFinishedPatch() {
        XCTAssertEqual(
            OpenClamAvatarExpressionMouthCompositingPolicy.sampleOperation,
            .additiveWithinPatch
        )
        XCTAssertEqual(
            OpenClamAvatarExpressionMouthCompositingPolicy.finishedPatchOperation,
            .sourceOverBaseFace,
            "The completed photographic mouth patch must replace the base pixels normally; "
                + "adding it to the face washes out lips and teeth."
        )
    }

    func testGridAtlasAddressesEveryFullExpressionMouthFrameInRowMajorOrder() {
        for (columns, rows) in [(5, 15), (4, 45)] {
            for frame in 0 ..< columns * rows {
                let address = OpenClamAvatarSpriteFramePolicy.address(
                    frame: frame,
                    columns: columns,
                    rows: rows
                )
                XCTAssertEqual(address.frame, frame)
                XCTAssertEqual(address.column, frame % columns)
                XCTAssertEqual(address.row, frame / columns)
                XCTAssertLessThan(address.column, columns)
                XCTAssertLessThan(address.row, rows)
            }
        }
    }

    func testMovesMotionFillsAvailableHeightAndStaysCenteredAcrossOrientations() {
        let source = CGSize(width: 720, height: 1_088)
        for available in [
            CGSize(width: 390, height: 844),
            CGSize(width: 844, height: 390),
            CGSize(width: 768, height: 1_024),
        ] {
            let layout = OpenClamAvatarMotionLayoutPolicy.layout(
                kind: .moves,
                availableSize: available,
                pixelSize: source
            )

            XCTAssertEqual(layout.playerFrame.height, available.height, accuracy: 0.001)
            XCTAssertEqual(layout.playerFrame.midX, available.width / 2, accuracy: 0.001)
            XCTAssertEqual(layout.playerFrame.minY, 0, accuracy: 0.001)
            XCTAssertEqual(
                layout.playerFrame.width / layout.playerFrame.height,
                source.width / source.height,
                accuracy: 0.000_001
            )
            XCTAssertEqual(layout.clippingBounds, CGRect(origin: .zero, size: available))
        }
    }

    func testEdgeIdlePinsItsMeasuredContactToThePhysicalLeftScreenEdge() {
        let source = CGSize(width: 720, height: 1_088)
        for available in [
            CGSize(width: 390, height: 844),
            CGSize(width: 844, height: 390),
            CGSize(width: 768, height: 1_024),
            CGSize(width: 1_024, height: 768),
            CGSize(width: 1_024, height: 1_366),
            CGSize(width: 507, height: 1_024),
            CGSize(width: 320, height: 1_024),
        ] {
            let layout = OpenClamAvatarMotionLayoutPolicy.layout(
                kind: .edgeIdle,
                availableSize: available,
                pixelSize: source
            )
            let contactX = layout.playerFrame.minX
                + layout.playerFrame.width
                    * OpenClamAvatarMotionLayoutPolicy.edgeIdleLeftContactFraction
            let expectedInset = min(
                OpenClamAvatarMotionLayoutPolicy.edgeIdlePreferredInset,
                available.width / 100
            )
            let visibleSubjectLeadingX = layout.playerFrame.minX
                + layout.playerFrame.width
                    * OpenClamAvatarMotionLayoutPolicy.edgeIdleContentBounds.minX
            let visibleSubjectWidth = layout.playerFrame.width
                * OpenClamAvatarMotionLayoutPolicy.edgeIdleContentBounds.width

            XCTAssertEqual(visibleSubjectLeadingX, expectedInset, accuracy: 0.001)
            XCTAssertLessThanOrEqual(
                visibleSubjectLeadingX + visibleSubjectWidth,
                available.width - expectedInset + 0.001,
                "Every retained Edge Idle frame must fit without clipping, including narrow Split View."
            )
            XCTAssertLessThanOrEqual(layout.playerFrame.height, available.height + 0.001)
            XCTAssertEqual(layout.playerFrame.midY, available.height / 2, accuracy: 0.001)
            if available.width >= 390 {
                XCTAssertEqual(layout.playerFrame.height, available.height, accuracy: 0.001)
            }
            XCTAssertGreaterThanOrEqual(
                contactX,
                visibleSubjectLeadingX,
                "The stable contact must remain inside the measured retained-alpha envelope."
            )
            XCTAssertLessThanOrEqual(
                contactX - visibleSubjectLeadingX,
                9,
                "The stable contact must remain visually flush with the physical left edge."
            )
            let visibleSubjectMidX = visibleSubjectLeadingX
                + visibleSubjectWidth / 2
            XCTAssertLessThanOrEqual(
                visibleSubjectMidX,
                available.width / 2 + 0.001,
                "Edge Idle must remain visibly left-anchored rather than centered."
            )
            XCTAssertEqual(layout.clippingBounds, CGRect(origin: .zero, size: available))
        }
    }

    func testMotionLayoutSanitizesInvalidAndTinyGeometry() {
        for invalid in [
            CGSize(width: CGFloat.nan, height: 844),
            CGSize(width: 390, height: CGFloat.infinity),
            CGSize(width: -1, height: 844),
            .zero,
        ] {
            let layout = OpenClamAvatarMotionLayoutPolicy.layout(
                kind: .moves,
                availableSize: invalid,
                pixelSize: CGSize(width: 720, height: 1_088)
            )
            XCTAssertEqual(layout.playerFrame, CGRect.zero)
            XCTAssertTrue(layout.clippingBounds.width.isFinite)
            XCTAssertTrue(layout.clippingBounds.height.isFinite)
            XCTAssertGreaterThanOrEqual(layout.clippingBounds.width, 0)
            XCTAssertGreaterThanOrEqual(layout.clippingBounds.height, 0)
        }

        let tiny = OpenClamAvatarMotionLayoutPolicy.layout(
            kind: .edgeIdle,
            availableSize: CGSize(width: 1, height: 1),
            pixelSize: CGSize(width: 720, height: 1_088)
        )
        XCTAssertTrue(tiny.playerFrame.minX.isFinite)
        XCTAssertTrue(tiny.playerFrame.width.isFinite)
        XCTAssertEqual(tiny.playerFrame.height, 1, accuracy: 0.001)
        XCTAssertEqual(
            tiny.playerFrame.minX
                + tiny.playerFrame.width
                    * OpenClamAvatarMotionLayoutPolicy.edgeIdleContentBounds.minX,
            0.01,
            accuracy: 0.001
        )
        XCTAssertEqual(tiny.clippingBounds, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

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

    func testFullExpressionMouthPolicyInterpolatesStrengthAndProductionViseme() throws {
        let geometry = fullExpressionGeometry()
        let active = try XCTUnwrap(
            OpenClamAvatarExpressionMouthPolicy.dominant(
                .init(
                    smile: 0.18,
                    sorrowMouth: 0,
                    horrorMouth: 0,
                    angerMouth: 0,
                    cheek: 0,
                    underEye: 0
                ),
                geometry: geometry
            )
        )
        XCTAssertEqual(active.kind, .smile)
        XCTAssertEqual(active.amount, 0.18, accuracy: 0.0001)

        let samples = OpenClamAvatarExpressionMouthPolicy.samples(
            kind: active.kind,
            amount: active.amount,
            previous: .silence,
            current: .velar,
            speechBlend: 0.25,
            geometry: geometry
        )
        let velarRow = try XCTUnwrap(
            OpenClamAvatarViseme.allCases.firstIndex(of: .velar)
        )
        XCTAssertEqual(
            samples,
            [
                .init(frame: 1, opacity: 0.75),
                .init(frame: velarRow * 5 + 1, opacity: 0.25),
            ]
        )
        XCTAssertEqual(samples.reduce(0) { $0 + $1.opacity }, 1, accuracy: 0.0001)
    }

    func testFullExpressionMouthPolicySelectsTheStrongestPhraseLocalEmotion() throws {
        let geometry = fullExpressionGeometry()
        let active = try XCTUnwrap(
            OpenClamAvatarExpressionMouthPolicy.dominant(
                .init(
                    smile: 0.18,
                    sorrowMouth: 0.20,
                    horrorMouth: 0.40,
                    angerMouth: 0.98,
                    cheek: 0.25,
                    underEye: 0.25
                ),
                geometry: geometry
            )
        )

        XCTAssertEqual(active.kind, .emotion(name: "anger", index: 2))
        XCTAssertEqual(active.amount, 0.98, accuracy: 0.0001)
        let samples = OpenClamAvatarExpressionMouthPolicy.samples(
            kind: active.kind,
            amount: 0.98,
            previous: .postalveolar,
            current: .openRounded,
            speechBlend: 1,
            geometry: geometry
        )
        let visemeCount = OpenClamAvatarViseme.allCases.count
        let row = 2 * visemeCount + (OpenClamAvatarViseme.allCases.firstIndex(of: .openRounded) ?? 0)
        XCTAssertEqual(samples.map(\.frame), [row * 4 + 2, row * 4 + 3])
        XCTAssertEqual(samples[0].opacity, 0.0625, accuracy: 0.0001)
        XCTAssertEqual(samples[1].opacity, 0.9375, accuracy: 0.0001)
    }

    func testPhraseCrossoverUsesOnlyDominantMouthBankToPreventDoubleLips() throws {
        let geometry = fullExpressionGeometry()
        let active = try XCTUnwrap(
            OpenClamAvatarExpressionMouthPolicy.dominant(
                .init(
                    smile: 0.12,
                    sorrowMouth: 0,
                    horrorMouth: 0.24,
                    angerMouth: 0,
                    cheek: 0,
                    underEye: 0
                ),
                geometry: geometry
            )
        )

        XCTAssertEqual(active.kind, .emotion(name: "horror", index: 1))
        XCTAssertEqual(active.amount, 0.24, accuracy: 0.0001)
        let samples = OpenClamAvatarExpressionMouthPolicy.samples(
            kind: active.kind,
            amount: active.amount,
            previous: .bilabial,
            current: .openRounded,
            speechBlend: 0.37,
            geometry: geometry
        )
        XCTAssertEqual(samples.reduce(0) { $0 + $1.opacity }, 1, accuracy: 0.0001)
    }

    func testSpeechBrowIntentMapsAgainstLegacyAndFullExpressionGeometry() {
        let geometry = fullExpressionGeometry()
        let fallbackCanonicalFrame = 1 * 14 + 9

        XCTAssertEqual(
            OpenClamAvatarBrowFramePolicy.frame(
                fallback: fallbackCanonicalFrame,
                offset: 6,
                squeeze: 0,
                expression: geometry
            ),
            1 * 14 + 9,
            "v4 must use its authored 6 px state"
        )
        XCTAssertEqual(
            OpenClamAvatarBrowFramePolicy.frame(
                fallback: fallbackCanonicalFrame,
                offset: 6,
                squeeze: 0,
                expression: nil
            ),
            1 * 14 + 11,
            "legacy packages must retain the older 6.5 px state mapping"
        )
        XCTAssertEqual(
            OpenClamAvatarBrowFramePolicy.frame(
                fallback: 7,
                offset: nil,
                squeeze: nil,
                expression: nil
            ),
            7,
            "tap/camera reactions authored as discrete frames stay untouched"
        )
    }

    func testFullExpressionCalibrationAppliesToBrowForeheadAndUnderEye() {
        var geometry = fullExpressionGeometry()
        geometry = .init(
            smile: geometry.smile,
            emotionMouth: geometry.emotionMouth,
            leftForehead: geometry.leftForehead,
            rightForehead: geometry.rightForehead,
            leftCheek: geometry.leftCheek,
            rightCheek: geometry.rightCheek,
            leftUnderEye: geometry.leftUnderEye,
            rightUnderEye: geometry.rightUnderEye,
            browOffsets: geometry.browOffsets,
            browSqueezeOffsets: geometry.browSqueezeOffsets,
            smileStrengths: geometry.smileStrengths,
            smileVisemes: geometry.smileVisemes,
            emotionMouthStrengths: geometry.emotionMouthStrengths,
            emotionMouthEmotions: geometry.emotionMouthEmotions,
            emotionMouthVisemes: geometry.emotionMouthVisemes,
            cheekOffsets: geometry.cheekOffsets,
            underEyeOffsets: geometry.underEyeOffsets,
            browGain: 1.25,
            foreheadGain: 0.6,
            underEyeGain: 1.3
        )

        XCTAssertEqual(
            OpenClamAvatarExpressionCalibrationPolicy.browOffset(
                4,
                expression: geometry
            ),
            5
        )
        XCTAssertEqual(
            OpenClamAvatarExpressionCalibrationPolicy.foreheadOffset(
                4,
                expression: geometry
            ) ?? -1,
            3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            OpenClamAvatarExpressionCalibrationPolicy.underEyeAmount(
                0.5,
                expression: geometry
            ),
            0.65,
            accuracy: 0.0001
        )
    }

    private func fullExpressionGeometry() -> OpenClamAvatarExpressionGeometry {
        func sprite(columns: Int, rows: Int) -> OpenClamAvatarSpriteGeometry {
            .init(
                box: .init(x: 400, y: 600, width: 100, height: 80),
                columns: columns,
                rows: rows,
                storage: .verticalStrip
            )
        }
        let visemes = OpenClamAvatarViseme.allCases
        return .init(
            smile: sprite(columns: 5, rows: visemes.count),
            emotionMouth: sprite(columns: 4, rows: visemes.count * 3),
            leftForehead: sprite(columns: 14, rows: 3),
            rightForehead: sprite(columns: 14, rows: 3),
            leftCheek: sprite(columns: 1, rows: 5),
            rightCheek: sprite(columns: 1, rows: 5),
            leftUnderEye: sprite(columns: 1, rows: 5),
            rightUnderEye: sprite(columns: 1, rows: 5),
            browOffsets: OpenClamAvatarExpressionGeometry.canonicalBrowOffsets,
            browSqueezeOffsets: OpenClamAvatarExpressionGeometry
                .canonicalBrowSqueezeOffsets,
            smileStrengths: OpenClamAvatarExpressionGeometry.canonicalSmileStrengths,
            smileVisemes: visemes,
            emotionMouthStrengths: OpenClamAvatarExpressionGeometry
                .canonicalEmotionMouthStrengths,
            emotionMouthEmotions: ["sorrow", "horror", "anger"],
            emotionMouthVisemes: visemes,
            cheekOffsets: OpenClamAvatarExpressionGeometry.canonicalCheekOffsets,
            underEyeOffsets: OpenClamAvatarExpressionGeometry.canonicalUnderEyeOffsets,
            browGain: 1,
            foreheadGain: 1,
            underEyeGain: 1
        )
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
