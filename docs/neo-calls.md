# Calls from your bots (Hermes Neo)

Hermes Neo is the owner's fork of Hermes. This page covers the one feature it adds: a Bot on the owner's Hermes
box can ring this iPhone like a phone call, and answering joins the call the box already holds. It is ported from the
owner's Hermes Bot app (`hermes-bot-app`, `ios/README.md`, "Calls from your bots" and "Voice calls").

## 1. Why CallKit here, when upstream says no

`docs/voice.md` §4.4 rejects LiveCommunicationKit, PushKit and CallKit for Talk: Apple presents them for calls between
people, App Review guideline 2.5.4 limits the `voip` background mode to its intended use, and Talk (you talking to a
Bot in the app) is not a VoIP call, so upstream uses background audio and a Live Activity instead.

A call from the box is different: the box places it (a server-held call on its call hub), it arrives while the app is
not running, and it must ring the locked phone. Only a VoIP push and CallKit can do that, so Neo uses them for this
feature alone. Talk is unchanged. Neo is a personal build, not an App Store submission.

The design point upstream's choice protects is audio-session ownership (`docs/voice.md` §7): one coordinator owns the
session and the engine. Neo keeps it:

- A call from a Bot takes the `.call` role (above Talk). For a CallKit call the role's profile has `systemActivation`:
  `pending` sets the category only, and the app never activates or deactivates the session (CallKit does, and an app
  that activates it itself gets a silent call). After CallKit's `didActivate` the role is updated to `active`, which is
  when voice processing goes on and the engine starts.
- The call records and plays through the coordinator's `AudioGraph` (`App/Calls/NeoCallAudio.swift`): the microphone is a
  consumer of its tap, the Bot's speech a player in the same engine. Hermes Bot's own engine is not ported.
- A ring while Talk runs is reported to CallKit and ended at once (busy): Talk's engine doesn't give way to another role.

## 2. The rule iOS enforces

Every VoIP push is reported to CallKit inside the PushKit callback, also one that can't be read, is late, a duplicate,
arrives during a call, or arrives with the switch off; those are reported and ended at once (`RingDecision`). iOS ends
an app that leaves a VoIP push unreported and stops sending it VoIP pushes after repeats.

## 3. Moving parts

| Piece | Where |
|---|---|
| Pairing, BFF client, device Bearer | `Packages/HermesBox/Sources/HermesBox/{BFF,Pairing}` (`PairingService.pairWithGateway`) |
| VoIP token, switch, Test ring | `CallOwner/VoIPRegistrar.swift`, `CallOwnerAPI.swift` |
| Ring rules, CallKit coordination | `CallOwner/RingDecision.swift`, `RingCoordinator.swift`, `RingWatch.swift` |
| The call hub client and the call | `Call/CallClient.swift`, `CallWire.swift`, `CallSession.swift`, `CallController.swift` |
| App glue | `App/Calls`: `NeoBox` (made at launch), `NeoPushKitHost`, `NeoCallKitHost`, `NeoCallAudio`, settings, call screen |

The box contract (`box/bff`): `POST /bff/pair/gateway`; `POST /bff/push/voip/register {token, environment,
topic}` where `topic` is the app's bundle id and `environment` is explicitly `sandbox` in Debug
and on the simulator, or `production` on a Release device; `DELETE /bff/push/voip/register`;
`GET /bff/push/apns/status` (`voip`);
`POST /bff/call-owner/test-ring`; the call socket `/gw/<id>/api/call/ws` (`box/call-hub/protocol.mjs`).

On a device the app reads the push environment from the build setting that supplies its
`aps-environment` entitlement. Neo registers VoIP tokens and Lock Screen request tokens with the
box using `sandbox` or `production`. Sealed alerts register separately through the
[gateway plugin](notifications.md), which calls the sandbox `development`; the box's sealed push
relay translates it to `sandbox` when sending to APNs.

## 4. Pairing on the gateway login

There's no pairing step. When **Calls from your bots** is switched on (and at launch, and when Settings opens, while it
is on) and the phone has no box device token, `NeoBox` takes the gateway in use (else the first with Bot Mode and a
login), and posts `{"deviceLabel":"HermesNeo","client":"ios"}` to `https://<that gateway's host>:9443/bff/pair/gateway`
with the gateway credential exactly as `BackendClient` sends it (`X-Hermes-Session-Token`, or its `Cookie`;
`BackendClient.authorizationHeaders()`). The port is `NeoBox.boxPort` (`neo.boxPort` in user defaults overrides it).

- 200: `{ok, device, deviceToken}`; the token goes to the Keychain and is the Bearer of every later box request.
- 403: "Sign in to your gateway again, then try again." with Retry (429 after repeated refusals: wait).
- 502 or no network: "Could not reach your box through your gateway…" with Retry.
- A different session token than the one the pairing was made with (a SHA-256 of it is kept in the Keychain), or a
  401/403 from the box to the device token later, drops the stored token, so the next attempt pairs again.

## 5. Settings

Settings → Calls: **Calls from your bots** (off by default; turning it on asks for the microphone, which a ring can't ask
for on a locked phone, then pairs and registers), its status line, the microphone warning, a failure with Retry, and
**Test ring**.

## 6. What to check (on the iPhone)

1. Settings → Calls → turn on Calls from your bots: "On. Your bots can ring this phone." 2. Test ring, lock the phone: a
full-screen call with the Hermes ringtone. 3. Answer: the Bot's opener within a few seconds; Mute and End from CallKit
work. 4. Decline: the box logs `declined`. 5. Let one ring out: a missed call in Recents.
