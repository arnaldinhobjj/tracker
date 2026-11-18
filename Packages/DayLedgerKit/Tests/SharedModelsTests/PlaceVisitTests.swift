import XCTest
import SharedModels

final class PlaceVisitTests: XCTestCase {
    func testSameVisitDetection() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        // ~50 m apart, 2 minutes apart: same visit.
        XCTAssertTrue(VisitMerging.isSameVisit(arrivalA: t, latA: 51.5000, lonA: -0.1200,
                                               arrivalB: t.addingTimeInterval(120), latB: 51.5004, lonB: -0.1200))
        // Same place but an hour later: a new visit.
        XCTAssertFalse(VisitMerging.isSameVisit(arrivalA: t, latA: 51.5, lonA: -0.12,
                                                arrivalB: t.addingTimeInterval(3_600), latB: 51.5, lonB: -0.12))
        // Same time, 1 km away: different.
        XCTAssertFalse(VisitMerging.isSameVisit(arrivalA: t, latA: 51.5, lonA: -0.12,
                                                arrivalB: t, latB: 51.509, lonB: -0.12))
    }

    func testCategoryName() {
        let visit = PlaceVisit(id: "v", arrival: Date(), departure: nil, latitude: 0, longitude: 0, placeCategory: "MKPOICategoryPublicTransport")
        XCTAssertEqual(visit.categoryName, "Public Transport")
    }
}
