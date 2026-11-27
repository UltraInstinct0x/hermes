import HermesActivityKit
import HermesBox
import HermesPush
import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// The long-pressed approval or question (`blocks/notifications.elyx` `notificationExpanded`,
/// `notificationExpandedQuestion`): the command, its risk and how long is left, or the question.
/// A question's choices become its actions (`notificationActionsQuestion`), each answering in
/// the background; the system menu can't hold more, so the rest stay in the app.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var host: UIHostingController<AnyView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        if BoxRequestNotifications.isBoxNotification(content.userInfo) {
            showBoxRequest(content)
            return
        }
        let shared = PushShared.current
        // What the envelope says, never the plain copy beside it, which the relay could have
        // written (`NotificationDelegate.notice(from:isRemote:)` in the app).
        guard let envelope = PushEnvelope(payload: content.userInfo[PushUserInfo.envelope]),
              let opened = shared.open(envelope) else { return }
        var notice = opened.notice
        notice.nameBot(chats: shared.botChats(gateway: opened.gateway.appID), names: shared.botNames(gateway: opened.gateway.appID))
        let gateway = opened.gateway.name
        show(AnyView(RequestDetail(notice: notice, gateway: gateway, received: notification.date)))
        if notice.kind == .question {
            extensionContext?.notificationActions = NotificationCatalog.actions(for: .question, choices: notice.actionChoices)
        }
    }

    private func showBoxRequest(_ content: UNNotificationContent) {
        let state = BoxRequestNotifications.contentState(content.userInfo)
        let presentation = state.map(RequestActivityPresentation.init)
        #if DEBUG && targetEnvironment(simulator)
        let demo = state?.botKey == "demo::hermes" && state?.requestId == "demo-answer-request"
        #else
        let demo = false
        #endif
        let actions = presentation?.actions(lockScreenAnswersEnabled: demo || NotificationCatalog.neoLockScreenAnswersEnabled,
                                             isStale: false) ?? []
        let fullCommand = actions.contains(.approve) ? state?.command : nil
        show(AnyView(VStack(alignment: .leading, spacing: 8) {
            Text(content.title).font(.headline)
            Text(VisibleText.of(fullCommand ?? state.flatMap { $0.detail.isEmpty ? nil : $0.detail } ?? content.body))
                .font(fullCommand == nil ? .subheadline : .system(.subheadline, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)))
        extensionContext?.notificationActions = actions.compactMap { action in
            guard let presentation, action != .openToAnswer else { return nil }
            let options: UNNotificationActionOptions = action == .typeAnAnswer ? [.foreground]
                : action == .deny ? [.authenticationRequired, .destructive] : [.authenticationRequired]
            return UNNotificationAction(identifier: BoxRequestNotifications.identifier(for: action),
                                        title: VisibleText.of(presentation.title(for: action)), options: options)
        }
    }

    private func show(_ detail: AnyView) {
        if let host {
            host.rootView = detail
        } else {
            let host = UIHostingController(rootView: detail)
            host.view.backgroundColor = .clear
            host.sizingOptions = [.preferredContentSize]
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            host.didMove(toParent: self)
            self.host = host
        }
        preferredContentSize = host?.view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)) ?? preferredContentSize
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: any UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        preferredContentSize = container.preferredContentSize
    }
}

/// The expanded request, drawn on the system's notification material.
struct RequestDetail: View {
    let notice: PushNotice
    let gateway: String?
    let received: Date

    private var context: String {
        [place, gateway ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(heading)
                    .font(.headline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !context.isEmpty {
                    Text(context)
                        .font(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            if notice.kind == .approval, let command = notice.command, !command.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(command)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Palette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let risk {
                        Label(risk, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.warning)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: .rect(cornerRadius: 14))
            }
            if notice.kind == .cardNeedsYou, !notice.body.isEmpty {
                Text(notice.body)
                    .font(.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface, in: .rect(cornerRadius: 14))
            }
            if notice.kind == .question, notice.questions.count > 1 {
                Text("\(notice.questions.count) questions. Answer the first here, or open Hermes for all of them.")
                    .font(.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            Text(footer)
                .font(.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var heading: String {
        switch notice.kind {
        case .approval:
            (notice.command?.isEmpty ?? true) ? String(localized: "\(notice.bot ?? "Hermes") needs your permission") : String(localized: "Run this command?")
        case .question:
            notice.questions.first?.question ?? notice.body
        case .cardNeedsYou:
            String(localized: "\(notice.bot ?? "Hermes") needs you")
        default:
            notice.title
        }
    }

    /// A card's title, else the chat, then the gateway.
    private var place: String {
        notice.kind == .cardNeedsYou ? (notice.cardTitle ?? notice.summary) : (notice.summary.isEmpty ? notice.subtitle : notice.summary)
    }

    /// Hermes's own description of the risk ("recursive delete"), as a sentence.
    private var risk: String? {
        guard let detail = notice.detail?.trimmingCharacters(in: .whitespaces), !detail.isEmpty else { return nil }
        return detail.prefix(1).uppercased() + detail.dropFirst()
    }

    private var footer: String {
        if notice.kind == .cardNeedsYou {
            return String(localized: "Reply answers it on the card, and the card goes back to Ready.")
        }
        if notice.kind == .question {
            return notice.isExpired() ? String(localized: "This question has expired.") : String(localized: "Hermes is waiting for your answer.")
        }
        return notice.expiryText() ?? String(localized: "Hermes is paused until you answer.")
    }
}
