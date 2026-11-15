import AppKit
import AuthenticationServices
import Foundation

/// Drives Raindrop's consumer OAuth authorization-code flow and exchanges
/// the resulting code for tokens through a minimal relay.
///
/// Raindrop's token endpoint requires `client_secret` in both the
/// authorization-code exchange and the refresh request
/// (https://developer.raindrop.io/v1/authentication/token) and documents no
/// PKCE alternative. A secret bundled in a distributed desktop app is not
/// protected, so this client never holds or sends one — it only builds the
/// browser-facing authorize URL (client_id is not secret; it is visible in
/// that URL to any user) and hands the resulting code to the relay described
/// in `docs/architecture.md` ("Minimal OAuth relay") and implemented in
/// `relay/`. See `docs/findings.md`.
@MainActor
final class RaindropOAuthClient: NSObject {
    /// `relay`: distribution path — the secret lives only on the relay.
    /// `direct`: personal mode — the user's own secret, read from Keychain,
    /// sent straight to Raindrop. Not for builds shipped to other people.
    enum TokenExchange {
        case relay(URL)
        case direct(clientSecret: String)
    }

    struct Configuration {
        var clientID: String
        var tokenExchange: TokenExchange
        var redirectURLScheme: String = "readerflow"

        var redirectURI: String { "\(redirectURLScheme)://oauth/raindrop" }
    }

    enum OAuthError: Error, LocalizedError {
        case missingCode
        case cancelled
        case relay(status: Int, body: String)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .missingCode: "Raindrop did not return an authorization code."
            case .cancelled: "Raindrop sign-in was cancelled."
            case .relay(let status, let body): "The token relay returned \(status): \(body)"
            case .transport(let error): error.localizedDescription
            }
        }
    }

    private let configuration: Configuration
    private var activeSession: ASWebAuthenticationSession?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    @MainActor
    func signIn() async throws -> RaindropTokenResponse {
        let code = try await authorize()
        return try await exchange(code: code)
    }

    func refresh(_ refreshToken: String) async throws -> RaindropTokenResponse {
        try await send(relayPath: "raindrop/refresh", grant: ["grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    private func authorizationURL() throws -> URL {
        var components = URLComponents(string: "https://raindrop.io/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code")
        ]
        guard let url = components.url else { throw OAuthError.missingCode }
        return url
    }

    @MainActor
    private func authorize() async throws -> String {
        let authorizeURL = try authorizationURL()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: configuration.redirectURLScheme
            ) { callbackURL, error in
                if let error {
                    if case ASWebAuthenticationSessionError.canceledLogin = error {
                        continuation.resume(throwing: OAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: OAuthError.transport(error))
                    }
                    return
                }
                guard
                    let callbackURL,
                    let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    continuation.resume(throwing: OAuthError.missingCode)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            session.start()
        }
    }

    private func exchange(code: String) async throws -> RaindropTokenResponse {
        try await send(relayPath: "raindrop/token", grant: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": configuration.redirectURI
        ])
    }

    private func send(relayPath: String, grant: [String: String]) async throws -> RaindropTokenResponse {
        let url: URL
        var body = grant
        switch configuration.tokenExchange {
        case .relay(let base):
            url = base.appendingPathComponent(relayPath)
        case .direct(let secret):
            url = URL(string: "https://raindrop.io/oauth/access_token")!
            body["client_id"] = configuration.clientID
            body["client_secret"] = secret
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw OAuthError.relay(status: status, body: String(data: data, encoding: .utf8) ?? "")
            }
            return try JSONDecoder().decode(RaindropTokenResponse.self, from: data)
        } catch let error as OAuthError {
            throw error
        } catch {
            throw OAuthError.transport(error)
        }
    }
}

extension RaindropOAuthClient: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
