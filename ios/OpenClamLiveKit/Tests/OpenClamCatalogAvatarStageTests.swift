import XCTest
@testable import OpenClamLiveKit

final class OpenClamCatalogAvatarStageTests: XCTestCase {
    func testStylizedBlinkUsesOnlyCanonicalOpenOrFullEyeClosedPlate() {
        let open = CaptainAyerEyeReactionState(
            lowerFrame: nil,
            upperFrame: 0,
            upperOpacity: 0
        )
        let half = CaptainAyerEyeReactionState(
            lowerFrame: 5,
            upperFrame: 6,
            upperOpacity: 0.95
        )
        let approachingClosed = CaptainAyerEyeReactionState(
            lowerFrame: 6,
            upperFrame: 7,
            upperOpacity: 0.77
        )
        let closed = CaptainAyerEyeReactionState(
            lowerFrame: 6,
            upperFrame: 7,
            upperOpacity: 0.78
        )

        for medium in [OpenClamAvatarSourceMedium.anime,
                       .illustration, .rendered3D, .gameArt] {
            XCTAssertEqual(
                OpenClamAvatarEyelidPlatePolicy.plan(
                    for: open, frameCount: 8, sourceMedium: medium
                ),
                .canonicalOpen
            )
            XCTAssertEqual(
                OpenClamAvatarEyelidPlatePolicy.plan(
                    for: half, frameCount: 8, sourceMedium: medium
                ),
                .canonicalOpen
            )
            XCTAssertEqual(
                OpenClamAvatarEyelidPlatePolicy.plan(
                    for: approachingClosed, frameCount: 8, sourceMedium: medium
                ),
                .canonicalOpen
            )
            XCTAssertEqual(
                OpenClamAvatarEyelidPlatePolicy.plan(
                    for: closed, frameCount: 8, sourceMedium: medium
                ),
                .semanticClosed(frame: 7)
            )
        }
    }

    func testPhotographicBlinkRetainsInterpolatedEightFramePolicy() {
        for state in [
            CaptainAyerEyeReactionState(
                lowerFrame: nil, upperFrame: 0, upperOpacity: 0
            ),
            CaptainAyerEyeReactionState(
                lowerFrame: 3, upperFrame: 4, upperOpacity: 0.5
            ),
            CaptainAyerEyeReactionState(
                lowerFrame: 6, upperFrame: 7, upperOpacity: 1
            ),
        ] {
            XCTAssertEqual(
                OpenClamAvatarEyelidPlatePolicy.plan(
                    for: state, frameCount: 8, sourceMedium: .photograph
                ),
                .interpolatedStrip
            )
        }
    }

    func testPhotographicFullExpressionFacePreservesCanonicalRotationForEverySpeechHeadPose() {
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
                sourceMedium: .photograph,
                bodyScale: bodyScale
            )

            XCTAssertEqual(plan.pitchDegrees, 0, accuracy: 0.000_001)
            XCTAssertEqual(plan.yawDegrees, 0, accuracy: 0.000_001)
            XCTAssertEqual(
                plan.rotationDegrees,
                canonicalRotation,
                accuracy: 0.000_001
            )
            XCTAssertEqual(plan.translationX, 0, accuracy: 0.000_001)
            XCTAssertEqual(plan.translationY, 0, accuracy: 0.000_001)
            XCTAssertEqual(plan.dynamicResamplingPassCount, 0)
        }
    }

    func testStylizedFullExpressionFaceZerosCanonicalRotationForEverySpeechHeadPose() {
        let canonicalRotation = 23.7223
        let pose = CaptainAyerFaceMirrorHeadPose(
            yaw: 0.72,
            pitch: -0.41,
            roll: 0.88
        )

        for medium in [OpenClamAvatarSourceMedium.anime,
                       .illustration, .rendered3D, .gameArt] {
            let plan = OpenClamAvatarFaceRegistrationPolicy.plan(
                canonicalRotationDegrees: canonicalRotation,
                reaction: pose,
                bodyLocked: true,
                sourceMedium: medium,
                bodyScale: 1.27
            )

            XCTAssertEqual(plan.pitchDegrees, 0, accuracy: 0.000_001)
            XCTAssertEqual(plan.yawDegrees, 0, accuracy: 0.000_001)
            XCTAssertEqual(plan.rotationDegrees, 0, accuracy: 0.000_001)
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
            sourceMedium: .photograph,
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

    func testExpressionMouthUsesNoseSafeMaskForStylizedSourcesOnly() throws {
        let avatar = try XCTUnwrap(OpenClamAvatarCatalog.avatar(id: "captain-ayer"))
        let authoredPatch = OpenClamAvatarSpeechPatchGeometry(
            rig: avatar.geometry,
            sourceMedium: .anime,
            expressionMouthBounds: CGRect(x: 408, y: 668, width: 230, height: 132),
            speechPatch: .init(
                box: .init(x: 418, y: 704, width: 205, height: 88),
                visemeXOffsets: [OpenClamAvatarViseme.open.rawValue: 9.5]
            )
        )

        XCTAssertNil(
            OpenClamAvatarExpressionMouthMaskPolicy.maskGeometry(
                for: authoredPatch,
                sourceMedium: .photograph
            ),
            "Photographic expression mouths must retain the existing unmasked renderer."
        )

        for medium in [OpenClamAvatarSourceMedium.anime,
                       .illustration, .rendered3D, .gameArt] {
            let mask = try XCTUnwrap(
                OpenClamAvatarExpressionMouthMaskPolicy.maskGeometry(
                    for: authoredPatch,
                    sourceMedium: medium
                )
            )
            XCTAssertEqual(mask, authoredPatch)
            XCTAssertEqual(mask.coreBounds, CGRect(x: 418, y: 704, width: 205, height: 88))
            XCTAssertTrue(mask.clipsFeatherToCoreBounds)
            XCTAssertGreaterThan(mask.coreBounds.minY, 700, "the stylized mask must stay below the nose tip")
        }
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

            XCTAssertEqual(layout.playerFrame.midX, available.width / 2, accuracy: 0.001)
            let content = OpenClamAvatarMotionLayoutPolicy.movesContentBounds
            XCTAssertEqual(
                layout.playerFrame.minY + layout.playerFrame.height * content.minY,
                0,
                accuracy: 0.001
            )
            XCTAssertEqual(
                layout.playerFrame.minY + layout.playerFrame.height * content.maxY,
                available.height,
                accuracy: 0.001
            )
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
            let visibleTop = layout.playerFrame.minY
                + layout.playerFrame.height
                    * OpenClamAvatarMotionLayoutPolicy.edgeIdleContentBounds.minY
            let visibleBottom = layout.playerFrame.minY
                + layout.playerFrame.height
                    * OpenClamAvatarMotionLayoutPolicy.edgeIdleContentBounds.maxY
            XCTAssertGreaterThanOrEqual(visibleTop, -0.001)
            XCTAssertEqual(visibleBottom, available.height, accuracy: 0.001)
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
        XCTAssertGreaterThan(tiny.playerFrame.height, 0)
        XCTAssertEqual(
            tiny.playerFrame.minX
                + tiny.playerFrame.width
                    * OpenClamAvatarMotionLayoutPolicy.edgeIdleContentBounds.minX,
            0.01,
            accuracy: 0.001
        )
        XCTAssertEqual(
            tiny.playerFrame.minY
                + tiny.playerFrame.height
                    * OpenClamAvatarMotionLayoutPolicy.edgeIdleContentBounds.maxY,
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(tiny.clippingBounds, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testConversationCanvasEndsAboveMeasuredComposerAndDrivesEveryMotion() {
        let bounds = OpenClamAvatarConversationCanvasPolicy.bounds(
            overlaySize: CGSize(width: 390, height: 844),
            overlayGlobalMinY: 0,
            composerTopGlobal: 730,
            topInset: 42
        )

        XCTAssertEqual(bounds, CGRect(x: 0, y: 42, width: 390, height: 684))
        for kind in OpenClamAvatarMotionKind.allCases {
            let motion = OpenClamAvatarMotionLayoutPolicy.layout(
                kind: kind,
                availableSize: bounds.size,
                pixelSize: CGSize(width: 720, height: 1_088)
            )
            XCTAssertEqual(motion.clippingBounds.size, bounds.size)
            let content = OpenClamAvatarMotionLayoutPolicy.contentBounds(for: kind)
            XCTAssertEqual(
                motion.playerFrame.minY + motion.playerFrame.height * content.maxY,
                bounds.height,
                accuracy: 0.001
            )
            XCTAssertGreaterThanOrEqual(
                motion.playerFrame.minY + motion.playerFrame.height * content.minY,
                -0.001
            )
        }
    }

    func testBundledFullBodiesFillConversationAndVisibleFeetMeetComposerFloor() throws {
        let canvas = CGRect(x: 0, y: 42, width: 390, height: 684)
        let expectedFractions: [String: CGFloat] = [
            "captain-ayer": 1_587.0 / 1_672.0,
            "ara": 1_406.0 / 1_448.0,
        ]

        for (id, expectedFraction) in expectedFractions {
            let avatar = try XCTUnwrap(OpenClamAvatarCatalog.avatar(id: id))
            let fraction = OpenClamAvatarConversationCanvasPolicy
                .fullBodyVisibleBottomFraction(for: avatar)
            let layout = OpenClamAvatarConversationCanvasPolicy.layout(
                crop: OpenClamCatalogAvatarStage.Presentation.expanded.crop(for: avatar),
                in: canvas,
                alignsVisibleFeet: true,
                visibleBottomFraction: fraction
            )

            XCTAssertEqual(fraction, expectedFraction, accuracy: 0.000_001, id)
            XCTAssertEqual(layout.bounds, canvas, id)
            XCTAssertEqual(layout.stageFrame.midX, canvas.midX, accuracy: 0.001, id)
            XCTAssertGreaterThan(layout.stageFrame.height, canvas.height, id)
            XCTAssertEqual(
                layout.stageFrame.minY + layout.stageFrame.height * fraction,
                canvas.maxY,
                accuracy: 0.001,
                id
            )
        }
    }

    func testCompactPresetIsHeadAndShouldersInsteadOfHalfBody() {
        for avatar in OpenClamAvatarCatalog.avatars {
            let face = avatar.geometry.faceBoundsInBody.cgRect
            let body = avatar.geometry.bodySize.cgSize
            let crop = OpenClamCatalogAvatarStage.Presentation.compact.crop(for: avatar)

            XCTAssertTrue(crop.contains(face), avatar.displayName)
            XCTAssertLessThanOrEqual(crop.height, face.height * 3.5 + 0.001)
            XCTAssertLessThan(crop.maxY, body.height * 0.5, avatar.displayName)
        }
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

    func testPhotographicSpeechPatchKeepsLegacyGeometryAndCrossfade() throws {
        let avatar = try XCTUnwrap(OpenClamAvatarCatalog.avatar(id: "captain-ayer"))
        let geometry = OpenClamAvatarSpeechPatchGeometry(
            rig: avatar.geometry,
            sourceMedium: .photograph,
            expressionMouthBounds: CGRect(x: 400, y: 680, width: 240, height: 150),
            speechPatch: .init(
                box: .init(x: 410, y: 700, width: 220, height: 110),
                visemeXOffsets: [OpenClamAvatarViseme.open.rawValue: 24]
            )
        )

        let eyeBottom = max(
            avatar.geometry.leftEye.box.cgRect.maxY,
            avatar.geometry.rightEye.box.cgRect.maxY
        )
        XCTAssertEqual(geometry.coreBounds.minX, 352)
        XCTAssertEqual(geometry.coreBounds.minY, max(630, eyeBottom + 62))
        XCTAssertEqual(geometry.coreBounds.maxY, 916)
        XCTAssertEqual(geometry.featherRadius, 18)
        XCTAssertFalse(geometry.clipsFeatherToCoreBounds)
        XCTAssertEqual(geometry.translationX(for: .open), 0)

        let plan = OpenClamAvatarFacePlatePolicy.plan(
            for: .init(previous: .open, current: .wide, blend: 0.4),
            sourceMedium: .photograph
        )
        XCTAssertEqual(plan.speechPatch?.back.viseme, .open)
        XCTAssertEqual(plan.speechPatch?.front?.viseme, .wide)
        XCTAssertEqual(plan.speechPatch?.front?.opacity ?? -1, 0.4, accuracy: 0.0001)
    }

    func testStylizedSpeechPatchExcludesNoseAndUsesAuthoredVisemeOffsets() throws {
        let avatar = try XCTUnwrap(OpenClamAvatarCatalog.avatar(id: "captain-ayer"))
        var offsets = Dictionary(
            uniqueKeysWithValues: OpenClamAvatarViseme.allCases.map {
                ($0.rawValue, 0.0)
            }
        )
        offsets[OpenClamAvatarViseme.open.rawValue] = 12.669
        offsets[OpenClamAvatarViseme.velar.rawValue] = 28.223
        let speechPatch = OpenClamAvatarSpeechPatchMetadata(
            box: .init(x: 413, y: 699, width: 215, height: 96),
            visemeXOffsets: offsets
        )
        let geometry = OpenClamAvatarSpeechPatchGeometry(
            rig: avatar.geometry,
            sourceMedium: .anime,
            expressionMouthBounds: CGRect(x: 412, y: 674, width: 225, height: 125),
            speechPatch: speechPatch
        )

        XCTAssertEqual(geometry.coreBounds, CGRect(x: 413, y: 699, width: 215, height: 96))
        XCTAssertEqual(geometry.conservativeDynamicBounds, geometry.coreBounds)
        XCTAssertEqual(geometry.featherRadius, 6)
        XCTAssertTrue(geometry.clipsFeatherToCoreBounds)
        XCTAssertGreaterThan(geometry.coreBounds.minY, 691, "the alternate Luffy nose ends above the speech plate")
        XCTAssertGreaterThan(geometry.stylizedVisibleBounds.minY, geometry.coreBounds.minY)
        XCTAssertLessThan(geometry.stylizedVisibleBounds.maxY, geometry.coreBounds.maxY)
        XCTAssertEqual(
            geometry.stylizedVisibleBounds.midX,
            geometry.coreBounds.midX,
            accuracy: 0.0001
        )
        XCTAssertEqual(geometry.translationX(for: .silence), 0)
        XCTAssertEqual(geometry.translationX(for: .open), 12.669, accuracy: 0.0001)
        XCTAssertEqual(geometry.translationX(for: .velar), 28.223, accuracy: 0.0001)
    }

    func testStylizedSpeechDifferenceMatteRejectsSkinButKeepsLipInk() {
        let centre = OpenClamAvatarStylizedSpeechPatchPixelPolicy.spatialAlpha(
            x: 99, y: 44, width: 200, height: 100
        )
        let nose = OpenClamAvatarStylizedSpeechPatchPixelPolicy.spatialAlpha(
            x: 99, y: 0, width: 200, height: 100
        )
        let chin = OpenClamAvatarStylizedSpeechPatchPixelPolicy.spatialAlpha(
            x: 99, y: 99, width: 200, height: 100
        )
        XCTAssertGreaterThan(centre, 0.99)
        XCTAssertLessThan(nose, 0.01)
        XCTAssertLessThan(chin, 0.01)
        XCTAssertEqual(
            OpenClamAvatarStylizedSpeechPatchPixelPolicy.differenceAlpha(
                maximumChannelDelta: 6, spatialAlpha: centre
            ),
            0,
            accuracy: 0.0001,
            "JPEG/skin noise must not become a visible face patch."
        )
        XCTAssertGreaterThan(
            OpenClamAvatarStylizedSpeechPatchPixelPolicy.differenceAlpha(
                maximumChannelDelta: 42, spatialAlpha: centre
            ),
            0.99,
            "Authored lip, tooth, and mouth-interior contrast must remain opaque."
        )
    }

    func testStylizedSpeechAndExpressionMouthsHardSwitchAtMidpoint() {
        let early = OpenClamAvatarFacePlatePolicy.plan(
            for: .init(previous: .open, current: .wide, blend: 0.49),
            sourceMedium: .illustration
        )
        XCTAssertEqual(early.speechPatch?.back.viseme, .open)
        XCTAssertNil(early.speechPatch?.front)
        let late = OpenClamAvatarFacePlatePolicy.plan(
            for: .init(previous: .open, current: .wide, blend: 0.5),
            sourceMedium: .illustration
        )
        XCTAssertEqual(late.speechPatch?.back.viseme, .wide)
        XCTAssertNil(late.speechPatch?.front)

        let geometry = fullExpressionGeometry()
        for (blend, expected) in [(0.49, OpenClamAvatarViseme.silence),
                                  (0.5, OpenClamAvatarViseme.velar)] {
            let samples = OpenClamAvatarExpressionMouthPolicy.samples(
                kind: .smile,
                // Deliberately between authored states. A stylized mouth must
                // choose one complete drawing rather than crossfade the 0.18
                // and 0.34 cells into blurred/double line art.
                amount: 0.26,
                previous: .silence,
                current: .velar,
                speechBlend: blend,
                geometry: geometry,
                sourceMedium: .anime
            )
            XCTAssertEqual(samples.count, 1)
            XCTAssertEqual(
                OpenClamAvatarExpressionMouthPolicy.viseme(
                    forFrame: samples[0].frame,
                    kind: .smile,
                    geometry: geometry
                ),
                expected
            )
            XCTAssertEqual(
                samples[0].frame % geometry.smileStrengths.count,
                1,
                "The equidistant 0.26 amount must deterministically choose the lower 0.18 drawing."
            )
            XCTAssertEqual(samples[0].opacity, 1, accuracy: 0.0001)
        }
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
