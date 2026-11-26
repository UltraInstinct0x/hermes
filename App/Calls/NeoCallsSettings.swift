#if os(iOS)
import HermesBox
import SwiftUI
import UIKit

/// Settings → Calls: the owner's box and "Calls from your bots" (off by default), with Test ring.
/// Ported from Hermes Bot (`LockScreenViews.swift`, `CallsToggleSection` and the Test ring row).
struct NeoCallsSettingsSection: View {
    @State private var box = NeoBox.shared
    @State private var isPairing = false
    @State private var confirmsUnpair = false

    var body: some View {
        let voip = box.voip
        Section {
            if box.isPaired {
                LabeledContent("Your box", value: box.box?.baseURL.host() ?? "")
                Toggle(isOn: Binding(get: { voip.isEnabled }, set: { on in Task { await box.setCallsEnabled(on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CallOwnerCopy.toggleTitle)
                        Text(voip.statusLine).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityHint(CallOwnerCopy.toggleHint)
                if voip.isEnabled, box.microphoneDenied {
                    Text("Hermes Neo can't use the microphone, so a call would be silent. Allow it in Settings, Hermes Neo, Microphone.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let failure = voip.failure {
                    NeoFailureRow(failure: failure) { Task { await voip.retry() } }
                }
                Button {
                    Task { await voip.sendTestRing() }
                } label: {
                    HStack {
                        Text(CallOwnerCopy.testButton)
                        Spacer()
                        if voip.isTesting { ProgressView() }
                    }
                }
                .disabled(voip.isTesting || !voip.isEnabled || voip.registeredOnBox != true)
                if let sentence = voip.testSentence {
                    Text(sentence).font(.footnote).foregroundStyle(.secondary)
                }
                if let failure = voip.testFailure {
                    NeoFailureRow(failure: failure) { Task { await voip.sendTestRing() } }
                }
                Button("Unpair This Phone", role: .destructive) { confirmsUnpair = true }
            } else {
                Button("Pair with Your Box…", systemImage: "qrcode.viewfinder") { isPairing = true }
            }
        } header: {
            Text(CallOwnerCopy.sectionTitle)
        } footer: {
            Text(box.isPaired ? CallOwnerCopy.footnote : "Pair with your Hermes box to let your bots call this phone. Open Pair phone on the box's desktop (/configure) for the code.")
        }
        .task { await voip.refreshStatus() }
        .sheet(isPresented: $isPairing) { BoxPairingView(box: box) }
        .confirmationDialog("Unpair this phone from your box?", isPresented: $confirmsUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { Task { await box.unpair() } }
        } message: {
            Text("Your bots will no longer be able to call this phone.")
        }
    }
}

/// One calm sentence, Retry, and the raw cause behind Copy Details.
struct NeoFailureRow: View {
    let failure: CalmFailure
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(failure.sentence).font(.footnote)
            HStack {
                Button("Retry", action: retry)
                Spacer()
                Button("Copy Details") { UIPasteboard.general.string = failure.details }
            }
            .buttonStyle(.borderless)
            .font(.footnote)
        }
    }
}

/// Pair with the box: scan the QR code the box's desktop shows (`/configure`, Pair phone) or paste
/// its link. The link is a one-time credential: it is used once and never kept, logged or shown
/// again. Ported from Hermes Bot (`PairingView.swift`).
struct BoxPairingView: View {
    @Bindable var box: NeoBox
    @Environment(\.dismiss) private var dismiss
    @State private var showsScanner = false

    var body: some View {
        NavigationStack {
            Form {
                if let failure = box.pairingFailure {
                    Section {
                        NeoFailureRow(failure: failure) { Task { await pair() } }
                    }
                }
                Section {
                    Text("Open Pair phone on your box's desktop (type /configure), then scan its code or paste its link here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Pairing link from your desktop", text: $box.linkText, axis: .vertical)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Pairing link")
                    TextField("Box address (only for a bare code)", text: $box.boxAddress)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Box address")
                }
                Section {
                    Button("Scan QR Code", systemImage: "qrcode.viewfinder") { showsScanner = true }
                    Button("Paste Link", systemImage: "doc.on.clipboard") {
                        box.linkText = UIPasteboard.general.string ?? box.linkText
                    }
                    Button {
                        Task { await pair() }
                    } label: {
                        HStack {
                            Text("Pair This Phone")
                            if box.isPairing { ProgressView() }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(box.linkText.isEmpty || box.isPairing)
                }
            }
            .navigationTitle("Pair with Your Box")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showsScanner) {
                BoxPairingScanner { scanned in
                    box.linkText = scanned
                    showsScanner = false
                    Task { await pair() }
                }
            }
        }
    }

    private func pair() async {
        await box.pair()
        if box.isPaired { dismiss() }
    }
}
#endif
