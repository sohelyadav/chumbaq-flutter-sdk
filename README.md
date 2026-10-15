# Dyplink Flutter SDK

Deep linking, deferred deep links, attribution, events, in-app messages,
banners, and push notifications for Dyplink.

## Platform support

> **Android only, today.** The iOS side of the plugin is not implemented:
> every call into it answers `UnsupportedError`, with a message saying so,
> rather than failing quietly. Push *engagement reporting* is the exception
> — it is pure Dart over `dart:io` and works on both platforms, although on
> iOS it has nothing to report until the native side lands, because it needs
> a device fingerprint from the core SDK.
>
> For iOS today, use the [iOS SDK](https://github.com/sohelyadav/dyplink-ios-sdk)
> directly.

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

This SDK never intercepts a message. Firebase Messaging is the app's, and
the SDK reports whatever the app hands it:

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

## Related SDKs

- [iOS SDK](https://github.com/sohelyadav/dyplink-ios-sdk)
- [Android SDK](https://github.com/sohelyadav/dyplink-android-sdk)

## License

TBD
