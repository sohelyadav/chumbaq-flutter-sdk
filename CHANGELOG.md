## 0.0.1

First release. A Flutter wrapper over the native Dyplink SDKs — the
offline event queue, session tracking, HTTP retries, install-referrer
parsing and FCM integration all stay in native code, so a Flutter app
behaves the same as a native one.

**Android and iOS.** Every module forwards to the native SDK on both
platforms. Three members stay Android-only and throw `UnsupportedError` on
iOS rather than answering emptily — `DyplinkPush.tokens` (APNs hands the
device token to the host app, not to the plugin), `registerMiPushToken` (a
Xiaomi channel) and `DyplinkBannerCarousel` (the PlatformView hosts
Android's native view). Calls on web and desktop throw, except for the
members listed in the README's platform-support table.

### iOS packaging — breaking, deliberate

* **`ios/dyplink.podspec` is gone; the iOS plugin is a Swift package**
  (`ios/dyplink/Package.swift`). Nothing to enable on Flutter 3.44+, where
  Swift Package Manager is on by default; an older Flutter needs
  `flutter config --enable-swift-package-manager`. The native iOS SDK ships
  as a Swift package with no CocoaPods spec, so a pod cannot depend on it: a
  podspec would have left the plugin failing at `import DyplinkCore` with
  "no such module", where having none makes Flutter say *"The following
  plugin(s) are only compatible with Swift Package Manager"* and name the
  fix. The podspec that was removed was unmodified `flutter create`
  boilerplate.
* Swift sources moved from `ios/Classes/` to `ios/dyplink/Sources/dyplink/`,
  the layout Flutter's SPM support requires. Pigeon's `swiftOut` follows.
* **Minimum iOS is 14.0**, level with the native SDK, where the removed
  podspec said 13.0. Flutter 3.47 migrates host projects to a deployment
  target of 15.0 anyway, so an app on a current Flutter is unaffected; an
  app pinned to iOS 13 is not supported.
* Like Android's `mavenLocal()` arrangement, the iOS build resolves the
  native SDK from a sibling checkout of `dyplink-ios-sdk`. Neither platform
  is installable from pub.dev until the native SDKs are published.

### Deep links and attribution

* `Dyplink.init`, `identify`, `track`, `trackConversion`, `trackRevenue`,
  `reset` and `flush`, forwarding to the native core SDK.
* `Dyplink.deepLinks` — a broadcast stream of direct and deferred links. The
  native listener attaches on first subscribe and detaches on last cancel.
* `matchDeferredDeepLink`, `getAttributedShortCode` and
  `getAttributedLinkId` for claiming the click that led to an install.
* A typed error hierarchy — `DyplinkNotInitialized`, `DyplinkInvalidConfig`,
  `DyplinkNetworkError`, `DyplinkApiError`, `DyplinkUnknownError` — mapped
  from the native codes rather than surfaced as raw `PlatformException`s.

### Push notifications

* `DyplinkPush.init`, `registerToken`, `registerMiPushToken`,
  `unregisterToken`, `isInitialized` and `isRegistered`.
* `DyplinkPush.tokens` — a broadcast stream of Firebase token refreshes.
  Android only; see the platform note above.
* Engagement reporting for all four event types the backend accepts:
  `reportNotificationReceived` (delivered), `reportNotificationImpression`,
  `reportNotificationClicked` and `reportNotificationDismissed`. Each takes
  optional `metadata`.
* An action-button tap can be attributed: pass `actionId` to
  `reportNotificationClicked` and it is reported as `metadata.actionId`, the
  key the native SDKs use. The call returns the pressed button's own deep
  link when it has one, and the campaign's destination otherwise.
* A campaign's rich content is handed over as data — `carouselFrom`,
  `timerFrom`, `actionsFrom`, `imageUrlFrom` — because the native SDK has
  already drawn the notification by the time Dart is running. Malformed
  content costs the extras, never the notification.
* This SDK never intercepts a message. Firebase Messaging stays the app's,
  and the SDK reports what the app hands it.

### In-app messages and banners

* `DyplinkMessages.onAppOpen`, `onScreenView` and `onEvent` as trigger
  points, plus an `events` stream of lifecycle, button and custom events.
  The native SDK draws the message, so there is no Flutter widget to place.
* `DyplinkBanners.loadBanners` and `clearCache`, and
  `DyplinkBannerCarousel` — a `PlatformView` hosting the native carousel so
  it matches native Dyplink banners exactly. The widget is Android-only and
  renders nothing on iOS; `loadBanners` works on both.

### Diagnostics

* `DyplinkDiagnostics`, off by default. Almost nothing in this package
  throws at its caller, which means a misconfigured integration looks like a
  working one. Turning this on reports the failures and skips those paths
  otherwise swallow. No API key, push token or device fingerprint is ever
  logged.
