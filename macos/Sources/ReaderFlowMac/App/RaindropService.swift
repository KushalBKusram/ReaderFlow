import Foundation

/// A thin client for the handful of Raindrop REST endpoints ReaderFlow needs
/// once a token is in hand: collection selection, nothing else. No bookmark
/// content is cached by this type.
struct RaindropService {
    func fetchCollections(accessToken: String) async throws -> [RaindropCollection] {
        var request = URLRequest(url: URL(string: "https://api.raindrop.io/rest/v1/collections")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct Envelope: Decodable { let items: [RaindropCollection] }
        return try JSONDecoder().decode(Envelope.self, from: data).items
    }
}
