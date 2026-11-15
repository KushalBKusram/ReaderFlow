import NearbySyncNative
import SwiftUI

/// Minimal Nearby Sync receiver for the Mac-to-iPhone rehearsal. Not a
/// production library UI: it exists to exercise pairing, transfer, resume,
/// verification and revocation on a real device.
struct NearbySyncReceiverView: View {
    @StateObject private var model = NearbySyncReceiverModel()
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                pairingSection
                if !model.peers.isEmpty { receiveSection }
                if !model.episodes.isEmpty { episodesSection }
                if case let .failed(message) = model.phase {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Nearby Sync")
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    QRScannerView { code in
                        scanning = false
                        model.stage(uri: code)
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan the Mac's QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
                }
            }
        }
    }

    @ViewBuilder private var pairingSection: some View {
        Section {
            switch model.phase {
            case let .awaitingApproval(endpoint):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Approve this sender?").font(.headline)
                    Text("The QR points at \(endpoint). Approve only if that is your Mac's address and you just started pairing there.")
                        .font(.footnote)
                    Text("This iPhone will identify itself as “\(model.receiverID)”.").font(.footnote)
                }
                Button("Approve and trust this Mac") { model.approve() }
                Button("Decline", role: .cancel) { model.decline() }
            case let .paired(request):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paired on this iPhone").font(.headline)
                    Text("Now copy this public pairing request to the Mac and paste it into the waiting sender-pair command within its 2-minute window, then type approve there. It contains no secret.")
                        .font(.footnote)
                    Text(request).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
                Button("Copy request") { UIPasteboard.general.setItems([[ "public.utf8-plain-text": request ]], options: [.expirationDate: Date().addingTimeInterval(180)]) }
                Button("Done") { model.dismissPairingResult() }
            default:
                TextField("This iPhone's ID", text: $model.receiverID).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Scan pairing QR") { scanning = true }
                TextField("…or paste the QR text (readerflow-nearby://…)", text: $model.pastedURI, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption)
                Button("Use pasted text") { model.stage(uri: model.pastedURI) }.disabled(model.pastedURI.isEmpty)
            }
        } header: { Text("1. Pair with your Mac") } footer: {
            Text("Pairing is explicit and expires after two minutes. The QR secret never leaves this device.")
        }
    }

    @ViewBuilder private var receiveSection: some View {
        Section {
            TextField("Mac IP address", text: $model.host).keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Port", text: $model.port).keyboardType(.numberPad)
            if let progress = model.progress ?? model.savedProgress {
                ProgressView(value: Double(progress.receivedChunks), total: Double(max(progress.totalChunks, 1)))
                Text("\(progress.receivedChunks) of \(progress.totalChunks) chunks saved").font(.footnote).monospacedDigit()
            }
            ForEach(model.peers, id: \.peerID) { peer in
                VStack(alignment: .leading, spacing: 4) {
                    Text(peer.peerID).font(.footnote.monospaced())
                    Text("Paired \(peer.pairedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                if model.phase == .receiving {
                    Button("Stop (progress is kept)") { model.stop() }
                } else {
                    Button("Receive from this Mac") { model.receive(from: peer) }
                }
                Button("Revoke this Mac", role: .destructive) { model.revoke(peer) }.disabled(model.phase == .receiving)
            }
            if model.savedProgress != nil, model.phase != .receiving {
                Button("Discard partial transfer", role: .destructive) { model.discardPartial() }
            }
            if let name = model.lastVerified {
                Label("\(name) passed SHA-256 verification", systemImage: "checkmark.seal")
            }
        } header: { Text("2. Receive") } footer: {
            Text("Keep this screen open while receiving. iOS asks for Local Network access the first time; if the first attempt times out while you answer, tap Receive again.")
        }
    }

    private var episodesSection: some View {
        Section("Received (verified)") {
            ForEach(model.episodes) { episode in
                HStack {
                    Text(episode.id).font(.footnote.monospaced())
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(episode.sizeBytes), countStyle: .file)).font(.caption)
                }
                .swipeActions { Button("Delete", role: .destructive) { model.delete(episode) } }
            }
        }
    }
}
