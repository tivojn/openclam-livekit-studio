import Foundation

enum GoogleMapsURLBuilder {
    static func drivingDirections(to rawDestination: String) throws -> URL {
        let destination = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty, destination.count <= 500 else {
            throw CommandValidationError.invalidParameter("destination")
        }

        var components = URLComponents(string: "https://www.google.com/maps/dir/")
        components?.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: destination),
            URLQueryItem(name: "travelmode", value: "driving"),
        ]
        guard let url = components?.url else {
            throw CommandValidationError.invalidParameter("destination")
        }
        return url
    }
}
