import CryptoKit
import Foundation

// Receiver-side building blocks shared by the iPhone app and its tests. They
// reuse the pairing, key agreement, AES-GCM channel and ledger from
// NearbySyncNative; nothing here defines new protocol messages.

extension PairingQR {
    /// Splits the sender-supplied "host:port" endpoint. Only the last colon
    /// separates the port, so the host is returned verbatim.
    public func hostAndPort() throws -> (host: String, port: UInt16) {
        guard let colon = endpoint.lastIndex(of: ":") else { throw NearbySyncError.malformedPacket }
        let host = String(endpoint[endpoint.startIndex ..< colon])
        guard !host.isEmpty, let port = UInt16(endpoint[endpoint.index(after: colon)...]), port > 0 else {
            throw NearbySyncError.malformedPacket
        }
        return (host, port)
    }
}

/// One receiver-side pairing attempt. `approve` is the explicit approval step:
/// until it is called nothing is persisted and no key is derived.
public struct ReceiverPairingSession: Sendable {
    public let qr: PairingQR
    public let receiverID: String

    public init(qr: PairingQR, receiverID: String) throws {
        guard qr.version == 1 else { throw NearbySyncError.malformedPacket }
        guard qr.expiresAt > Date() else { throw NearbySyncError.pairingExpired }
        guard !receiverID.isEmpty else { throw NearbySyncError.invalidState("Receiver ID must not be empty.") }
        self.qr = qr
        self.receiverID = receiverID
    }

    public init(uri: String, receiverID: String) throws {
        try self.init(qr: PairingQR.fromURI(uri.trimmingCharacters(in: .whitespacesAndNewlines)), receiverID: receiverID)
    }

    /// Persists the sender as trusted and returns the public-key-only request
    /// to hand to the sender. The request contains no QR secret or private key.
    public func approve(trustStore: TrustStore) throws -> (peer: TrustedPeer, request: ReceiverPairingRequest) {
        let identity = DeviceIdentity(id: receiverID)
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        let authority = PairingAuthority(identity: identity, trustStore: trustStore)
        let peer = try authority.pairAsReceiver(qr: qr, receiver: identity, receiverAgreementPrivateKey: agreement, senderAgreementPublicKey: qr.senderAgreementPublicKey, explicitlyApproved: true)
        let request = ReceiverPairingRequest(sessionID: qr.sessionID, receiverID: receiverID, receiverSigningPublicKey: identity.signingKey.publicKey.rawRepresentation, receiverAgreementPublicKey: agreement.publicKey.rawRepresentation)
        return (peer, request)
    }
}

public struct ReceiveProgress: Sendable, Equatable {
    public let receivedChunks: Int
    public let totalChunks: Int
}

public enum EpisodeReceiver {
    public static let maxEpisodeBytes = 4 * 1_024 * 1_024 * 1_024
    /// The frame limit is 2,000,000 bytes including AES-GCM overhead.
    public static let maxChunkBytes = 1_900_000
    public static let ledgerName = "ledger.json"
    public static let partialName = "episode.partial"

    /// Peer-supplied identifiers become file names, so only a conservative
    /// character set is accepted.
    public static func safeFileName(for episodeID: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !episodeID.isEmpty, episodeID.count <= 100, !episodeID.hasPrefix("."),
              episodeID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw NearbySyncError.invalidState("The offered episode ID is not a safe file name.")
        }
        return episodeID + ".m4a"
    }

    /// Chunks already acknowledged by a persisted ledger, if any.
    public static func savedProgress(stagingDirectory: URL) -> ReceiveProgress? {
        guard let data = try? Data(contentsOf: stagingDirectory.appendingPathComponent(ledgerName)),
              let ledger = try? JSONDecoder().decode(TransferLedger.self, from: data) else { return nil }
        return ReceiveProgress(receivedChunks: ledger.receivedChunks.count, totalChunks: ledger.manifest.chunkSHA256.count)
    }

    public static func discardStaging(_ stagingDirectory: URL) {
        try? FileManager.default.removeItem(at: stagingDirectory.appendingPathComponent(ledgerName))
        try? FileManager.default.removeItem(at: stagingDirectory.appendingPathComponent(partialName))
    }

    /// Blocking. Pulls the manifest and any chunks missing from the persisted
    /// ledger, persists the ledger after every acknowledged chunk, and moves
    /// the staged file into `libraryDirectory` only after the whole-file
    /// SHA-256 check passes. Safe to call again after any failure.
    @discardableResult
    public static func receive(
        peer: TrustedPeer,
        host: String,
        port: UInt16,
        stagingDirectory: URL,
        libraryDirectory: URL,
        requestTimeout: TimeInterval = 60,
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (ReceiveProgress) -> Void = { _ in }
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)

        let manifestData = try EncryptedLocalChannel.request(host: .init(host), port: port, keyData: peer.channelKey, payload: Data("manifest".utf8), timeout: 30)
        if let text = String(data: manifestData, encoding: .utf8), text.hasPrefix("error:") {
            throw NearbySyncError.invalidState("Sender refused the manifest request.")
        }
        let manifest: EpisodeManifest
        do {
            let decoded = try JSONDecoder().decode(EpisodeManifest.self, from: manifestData)
            // Re-run the validating initializer on peer-supplied data.
            manifest = try EpisodeManifest(episodeID: decoded.episodeID, sizeBytes: decoded.sizeBytes, sha256Hex: decoded.sha256Hex, chunkSize: decoded.chunkSize, chunkSHA256: decoded.chunkSHA256)
        } catch let error as NearbySyncError { throw error } catch { throw NearbySyncError.malformedPacket }
        guard manifest.sizeBytes <= maxEpisodeBytes, manifest.chunkSize <= maxChunkBytes else {
            throw NearbySyncError.invalidState("The offered episode is larger than this receiver accepts.")
        }
        let finalURL = libraryDirectory.appendingPathComponent(try safeFileName(for: manifest.episodeID))

        // Idempotent retry: an already-verified identical episode is not duplicated.
        if fm.fileExists(atPath: finalURL.path), (try? sha256(of: finalURL)) == manifest.sha256Hex {
            discardStaging(stagingDirectory)
            progress(ReceiveProgress(receivedChunks: manifest.chunkSHA256.count, totalChunks: manifest.chunkSHA256.count))
            return finalURL
        }

        let ledgerURL = stagingDirectory.appendingPathComponent(ledgerName)
        let partial = stagingDirectory.appendingPathComponent(partialName)
        var ledger: TransferLedger
        if let saved = try? Data(contentsOf: ledgerURL), fm.fileExists(atPath: partial.path) {
            let decoded = try JSONDecoder().decode(TransferLedger.self, from: saved)
            guard decoded.manifest == manifest else { throw NearbySyncError.manifestMismatch }
            // Re-validate the saved indices against the manifest.
            ledger = try TransferLedger(manifest: manifest, receivedChunks: decoded.receivedChunks)
        } else {
            discardStaging(stagingDirectory)
            ledger = try TransferLedger(manifest: manifest)
            fm.createFile(atPath: partial.path, contents: nil)
        }
        let target = try FileHandle(forUpdating: partial)
        defer { try? target.close() }
        try target.truncate(atOffset: UInt64(manifest.sizeBytes))
        let total = manifest.chunkSHA256.count
        progress(ReceiveProgress(receivedChunks: ledger.receivedChunks.count, totalChunks: total))

        for index in ledger.missingIndices {
            if isCancelled() { throw CancellationError() }
            let chunk = try EncryptedLocalChannel.request(host: .init(host), port: port, keyData: peer.channelKey, payload: Data("chunk:\(index)".utf8), timeout: requestTimeout)
            // Verify before writing so a bad chunk never reaches the staging file.
            var probe = ledger
            _ = try probe.record(index: index, payload: chunk)
            try target.seek(toOffset: UInt64(index * manifest.chunkSize))
            try target.write(contentsOf: chunk)
            try target.synchronize()
            ledger = probe
            try JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
            progress(ReceiveProgress(receivedChunks: ledger.receivedChunks.count, totalChunks: total))
        }

        try ledger.verify(assembled: partial)
        if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
        try fm.moveItem(at: partial, to: finalURL)
        try? fm.removeItem(at: ledgerURL)
        return finalURL
    }
}
