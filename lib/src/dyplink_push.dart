import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpHeaders;

import 'package:flutter/services.dart';

import 'dyplink_core.dart';
import 'dyplink_diagnostics.dart';
import 'dyplink_error.dart';
import 'dyplink_models.dart';
import 'dyplink_platform.dart';
import 'pigeon.g.dart' as pg;

/// Data-payload key that Dyplink stamps onto outgoing FCM messages for a
/// campaign push. Its absence means the notification did not originate
/// from a Dyplink campaign, so engagement reporting is skipped.
const String _campaignIdDataKey = 'dyplink_campaign_id';

/// Data-payload keys that may carry a campaign push's destination URL, in
/// precedence order. Matches the Android SDK's `PushNotificationHandler`,
/// which reads `deep_link_url` and falls back to `link`.
const List<String> _deepLinkDataKeys = <String>['deep_link_url', 'link'];

/// Keys carrying content no push provider renders itself.
const String _carouselDataKey = 'dyplink_carousel';
const String _timerDataKey = 'dyplink_timer';
const String _actionsDataKey = 'dyplink_actions';
const String _imageUrlDataKey = 'dyplink_image_url';

/// Optional push notification module for the Dyplink SDK.
///
/// Call [init] after [Dyplink.init] to enable automatic FCM push token
/// management. This module wraps the native Dyplink Push module, which in
/// turn wraps Firebase Messaging.
///
/// It also reports push engagement for Dyplink campaigns — all four event
/// types the backend accepts, see [reportNotificationReceived],
/// [reportNotificationImpression], [reportNotificationClicked] and
/// [reportNotificationDismissed]. Unlike token management, engagement
/// reporting is a pure-Dart HTTP call: it works on both Android and iOS,
/// and only requires [Dyplink.init] to have been called, not [init].
///
/// Usage:
/// ```dart
/// await Dyplink.instance.init(config);
/// await DyplinkPush.instance.init();
///
/// // Listen for FCM token updates.
/// DyplinkPush.instance.tokens.listen((token) => print('new token: $token'));
///
/// // Report push engagement from firebase_messaging's own handlers — the
/// // SDK never intercepts messages itself, it just reports what you hand it.
/// FirebaseMessaging.onMessage.listen(
///   (message) => DyplinkPush.instance.reportNotificationReceived(message.data),
/// );
/// FirebaseMessaging.onMessageOpenedApp.listen((message) async {
///   // A tap also hands back the campaign's destination URL, if it has one.
///   final url = await DyplinkPush.instance.reportNotificationClicked(message.data);
///   if (url != null) router.go(url);
/// });
/// ```
class DyplinkPush {
  DyplinkPush._();
  static final DyplinkPush instance = DyplinkPush._();

  // ignore: public_member_api_docs
  pg.DyplinkPushHostApi hostApi = pg.DyplinkPushHostApi();

  /// Sends a single push-engagement event to the Dyplink backend.
  ///
  /// Visible for testing — replace with a fake to avoid real network calls
  /// and to simulate transport failures.
  // ignore: public_member_api_docs
  Future<void> Function(
    String baseUrl,
    String apiKey,
    Map<String, Object?> body,
  ) postEvent = _defaultPostEvent;

  /// Resolves the `platform` string ("android"/"ios") sent with engagement
  /// events; null means an unsupported platform, so reporting is skipped.
  ///
  /// Visible for testing — `Platform.isAndroid`/`isIOS` are both false
  /// under `flutter test` (which runs on the host OS), so tests override
  /// this to exercise the reporting path. Overriding [DyplinkPlatform.resolve]
  /// does the same thing for the whole SDK at once; this stays separate so a
  /// test can report as one platform while gating as another.
  // ignore: public_member_api_docs
  String? Function() platformName = _defaultPlatformName;

  /// Resolves the device fingerprint attached to engagement events.
  /// Defaults to [Dyplink.instance]'s `deviceFingerprint`.
  ///
  /// Visible for testing — the default forwards to core `Dyplink`, which is
  /// itself platform-gated (Android and iOS); tests override this to
  /// exercise the reporting path independent of that gate.
  // ignore: public_member_api_docs
  Future<String> Function() deviceFingerprintProvider =
      () => Dyplink.instance.deviceFingerprint;

  StreamController<String>? _tokenController;
  StreamSubscription<Object?>? _tokenSub;

  static const EventChannel _tokenChannel =
      EventChannel('com.dyplink.dyplink/push_tokens');

  /// Initialize the push module. Requires Dyplink.init() to have been called.
  Future<void> init() {
    _ensureSupported();
    return runCatchingDyplink(hostApi.initialize);
  }

  /// Whether the push module has been initialized.
  ///
  /// Answers false rather than throwing on a platform the native plugin
  /// does not support, so feature detection does not need a `try`. See the
  /// README's platform-support section for the full list of members that
  /// answer instead of throwing.
  Future<bool> get isInitialized => _supported
      ? runCatchingDyplink(hostApi.isPushInitialized)
      : Future.value(false);

  /// Whether a push token is currently registered with the Dyplink backend,
  /// on any delivery channel (FCM, APNs, Mi Push).
  ///
  /// Answers false rather than throwing on an unsupported platform, for the
  /// same reason as [isInitialized].
  Future<bool> get isRegistered =>
      _supported ? runCatchingDyplink(hostApi.isRegistered) : Future.value(false);

  /// Manually register a push token: an FCM registration token on Android,
  /// an APNs device token on iOS.
  ///
  /// On iOS the host app owns APNs registration, so this is the *only* way a
  /// token reaches Dyplink. Hex-encode the `Data` token your
  /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
  /// receives and pass it over a channel of your own — there is nothing for
  /// the plugin to intercept, which is the same reason [tokens] has no iOS
  /// implementation.
  Future<void> registerToken(String token) {
    _ensureSupported();
    return runCatchingDyplink(() => hostApi.registerToken(token));
  }

  /// Register a Xiaomi Mi Push regId with the Dyplink backend.
  ///
  /// MIUI throttles background FCM aggressively, so on Xiaomi devices the
  /// vendor channel is the one that actually gets delivered. This does not
  /// replace the FCM token — the backend keeps both, prefers the vendor
  /// channel, and still sends exactly one notification.
  ///
  /// **The host app owns the Mi Push SDK.** Dyplink deliberately does not
  /// depend on Xiaomi's closed-source AAR, so the app must add the Mi Push
  /// SDK to its own Android build, call `MiPushClient.registerPush`, receive
  /// the regId in its own `PushMessageReceiver.onReceiveRegisterResult`, and
  /// pass it here over a channel of its own making. The app's package name
  /// must match the one registered with Xiaomi, or Xiaomi never issues a
  /// regId to begin with.
  ///
  /// A [DyplinkApiError] with status 400 means the deployment has no Mi Push
  /// credentials configured — the server rejects a channel it cannot deliver
  /// on. It does not mean the call was malformed.
  ///
  /// **Android only.** Throws [UnsupportedError] on iOS: Mi Push is a Xiaomi
  /// delivery channel and Xiaomi devices are Android devices, so there is
  /// neither a regId to register nor an iOS SDK API to register it with.
  Future<void> registerMiPushToken(String regId) {
    _ensureAndroidOnly(
      'DyplinkPush.registerMiPushToken',
      'Mi Push is a Xiaomi/Android delivery channel',
    );
    return runCatchingDyplink(() => hostApi.registerMiPushToken(regId));
  }

  /// Unregister every push token registered for this device — the FCM or APNs
  /// token and any vendor channel such as Mi Push. Call on user logout.
  Future<void> unregisterToken() {
    _ensureSupported();
    return runCatchingDyplink(hostApi.unregisterToken);
  }

  /// Broadcast stream of push token updates.
  ///
  /// Emits whenever Firebase issues a new registration token, which it does
  /// on install, on app-data clear, and on restore to a new device. The
  /// token is already registered with the Dyplink backend by the time it
  /// arrives here — this stream is for apps that need to do something of
  /// their own with it, not a step in Dyplink's own registration.
  ///
  /// The native listener is attached when the first subscriber appears and
  /// detached when the last one cancels.
  ///
  /// Two things it does not emit:
  ///
  ///   * The token the app already has. A refresh is an event, not a value
  ///     — a subscriber that starts listening after one has happened sees
  ///     nothing. There is no replay.
  ///   * A refresh that arrives while no Flutter engine is running. Firebase
  ///     can deliver one to a background service on a cold start, before
  ///     Dart exists; Dyplink still registers it natively, but there is no
  ///     stream for it to reach.
  ///
  /// This needs the plugin's own `FirebaseMessagingService` subclass, which
  /// the plugin's manifest installs for you. An app that registers its own
  /// service instead must forward `onNewToken` to
  /// `DyplinkFlutterMessagingService.publishToken(token)` or this stream
  /// stays silent — see the README's push section.
  ///
  /// **Android only.** Throws [UnsupportedError] on iOS, where there is
  /// nothing to stream from: APNs hands the device token to the host app's
  /// own `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`,
  /// never to the plugin. An app that needs the token already has it there,
  /// and passes it to [registerToken]. A stream that stayed open and never
  /// emitted would be indistinguishable from an app whose token simply never
  /// refreshes, so this says so instead.
  Stream<String> get tokens {
    _ensureAndroidOnly(
      'DyplinkPush.tokens',
      'iOS delivers the APNs device token to the host app, not to the plugin',
    );
    _tokenController ??= StreamController<String>.broadcast(
      onListen: _onTokenListen,
      onCancel: _onTokenCancel,
    );
    return _tokenController!.stream;
  }

  Future<void> _onTokenListen() async {
    try {
      await hostApi.startTokenStream();
    } on PlatformException catch (e) {
      // The stream stays open either way, so the failure is only visible as
      // an absence of tokens — which is exactly what this reports.
      DyplinkDiagnostics.reportFailure('DyplinkPush.tokens (start)', e);
    }
    _tokenSub = _tokenChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is String) _tokenController?.add(event);
      },
      onError: (Object err) {
        _tokenController?.addError(err);
      },
    );
  }

  Future<void> _onTokenCancel() async {
    await _tokenSub?.cancel();
    _tokenSub = null;
    try {
      await hostApi.stopTokenStream();
    } on PlatformException catch (e) {
      DyplinkDiagnostics.reportFailure('DyplinkPush.tokens (stop)', e);
    }
  }

  // ── Push engagement reporting ──────────────────────────────────────────────
  //
  // Flutter apps drive push handling through firebase_messaging's own
  // callbacks (onMessage, onMessageOpenedApp, background handlers). This
  // SDK does not intercept those — it just accepts the message's data map
  // and reports it, if it is a Dyplink campaign push.
  //
  // This is deliberately pure Dart, not routed through Pigeon: the data
  // originates in Dart already (from firebase_messaging), the POST is a
  // single fire-and-forget call with no queueing/retry needs, and the same
  // code then serves both platforms — it predates the iOS bridge and kept
  // working on iOS while the rest of the module did not.

  /// Reports that a Dyplink push notification was delivered to this device.
  ///
  /// Call this with the raw FCM data payload — e.g. from
  /// `firebase_messaging`'s `FirebaseMessaging.onMessage` (foreground) or
  /// `FirebaseMessaging.onBackgroundMessage` (background/terminated)
  /// handlers, passing `message.data`.
  ///
  /// [metadata] is stored alongside the event and returned with the
  /// campaign's report. Use it for anything the campaign report should be
  /// able to break down by that the payload does not already carry.
  ///
  /// No-ops if [data] has no `dyplink_campaign_id` key (the push did not
  /// originate from a Dyplink campaign) or if [Dyplink.init] has not been
  /// called yet. Never throws — a network failure is swallowed so it can
  /// never block or break notification handling. Turn on
  /// [DyplinkDiagnostics] to see the failures this hides.
  Future<void> reportNotificationReceived(
    Map<String, dynamic> data, {
    Map<String, Object?>? metadata,
  }) =>
      _reportEvent(data, 'delivered', metadata: metadata);

  /// Reports that a Dyplink push notification was shown to the user.
  ///
  /// Distinct from [reportNotificationReceived]: delivery is the device
  /// taking the message, an impression is the user having had the chance to
  /// see it. A push that arrives while notifications are blocked is
  /// delivered but never seen, and a campaign judged on click-through needs
  /// the second number as its denominator.
  ///
  /// Flutter has no notification UI of its own, so there is no moment this
  /// SDK can detect for you — report it from wherever the app knows the
  /// notification was actually presented.
  ///
  /// Same no-op-if-not-a-campaign and never-throws semantics as
  /// [reportNotificationReceived].
  Future<void> reportNotificationImpression(
    Map<String, dynamic> data, {
    Map<String, Object?>? metadata,
  }) =>
      _reportEvent(data, 'impression', metadata: metadata);

  /// Reports that the user dismissed a Dyplink push notification without
  /// acting on it — swiped it away, or cleared the shade.
  ///
  /// A dismissal is the negative signal a campaign's report has no other way
  /// to get: without it, a notification the user actively rejected is
  /// indistinguishable from one they never looked at.
  ///
  /// Same no-op-if-not-a-campaign and never-throws semantics as
  /// [reportNotificationReceived].
  Future<void> reportNotificationDismissed(
    Map<String, dynamic> data, {
    Map<String, Object?>? metadata,
  }) =>
      _reportEvent(data, 'dismissed', metadata: metadata);

  /// One frame of a campaign's carousel.
  ///
  /// Returned rather than rendered: Flutter has no notification UI of its own,
  /// and the native SDKs draw the notification before Dart is running. An app
  /// that wants to show these has to build the screen itself, which is why
  /// they are surfaced as data.
  static List<PushCarouselSlide> carouselFrom(Map<String, dynamic> data) {
    final raw = data[_carouselDataKey];
    if (raw is! String || raw.isEmpty) return const <PushCarouselSlide>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <PushCarouselSlide>[];
      return decoded
          .whereType<Map<Object?, Object?>>()
          .map(PushCarouselSlide.fromMap)
          // A slide with no image is a blank frame, so it is dropped rather
          // than shown empty.
          .where((slide) => slide.imageUrl.isNotEmpty)
          .toList(growable: false);
    } on FormatException {
      // Malformed content costs the extras, never the notification.
      return const <PushCarouselSlide>[];
    }
  }

  /// A campaign's image, or null when it carries none.
  ///
  /// Only a campaign delivered over APNs or Mi Push carries this: FCM has an
  /// image field of its own and its client SDK renders it without help. So a
  /// null here does not mean the notification had no picture — it means
  /// there is none for the app to draw itself.
  static String? imageUrlFrom(Map<String, dynamic> data) {
    final raw = data[_imageUrlDataKey];
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  /// A campaign's action buttons, in the order the campaign set them.
  ///
  /// Surfaced for the same reason as [carouselFrom]: the native SDK has
  /// already drawn the notification by the time Dart is running, so this is
  /// for the app's own use rather than for rendering the notification.
  /// Android's SDK renders at most three of these on the notification itself,
  /// and iOS renders none from a payload.
  static List<PushAction> actionsFrom(Map<String, dynamic> data) {
    final raw = data[_actionsDataKey];
    if (raw is! String || raw.isEmpty) return const <PushAction>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <PushAction>[];
      return decoded
          .whereType<Map<Object?, Object?>>()
          .map(PushAction.fromMap)
          .whereType<PushAction>()
          .toList(growable: false);
    } on FormatException {
      // Malformed content costs the extras, never the notification.
      return const <PushAction>[];
    }
  }

  /// A campaign's countdown, or null when it carries none or an unusable one.
  static PushTimer? timerFrom(Map<String, dynamic> data) {
    final raw = data[_timerDataKey];
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return PushTimer.fromMap(decoded.cast<Object?, Object?>());
    } on FormatException {
      return null;
    }
  }

  /// Reports that the user tapped a Dyplink push notification, and returns
  /// the destination URL so the app can route to it.
  ///
  /// Call this from `firebase_messaging`'s `FirebaseMessaging.onMessageOpenedApp`
  /// listener, or after `FirebaseMessaging.instance.getInitialMessage()`
  /// resolves to a non-null message on cold start, passing `message.data`:
  /// ```dart
  /// final url = await DyplinkPush.instance.reportNotificationClicked(message.data);
  /// if (url != null) router.go(url);
  /// ```
  ///
  /// Pass [actionId] when the tap was on one of the campaign's action
  /// buttons rather than the notification body — the id of the
  /// [PushAction] the user pressed. It is reported as `metadata.actionId`,
  /// which is what lets a campaign's report separate "pressed Buy now" from
  /// "tapped the notification"; the same key the Android SDK sends. Without
  /// it, a button tap is indistinguishable from a body tap.
  ///
  /// ```dart
  /// final actions = DyplinkPush.actionsFrom(message.data);
  /// final url = await DyplinkPush.instance.reportNotificationClicked(
  ///   message.data,
  ///   actionId: actions.first.id,
  /// );
  /// ```
  ///
  /// Returns the pressed [PushAction]'s own `deepLinkUrl` when [actionId]
  /// names a button that has one. Otherwise returns the campaign's
  /// destination, taken from the payload's `deep_link_url` key and falling
  /// back to `link` — the same precedence the Android SDK uses. Returns null
  /// when the campaign carried no destination, when either key holds
  /// something other than a non-empty string, or when [data] is not a Dyplink
  /// campaign push at all.
  ///
  /// [metadata] is merged under the reported `metadata` object. An
  /// `actionId` key in it is overwritten by [actionId] when both are given.
  ///
  /// The URL is *also* emitted on [Dyplink.deepLinks], so apps already
  /// listening there handle push taps through the same channel as every other
  /// link. That path is best-effort only: on cold start the click is
  /// typically reported before the widget tree is up, so nothing is
  /// subscribed yet and the event goes nowhere. The returned value is the
  /// reliable channel — prefer it, and treat the stream as a convenience.
  ///
  /// Same no-op-if-not-a-campaign and never-throws semantics as
  /// [reportNotificationReceived]. Extracting the URL is independent of
  /// reporting it, so a failed analytics call still yields the destination.
  Future<String?> reportNotificationClicked(
    Map<String, dynamic> data, {
    String? actionId,
    Map<String, Object?>? metadata,
  }) async {
    if (_campaignIdFrom(data) == null) return null;

    final deepLinkUrl = _destinationFor(data, actionId);
    if (deepLinkUrl != null) {
      // Ahead of the report, so a slow POST can never delay routing. No-ops
      // unless the app has already opened the deep-link stream.
      Dyplink.instance.emitDeepLink(
        DeepLinkResult(url: deepLinkUrl, isDeferred: false),
      );
    }

    try {
      await _reportEvent(
        data,
        'click',
        metadata: actionId == null
            ? metadata
            : <String, Object?>{...?metadata, 'actionId': actionId},
      );
    } catch (_) {
      // Belt-and-braces: _reportEvent already swallows its own failures, but
      // analytics must never cost the caller the URL — the user still has to
      // reach the destination.
    }
    return deepLinkUrl;
  }

  /// Where a tap should go: the pressed button's own destination when it has
  /// one, else the campaign's.
  ///
  /// An [actionId] that matches no button, or matches one with no
  /// `deepLinkUrl`, falls through to the campaign's own destination rather
  /// than to null — a button is an additional way into the campaign, so the
  /// campaign's destination is the right default for one that names none.
  String? _destinationFor(Map<String, dynamic> data, String? actionId) {
    if (actionId != null) {
      for (final action in actionsFrom(data)) {
        if (action.id == actionId) {
          final actionUrl = action.deepLinkUrl;
          if (actionUrl != null) return actionUrl;
          break;
        }
      }
    }
    return _deepLinkFrom(data);
  }

  /// The Dyplink campaign ID in [data], or null if this is not a campaign
  /// push (key absent, or present but blank).
  String? _campaignIdFrom(Map<String, dynamic> data) {
    final rawCampaignId = data[_campaignIdDataKey];
    if (rawCampaignId == null) return null;
    final campaignId = rawCampaignId.toString();
    return campaignId.isEmpty ? null : campaignId;
  }

  /// The destination URL in [data], or null if the push carried none.
  ///
  /// [data] comes straight off the platform channel and may hold anything, so
  /// a value that is not a non-empty [String] is treated as absent and the
  /// next key in [_deepLinkDataKeys] is tried.
  String? _deepLinkFrom(Map<String, dynamic> data) {
    for (final key in _deepLinkDataKeys) {
      final value = data[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }

  Future<void> _reportEvent(
    Map<String, dynamic> data,
    String type, {
    Map<String, Object?>? metadata,
  }) async {
    // A push that is not a Dyplink campaign is the ordinary case for an app
    // that also sends its own, so it is not worth a diagnostic.
    final campaignId = _campaignIdFrom(data);
    if (campaignId == null) return;

    final config = Dyplink.instance.currentConfig;
    if (config == null) {
      DyplinkDiagnostics.reportSkipped(
        'push "$type" report',
        'Dyplink.init has not been called, so there is no project to report to',
      );
      return;
    }

    final platform = platformName();
    if (platform == null) {
      DyplinkDiagnostics.reportSkipped(
        'push "$type" report',
        'the backend does not accept events from this platform',
      );
      return;
    }

    final String deviceFingerprint;
    try {
      deviceFingerprint = await deviceFingerprintProvider();
    } catch (e) {
      // No fingerprint to report with: `Dyplink.init` has not run, or this
      // is a platform the native bridge does not cover (web, desktop).
      DyplinkDiagnostics.reportFailure(
        'push "$type" report (device fingerprint)',
        e,
      );
      return;
    }

    final body = <String, Object?>{
      'projectId': config.projectId,
      'campaignId': campaignId,
      'deviceFingerprint': deviceFingerprint,
      'type': type,
      'platform': platform,
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
      // Omitted rather than sent null: the backend's DTO validates
      // `metadata` as an object when present, and rejects the whole event
      // on anything else.
      if (metadata != null && metadata.isNotEmpty) 'metadata': metadata,
    };

    try {
      await postEvent(config.baseUrl, config.apiKey, body);
    } catch (e) {
      // Reporting is best-effort — never propagate a transport failure.
      DyplinkDiagnostics.reportFailure('push "$type" report', e);
    }
  }

  /// Resolved through [DyplinkPlatform] rather than `dart:io` so tests can
  /// reach both branches; see that class for why.
  static bool get _supported => DyplinkPlatform.isSupported;

  void _ensureSupported() {
    if (!_supported) {
      throw UnsupportedError(
        'DyplinkPush supports Android and iOS only; this is '
        '${DyplinkPlatform.description}.',
      );
    }
  }

  /// Guard for the two members that are Android-only even now that the rest
  /// of the module works on iOS — [tokens] and [registerMiPushToken]. Each
  /// says why in its own dartdoc.
  void _ensureAndroidOnly(String member, String reason) {
    if (!DyplinkPlatform.isAndroid) {
      throw UnsupportedError(
        '$member is Android-only: $reason. Platform is '
        '${DyplinkPlatform.description}.',
      );
    }
  }
}

String? _defaultPlatformName() => DyplinkPlatform.name;

Future<void> _defaultPostEvent(
  String baseUrl,
  String apiKey,
  Map<String, Object?> body,
) async {
  final normalizedBase =
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .postUrl(Uri.parse('$normalizedBase/api/push-notifications/events'))
        .timeout(const Duration(seconds: 10));
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.set('x-api-key', apiKey);
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 10));
    await response.drain<void>().timeout(const Duration(seconds: 10));
  } finally {
    client.close(force: true);
  }
}
