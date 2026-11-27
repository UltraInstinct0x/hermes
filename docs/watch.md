# Apple Watch

The Hermes watchOS app is a companion to the iPhone app. Open Hermes on the paired iPhone and
connect Bot Mode there first. The Watch doesn't sign in to gateways or receive their addresses
or credentials.

## 1. Bots and replies

The list shows Bots from the iPhone's configured Bot Mode gateways, including hidden Bots and
known Bots on disconnected gateways. Each row shows the Bot's name and whether it is idle,
working or offline. A gateway name is shown when Bots on different gateways share a name, unless
the gateway name repeats the Bot's name. The Watch reads again when it comes to the foreground
or regains its phone connection. Tap Refresh to read again while it stays open. If the phone has
not loaded a gateway's roster yet, open Hermes on the phone and refresh after the roster loads.

Tap a Bot to read its latest visible assistant answer from its permanent Bot Chat. The Watch
formats Markdown with inert links, shows a text fallback for card directives, and shortens long
answers. Fenced examples stay code.
Opening a reply doesn't create a chat or mark it read. The Watch doesn't send chat messages,
receive Hermes notices, or take calls.

The companion uses interactive WatchConnectivity requests. The iPhone reads its existing
`BotRoster` and reuses the Bot Chat lookup and stored transcript API from
[Bots and Bot Chats](bots-groups-skills.md). No message is queued or saved to disk by the Watch
app. The wire messages identify a Bot by gateway UUID and profile name.

## 2. Check it

- Run the `HermesWatch` scheme's UI tests on a watch simulator. They use a Debug-only relay fixture
  to verify Bot states, reply navigation, and answering a request without a paired phone.
- For a paired simulator or device check, open Hermes on the iPhone with Bot Mode connected,
  open Hermes on the Watch, and compare the roster and a Bot Chat reply. On the simulator use
  the existing [mock gateway bootstrap](development.md). Take the phone out of reach and check
  that the Watch offers Retry. Reconnect it and confirm the Watch reads the roster again.
- Before distributing an iOS archive, register the companion bundle ID
  `co.caffeinatedcode.hermes.watchkitapp` and provision its `Hermes Watch App Store` profile
  alongside the other [App Store profiles](releasing.md).

## 3. Approvals and questions

Open **Requests** from the Bots screen to see pending approvals and clarify questions from the
paired iPhone. For a supported approval, the Watch shows the whole command and offers Allow Once
or Deny. Review flagged approvals, memory saves, and payment fills on the iPhone. For a question,
pick an offered choice (or several when allowed), or use the Watch text field, including system
dictation, when the question accepts words. A multi-question request sends one answer after the
last question.

The iPhone uses the same owning-session attach as [Needs You](inbox.md). It checks the complete
`srq-…` ID and the displayed request against the owner's live snapshot before sending the answer.
Nothing is queued on the Watch. **Answer sent** shows your answer and its Bot or chat. It means
the iPhone wrote the reply, not that the gateway confirmed it won. **Back to Requests** returns
to a refreshed list. If someone else answered, the request changed, or it expired, the Watch
tells you it is no longer pending. If the phone can't confirm the send, refresh Requests before
trying again. Existing notifications and their actions are unchanged.
Removing a gateway on the iPhone invalidates its Watch requests and refreshes the list when the
Watch receives the change.
