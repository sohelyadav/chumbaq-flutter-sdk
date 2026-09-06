import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpHeaders, Platform;

import 'package:flutter/services.dart';

import 'dyplink_core.dart';
import 'dyplink_error.dart';
import 'pigeon.g.dart' as pg;

/// Data-payload key that Dyplink stamps onto outgoing FCM messages for a
/// campaign push. Its absence means the notification did not originate
/// from a Dyplink campaign, so engagement reporting is skipped.
const String _campaignIdDataKey = 'dyplink_campaign_id';

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
/// FirebaseMessaging.onMessageOpenedApp.listen(
///   (message) => DyplinkPush.instance.reportNotificationClicked(message.data),
/// );
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

  /// Reports that the user tapped a Dyplink push notification.
  ///
  /// Call this from `firebase_messaging`'s `FirebaseMessaging.onMessageOpenedApp`
  /// listener, or after `FirebaseMessaging.instance.getInitialMessage()`
  /// resolves to a non-null message on cold start, passing `message.data`.
  ///
  /// Same no-op-if-not-a-campaign and never-throws semantics as
  /// [reportNotificationReceived].
  Future<void> reportNotificationClicked(Map<String, dynamic> data) =>
      _reportEvent(data, 'click');

  Future<void> _reportEvent(Map<String, dynamic> data, String type) async {
    final rawCampaignId = data[_campaignIdDataKey];
    if (rawCampaignId == null) return;
    final campaignId = rawCampaignId.toString();
    if (campaignId.isEmpty) return;

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
