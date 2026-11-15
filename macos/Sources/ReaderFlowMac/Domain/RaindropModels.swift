import Foundation

/// The token-exchange/refresh response shape, identical for both grants per
/// https://developer.raindrop.io/v1/authentication/token.
struct RaindropTokenResponse: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

/// A Raindrop bookmark collection, as returned by
/// `GET https://api.raindrop.io/rest/v1/collections`.
struct RaindropCollection: Codable, Equatable, Identifiable {
    let id: Int
    let title: String

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case title
    }
}
