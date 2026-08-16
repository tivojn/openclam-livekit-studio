import XCTest
@testable import OpenClamLiveKit

final class OpenClamCatalogAvatarStageTests: XCTestCase {
    func testPublicGuideTransformMatchesFixtureGeometry() throws {
        let guide = try XCTUnwrap(OpenClamAvatarCatalog.avatar(id: "captain-ayer"))
        XCTAssertEqual(guide.geometry.faceTransform.uniformScale, 0.1, accuracy: 0.000001)
        XCTAssertEqual(guide.geometry.faceTransform.rotationDegrees, 0, accuracy: 0.0001)
        XCTAssertEqual(guide.geometry.faceCenterInBody.x, 63.2, accuracy: 0.02)
        XCTAssertEqual(guide.geometry.faceCenterInBody.y, 55.2, accuracy: 0.02)
        XCTAssertEqual(guide.geometry.eyeAnchorInBody.x, 63.1, accuracy: 0.001)
        XCTAssertEqual(guide.geometry.eyeAnchorInBody.y, 53.2, accuracy: 0.001)
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
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
