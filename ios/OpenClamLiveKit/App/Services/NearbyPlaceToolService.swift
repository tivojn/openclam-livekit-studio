import CoreLocation
import Foundation
import MapKit

@MainActor
protocol AgentLocationProviding: AnyObject {
    func currentLocation() async throws -> CLLocation
}

@MainActor
protocol AgentNearbyMapSearching: AnyObject {
    func mapItems(matching query: String, in region: MKCoordinateRegion) async throws -> [MKMapItem]
}

@MainActor
final class DeviceLocationProvider: NSObject, AgentLocationProviding, @preconcurrency CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private let timeoutNanoseconds: UInt64
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var hasRequestedLocation = false

    init(manager: CLLocationManager = CLLocationManager(), timeoutSeconds: TimeInterval = 15) {
        self.manager = manager
        let boundedTimeout = timeoutSeconds.isFinite ? min(max(1, timeoutSeconds), 60) : 15
        timeoutNanoseconds = UInt64(boundedTimeout * 1_000_000_000)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> CLLocation {
        guard continuation == nil else {
            throw AgentToolServiceError.locationRequestInProgress
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(with: .failure(AgentToolServiceError.locationRequestCancelled))
                    return
                }
                beginLocationRequest()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(with: .failure(AgentToolServiceError.locationRequestCancelled))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        continueAfterAuthorizationChange(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let newestUsableLocation = locations
            .filter { location in
                CLLocationCoordinate2DIsValid(location.coordinate)
                    && location.horizontalAccuracy >= 0
                    && abs(location.timestamp.timeIntervalSinceNow) <= 300
            }
            .max(by: { $0.timestamp < $1.timestamp })

        guard let newestUsableLocation else {
            finish(with: .failure(AgentToolServiceError.locationUnavailable))
            return
        }
        finish(with: .success(newestUsableLocation))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: .failure(AgentToolServiceError.locationUnavailable))
    }

    private func beginLocationRequest() {
        let usageKey = "NSLocationWhenInUseUsageDescription"
        let usageDescription = Bundle.main.object(forInfoDictionaryKey: usageKey) as? String
        guard let usageDescription,
              !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finish(with: .failure(AgentToolServiceError.missingLocationUsageDescription))
            return
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            requestOneLocation()
        case .denied:
            finish(with: .failure(AgentToolServiceError.locationPermissionDenied))
        case .restricted:
            finish(with: .failure(AgentToolServiceError.locationPermissionRestricted))
        @unknown default:
            finish(with: .failure(AgentToolServiceError.locationUnavailable))
        }
    }

    private func continueAfterAuthorizationChange(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            break
        case .authorizedAlways, .authorizedWhenInUse:
            requestOneLocation()
        case .denied:
            finish(with: .failure(AgentToolServiceError.locationPermissionDenied))
        case .restricted:
            finish(with: .failure(AgentToolServiceError.locationPermissionRestricted))
        @unknown default:
            finish(with: .failure(AgentToolServiceError.locationUnavailable))
        }
    }

    private func requestOneLocation() {
        guard !hasRequestedLocation else { return }
        hasRequestedLocation = true
        let timeoutNanoseconds = timeoutNanoseconds
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.finish(with: .failure(AgentToolServiceError.locationRequestTimedOut))
        }
        manager.requestLocation()
    }

    private func finish(with result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        hasRequestedLocation = false
        continuation.resume(with: result)
    }
}

@MainActor
final class AppleNearbyMapSearcher: AgentNearbyMapSearching {
    func mapItems(matching query: String, in region: MKCoordinateRegion) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        request.region = region
        return try await MKLocalSearch(request: request).start().mapItems
    }
}

@MainActor
final class NearbyPlaceToolService {
    static let defaultRadiusMeters: CLLocationDistance = 5_000
    static let allowedRadiusMeters: ClosedRange<CLLocationDistance> = 100 ... 50_000
    static let allowedResultCount = 1 ... 20

    private let locationProvider: any AgentLocationProviding
    private let mapSearcher: any AgentNearbyMapSearching

    init() {
        locationProvider = DeviceLocationProvider()
        mapSearcher = AppleNearbyMapSearcher()
    }

    init(locationProvider: any AgentLocationProviding, mapSearcher: any AgentNearbyMapSearching) {
        self.locationProvider = locationProvider
        self.mapSearcher = mapSearcher
    }

    func searchNearby(
        query rawQuery: String,
        radiusMeters: CLLocationDistance = 5_000,
        limit: Int = 8
    ) async throws -> NearbyPlaceSearchOutcome {
        let query = try AgentToolInputValidator.singleLine(
            rawQuery,
            field: "nearby place query",
            maximumLength: 160
        )
        guard Self.allowedRadiusMeters.contains(radiusMeters), radiusMeters.isFinite else {
            throw AgentToolServiceError.invalidInput(
                field: "search radius",
                reason: "use a value from 100 to 50000 meters"
            )
        }
        guard Self.allowedResultCount.contains(limit) else {
            throw AgentToolServiceError.invalidInput(
                field: "result limit",
                reason: "use a value from 1 to 20"
            )
        }

        let location = try await locationProvider.currentLocation()
        guard CLLocationCoordinate2DIsValid(location.coordinate) else {
            throw AgentToolServiceError.locationUnavailable
        }

        let region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: radiusMeters * 2,
            longitudinalMeters: radiusMeters * 2
        )

        let items: [MKMapItem]
        do {
            items = try await mapSearcher.mapItems(matching: query, in: region)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentToolServiceError.nearbySearchUnavailable
        }

        var seen = Set<String>()
        let candidates = items.compactMap { item -> NearbyPlaceCandidate? in
            let coordinate = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            let candidateLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let distance = location.distance(from: candidateLocation)
            guard distance.isFinite, distance <= radiusMeters else { return nil }

            let name = compact(item.name ?? "Unnamed place", maximumLength: 200)
            let address = compact(address(for: item), maximumLength: 500)
            let deduplicationKey = "\(normalized(name))|\(coordinate.latitude)|\(coordinate.longitude)"
            guard seen.insert(deduplicationKey).inserted else { return nil }

            return NearbyPlaceCandidate(
                id: UUID().uuidString,
                name: name,
                address: address,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                distanceMeters: distance
            )
        }
        .sorted { left, right in
            if left.distanceMeters != right.distanceMeters {
                return left.distanceMeters < right.distanceMeters
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }

        return NearbyPlaceSearchOutcome(
            query: query,
            radiusMeters: radiusMeters,
            candidates: Array(candidates.prefix(limit)),
            hasMoreCandidates: candidates.count > limit
        )
    }

    private func address(for item: MKMapItem) -> String {
        let title = item.placemark.title ?? ""
        guard let name = item.name, title.hasPrefix(name + ", ") else { return title }
        return String(title.dropFirst(name.count + 2))
    }

    private func compact(_ value: String, maximumLength: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumLength))
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
