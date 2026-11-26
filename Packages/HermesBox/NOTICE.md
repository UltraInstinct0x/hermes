# Notices

`HermesBox` and `App/Calls` are ported from the owner's Hermes Bot app (`hermes-bot-app`, `ios/`), with its own
notice carried over below.

## kaishi00/hermes-conduit (MIT): CallKit and PushKit patterns

Small pieces of the ring path are adapted from
[github.com/kaishi00/hermes-conduit](https://github.com/kaishi00/hermes-conduit), file `Conduit/Voice/HermesNativeCalls.swift`.
Nothing was copied wholesale: each piece was rewritten in Hermes Bot's style and naming, without that project's relay
service, branding or other files. The adapted ideas are:

- the `CXProviderConfiguration` set-up and the `CXCallUpdate` fields of an incoming call (`App/Calls/NeoCallKitHost.swift`);
- the PushKit delegate: the token as hex and the handling of an invalidated token (`App/Calls/NeoPushKitHost.swift`);
- the table of what a failed `reportNewIncomingCall` means, the `providerDidReset` and `timedOutPerforming` handling, and
  the waiter that holds the call's audio until CallKit's `didActivate` within a bounded time
  (`App/Calls/NeoCallKitHost.swift`, `Sources/HermesBox/CallOwner/RingCoordinator.swift`);
- a pure plan per VoIP push (ring, or report and end at once) (`Sources/HermesBox/CallOwner/RingDecision.swift`).

Those files carry a comment naming the source. The adapted pieces are distributed under the MIT license of the original:

```
MIT License

Copyright (c) 2026 kaishi00

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
