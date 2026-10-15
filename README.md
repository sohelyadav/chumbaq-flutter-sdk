# Dyplink Flutter SDK

Deep linking, deferred deep links, attribution, events, in-app messages,
banners, and push notifications for Dyplink.

## Platform support

Android and iOS. Neither is installable from pub.dev yet: both build against
a local checkout of their native SDK, so adding the dependency is not the
whole story — see [iOS setup](#ios-setup) for the two requirements there,
and `android/build.gradle.kts` for the `mavenLocal()` equivalent.

Anything that needs the native SDK throws `UnsupportedError` on web and
desktop, with a message saying so, rather than failing quietly. Five members
answer instead of throwing, because for each of them an answer is more
useful than an exception:

| Member | Where there is no native bridge |
|---|---|
| `Dyplink.isInitialized` | `false` |
| `DyplinkPush.isInitialized` | `false` |
| `DyplinkPush.isRegistered` | `false` |
| `DyplinkBannerCarousel` | renders `SizedBox.shrink()` |
| publishing to `Dyplink.deepLinks` | drops the event |

The first three are questions whose honest answer is "no" — making them
throw would mean wrapping every feature check in a `try`. The carousel is a
widget, and a widget cannot report an unsupported platform out of `build`
without replacing the screen with an error box. The last is best-effort by
design on every platform: it publishes only if something has already
subscribed.

Three members are Android-only even now that the rest of the plugin runs on
iOS. Each throws `UnsupportedError` there — none of them returns an empty
stream or a quiet success:

| Member | Why, and what to do on iOS |
|---|---|
| `DyplinkPush.tokens` | APNs hands the device token to the host app's own app delegate, never to the plugin, so there is nothing to stream. Pass the token you receive to `DyplinkPush.registerToken`. |
| `DyplinkPush.registerMiPushToken` | Mi Push is a Xiaomi delivery channel, and Xiaomi handsets are Android handsets. |
| `DyplinkBannerCarousel` | The widget hosts Android's native carousel view through a PlatformView. On iOS it renders `SizedBox.shrink()`; call `DyplinkBanners.loadBanners` and build the carousel in Flutter. |

Push **engagement reporting** is pure Dart over `dart:io`, so it needs only
`Dyplink.init` — on both platforms, and it worked on iOS before the rest of
the plugin did.

To watch any of these do nothing, turn on [diagnostics](#diagnostics).

## iOS setup

> **iOS is not installable from pub.dev yet.** The plugin builds against a
> *sibling checkout* of the native SDK, because `dyplink-ios-sdk` is not
> published and has no release tag — the same arrangement as Android, which
> pulls the native SDK from `mavenLocal()`. Until both SDKs are published,
> iOS support is usable from a Dyplink workspace checkout, not from
> `flutter pub add dyplink`. See [requirement 2](#2-a-sibling-checkout-of-the-native-ios-sdk).

Two hard requirements. Both fail the build if unmet, and the first one fails
it before any of your code is compiled.

### 1. Swift Package Manager

**The iOS plugin is a Swift package, with no podspec.** The native
[iOS SDK](https://github.com/sohelyadav/dyplink-ios-sdk) it wraps ships as a
Swift package and has no CocoaPods spec to depend on, so a pod could not pull
it in.

Nothing to do on **Flutter 3.44 or newer**: Swift Package Manager has been
on by default since 3.44.0, including on stable, and `flutter config --list`
reporting `enable-swift-package-manager: (Not set)` means on. On an older
Flutter, or a project where it was explicitly turned off, enable it once:

```sh
flutter config --enable-swift-package-manager
```

Without it there is no iOS support at all, and the build stops with the
reason rather than a confusing `no such module 'DyplinkCore'` later:

```
The following plugin(s) are only compatible with Swift Package Manager:
  - dyplink
```

### 2. A sibling checkout of the native iOS SDK

```
dyplink/
  dyplink-flutter-sdk/   <- this repo
  dyplink-ios-sdk/       <- the native SDK, checked out beside it
```

`ios/dyplink/Package.swift` resolves the SDK from that path. If it is not
there, package resolution fails with a message naming the directory it
looked in — it does not fall back to a stale or partial build. Point the
manifest somewhere else if your layout differs; swap it for
`.package(url:, from:)` once the SDK is published.

Minimum iOS: **14.0**, level with the native SDK. Flutter 3.47 itself
migrates host projects to a deployment target of 15.0, so in practice your
app will be on 15.

### Deep links

Two more steps, both specific to how iOS delivers links:

**1. Register your custom scheme** in `ios/Runner/Info.plist`, matching the
`customScheme` you pass to `DyplinkConfig`. Without it iOS never hands the
URL to the app:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array><string>yourscheme</string></array>
  </dict>
</array>
```

**2. For Universal Links**, add the Associated Domains capability
(`applinks:your.dyplink.host`) and serve the matching
`apple-app-site-association` file from that host.

The plugin registers for both the scene and the app-delegate URL callbacks,
so a `FlutterAppDelegate`-based app needs no code of its own — including for
a link that launched the app, which arrives before `Dyplink.init` has run
and is replayed to `Dyplink.deepLinks` once it has.

### Push

Push on iOS is APNs, and the host app owns registration:

```swift
func application(
  _ application: UIApplication,
  didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
  let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
  // Hand `hex` to Dart and call DyplinkPush.instance.registerToken(hex).
}
```

## Installation

```yaml
dependencies:
  dyplink: ^0.0.1
```

## Getting started

```dart
final config = DyplinkConfig.builder(
  baseUrl: 'https://your-dyplink-host',
  apiKey: '<project API key>',
  projectId: '<project id>',
).build();

await Dyplink.instance.init(config);

// Where a deep link should take the app.
Dyplink.instance.deepLinks.listen((link) => router.go(link.url));

// After a fresh install, to claim the click that led to it.
final match = await Dyplink.instance.matchDeferredDeepLink();

// Who this is, once they log in.
await Dyplink.instance.identify(
  IdentifyParams.builder().externalUserId('u_42').build(),
);
```

## In-app messages

```dart
DyplinkMessages.instance.events.listen((event) => switch (event) {
  MessageLifecycleEvent(:final eventType) => log(eventType),
  MessageButtonAction(:final button) => router.go(button.actionUrl!),
  MessageCustomEvent(:final eventName) => analytics.track(eventName),
});

await DyplinkMessages.instance.onAppOpen();
await DyplinkMessages.instance.onScreenView('Home');
await DyplinkMessages.instance.onEvent('purchase');
```

The **native** SDK draws the message — all five layouts, the picture, the
theme and the buttons — so there is no Flutter widget to place. What arrives
in Dart is the stream of what happened to it.

## Push notifications

This SDK never intercepts a message. Firebase Messaging on Android, and APNs
on iOS, are the app's; the SDK reports whatever the app hands it. On iOS that
includes the device token itself — see [iOS setup](#ios-setup).

```dart
await DyplinkPush.instance.init();

FirebaseMessaging.onMessage.listen(
  (message) => DyplinkPush.instance.reportNotificationReceived(message.data),
);

FirebaseMessaging.onMessageOpenedApp.listen((message) async {
  // A tap also hands back the campaign's destination, if it has one.
  final url = await DyplinkPush.instance.reportNotificationClicked(message.data);
  if (url != null) router.go(url);
});
```

### The four engagement events

The backend accepts four, and each is a different column of a campaign's
report. Only `delivered` and `click` have an obvious moment to hook; the
other two are the app's to report, because Flutter is not what drew the
notification.

| Call | Reports | When |
|---|---|---|
| `reportNotificationReceived` | `delivered` | the device took the message |
| `reportNotificationImpression` | `impression` | the user could actually see it |
| `reportNotificationClicked` | `click` | they tapped it |
| `reportNotificationDismissed` | `dismissed` | they swiped it away |

`delivered` is not `impression`: a push that arrives while notifications are
blocked is delivered and never seen, and a click-through rate measured
against deliveries flatters the campaign. `dismissed` is the only negative
signal — without it a rejected notification looks like an ignored one.

All four take optional `metadata`, stored with the event and returned with
the campaign's report.

### Attributing an action-button tap

A button press is a click, but the campaign's report can only separate it
from a tap on the body if the button's id comes along. Pass it as
`actionId`; it is sent as `metadata.actionId`, the same key the Android SDK
uses.

```dart
final actions = DyplinkPush.actionsFrom(message.data);

final url = await DyplinkPush.instance.reportNotificationClicked(
  message.data,
  actionId: actions.first.id,
);
```

The returned URL is the pressed button's own `deepLinkUrl` when it has one,
and the campaign's destination otherwise.

### Token updates — Android only

```dart
DyplinkPush.instance.tokens.listen((token) => log('new push token: $token'));
```

Emits whenever Firebase issues a new registration token. Dyplink has already
registered it with the backend by then — the stream is for apps that need to
do something of their own with it.

On iOS this throws `UnsupportedError`. APNs gives the device token to the
host app's own
`application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` and never
to the plugin, so there is nothing to stream; call
`DyplinkPush.instance.registerToken` with what you receive.

There is no replay: a refresh is an event, so a subscriber that starts
listening afterwards sees nothing. A refresh delivered to a background
service on a cold start, before Dart exists, is registered natively but has
no stream to reach.

This rides on the plugin's own `FirebaseMessagingService` subclass, which
the plugin's manifest installs in place of the native SDK's. An app that
registers a service of its own instead should subclass
`DyplinkFlutterMessagingService`, or forward its `onNewToken` to
`DyplinkFlutterMessagingService.publishToken(token)`.

### Xiaomi devices — Android only

MIUI throttles background FCM hard enough that on Xiaomi handsets the vendor
channel is the one that gets delivered. The app owns the Mi Push SDK —
Dyplink does not depend on Xiaomi's closed-source AAR — so add it to the
Android build, call `MiPushClient.registerPush`, and hand the regId over:

```dart
await DyplinkPush.instance.registerMiPushToken(regId);
```

This is an addition, not a replacement: the backend keeps both tokens,
prefers the vendor channel, and still sends exactly one notification. A
`DyplinkApiError` with status 400 means the deployment has no Mi Push
credentials configured.

### Rich content is handed over as data, not drawn

Flutter has no notification UI of its own, and on Android the native SDK has
already drawn the notification before Dart is running. So a campaign's
extras are surfaced as typed models for the app to do what it likes with —
attributing a tap to the button that caused it, or re-showing the same
content in a screen:

```dart
final slides  = DyplinkPush.carouselFrom(message.data);  // List<PushCarouselSlide>
final timer   = DyplinkPush.timerFrom(message.data);     // PushTimer?
final actions = DyplinkPush.actionsFrom(message.data);   // List<PushAction>
final image   = DyplinkPush.imageUrlFrom(message.data);  // String?
```

Each of them answers empty or null for a payload that carries none, or
carries one that cannot be read — malformed content costs the extras, never
the notification.

`imageUrlFrom` is null for a campaign delivered over FCM, which carries an
image field of its own that the Firebase client renders without help. It is
non-null only where the client has to attach the picture itself.

## Diagnostics

Almost nothing in this package throws at its caller. Engagement reporting
must never cost an app a notification tap, a stream whose native listener
fails to attach has to stay open, and a widget cannot throw out of `build`.
The result is that a misconfigured integration looks exactly like a working
one: calls return, streams stay open, and nothing happens.

```dart
DyplinkDiagnostics.enabled = true;  // before Dyplink.init
```

Turning this on makes those paths say so — which call went quiet, and
whether it was a failure or a skip. Behaviour is identical either way; it is
a debugging aid, not an error channel, and it is off by default.

Reports go to `debugPrint`. Send them somewhere else with
`DyplinkDiagnostics.sink`. Nothing logged carries an API key, a push token
or a device fingerprint, so a report is safe to paste into an issue.

## Related SDKs

- [iOS SDK](https://github.com/sohelyadav/dyplink-ios-sdk)
- [Android SDK](https://github.com/sohelyadav/dyplink-android-sdk)

## License

TBD
