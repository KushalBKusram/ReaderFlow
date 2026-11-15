import Foundation
import NearbySyncNative
import SwiftUI

/// Cross-thread cancel flag for the blocking receive loop.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

struct ReceivedEpisode: Identifiable, Equatable {
    let url: URL
    let sizeBytes: Int
    var id: String { url.lastPathComponent }
}

@MainActor
final class NearbySyncReceiverModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case awaitingApproval(endpoint: String)
        case paired(request: String)
        case receiving
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peers: [TrustedPeer] = []
    @Published private(set) var progress: ReceiveProgress?
    @Published private(set) var episodes: [ReceivedEpisode] = []
    @Published private(set) var lastVerified: String?
    @Published var receiverID: String = UserDefaults.standard.string(forKey: "nearbySync.receiverID") ?? "iphone-receiver"
    @Published var host: String = UserDefaults.standard.string(forKey: "nearbySync.host") ?? ""
    @Published var port: String = UserDefaults.standard.string(forKey: "nearbySync.port") ?? "8443"
    @Published var pastedURI: String = ""

    private let root: URL
    private var trustStore: TrustStore?
    private var pending: ReceiverPairingSession?
    private var cancel: CancelFlag?

    var stagingDirectory: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    var libraryDirectory: URL { root.appendingPathComponent("Episodes", isDirectory: true) }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NearbySync", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            trustStore = try TrustStore(url: self.root.appendingPathComponent("trust.json"))
        } catch {
            phase = .failed("Could not open the trust store: \(error.localizedDescription)")
        }
        refresh()
    }

    var savedProgress: ReceiveProgress? { EpisodeReceiver.savedProgress(stagingDirectory: stagingDirectory) }

    func refresh() {
        peers = (trustStore?.all() ?? []).sorted { $0.pairedAt < $1.pairedAt }
        let urls = (try? FileManager.default.contentsOfDirectory(at: libraryDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        episodes = urls.filter { $0.pathExtension == "m4a" }.map {
            ReceivedEpisode(url: $0, sizeBytes: (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }.sorted { $0.id < $1.id }
    }

    // MARK: Pairing

    /// Step 1: a scanned or pasted QR payload. Nothing is trusted yet.
    func stage(uri: String) {
        do {
            let session = try ReceiverPairingSession(uri: uri, receiverID: receiverID.trimmingCharacters(in: .whitespaces))
            pending = session
            let hostPort = try session.qr.hostAndPort()
            host = hostPort.host
            port = String(hostPort.port)
            phase = .awaitingApproval(endpoint: session.qr.endpoint)
        } catch {
            pending = nil
            phase = .failed(error.localizedDescription)
        }
    }

    /// Step 2: the explicit approve action.
    func approve() {
        guard let pending, let trustStore else { return }
        do {
            let result = try pending.approve(trustStore: trustStore)
            let json = try JSONEncoder().encode(result.request)
            self.pending = nil
            pastedURI = ""
            UserDefaults.standard.set(receiverID, forKey: "nearbySync.receiverID")
            UserDefaults.standard.set(host, forKey: "nearbySync.host")
            UserDefaults.standard.set(port, forKey: "nearbySync.port")
            phase = .paired(request: String(decoding: json, as: UTF8.self))
            refresh()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func decline() {
        pending = nil
        phase = .idle
    }

    func dismissPairingResult() { phase = .idle }

    // MARK: Receive

    func receive(from peer: TrustedPeer) {
        guard let portValue = UInt16(port), !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            phase = .failed("Enter the Mac's IP address and port.")
            return
        }
        UserDefaults.standard.set(host, forKey: "nearbySync.host")
        UserDefaults.standard.set(port, forKey: "nearbySync.port")
        let flag = CancelFlag()
        cancel = flag
        phase = .receiving
        lastVerified = nil
        let host = host.trimmingCharacters(in: .whitespaces)
        let staging = stagingDirectory, library = libraryDirectory
        UIApplication.shared.isIdleTimerDisabled = true
        // The library call is blocking, so run it on a plain background queue.
        let model = self
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                try EpisodeReceiver.receive(peer: peer, host: host, port: portValue, stagingDirectory: staging, libraryDirectory: library, isCancelled: { flag.isSet }, progress: { value in
                    Task { @MainActor in model.progress = value }
                })
            }
            Task { @MainActor in model.finish(outcome) }
        }
    }

    func stop() { cancel?.set() }

    private func finish(_ outcome: Result<URL, Error>) {
        UIApplication.shared.isIdleTimerDisabled = false
        cancel = nil
        switch outcome {
        case let .success(url):
            lastVerified = url.lastPathComponent
            progress = nil
            phase = .idle
        case let .failure(error):
            progress = EpisodeReceiver.savedProgress(stagingDirectory: stagingDirectory)
            phase = error is CancellationError
                ? .failed("Stopped. Progress is saved; tap Receive to resume.")
                : .failed("\(error.localizedDescription) Progress is saved; tap Receive to resume.")
        }
        refresh()
    }

    func discardPartial() {
        EpisodeReceiver.discardStaging(stagingDirectory)
        progress = nil
        phase = .idle
    }

    // MARK: Revocation

    /// Removes the trust record (so no further transfer can start without a
    /// fresh QR pairing) and drops any partial transfer from that sender.
    func revoke(_ peer: TrustedPeer) {
        do {
            try trustStore?.revoke(peer.peerID)
            discardPartial()
            refresh()
        } catch {
            phase = .failed("Could not revoke: \(error.localizedDescription)")
        }
    }

    func delete(_ episode: ReceivedEpisode) {
        try? FileManager.default.removeItem(at: episode.url)
        refresh()
    }
}
