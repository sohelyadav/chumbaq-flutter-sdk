import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpHeaders, Platform;

import 'package:flutter/services.dart';

import 'dyplink_core.dart';
import 'dyplink_error.dart';
import 'dyplink_models.dart';
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

/// Optional push notification module for the Dyplink SDK.
///
/// Call [init] after [Dyplink.init] to enable automatic FCM push token
/// management. This module wraps the native Dyplink Push module, which in
/// turn wraps Firebase Messaging.
///
/// It also reports push engagement (delivered / clicked) for Dyplink
/// campaigns — see [reportNotificationReceived] and
/// [reportNotificationClicked]. Unlike token management, engagement
/// reporting is a pure-Dart HTTP call: it works on both Android and iOS,
/// and only requires [Dyplink.init] to have been called, not [init].
///
/// Usage:
/// ```dart
/// await Dyplink.instance.init(config);
/// await DyplinkPush.instance.init();
///
/// // Listen for FCM token updates (if any emit).
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
  /// this to exercise the reporting path.
  // ignore: public_member_api_docs
  String? Function() platformName = _defaultPlatformName;

  /// Resolves the device fingerprint attached to engagement events.
  /// Defaults to [Dyplink.instance]'s `deviceFingerprint`.
  ///
  /// Visible for testing — the default forwards to core `Dyplink`, which is
  /// itself platform-gated (Android only, for now); tests override this to
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
  Future<bool> get isInitialized =>
      _supported ? runCatchingDyplink(hostApi.isInitialized) : Future.value(false);

  /// Whether an FCM token is currently registered with the Dyplink backend.
  Future<bool> get isRegistered =>
      _supported ? runCatchingDyplink(hostApi.isRegistered) : Future.value(false);

  /// Manually register an FCM token.
  Future<void> registerToken(String token) {
    _ensureSupported();
    return runCatchingDyplink(() => hostApi.registerToken(token));
  }

  /// Unregister the current FCM token. Call on user logout.
  Future<void> unregisterToken() {
    _ensureSupported();
    return runCatchingDyplink(hostApi.unregisterToken);
  }

  /// Broadcast stream of FCM token updates.
  ///
  /// Note: the current native SDK does not yet emit token-refresh events
  /// on this channel — subscribing is safe but may not yield values until
  /// the underlying SDK exposes a refresh hook.
  Stream<String> get tokens {
    _ensureSupported();
    _tokenController ??= StreamController<String>.broadcast(
      onListen: _onTokenListen,
      onCancel: _onTokenCancel,
    );
    return _tokenController!.stream;
  }

  Future<void> _onTokenListen() async {
    try {
      await hostApi.startTokenStream();
    } on PlatformException {
      // No-op.
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
    } on PlatformException {
      // No-op.
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
  // single fire-and-forget call with no queueing/retry needs, and it must
  // work on iOS even though the native push token module above does not
  // support iOS yet.

  /// Reports that a Dyplink push notification was delivered to this device.
  ///
  /// Call this with the raw FCM data payload — e.g. from
  /// `firebase_messaging`'s `FirebaseMessaging.onMessage` (foreground) or
  /// `FirebaseMessaging.onBackgroundMessage` (background/terminated)
  /// handlers, passing `message.data`.
  ///
  /// No-ops if [data] has no `dyplink_campaign_id` key (the push did not
  /// originate from a Dyplink campaign) or if [Dyplink.init] has not been
  /// called yet. Never throws — a network failure is swallowed so it can
  /// never block or break notification handling.
  Future<void> reportNotificationReceived(Map<String, dynamic> data) =>
      _reportEvent(data, 'delivered');

  /// Reports that the user tapped a Dyplink push notification, and returns
  /// the campaign's destination URL so the app can route to it.
  ///
  /// Call this from `firebase_messaging`'s `FirebaseMessaging.onMessageOpenedApp`
  /// listener, or after `FirebaseMessaging.instance.getInitialMessage()`
  /// resolves to a non-null message on cold start, passing `message.data`:
  /// ```dart
  /// final url = await DyplinkPush.instance.reportNotificationClicked(message.data);
  /// if (url != null) router.go(url);
  /// ```
  ///
  /// Returns the URL taken from the payload's `deep_link_url` key, falling
  /// back to `link` — the same precedence the Android SDK uses. Returns null
  /// when the campaign carried no destination, when either key holds
  /// something other than a non-empty string, or when [data] is not a Dyplink
  /// campaign push at all.
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

  Future<String?> reportNotificationClicked(Map<String, dynamic> data) async {
    if (_campaignIdFrom(data) == null) return null;

    final deepLinkUrl = _deepLinkFrom(data);
    if (deepLinkUrl != null) {
      // Ahead of the report, so a slow POST can never delay routing. No-ops
      // unless the app has already opened the deep-link stream.
      Dyplink.instance.emitDeepLink(
        DeepLinkResult(url: deepLinkUrl, isDeferred: false),
      );
    }

    try {
      await _reportEvent(data, 'click');
    } catch (_) {
      // Belt-and-braces: _reportEvent already swallows its own failures, but
      // analytics must never cost the caller the URL — the user still has to
      // reach the destination.
    }
    return deepLinkUrl;
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

  Future<void> _reportEvent(Map<String, dynamic> data, String type) async {
    final campaignId = _campaignIdFrom(data);
    if (campaignId == null) return;

    final config = Dyplink.instance.currentConfig;
    if (config == null) return;

    final platform = platformName();
    if (platform == null) return;

    final String deviceFingerprint;
    try {
      deviceFingerprint = await deviceFingerprintProvider();
    } catch (_) {
      // Core SDK not ready on this platform yet (e.g. iOS support is still
      // native-side "coming soon") — nothing sensible to report.
      return;
    }

    final body = <String, Object?>{
      'projectId': config.projectId,
      'campaignId': campaignId,
      'deviceFingerprint': deviceFingerprint,
      'type': type,
      'platform': platform,
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    };

    try {
      await postEvent(config.baseUrl, config.apiKey, body);
    } catch (_) {
      // Reporting is best-effort — never propagate a transport failure.
    }
  }

  static bool get _supported => Platform.isAndroid;

  void _ensureSupported() {
    if (!_supported) {
      throw UnsupportedError(
        'DyplinkPush currently only supports Android. iOS support is coming soon.',
      );
    }
  }
}

String? _defaultPlatformName() =>
    Platform.isAndroid ? 'android' : Platform.isIOS ? 'ios' : null;

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
