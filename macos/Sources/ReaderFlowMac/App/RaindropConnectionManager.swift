import Foundation

/// Drives the Settings UI's Raindrop connection state.
///
/// Two token-exchange modes (see `RaindropOAuthClient.TokenExchange`):
/// personal mode when the user has stored their own client secret in the
/// Keychain, otherwise the relay when a relay URL is configured. The client
/// ID and relay URL are not secrets and live in `UserDefaults`.
@MainActor
final class RaindropConnectionManager: ObservableObject {
    enum State: Equatable {
        case notConfigured
        case disconnected
        case connecting
        case connected(collections: [RaindropCollection])
        case failed(String)
    }

    @Published private(set) var state: State = .notConfigured
    @Published private(set) var hasStoredSecret = RaindropClientSecretStore().load() != nil

    private let tokenStore = RaindropTokenStore()
    private let secretStore = RaindropClientSecretStore()
    private let raindropService = RaindropService()

    init() {
        refreshState()
    }

    func refreshState() {
        hasStoredSecret = secretStore.load() != nil
        guard RaindropConnectionSettings.oauthConfiguration() != nil else {
            state = .notConfigured
            return
        }
        state = tokenStore.load() == nil ? .disconnected : .connected(collections: [])
    }

    func saveClientSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try secretStore.save(trimmed)
            refreshState()
        } catch {
            state = .failed("Couldn't store the client secret in Keychain: \(error.localizedDescription)")
        }
    }

    func clearClientSecret() {
        secretStore.clear()
        refreshState()
    }

    func connect() async {
        guard let configuration = RaindropConnectionSettings.oauthConfiguration() else {
            state = .notConfigured
            return
        }
        state = .connecting
        do {
            let token = try await RaindropOAuthClient(configuration: configuration).signIn()
            try tokenStore.save(Self.stored(from: token))
            await loadCollections()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Re-reads collections using the stored token, refreshing it first if it
    /// is expired or about to be.
    func reloadCollections() async {
        guard tokenStore.load() != nil else { return }
        await loadCollections()
    }

    func disconnect() {
        tokenStore.clear()
        RaindropConnectionSettings.selectedCollectionID = nil
        state = .disconnected
    }

    private func loadCollections() async {
        do {
            let accessToken = try await freshAccessToken()
            let collections = try await raindropService.fetchCollections(accessToken: accessToken)
            state = .connected(collections: collections)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func freshAccessToken() async throws -> String {
        guard let stored = tokenStore.load() else { throw RaindropOAuthClient.OAuthError.missingCode }
        guard stored.expiresAt.timeIntervalSinceNow < 60 else { return stored.accessToken }
        guard let configuration = RaindropConnectionSettings.oauthConfiguration() else {
            throw RaindropOAuthClient.OAuthError.missingCode
        }
        let refreshed = try await RaindropOAuthClient(configuration: configuration).refresh(stored.refreshToken)
        let updated = Self.stored(from: refreshed)
        try tokenStore.save(updated)
        return updated.accessToken
    }

    private static func stored(from token: RaindropTokenResponse) -> RaindropTokenStore.StoredToken {
        .init(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn))
        )
    }
}

/// Where the user-entered, non-secret Raindrop app registration values live.
enum RaindropConnectionSettings {
    @MainActor static var clientID: String {
        get { UserDefaults.standard.string(forKey: "raindropClientID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "raindropClientID") }
    }

    @MainActor static var relayBaseURLString: String {
        get { UserDefaults.standard.string(forKey: "raindropRelayBaseURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "raindropRelayBaseURL") }
    }

    @MainActor static var selectedCollectionID: Int? {
        get { UserDefaults.standard.object(forKey: "raindropSelectedCollectionID") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "raindropSelectedCollectionID") }
    }

    @MainActor static func oauthConfiguration() -> RaindropOAuthClient.Configuration? {
        guard !clientID.isEmpty else { return nil }
        if let secret = RaindropClientSecretStore().load() {
            return .init(clientID: clientID, tokenExchange: .direct(clientSecret: secret))
        }
        if let relayURL = URL(string: relayBaseURLString), relayURL.scheme?.hasPrefix("http") == true {
            return .init(clientID: clientID, tokenExchange: .relay(relayURL))
        }
        return nil
    }
}
