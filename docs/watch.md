# Apple Watch

The Hermes watchOS app is a read-only companion. Open Hermes on the paired iPhone and
connect Bot Mode there first. The Watch doesn't sign in to gateways or receive their addresses
or credentials.

## 1. Bots and replies

The list shows Bots from the iPhone's configured Bot Mode gateways, including hidden Bots and
known Bots on disconnected gateways. Each row shows its gateway and whether the Bot is idle,
working or offline. The Watch reads again when it comes to the foreground or regains its phone
connection. Tap Refresh to read again while it stays open. If the phone has not loaded a
gateway's roster yet, open Hermes on the phone and refresh after the roster loads.

Tap a Bot to read its latest visible assistant answer from its permanent Bot Chat. The Watch
shows text only and shortens long answers. Opening a reply doesn't create a chat or mark it
read. It doesn't show approvals or notices, send messages, or take calls.

The companion uses interactive WatchConnectivity requests. The iPhone reads its existing
`BotRoster` and reuses the Bot Chat lookup and stored transcript API from
[Bots and Bot Chats](bots-groups-skills.md). No message is queued or saved to disk by the Watch
app. The wire messages identify a Bot by gateway UUID and profile name.

## 2. Check it

- Run the `HermesWatch` scheme's UI tests on a watch simulator. They use a Debug-only relay fixture
  to verify the Bot states and reply navigation without a paired phone.
- For a paired simulator or device check, open Hermes on the iPhone with Bot Mode connected,
  open Hermes on the Watch, and compare the roster and a Bot Chat reply. On the simulator use
  the existing [mock gateway bootstrap](development.md). Take the phone out of reach and check
  that the Watch offers Retry. Reconnect it and confirm the Watch reads the roster again.
- Before distributing an iOS archive, register the companion bundle ID
  `co.caffeinatedcode.hermes.watchkitapp` and provision its `Hermes Watch App Store` profile
  alongside the other [App Store profiles](releasing.md).
