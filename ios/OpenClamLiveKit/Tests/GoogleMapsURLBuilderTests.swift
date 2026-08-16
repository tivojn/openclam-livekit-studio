import XCTest
@testable import OpenClamLiveKit

final class GoogleMapsURLBuilderTests: XCTestCase {
    func testBuildsDrivingDirectionsInsteadOfPlaceSearch() throws {
        let url = try GoogleMapsURLBuilder.drivingDirections(
            to: "McDonald's (Future Gongyuan Branch), Beijing"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.google.com")
        XCTAssertEqual(components.path, "/maps/dir/")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "api" })?.value, "1")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "destination" })?.value,
            "McDonald's (Future Gongyuan Branch), Beijing"
        )
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "travelmode" })?.value,
            "driving"
        )
        XCTAssertNil(components.queryItems?.first(where: { $0.name == "query" }))
    }

    func testRejectsEmptyOrOversizedDestination() {
        XCTAssertThrowsError(try GoogleMapsURLBuilder.drivingDirections(to: "   "))
        XCTAssertThrowsError(
            try GoogleMapsURLBuilder.drivingDirections(to: String(repeating: "x", count: 501))
        )
    }
}
