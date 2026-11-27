#if os(iOS)
import HermesBox
import SwiftUI
import UIKit

/// Settings → Calls: "Calls from your bots" (off by default) and Test ring. Ported from Hermes Bot
/// (`LockScreenViews.swift`, `CallsToggleSection` and the Test ring row). There's no pairing step:
/// switching it on pairs this phone with the box on the gateway login (`NeoBox.ensurePaired`).
///
/// A modifier on a `Section` inside a `Form` lands on each of its rows, header and footer, so the
/// `.task` sits on the switch's row only.
struct NeoCallsSettingsSection: View {
    @State private var box = NeoBox.shared

    var body: some View {
        let voip = box.voip
        Section {
            Toggle(isOn: Binding(get: { voip.isEnabled }, set: { on in Task { await box.setCallsEnabled(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CallOwnerCopy.toggleTitle)
                    Text(box.statusLine).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .accessibilityHint(CallOwnerCopy.toggleHint)
            .task { await box.refresh() }
            if voip.isEnabled, box.microphoneDenied {
                Text("Hermes Neo can't use the microphone, so a call would be silent. Allow it in Settings, Hermes Neo, Microphone.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if voip.isEnabled, let failure = box.pairingFailure {
                NeoFailureRow(failure: failure) { Task { await box.retry() } }
            } else if let failure = voip.failure {
                NeoFailureRow(failure: failure) { Task { await box.retry() } }
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
        } header: {
            Text(CallOwnerCopy.sectionTitle)
        } footer: {
            Text(CallOwnerCopy.footnote)
        }
        NeoRequestsSettingsSection(box: box)
    }
}

/// Settings → Requests: approval and question updates from the box, separate from calls and chat notifications.
struct NeoRequestsSettingsSection: View {
    let box: NeoBox

    var body: some View {
        let push = box.push
        Section {
            Toggle(isOn: Binding(get: { box.lockScreen.approvals }, set: { on in Task { await box.setRequestsEnabled(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Requests on this phone")
                    Text("See approvals and questions on the Lock Screen.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .task { await box.refreshPush() }
            if box.lockScreen.approvals {
                if let failure = box.pairingFailure {
                    NeoFailureRow(failure: failure) { Task { await box.setRequestsEnabled(true) } }
                } else if push.serverEnabled == false {
                    Text("Your box has push turned off.").font(.footnote)
                    Button("Check again") { Task { await box.refreshPush() } }
                } else if push.diagnostics.notificationsAllowed == false {
                    Text("Notifications are off for Hermes Neo. Requests still appear in the app.").font(.footnote)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } else if let error = push.diagnostics.lastError {
                    Text(error).font(.footnote)
                    Button("Check again") { Task { await box.setRequestsEnabled(true) } }
                }
            }
        } header: {
            Text("Requests")
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
#endif
