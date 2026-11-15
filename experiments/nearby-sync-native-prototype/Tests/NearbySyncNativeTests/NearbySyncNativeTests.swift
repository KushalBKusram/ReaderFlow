import CryptoKit
import Foundation
import XCTest
@testable import NearbySyncNative

final class NearbySyncNativeTests: XCTestCase {
    func testManifestAndLedgerMatchCommittedSemantics() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("episode.m4a")
        try Data(repeating: 0x41, count: 100).write(to: media)
        let manifest = try buildManifest(source: media, episodeID: "episode-123", chunkSize: 17)
        var ledger = try TransferLedger(manifest: manifest)
        let bytes = try Data(contentsOf: media)
        for index in manifest.chunkSHA256.indices {
            let start = index * 17; let end = min(start + 17, bytes.count)
            XCTAssertTrue(try ledger.record(index: index, payload: bytes.subdata(in: start ..< end)))
        }
        try ledger.verify(assembled: media)
    }

    func testPairingRequiresApprovalAndRevocationRemovesTrust() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = DeviceIdentity(id: "sender"), receiver = DeviceIdentity(id: "receiver")
        let store = try TrustStore(url: root.appendingPathComponent("trust.json"))
        let authority = PairingAuthority(identity: sender, trustStore: store)
        let qr = authority.begin(endpoint: "192.168.1.1:8443")
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try authority.approvePairing(qr: qr, receiver: receiver, receiverAgreementPublicKey: agreement.publicKey.rawRepresentation, explicitlyApproved: false))
        let senderPeer = try authority.approvePairing(qr: qr, receiver: receiver, receiverAgreementPublicKey: agreement.publicKey.rawRepresentation, explicitlyApproved: true)
        let qr2 = authority.begin(endpoint: "192.168.1.1:8443")
        let receiverAgreement = Curve25519.KeyAgreement.PrivateKey()
        let approved = try authority.approvePairing(qr: qr2, receiver: receiver, receiverAgreementPublicKey: receiverAgreement.publicKey.rawRepresentation, explicitlyApproved: true)
        let receiverPeer = try authority.pairAsReceiver(qr: qr2, receiver: receiver, receiverAgreementPrivateKey: receiverAgreement, senderAgreementPublicKey: qr2.senderAgreementPublicKey, explicitlyApproved: true)
        XCTAssertEqual(senderPeer.peerID, receiver.id)
        XCTAssertEqual(approved.channelKey, receiverPeer.channelKey)
        XCTAssertNotNil(store.peer(receiver.id))
        try store.revoke(receiver.id)
        XCTAssertNil(store.peer(receiver.id))
    }

    func testPublicReceiverRequestCompletesSenderApprovalWithoutQRSecret() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = DeviceIdentity(id: "sender")
        let receiver = DeviceIdentity(id: "receiver")
        let senderAuthority = PairingAuthority(identity: sender, trustStore: try TrustStore(url: root.appendingPathComponent("sender.json")))
        let receiverAuthority = PairingAuthority(identity: receiver, trustStore: try TrustStore(url: root.appendingPathComponent("receiver.json")))
        let qr = senderAuthority.begin(endpoint: "192.168.1.1:8443")
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        let receiverPeer = try receiverAuthority.pairAsReceiver(qr: qr, receiver: receiver, receiverAgreementPrivateKey: agreement, senderAgreementPublicKey: qr.senderAgreementPublicKey, explicitlyApproved: true)
        let request = ReceiverPairingRequest(sessionID: qr.sessionID, receiverID: receiver.id, receiverSigningPublicKey: receiver.signingKey.publicKey.rawRepresentation, receiverAgreementPublicKey: agreement.publicKey.rawRepresentation)
        let senderPeer = try senderAuthority.approvePairing(request: request, explicitlyApproved: true)
        XCTAssertEqual(senderPeer.channelKey, receiverPeer.channelKey)
        let serialized = try JSONEncoder().encode(request)
        XCTAssertFalse(serialized.contains(qr.secret))
    }

    // MARK: Receiver

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var chunks: [Int] = []
        func add(_ i: Int) { lock.withLock { chunks.append(i) } }
        var all: [Int] { lock.withLock { chunks } }
    }

    private func tempRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSender(media: Data, root: URL, key: Data, counter: Counter, corruptIndex: Int? = nil, episodeID: String = "episode-1") throws -> (EncryptedLocalChannel, EpisodeManifest) {
        let source = root.appendingPathComponent("source.bin")
        try media.write(to: source)
        let manifest = try buildManifest(source: source, episodeID: episodeID, chunkSize: 1024)
        let channel = try EncryptedLocalChannel(port: .any, keyData: key) { request in
            if request == Data("manifest".utf8) { return try JSONEncoder().encode(manifest) }
            let text = String(decoding: request, as: UTF8.self)
            guard text.hasPrefix("chunk:"), let index = Int(text.dropFirst(6)), manifest.chunkSHA256.indices.contains(index) else { throw NearbySyncError.malformedPacket }
            counter.add(index)
            var chunk = media.subdata(in: index * 1024 ..< min((index + 1) * 1024, media.count))
            if index == corruptIndex { chunk[0] ^= 0xFF }
            return chunk
        }
        channel.start()
        while !channel.isReady { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return (channel, manifest)
    }

    private func pairedPeer(root: URL) throws -> TrustedPeer {
        let senderAuthority = PairingAuthority(identity: DeviceIdentity(id: "sender"), trustStore: try TrustStore(url: root.appendingPathComponent("sender-trust.json")))
        let qr = senderAuthority.begin(endpoint: "127.0.0.1:1")
        let session = try ReceiverPairingSession(uri: try qr.uri(), receiverID: "iphone")
        let (peer, request) = try session.approve(trustStore: try TrustStore(url: root.appendingPathComponent("receiver-trust.json")))
        let senderPeer = try senderAuthority.approvePairing(request: request, explicitlyApproved: true)
        XCTAssertEqual(peer.channelKey, senderPeer.channelKey)
        return peer
    }

    func testReceiverPairingFromURIDerivesSenderKeyAndRejectsExpiredQR() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try pairedPeer(root: root)
        let authority = PairingAuthority(identity: DeviceIdentity(id: "s"), trustStore: try TrustStore(url: root.appendingPathComponent("x.json")))
        let expired = PairingQR(endpoint: "10.0.0.2:8443", expiresAt: Date().addingTimeInterval(-1), secret: Data(repeating: 1, count: 32), senderSigningPublicKey: Data(repeating: 2, count: 32), senderAgreementPublicKey: Data(repeating: 3, count: 32))
        XCTAssertThrowsError(try ReceiverPairingSession(qr: expired, receiverID: "iphone")) { XCTAssertEqual($0 as? NearbySyncError, .pairingExpired) }
        XCTAssertThrowsError(try ReceiverPairingSession(uri: "not a qr", receiverID: "iphone"))
        let fresh = authority.begin(endpoint: "10.0.0.2:8443")
        XCTAssertEqual(try fresh.hostAndPort().host, "10.0.0.2")
        XCTAssertEqual(try fresh.hostAndPort().port, 8443)
        let bad = PairingQR(endpoint: "10.0.0.2", expiresAt: Date().addingTimeInterval(60), secret: Data(), senderSigningPublicKey: Data(), senderAgreementPublicKey: Data())
        XCTAssertThrowsError(try bad.hostAndPort())
    }

    func testReceiveVerifiesAndExposesOnlyAfterDigestCheck() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let peer = try pairedPeer(root: root)
        let media = Data((0 ..< 10_500).map { UInt8($0 % 251) })
        let (channel, manifest) = try makeSender(media: media, root: root, key: peer.channelKey, counter: Counter())
        defer { channel.cancel() }
        let staging = root.appendingPathComponent("staging"), library = root.appendingPathComponent("library")
        let final = try EpisodeReceiver.receive(peer: peer, host: "127.0.0.1", port: channel.port!, stagingDirectory: staging, libraryDirectory: library)
        XCTAssertEqual(try sha256(of: final), manifest.sha256Hex)
        XCTAssertEqual(try Data(contentsOf: final), media)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent(EpisodeReceiver.partialName).path))
        XCTAssertNil(EpisodeReceiver.savedProgress(stagingDirectory: staging))
        // Retrying after completion does not duplicate or refetch.
        let again = try EpisodeReceiver.receive(peer: peer, host: "127.0.0.1", port: channel.port!, stagingDirectory: staging, libraryDirectory: library)
        XCTAssertEqual(again, final)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path).count, 1)
    }

    func testInterruptedReceiveResumesOnlyMissingChunks() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let peer = try pairedPeer(root: root)
        let media = Data((0 ..< 10_500).map { UInt8($0 % 241) })
        let counter = Counter()
        let (channel, manifest) = try makeSender(media: media, root: root, key: peer.channelKey, counter: counter)
        defer { channel.cancel() }
        let staging = root.appendingPathComponent("staging"), library = root.appendingPathComponent("library")
        let acknowledged = Counter()
        XCTAssertThrowsError(try EpisodeReceiver.receive(peer: peer, host: "127.0.0.1", port: channel.port!, stagingDirectory: staging, libraryDirectory: library, isCancelled: { (acknowledged.all.last ?? 0) >= 4 }, progress: { acknowledged.add($0.receivedChunks) })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(EpisodeReceiver.savedProgress(stagingDirectory: staging)?.receivedChunks, 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path).count, 0)
        let before = counter.all.count
        let final = try EpisodeReceiver.receive(peer: peer, host: "127.0.0.1", port: channel.port!, stagingDirectory: staging, libraryDirectory: library)
        XCTAssertEqual(counter.all.count - before, manifest.chunkSHA256.count - 4)
        XCTAssertEqual(Set(counter.all.dropFirst(before)), Set(4 ..< manifest.chunkSHA256.count))
        XCTAssertEqual(try sha256(of: final), manifest.sha256Hex)
    }

    func testCorruptChunkNeverReachesLibraryOrLedger() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let peer = try pairedPeer(root: root)
        let media = Data(repeating: 7, count: 5_000)
        let (channel, _) = try makeSender(media: media, root: root, key: peer.channelKey, counter: Counter(), corruptIndex: 2)
        defer { channel.cancel() }
        let staging = root.appendingPathComponent("staging"), library = root.appendingPathComponent("library")
        XCTAssertThrowsError(try EpisodeReceiver.receive(peer: peer, host: "127.0.0.1", port: channel.port!, stagingDirectory: staging, libraryDirectory: library)) { XCTAssertEqual($0 as? NearbySyncError, .chunkMismatch(2)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path).count, 0)
        XCTAssertEqual(EpisodeReceiver.savedProgress(stagingDirectory: staging)?.receivedChunks, 2)
    }

    func testUnsafeEpisodeIDsAndWrongKeyAreRejected() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let peer = try pairedPeer(root: root)
        XCTAssertThrowsError(try EpisodeReceiver.safeFileName(for: "../evil"))
        XCTAssertThrowsError(try EpisodeReceiver.safeFileName(for: ".hidden"))
        XCTAssertEqual(try EpisodeReceiver.safeFileName(for: "ep-1.v2"), "ep-1.v2.m4a")
        let (channel, _) = try makeSender(media: Data(repeating: 1, count: 100), root: root, key: peer.channelKey, counter: Counter(), episodeID: "a/b")
        defer { channel.cancel() }
        XCTAssertThrowsError(try EpisodeReceiver.receive(peer: peer, host: "127.0.0.1", port: channel.port!, stagingDirectory: root.appendingPathComponent("s"), libraryDirectory: root.appendingPathComponent("l")))
        // A revoked-then-re-paired (different) key cannot talk to the old sender.
        let other = TrustedPeer(peerID: "x", signingPublicKey: Data(), channelKey: Data(repeating: 9, count: 32), pairedAt: Date())
        XCTAssertThrowsError(try EpisodeReceiver.receive(peer: other, host: "127.0.0.1", port: channel.port!, stagingDirectory: root.appendingPathComponent("s"), libraryDirectory: root.appendingPathComponent("l")))
    }
}
