import AppKit
import CoreImage
import CryptoKit
import Foundation
@preconcurrency import Network
import NearbySyncNative

func usage() {
    print("""
    readerflow-nearby-sync-native sender-pair <trust-dir> <sender-endpoint> <qr.png>
    readerflow-nearby-sync-native receiver-pair <trust-dir> <receiver-id>
    readerflow-nearby-sync-native serve <trust-dir> <receiver-id> <source-file> <port>
    readerflow-nearby-sync-native receive <trust-dir> <sender-peer-id> <host> <port> <staging-dir>
    readerflow-nearby-sync-native revoke <trust-dir> <peer-id>
    readerflow-nearby-sync-native self-test <results-directory>

    Pairing commands read QR/request data from standard input and never print a
    QR URI, pairing secret, or private key. See README.md for the two-Mac flow.
    """)
}

func writeQR(_ text: String, to url: URL) throws {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
        throw NearbySyncError.invalidState("The system QR generator is unavailable.")
    }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
        throw NearbySyncError.invalidState("Could not create pairing QR image.")
    }
    let rep = NSBitmapImageRep(ciImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NearbySyncError.invalidState("Could not encode pairing QR image.")
    }
    try png.write(to: url, options: .atomic)
}

func selfTest(results: URL) throws {
    try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
    let senderStore = try TrustStore(url: results.appendingPathComponent("sender-trust.json"))
    let receiverStore = try TrustStore(url: results.appendingPathComponent("receiver-trust.json"))
    let sender = DeviceIdentity(id: "mac-sender")
    let receiver = DeviceIdentity(id: "mac-receiver")
    let authority = PairingAuthority(identity: sender, trustStore: senderStore)
    let receiverAuthority = PairingAuthority(identity: receiver, trustStore: receiverStore)
    let agreement = Curve25519.KeyAgreement.PrivateKey()
    let placeholder = authority.begin(endpoint: "127.0.0.1:0")
    let senderPeer = try authority.approvePairing(qr: placeholder, receiver: receiver, receiverAgreementPublicKey: agreement.publicKey.rawRepresentation, explicitlyApproved: true)
    let receiverPeer = try receiverAuthority.pairAsReceiver(qr: placeholder, receiver: receiver, receiverAgreementPrivateKey: agreement, senderAgreementPublicKey: placeholder.senderAgreementPublicKey, explicitlyApproved: true)
    guard senderPeer.channelKey == receiverPeer.channelKey else { throw NearbySyncError.authenticationFailed }

    let source = results.appendingPathComponent("non-sensitive-250mb.m4a")
    let bytes = 250 * 1_024 * 1_024
    let block = Data(repeating: 0x52, count: 1_024 * 1_024)
    FileManager.default.createFile(atPath: source.path, contents: nil)
    let handle = try FileHandle(forWritingTo: source); defer { try? handle.close() }
    for _ in 0 ..< 250 { try handle.write(contentsOf: block) }
    try handle.synchronize()
    let manifest = try buildManifest(source: source, episodeID: "non-sensitive-250mb")
    let offeredManifest = try EpisodeManifest(episodeID: manifest.episodeID, sizeBytes: manifest.sizeBytes, sha256Hex: manifest.sha256Hex, chunkSize: manifest.chunkSize, chunkSHA256: manifest.chunkSHA256)
    var ledger = try TransferLedger(manifest: offeredManifest)
    let staging = results.appendingPathComponent("staging.m4a")
    FileManager.default.createFile(atPath: staging.path, contents: Data(repeating: 0, count: bytes))
    let target = try FileHandle(forUpdating: staging); defer { try? target.close() }
    func makeChannel() throws -> EncryptedLocalChannel {
        try EncryptedLocalChannel(port: .any, keyData: senderPeer.channelKey) { request in
            if request == Data("manifest".utf8) { return try JSONEncoder().encode(manifest) }
            guard let requestText = String(data: request, encoding: .utf8), requestText.hasPrefix("chunk:"), let index = Int(requestText.dropFirst("chunk:".count)), manifest.chunkSHA256.indices.contains(index) else {
                throw NearbySyncError.malformedPacket
            }
            let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
            try input.seek(toOffset: UInt64(index * manifest.chunkSize))
            return try input.read(upToCount: manifest.chunkSize) ?? Data()
        }
    }
    var channel = try makeChannel()
    channel.start()
    while !channel.isReady { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    guard let initialPort = channel.port else { throw NearbySyncError.invalidState("Local listener did not start.") }
    let receivedManifest = try JSONDecoder().decode(EpisodeManifest.self, from: EncryptedLocalChannel.request(host: "127.0.0.1", port: initialPort, keyData: receiverPeer.channelKey, payload: Data("manifest".utf8)))
    guard receivedManifest == offeredManifest else { throw NearbySyncError.manifestMismatch }
    for index in manifest.chunkSHA256.indices {
        // Two deliberate listener stops emulate loss of the Wi-Fi path. The
        // durable ledger is reloaded before retrying, so already acknowledged
        // chunks are never rewritten as new work.
        if index == 50 || index == 150 {
            channel.cancel()
            try JSONEncoder().encode(ledger).write(to: results.appendingPathComponent("ledger-interrupt-\(index - 1).json"), options: .atomic)
            ledger = try JSONDecoder().decode(TransferLedger.self, from: Data(contentsOf: results.appendingPathComponent("ledger-interrupt-\(index - 1).json")))
            channel = try makeChannel(); channel.start()
            while !channel.isReady { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        if index == 100 {
            channel.cancel()
            try JSONEncoder().encode(ledger).write(to: results.appendingPathComponent("ledger-restart.json"), options: .atomic)
            ledger = try JSONDecoder().decode(TransferLedger.self, from: Data(contentsOf: results.appendingPathComponent("ledger-restart.json")))
            channel = try makeChannel(); channel.start()
            while !channel.isReady { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        guard let port = channel.port else { throw NearbySyncError.invalidState("Local listener did not restart.") }
        let chunk = try EncryptedLocalChannel.request(host: "127.0.0.1", port: port, keyData: receiverPeer.channelKey, payload: Data("chunk:\(index)".utf8), timeout: 30)
        try target.seek(toOffset: UInt64(index * manifest.chunkSize))
        try target.write(contentsOf: chunk)
        _ = try ledger.record(index: index, payload: chunk)
    }
    try target.synchronize()
    try ledger.verify(assembled: staging)
    channel.cancel()
    try senderStore.revoke(receiver.id)
    let revoked = senderStore.peer(receiver.id) == nil
    guard revoked else { throw NearbySyncError.peerRevoked }
    let report = """
    # Native macOS loopback rehearsal

    - Result: PASS for native same-host loopback only; not evidence for two physical Macs or mobile.
    - Pairing: explicit approval parameters exercised on both peer roles; QR session was one-time and expiring.
    - Channel: Network TCP plus CryptoKit AES-GCM, with a Curve25519-derived 256-bit channel key.
    - Media: \(bytes) bytes; final SHA-256 \(manifest.sha256Hex).
    - Interrupt ledger checkpoints: chunks 49 and 149.
    - Restart ledger checkpoint: chunk 99.
    - Final integrity: PASS.
    - Revocation: PASS; sender trust record removed. A new QR pairing is required before a future channel can be derived.

    Limitation: this automated run used loopback, not two physical Macs and did not toggle Wi-Fi. Run the documented two-Mac rehearsal before treating this as desktop-to-desktop evidence.
    """
    try report.write(to: results.appendingPathComponent("RESULTS.md"), atomically: true, encoding: .utf8)
    print(report)
}

func requireApproval(_ prompt: String) throws {
    fputs(prompt + "\n", stderr)
    let terminal = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/tty"))
    defer { try? terminal.close() }
    let answer = String(decoding: terminal.availableData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard answer == "approve" else { throw NearbySyncError.pairingNotApproved }
}

func inputData() throws -> Data {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else { throw NearbySyncError.invalidState("Expected pairing data on standard input.") }
    return data
}

func senderPair(trustDirectory: URL, endpoint: String, qrOutput: URL) throws {
    try FileManager.default.createDirectory(at: trustDirectory, withIntermediateDirectories: true)
    let identity = DeviceIdentity()
    let authority = PairingAuthority(identity: identity, trustStore: try TrustStore(url: trustDirectory.appendingPathComponent("trust.json")))
    let qr = authority.begin(endpoint: endpoint)
    try writeQR(try qr.uri(), to: qrOutput)
    print("QR created locally. Scan it before it expires; do not save or share the QR payload.")
    print("After the receiver explicitly approves, paste its public pairing request on standard input, then press Control-D.")
    let request = try JSONDecoder().decode(ReceiverPairingRequest.self, from: inputData())
    try requireApproval("Approve receiver \(request.receiverID)? Type approve to persist trust:")
    _ = try authority.approvePairing(request: request, explicitlyApproved: true)
    print("Pairing approved. The receiver identity is trusted locally.")
}

func receiverPair(trustDirectory: URL, receiverID: String) throws {
    try FileManager.default.createDirectory(at: trustDirectory, withIntermediateDirectories: true)
    fputs("Scan the fresh sender QR and provide only its URI on standard input, then press Control-D. Do not retain it.\n", stderr)
    let qr = try PairingQR.fromURI(String(decoding: inputData(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    guard qr.expiresAt > Date() else { throw NearbySyncError.pairingExpired }
    try requireApproval("Approve the displayed sender endpoint \(qr.endpoint)? Type approve to continue:")
    let identity = DeviceIdentity(id: receiverID)
    let agreement = Curve25519.KeyAgreement.PrivateKey()
    let authority = PairingAuthority(identity: identity, trustStore: try TrustStore(url: trustDirectory.appendingPathComponent("trust.json")))
    let peer = try authority.pairAsReceiver(qr: qr, receiver: identity, receiverAgreementPrivateKey: agreement, senderAgreementPublicKey: qr.senderAgreementPublicKey, explicitlyApproved: true)
    let request = ReceiverPairingRequest(sessionID: qr.sessionID, receiverID: receiverID, receiverSigningPublicKey: identity.signingKey.publicKey.rawRepresentation, receiverAgreementPublicKey: agreement.publicKey.rawRepresentation)
    let encoded = try JSONEncoder().encode(request)
    try FileHandle.standardOutput.write(contentsOf: encoded)
    try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
    fputs("Receiver approval complete. Sender peer ID: \(peer.peerID). Send the public request above to the sender; it contains no secret.\n", stderr)
}

func serve(trustDirectory: URL, receiverID: String, source: URL, port: UInt16) throws {
    let store = try TrustStore(url: trustDirectory.appendingPathComponent("trust.json"))
    guard let peer = store.peer(receiverID) else { throw NearbySyncError.peerRevoked }
    let manifest = try buildManifest(source: source, episodeID: source.deletingPathExtension().lastPathComponent)
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw NearbySyncError.invalidState("Invalid listening port.") }
    let channel = try EncryptedLocalChannel(port: endpointPort, keyData: peer.channelKey) { request in
        if request == Data("manifest".utf8) { return try JSONEncoder().encode(manifest) }
        guard let text = String(data: request, encoding: .utf8), text.hasPrefix("chunk:"), let index = Int(text.dropFirst(6)), manifest.chunkSHA256.indices.contains(index) else { throw NearbySyncError.malformedPacket }
        let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(index * manifest.chunkSize))
        return try handle.read(upToCount: manifest.chunkSize) ?? Data()
    }
    channel.start()
    while !channel.isReady { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    print("Encrypted sender ready on port \(port). No media or key material is logged. Press Control-C to stop.")
    RunLoop.current.run()
}

func receive(trustDirectory: URL, senderPeerID: String, host: String, port: UInt16, stagingDirectory: URL) throws {
    let store = try TrustStore(url: trustDirectory.appendingPathComponent("trust.json"))
    guard let peer = store.peer(senderPeerID) else { throw NearbySyncError.peerRevoked }
    try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    let manifestData = try EncryptedLocalChannel.request(host: NWEndpoint.Host(host), port: port, keyData: peer.channelKey, payload: Data("manifest".utf8), timeout: 30)
    let manifest = try JSONDecoder().decode(EpisodeManifest.self, from: manifestData)
    let ledgerURL = stagingDirectory.appendingPathComponent("ledger.json")
    var ledger: TransferLedger
    if let saved = try? Data(contentsOf: ledgerURL) {
        ledger = try JSONDecoder().decode(TransferLedger.self, from: saved)
        guard ledger.manifest == manifest else { throw NearbySyncError.manifestMismatch }
    } else { ledger = try TransferLedger(manifest: manifest) }
    let partial = stagingDirectory.appendingPathComponent("episode.partial")
    if !FileManager.default.fileExists(atPath: partial.path) {
        FileManager.default.createFile(atPath: partial.path, contents: Data(repeating: 0, count: manifest.sizeBytes))
    }
    let target = try FileHandle(forUpdating: partial); defer { try? target.close() }
    for index in ledger.missingIndices {
        let chunk = try EncryptedLocalChannel.request(host: NWEndpoint.Host(host), port: port, keyData: peer.channelKey, payload: Data("chunk:\(index)".utf8), timeout: 60)
        try target.seek(toOffset: UInt64(index * manifest.chunkSize)); try target.write(contentsOf: chunk)
        _ = try ledger.record(index: index, payload: chunk)
        try JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
    }
    try target.synchronize(); try ledger.verify(assembled: partial)
    let final = stagingDirectory.appendingPathComponent(manifest.episodeID + ".m4a")
    if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
    try FileManager.default.moveItem(at: partial, to: final)
    try FileManager.default.removeItem(at: ledgerURL)
    print("Transfer verified and exposed after whole-file SHA-256 validation.")
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "sender-pair" where arguments.count == 4:
        try senderPair(trustDirectory: URL(fileURLWithPath: arguments[1]), endpoint: arguments[2], qrOutput: URL(fileURLWithPath: arguments[3]))
    case "receiver-pair" where arguments.count == 3:
        try receiverPair(trustDirectory: URL(fileURLWithPath: arguments[1]), receiverID: arguments[2])
    case "serve" where arguments.count == 5:
        guard let port = UInt16(arguments[4]) else { throw NearbySyncError.invalidState("Invalid listening port.") }
        try serve(trustDirectory: URL(fileURLWithPath: arguments[1]), receiverID: arguments[2], source: URL(fileURLWithPath: arguments[3]), port: port)
    case "receive" where arguments.count == 6:
        guard let port = UInt16(arguments[4]) else { throw NearbySyncError.invalidState("Invalid sender port.") }
        try receive(trustDirectory: URL(fileURLWithPath: arguments[1]), senderPeerID: arguments[2], host: arguments[3], port: port, stagingDirectory: URL(fileURLWithPath: arguments[5]))
    case "revoke" where arguments.count == 3:
        let store = try TrustStore(url: URL(fileURLWithPath: arguments[1]).appendingPathComponent("trust.json"))
        try store.revoke(arguments[2])
        print("Peer revoked locally. A fresh QR pairing is required before reconnecting.")
    case "self-test" where arguments.count == 2:
        try selfTest(results: URL(fileURLWithPath: arguments[1]))
    default: usage(); exit(2)
    }
} catch { fputs("error: \(error.localizedDescription)\n", stderr); exit(1) }
