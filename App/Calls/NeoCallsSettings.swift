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

/// Settings → Requests: what the box may put on this phone's Lock Screen (Hermes Bot's S22 choices, minimal): the
/// requests bubble with Approve, Deny and a question's answers, and the always-on bubble of your bots. No chat
/// notifications. Test notification asks the box for one alert and one bubble update.
struct NeoRequestsSettingsSection: View {
    let box: NeoBox

    var body: some View {
        let push = box.push
        Section {
            Toggle(isOn: Binding(get: { box.lockScreen.approvals }, set: { on in Task { await box.setRequestsEnabled(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Requests on this phone")
                    Text("Approvals and questions on the Lock Screen, answered there.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .task { await box.refreshPush() }
            Toggle(isOn: Binding(get: { box.lockScreen.alwaysOn }, set: { on in Task { await box.setBotsBubbleEnabled(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your bots on the Lock Screen")
                    Text("A Live Activity with what your bots are doing.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if box.lockScreen.wantsPush {
                if push.serverEnabled == false {
                    Text("Your box has push turned off.").font(.footnote).foregroundStyle(.orange)
                } else if let error = push.diagnostics.lastError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                } else if push.diagnostics.notificationsAllowed == false {
                    Text("Notifications are off for Hermes Neo in Settings, so requests arrive without a sound.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Button {
                    Task { await push.sendTest() }
                } label: {
                    HStack {
                        Text("Test notification")
                        Spacer()
                        if push.isTesting { ProgressView() }
                    }
                }
                .disabled(push.isTesting || !box.isPaired)
                if let sentence = push.testSentence {
                    Text(sentence).font(.footnote).foregroundStyle(.secondary)
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
