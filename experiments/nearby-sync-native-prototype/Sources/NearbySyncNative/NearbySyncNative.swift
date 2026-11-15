import CryptoKit
import Foundation
@preconcurrency import Network

public enum NearbySyncError: Error, LocalizedError, Equatable {
    case pairingExpired
    case pairingSecretMismatch
    case pairingNotApproved
    case peerRevoked
    case malformedPacket
    case authenticationFailed
    case manifestMismatch
    case chunkMismatch(Int)
    case incompleteTransfer
    case finalDigestMismatch
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .pairingExpired: "The pairing QR has expired. Start a new pairing session."
        case .pairingSecretMismatch: "The pairing QR is not valid for this session."
        case .pairingNotApproved: "Both Macs must explicitly approve pairing."
        case .peerRevoked: "This peer was revoked and must pair again."
        case .malformedPacket: "Received malformed Nearby Sync data."
        case .authenticationFailed: "The encrypted channel could not be authenticated."
        case .manifestMismatch: "The offered episode does not match the committed manifest."
        case let .chunkMismatch(index): "Chunk \(index) does not match the committed manifest."
        case .incompleteTransfer: "The transfer is incomplete."
        case .finalDigestMismatch: "The completed episode does not match its SHA-256 digest."
        case let .invalidState(message): message
        }
    }
}

public struct EpisodeManifest: Codable, Sendable, Equatable {
    public let episodeID: String
    public let sizeBytes: Int
    public let sha256Hex: String
    public let chunkSize: Int
    public let chunkSHA256: [String]

    enum CodingKeys: String, CodingKey {
        case episodeID = "episode_id"
        case sizeBytes = "size_bytes"
        case sha256Hex = "sha256_hex"
        case chunkSize = "chunk_size"
        case chunkSHA256 = "chunk_sha256"
    }

    public init(episodeID: String, sizeBytes: Int, sha256Hex: String, chunkSize: Int, chunkSHA256: [String]) throws {
        guard !episodeID.isEmpty, sizeBytes >= 0, chunkSize > 0 else {
            throw NearbySyncError.invalidState("Manifest has an invalid identifier, size, or chunk size.")
        }
        let expected = sizeBytes == 0 ? 0 : Int(ceil(Double(sizeBytes) / Double(chunkSize)))
        guard expected == chunkSHA256.count, Self.isDigest(sha256Hex), chunkSHA256.allSatisfy(Self.isDigest) else {
            throw NearbySyncError.invalidState("Manifest hashes do not match its declared size.")
        }
        self.episodeID = episodeID
        self.sizeBytes = sizeBytes
        self.sha256Hex = sha256Hex
        self.chunkSize = chunkSize
        self.chunkSHA256 = chunkSHA256
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}

public func buildManifest(source: URL, episodeID: String, chunkSize: Int = 1_048_576) throws -> EpisodeManifest {
    guard chunkSize > 0 else { throw NearbySyncError.invalidState("Chunk size must be positive.") }
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }
    var whole = SHA256()
    var hashes: [String] = []
    var size = 0
    while true {
        let chunk = try handle.read(upToCount: chunkSize) ?? Data()
        if chunk.isEmpty { break }
        whole.update(data: chunk)
        hashes.append(SHA256.hash(data: chunk).hexString)
        size += chunk.count
    }
    return try EpisodeManifest(episodeID: episodeID, sizeBytes: size, sha256Hex: whole.finalize().hexString, chunkSize: chunkSize, chunkSHA256: hashes)
}

public struct TransferLedger: Codable, Sendable {
    public let manifest: EpisodeManifest
    public private(set) var receivedChunks: Set<Int>

    enum CodingKeys: String, CodingKey { case manifest; case receivedChunks = "received_chunks" }

    public init(manifest: EpisodeManifest, receivedChunks: Set<Int> = []) throws {
        guard receivedChunks.allSatisfy({ $0 >= 0 && $0 < manifest.chunkSHA256.count }) else {
            throw NearbySyncError.invalidState("Saved ledger contains an invalid chunk index.")
        }
        self.manifest = manifest
        self.receivedChunks = receivedChunks
    }

    public var missingIndices: [Int] { (0 ..< manifest.chunkSHA256.count).filter { !receivedChunks.contains($0) } }
    public var isComplete: Bool { receivedChunks.count == manifest.chunkSHA256.count }

    @discardableResult
    public mutating func record(index: Int, payload: Data) throws -> Bool {
        guard index >= 0 && index < manifest.chunkSHA256.count else { throw NearbySyncError.chunkMismatch(index) }
        guard SHA256.hash(data: payload).hexString == manifest.chunkSHA256[index] else { throw NearbySyncError.chunkMismatch(index) }
        return receivedChunks.insert(index).inserted
    }

    public func verify(assembled: URL) throws {
        guard isComplete else { throw NearbySyncError.incompleteTransfer }
        let attributes = try FileManager.default.attributesOfItem(atPath: assembled.path)
        guard attributes[.size] as? Int == manifest.sizeBytes else { throw NearbySyncError.finalDigestMismatch }
        let actual = try sha256(of: assembled)
        guard actual == manifest.sha256Hex else { throw NearbySyncError.finalDigestMismatch }
    }
}

public struct PairingQR: Codable, Sendable {
    public let version: Int
    public let endpoint: String
    public let sessionID: String
    public let expiresAt: Date
    public let secret: Data
    public let senderSigningPublicKey: Data
    public let senderAgreementPublicKey: Data

    public init(endpoint: String, sessionID: String = UUID().uuidString, expiresAt: Date, secret: Data, senderSigningPublicKey: Data, senderAgreementPublicKey: Data) {
        self.version = 1
        self.endpoint = endpoint
        self.sessionID = sessionID
        self.expiresAt = expiresAt
        self.secret = secret
        self.senderSigningPublicKey = senderSigningPublicKey
        self.senderAgreementPublicKey = senderAgreementPublicKey
    }

    public func uri() throws -> String {
        let data = try JSONEncoder().encode(self)
        return "readerflow-nearby://pair/" + data.base64URLEncodedString()
    }

    public static func fromURI(_ value: String) throws -> PairingQR {
        guard let encoded = value.split(separator: "/").last, let data = Data(base64URLEncoded: String(encoded)) else {
            throw NearbySyncError.malformedPacket
        }
        return try JSONDecoder().decode(PairingQR.self, from: data)
    }
}

public struct TrustedPeer: Codable, Sendable, Equatable {
    public let peerID: String
    public let signingPublicKey: Data
    public let channelKey: Data
    public let pairedAt: Date
}

/// Public data returned by a receiver after it has scanned a QR payload and
/// explicitly approved the displayed sender. It intentionally carries no QR
/// secret, private key, media, or source text.
public struct ReceiverPairingRequest: Codable, Sendable {
    public let sessionID: String
    public let receiverID: String
    public let receiverSigningPublicKey: Data
    public let receiverAgreementPublicKey: Data

    public init(sessionID: String, receiverID: String, receiverSigningPublicKey: Data, receiverAgreementPublicKey: Data) {
        self.sessionID = sessionID
        self.receiverID = receiverID
        self.receiverSigningPublicKey = receiverSigningPublicKey
        self.receiverAgreementPublicKey = receiverAgreementPublicKey
    }
}

public final class TrustStore: @unchecked Sendable {
    private let url: URL
    private var peers: [String: TrustedPeer]
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            self.peers = try JSONDecoder().decode([String: TrustedPeer].self, from: data)
        } else { self.peers = [:] }
    }

    public func peer(_ id: String) -> TrustedPeer? { lock.withLock { peers[id] } }
    public func all() -> [TrustedPeer] { lock.withLock { Array(peers.values) } }
    public func save(_ peer: TrustedPeer) throws { try lock.withLock { peers[peer.peerID] = peer; try persist() } }
    public func revoke(_ id: String) throws { try lock.withLock { peers.removeValue(forKey: id); try persist() } }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(peers)
        try data.write(to: url, options: .atomic)
    }
}

public struct DeviceIdentity: Sendable {
    public let id: String
    public let signingKey: Curve25519.Signing.PrivateKey
    public init(id: String = UUID().uuidString) { self.id = id; self.signingKey = Curve25519.Signing.PrivateKey() }
}

public final class PairingAuthority: @unchecked Sendable {
    public let identity: DeviceIdentity
    private let trustStore: TrustStore
    private let lock = NSLock()
    private var sessions: [String: PairingQR] = [:]
    private var sessionKeys: [String: Curve25519.KeyAgreement.PrivateKey] = [:]

    public init(identity: DeviceIdentity, trustStore: TrustStore) { self.identity = identity; self.trustStore = trustStore }

    public func begin(endpoint: String, ttl: TimeInterval = 120) -> PairingQR {
        let secret = Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) })
        let key = Curve25519.KeyAgreement.PrivateKey()
        let qr = PairingQR(endpoint: endpoint, expiresAt: Date().addingTimeInterval(ttl), secret: secret, senderSigningPublicKey: identity.signingKey.publicKey.rawRepresentation, senderAgreementPublicKey: key.publicKey.rawRepresentation)
        lock.withLock { sessions[qr.sessionID] = qr; sessionKeys[qr.sessionID] = key }
        return qr
    }

    public func approvePairing(qr: PairingQR, receiver: DeviceIdentity, receiverAgreementPublicKey: Data, explicitlyApproved: Bool) throws -> TrustedPeer {
        guard explicitlyApproved else { throw NearbySyncError.pairingNotApproved }
        let pair: (PairingQR, Curve25519.KeyAgreement.PrivateKey)? = lock.withLock {
            guard let saved = sessions[qr.sessionID], let key = sessionKeys[qr.sessionID] else { return nil }
            return (saved, key)
        }
        guard let pair, pair.0.expiresAt > Date(), pair.0.secret == qr.secret else { throw NearbySyncError.pairingExpired }
        let (saved, agreement) = pair
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: receiverAgreementPublicKey)
        let shared = try agreement.sharedSecretFromKeyAgreement(with: remote)
        let material = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: saved.secret, sharedInfo: Data("readerflow-nearby-v1".utf8), outputByteCount: 32)
        let peer = TrustedPeer(peerID: receiver.id, signingPublicKey: receiver.signingKey.publicKey.rawRepresentation, channelKey: material.withUnsafeBytes { Data($0) }, pairedAt: Date())
        try trustStore.save(peer)
        lock.withLock { sessions.removeValue(forKey: qr.sessionID); sessionKeys.removeValue(forKey: qr.sessionID) }
        return peer
    }

    /// Sender-side approval for the two-Mac CLI. The sender retains the QR
    /// session and its private agreement key, so the receiver does not have to
    /// send the QR secret back over a terminal, file, or network request.
    public func approvePairing(request: ReceiverPairingRequest, explicitlyApproved: Bool) throws -> TrustedPeer {
        guard explicitlyApproved else { throw NearbySyncError.pairingNotApproved }
        let pair: (PairingQR, Curve25519.KeyAgreement.PrivateKey)? = lock.withLock {
            guard let saved = sessions[request.sessionID], let key = sessionKeys[request.sessionID] else { return nil }
            return (saved, key)
        }
        guard let (qr, agreement) = pair, qr.expiresAt > Date() else { throw NearbySyncError.pairingExpired }
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.receiverAgreementPublicKey)
        let shared = try agreement.sharedSecretFromKeyAgreement(with: remote)
        let material = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: qr.secret, sharedInfo: Data("readerflow-nearby-v1".utf8), outputByteCount: 32)
        let peer = TrustedPeer(peerID: request.receiverID, signingPublicKey: request.receiverSigningPublicKey, channelKey: material.withUnsafeBytes { Data($0) }, pairedAt: Date())
        try trustStore.save(peer)
        lock.withLock { sessions.removeValue(forKey: request.sessionID); sessionKeys.removeValue(forKey: request.sessionID) }
        return peer
    }

    /// The receiver creates and retains this agreement key while the approval
    /// screen is visible.  It is deliberately passed back here so both peers
    /// derive the same key; generating a second key after approval would make
    /// the encrypted channel unusable.
    public func pairAsReceiver(qr: PairingQR, receiver: DeviceIdentity, receiverAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey, senderAgreementPublicKey: Data, explicitlyApproved: Bool) throws -> TrustedPeer {
        guard explicitlyApproved, qr.expiresAt > Date() else { throw NearbySyncError.pairingNotApproved }
        let sender = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderAgreementPublicKey)
        let shared = try receiverAgreementPrivateKey.sharedSecretFromKeyAgreement(with: sender)
        let material = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: qr.secret, sharedInfo: Data("readerflow-nearby-v1".utf8), outputByteCount: 32)
        let peer = TrustedPeer(peerID: "sender-" + SHA256.hash(data: qr.senderSigningPublicKey).hexString.prefix(16), signingPublicKey: qr.senderSigningPublicKey, channelKey: material.withUnsafeBytes { Data($0) }, pairedAt: Date())
        try trustStore.save(peer)
        return peer
    }
}

// Framed local-network transport. Every application message is AES-GCM sealed
// with a key established by explicit QR pairing. `Network` supplies local Wi-Fi
// transport; TLS is deliberately not relied on for peer identity here.
public final class EncryptedLocalChannel: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) throws -> Data
    private let listener: NWListener
    private let key: SymmetricKey
    private let handler: Handler
    private let queue = DispatchQueue(label: "ReaderFlow.NearbySync.Native")
    private let readyLock = NSLock()
    private var ready = false

    public init(port: NWEndpoint.Port = .any, keyData: Data, handler: @escaping Handler) throws {
        guard keyData.count == 32 else { throw NearbySyncError.invalidState("Nearby Sync channel key must be 256 bits.") }
        self.listener = try NWListener(using: .tcp, on: port)
        self.key = SymmetricKey(data: keyData)
        self.handler = handler
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.readyLock.withLock { self?.ready = true } }
        }
    }

    public var port: UInt16? { listener.port.map { UInt16($0.rawValue) } }
    public var isReady: Bool { readyLock.withLock { ready } }
    public func start() { listener.start(queue: queue) }
    public func cancel() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveFrame(connection) { [weak self] result in
            guard let self else { return }
            let response: Data
            do {
                let sealed = try result.get()
                let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: self.key, authenticating: Data("readerflow-nearby-v1".utf8))
                let reply = try self.handler(plaintext)
                response = try AES.GCM.seal(reply, using: self.key, authenticating: Data("readerflow-nearby-v1".utf8)).combined!
            } catch {
                // Even errors stay inside the authenticated channel, so an
                // observer cannot use them as an oracle about transfer state.
                response = (try? AES.GCM.seal(Data("error:\(error.localizedDescription)".utf8), using: self.key, authenticating: Data("readerflow-nearby-v1".utf8)).combined) ?? Data()
            }
            self.sendFrame(connection, response) { connection.cancel() }
        }
    }

    public static func request(host: NWEndpoint.Host, port: UInt16, keyData: Data, payload: Data, timeout: TimeInterval = 15) throws -> Data {
        guard keyData.count == 32, let endpointPort = NWEndpoint.Port(rawValue: port) else { throw NearbySyncError.invalidState("Invalid encrypted channel endpoint.") }
        let connection = NWConnection(host: host, port: endpointPort, using: .tcp)
        let queue = DispatchQueue(label: "ReaderFlow.NearbySync.Client")
        let ready = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success else { connection.cancel(); throw NearbySyncError.invalidState("Timed out opening local channel.") }
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(payload, using: key, authenticating: Data("readerflow-nearby-v1".utf8)).combined!
        let sent = DispatchSemaphore(value: 0)
        sendFrame(connection, sealed) { _ in sent.signal() }
        guard sent.wait(timeout: .now() + timeout) == .success else { connection.cancel(); throw NearbySyncError.invalidState("Timed out sending encrypted data.") }
        let response = try receiveFrameSync(connection, timeout: timeout)
        connection.cancel()
        return try AES.GCM.open(AES.GCM.SealedBox(combined: response), using: key, authenticating: Data("readerflow-nearby-v1".utf8))
    }

    private func sendFrame(_ connection: NWConnection, _ body: Data, completion: @escaping @Sendable () -> Void) {
        Self.sendFrame(connection, body) { _ in completion() }
    }
    private static func sendFrame(_ connection: NWConnection, _ body: Data, completion: @escaping @Sendable (NWError?) -> Void) {
        var length = UInt32(body.count).bigEndian
        let header = Data(bytes: &length, count: 4)
        connection.send(content: header + body, completion: .contentProcessed(completion))
    }
    private func receiveFrame(_ connection: NWConnection, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        Self.receiveExactly(connection, count: 4) { header in
            switch header {
            case let .failure(error): completion(.failure(error))
            case let .success(data):
                let length = Self.frameLength(data)
                guard length > 0 && length <= 2_000_000 else { completion(.failure(NearbySyncError.malformedPacket)); return }
                Self.receiveExactly(connection, count: Int(length), completion: completion)
            }
        }
    }
    private static func receiveFrameSync(_ connection: NWConnection, timeout: TimeInterval) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedFrameResult()
        receiveExactly(connection, count: 4) { header in
            switch header {
            case let .failure(error): result.set(.failure(error)); semaphore.signal()
            case let .success(data):
                let length = frameLength(data)
                guard length > 0 && length <= 2_000_000 else { result.set(.failure(NearbySyncError.malformedPacket)); semaphore.signal(); return }
                receiveExactly(connection, count: Int(length)) { value in result.set(value); semaphore.signal() }
            }
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { throw NearbySyncError.invalidState("Timed out receiving encrypted data.") }
        guard let received = result.get() else { throw NearbySyncError.invalidState("Encrypted response did not contain a frame.") }
        return try received.get()
    }
    private static func receiveExactly(_ connection: NWConnection, count: Int, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        let accumulator = FrameAccumulator()
        @Sendable func next() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: count - accumulator.count) { data, _, complete, error in
                if let error { completion(.failure(error)); return }
                if let data { accumulator.append(data) }
                if accumulator.count == count { completion(.success(accumulator.data)) }
                else if complete { completion(.failure(NearbySyncError.malformedPacket)) }
                else { next() }
            }
        }
        next()
    }

    private static func frameLength(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

private final class LockedFrameResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Data, Error>?
    func set(_ result: Result<Data, Error>) { lock.withLock { value = result } }
    func get() -> Result<Data, Error>? { lock.withLock { value } }
}

private final class FrameAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    var count: Int { lock.withLock { value.count } }
    var data: Data { lock.withLock { value } }
    func append(_ data: Data) { lock.withLock { value.append(data) } }
}

public func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().hexString
}

private extension Digest { var hexString: String { map { String(format: "%02x", $0) }.joined() } }
private extension Data {
    func base64URLEncodedString() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URLEncoded value: String) { var v = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); v += String(repeating: "=", count: (4 - v.count % 4) % 4); self.init(base64Encoded: v) }
}
