# Apple Watch companion

`HermesWatch` (watchOS 11+) is embedded in the iPhone app. `HermesWatchWidgets`
provides rectangular, circular and inline WidgetKit complications. Shared wire
models live in `WatchShared`; the phone-only relay is in `HermesMobile/Watch`.
The share, Live Activity and notification extensions do not use these models.

## Setup and signing

Use Xcode 27 with the iOS and watchOS SDKs installed. The existing
`Config/Local.xcconfig` overrides apply to both new targets: set your own
`DEVELOPMENT_TEAM`, `APP_BUNDLE_IDENTIFIER` and `APP_GROUP_IDENTIFIER` together
as described in `CONTRIBUTING.md`. The derived Watch IDs are
`$(APP_BUNDLE_IDENTIFIER).watchkitapp` and
`$(APP_BUNDLE_IDENTIFIER).watchkitapp.widgets`; the companion identifier is
`$(APP_BUNDLE_IDENTIFIER)`. Both Watch targets join `$(APP_GROUP_IDENTIFIER)`.
Register the two new default App IDs with the maintainer's team before an
upstream merge; no new signing credentials belong in the repository.

Build/run the signed `HermesMobile` scheme on a paired iPhone, configure a
server there, then install Hermex through the iPhone Watch app (or select the
paired Watch as the `HermesWatch` scheme destination in Xcode). Use a paired
simulator pair for development; a generic Watch build verifies compilation
but cannot exercise WatchConnectivity. Do not install a signing-disabled build
for manual testing: phone Keychain access needs normal Debug entitlements.

The branch-only, fork-only `Watch Branch Verification` workflow uses the same
`xcode-27` hosted runner and Xcode 27.0 pin as upstream PR CI. This is a public
preview GitHub-hosted label, not an upstream private runner. The image includes
iOS/watchOS 27 simulators. It builds the actual Watch app/widget and the iPhone
embedding path, then runs focused XCTest and the full retained regression suite
without signing secrets. It is triggered only by a push to
`feat/apple-watch-complication` in `cwallace/hermex` or a manual dispatch on
that branch. It uploads validation logs/results only; it performs no app
distribution. Local focused command:

```sh
scripts/test-sim <iphone-simulator-udid> --only HermesMobileTests/WatchRelayTests
```

## Count and target

The count is a fresh server read, never stored history or a recency estimate.
For direct Hermes it uses `session.active_list` with
`SessionRowAttentionState.hermesStates`: unique nonempty `session_key` values
whose runtimes are `starting`, `working`, `streaming` or `waiting`. Idle,
resuming and unknown states do not count. Like the existing attention policy,
several runtimes with the same stored key count once. The host's live list has
no Profile identity, so this count covers **all Profiles in that server
process**, including active bot chats; it cannot separate equal keys in
different Profiles. `is_active` is never used.

For legacy webui it counts unique session IDs with `isStreaming` or a nonempty
`activeStreamId`, exactly `SessionRowView.isActiveStreaming`. This includes a
stream held open for approval or clarification. Webui lists its active Profile;
the phone checks that Profile before and after reading the list. Read failures,
expired sign-in, missing methods or missing reply fields show unavailable,
never zero. An idle server that successfully returns an empty live list shows 0.

The server is always the phone's currently selected **saved** server. The
Watch uses the neutral label “Selected iPhone server” so hostnames/URLs never
leave the phone. New sessions use that same server and the phone's saved Hermes
Profile choice if it still exists, otherwise the dashboard's current Profile.
Webui uses its active Profile. The Watch names the creation Profile separately
from the all-Profile count. Refresh produces an opaque target token; server,
Profile preference, credentials identity, sign-out, app lock or protected-data
changes invalidate it. Cancellation is checked before every write; webui's API
actor also checks a synchronously revoked ownership ticket at HTTP dispatch. The server's Profile is rechecked before creation.

## New Session and failure behavior

A complication has **one tap target**. All families use `widgetURL` to open the
Watch app directly to its New Session composer; the rectangular face visibly
shows “+ New Session”. There is no independent watch-face intent button.
Apple's current [widget interactivity documentation](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
lists interactive accessory families on iPhone/iPad, not Apple Watch.

Enter the first message using normal Watch text input/dictation, then tap the
actual New Session button. This explicitly creates a session **and sends that
message**. The phone calls the existing `HermesCall.sessionNew` and
`promptSubmit`, or webui's `APIClient.createSession` and `startChat`, then verifies
the stored session through the existing read API before returning its ID. An
empty Hermes `session.create` is lazy and would disappear without its first
prompt, which is why the composer is required. There is no transcript on Watch.
Continue the session in the iPhone's normal Sessions list.

Creation and refresh disable the in-flight controls. Requests are never sent
through a queued background-transfer API. A delivery timeout or network error
keeps an opaque request identity on Watch; Check Result only reads the phone's
outcome and never resends a write. The phone shares concurrent requests with
the same UUID and retains up to 128 outcomes in memory. Before writing it
persists a UUID/time tombstone; after phone process death it returns unknown
instead of replaying that request. Requests expire after 15 minutes, tombstones
last at least one hour, and a full journal refuses new work rather than evicting
an unexpired request. Outcomes and IDs are not synced to the complication.
Start Another requires explicit confirmation to check iPhone first: an unknown
request may already have succeeded. No promise of server-side exactly-once
creation survives an ambiguous network failure.

## Pairing, lock and freshness limits

The relay starts in the iPhone app initializer, including a background
WatchConnectivity wake, and uses only existing phone credentials and headers.
No password, token, URL, full message or transcript enters application context
or complication storage. The first prompt travels transiently Watch → phone
only after the user's tap. The complication snapshot contains just a count,
Profile name, opaque target token, timestamp and a bounded error enum. App-group
storage is local to the Watch; WatchConnectivity carries the snapshot across
devices. Watch UI strings use a dedicated `Watch` catalog with English fallback.

Both sides activate `WCSession`. An active Watch sends `sendMessage` without
preemptively refusing a temporarily false `isReachable`: Apple documents that
it [can wake the paired iPhone app in the background](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)).
If delivery fails, the UI asks the user to check the phone. An unconfigured or
signed-out phone refuses work. When Hermex app lock is enabled, the phone app
must be foregrounded and unlocked for either reads or writes; its background
relock grace period never grants Watch access. Protected-data lock also refuses
work. Existing cached snapshots can remain on an offline Watch until delivered
invalidation arrives, so their age is always meaningful.

The phone refreshes on WC activation, active-app entry and once a minute only
while active. Opening/refreshing the Watch app requests another read. Phone
application-context changes reload the Watch widget timeline. WidgetKit decides
when a face can repaint: it is **not** a per-second live counter. The timeline
marks a snapshot stale after five minutes and requests another local timeline
within 15 minutes; that timeline read does not contact the server. A stale
count remains labelled stale; errors replace the count with unavailable.

Manual paired-device pass: inspect all three face families and the New Session
route; create one disposable session with a short first prompt and find it on
phone; verify an approval wait counts; test an unreachable phone/server,
expired auth, app lock, server/Profile switching and sign-out; time out one
request and Check Result without creating a duplicate. Review VoiceOver,
large text and light/dark appearance. No animations or continuous repainting
were introduced. Real server writes are a maintainer-only manual check here.
