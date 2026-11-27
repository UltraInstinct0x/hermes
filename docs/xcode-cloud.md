# Hermes Neo on TestFlight

This setup is for `UltraInstinct0x/hermes` → `neo`. One iOS archive contains Hermes Neo
and its Watch companion. It does not publish to the App Store or build the Mac app.

## One-time setup

1. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list),
   select team `GM3SRSD642`. Reuse existing identifiers, or register the missing ones:

   | Explicit bundle ID | App ID capabilities |
   | --- | --- |
   | `dev.supersaiyan.hermesneo` | Push Notifications, iCloud (key-value storage), Communication Notifications, Time Sensitive Notifications, App Groups |
   | `dev.supersaiyan.hermesneo.NotificationService` | App Groups |
   | `dev.supersaiyan.hermesneo.NotificationContent` | App Groups |
   | `dev.supersaiyan.hermesneo.Widgets` | App Groups |
   | `dev.supersaiyan.hermesneo.watchkitapp` | No extra capabilities. This is the embedded Watch app, not a separate App Store Connect record. |

   Attach `group.dev.supersaiyan.hermesneo` to the iPhone app and all three extensions.
   Those four targets share Keychain group `GM3SRSD642.dev.supersaiyan.hermesneo.push`
   through their entitlements; it isn't a separate App Group. Live Activities, background
   audio, fetch, remote notifications and VoIP, and the Watch companion relationship are
   already declared in the project. Cloud signs the build automatically; no certificates,
   provisioning profiles or App Store Connect API key need to be sent to anyone.
2. In [App Store Connect → Apps](https://appstoreconnect.apple.com/apps), create or reuse the
   **iOS** app record for Hermes Neo (`dev.supersaiyan.hermesneo`). If creating it, choose
   your primary language and a unique SKU. In the app's **TestFlight → Internal Testing**,
   create **Hermes Neo Internal** and add your App Store Connect user as a tester.
3. On a Mac with Xcode 27, check out `neo` after the PR merges and open `Hermes.xcodeproj`.
   Sign in to Xcode with team `GM3SRSD642`, then choose **Report navigator → Cloud → Get Started**.
   Select the Hermes iOS product and its App Store Connect record. When prompted, authorize
   Xcode Cloud on GitHub for `UltraInstinct0x/hermes` only.
4. Configure the workflow before starting its first build:
   - **Environment:** a released **Xcode 27.x** and compatible macOS from the Cloud picker
     (Xcode 26.6 cannot build this project).
   - **Start Conditions:** **Branch Changes** for exactly `neo`, with no path filters. Remove
     the default-branch and pull-request triggers. Turn off **Auto-cancel Builds** so a new
     merge does not cancel the previous build. Don't use `[ci skip]` on a merge to `neo`.
   - **Action:** **Archive**, **iOS**, shared scheme **Hermes** (Release),
     **TestFlight (Internal Testing Only)**. The archive already embeds **HermesWatch**;
     don't add a separate watchOS action.
   - **Post-Action:** **TestFlight Internal Testing**, group **Hermes Neo Internal**.
     Save and start the first build from `neo`. Xcode Cloud assigns the build number.
     If a build of this same app version was already uploaded, set the
     [next Cloud build number](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds)
     above the highest uploaded number before starting.
5. When the build finishes processing, accept the invitation in [TestFlight](https://testflight.apple.com/)
   on your iPhone, install **Hermes Neo** and enable **Automatic Updates** for that beta.
   On the paired iPhone, open **Watch → My Watch → Available Apps** and install **Hermes**
   if the companion isn't already installed. Subsequent successful builds are distributed
   through TestFlight; iOS controls when the automatic update installs.

## Check the first delivery

In [App Store Connect → Xcode Cloud](https://appstoreconnect.apple.com/xcode-cloud), check that
the archived commit is from `neo` and that the TestFlight post-action succeeded. Match the build
number in TestFlight. With Bot Mode connected on the iPhone, open **Hermes → Requests** on
the Watch and try a question or approval. Release builds register with **production APNs**;
if alerts that worked in Debug don't arrive, check production delivery for the Neo topic on
the push provider separately from TestFlight.

The committed Xcode project is the Cloud input. Run `xcodegen generate` locally when changing
`project.yml` or adding targets or source files, and commit generated project changes with the PR.
The project's Swift package lockfile pins the public dependencies; Cloud doesn't need XcodeGen
or a post-clone script.
