import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'dyplink_error.dart';
import 'dyplink_models.dart';
import 'pigeon.g.dart' as pg;

/// Main entry point for the Dyplink Flutter SDK.
///
/// Initialize once at app startup:
/// ```dart
/// final config = DyplinkConfig.builder(
///   baseUrl: 'https://api.dyplink.com',
///   apiKey: 'your-api-key',
///   projectId: 'your-project-id',
/// ).logLevel(DyplinkLogLevel.debug).build();
///
/// await Dyplink.instance.init(config);
/// ```
class Dyplink {
  Dyplink._();
  static final Dyplink instance = Dyplink._();

  // Visible for testing — lets tests inject a mock HostApi.
  // ignore: public_member_api_docs
  pg.DyplinkHostApi hostApi = pg.DyplinkHostApi();

  /// The configuration most recently applied via [init], or null if [init]
  /// has not yet succeeded.
  ///
  /// Not part of the package's curated public API (see `lib/dyplink.dart`),
  /// but left public within the library so other modules — e.g.
  /// `DyplinkPush` push-event reporting — can reach baseUrl/apiKey/projectId
  /// without the host app having to supply them a second time.
  // ignore: public_member_api_docs
  DyplinkConfig? currentConfig;

  // Deep link stream state. We own a broadcast StreamController so multiple
  // subscribers share a single native listener, and we wire start/stop of
  // the native listener to the first-listen / last-cancel edges.
  StreamController<DeepLinkResult>? _deepLinkController;
  StreamSubscription<Object?>? _deepLinkSub;

  static const EventChannel _deepLinkChannel =
      EventChannel('com.dyplink.dyplink/deep_links');

  /// Whether the SDK has been successfully initialized on the native side.
  Future<bool> get isInitialized =>
      _supported ? runCatchingDyplink(hostApi.isInitialized) : Future.value(false);

  /// The current distinct ID (anonymous or identified).
  ///
  /// Throws [DyplinkNotInitialized] if called before [init].
  Future<String> get distinctId {
    _ensureSupported();
    return runCatchingDyplink(hostApi.distinctId);
  }

  /// The stable device fingerprint UUID.
  ///
  /// Throws [DyplinkNotInitialized] if called before [init].
  Future<String> get deviceFingerprint {
    _ensureSupported();
    return runCatchingDyplink(hostApi.deviceFingerprint);
  }

  /// Initialize the SDK. Safe to call more than once — subsequent calls are
  /// no-ops on the native side. Throws [DyplinkInvalidConfig] if config is
  /// missing required fields.
  Future<void> init(DyplinkConfig config) {
    _ensureSupported();
    return runCatchingDyplink(() async {
      await hostApi.initialize(config.toDto());
      currentConfig = config;
    });
  }

  /// Identify the current user with the given parameters.
  ///
  /// Throws [DyplinkNotInitialized], [DyplinkNetworkError], or
  /// [DyplinkApiError] on failure.
  Future<IdentifyResult> identify(IdentifyParams params) async {
    _ensureSupported();
    return runCatchingDyplink(() async {
      final dto = await hostApi.identify(params.toDto());
      return IdentifyResult.fromDto(dto);
    });
  }

  /// Track a custom event. Fire-and-forget — events are queued natively and
  /// flushed in batches.
  Future<void> track(String eventName, {Map<String, Object>? properties}) {
    _ensureSupported();
    return runCatchingDyplink(
      () => hostApi.track(eventName, properties),
    );
  }

  /// Track a conversion event with attribution data.
  Future<void> trackConversion(TrackConversionParams params) {
    _ensureSupported();
    return runCatchingDyplink(
      () => hostApi.trackConversion(params.toDto()),
    );
  }

  /// Track a revenue event for the current device.
  Future<void> trackRevenue(double amount, {String currency = 'USD'}) {
    _ensureSupported();
    return runCatchingDyplink(
      () => hostApi.trackRevenue(amount, currency),
    );
  }

  /// Attempt a deferred deep link match against the Dyplink backend.
  ///
  /// Typically called once on first launch after install. If the user
  /// clicked a Dyplink before installing, the server returns the original
  /// link params here.
  Future<DeferredMatchResult> matchDeferredDeepLink() async {
    _ensureSupported();
    return runCatchingDyplink(() async {
      final dto = await hostApi.matchDeferredDeepLink();
      return DeferredMatchResult.fromDto(dto);
    });
  }

  /// Returns the attributed short code from a prior deferred match, or null.
  Future<String?> getAttributedShortCode() {
    _ensureSupported();
    return runCatchingDyplink(hostApi.getAttributedShortCode);
  }

  /// Returns the attributed link ID from a prior deferred match, or null.
  Future<String?> getAttributedLinkId() {
    _ensureSupported();
    return runCatchingDyplink(hostApi.getAttributedLinkId);
  }

  /// Reset identity. Call on user logout — generates a fresh anonymous ID.
  Future<void> reset() {
    _ensureSupported();
    return runCatchingDyplink(hostApi.reset);
  }

  /// Immediately flush all queued events to the backend.
  Future<void> flush() {
    _ensureSupported();
    return runCatchingDyplink(hostApi.flush);
  }

  /// Broadcast stream of deep link events (both direct and deferred).
  ///
  /// Subscribe from a `StatefulWidget`:
  /// ```dart
  /// Dyplink.instance.deepLinks.listen((link) {
  ///   Navigator.of(context).pushNamed(link.url);
  /// });
  /// ```
  ///
  /// The native deep-link listener is attached when the first subscriber
  /// appears and detached when the last one cancels.
  Stream<DeepLinkResult> get deepLinks {
    _ensureSupported();
    _deepLinkController ??= StreamController<DeepLinkResult>.broadcast(
      onListen: _onDeepLinkListen,
      onCancel: _onDeepLinkCancel,
    );
    return _deepLinkController!.stream;
  }

  Future<void> _onDeepLinkListen() async {
    try {
      await hostApi.startDeepLinkStream();
    } on PlatformException {
      // Swallow — the stream will still be open; we just won't emit events.
    }
    _deepLinkSub = _deepLinkChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final result = DeepLinkResult.fromEventMap(
            event.cast<Object?, Object?>(),
          );
          _deepLinkController?.add(result);
        }
      },
      onError: (Object err) {
        _deepLinkController?.addError(err);
      },
    );
  }

  Future<void> _onDeepLinkCancel() async {
    await _deepLinkSub?.cancel();
    _deepLinkSub = null;
    try {
      await hostApi.stopDeepLinkStream();
    } on PlatformException {
      // No-op.
    }
  }

  // ── Platform support ────────────────────────────────────────────────────

  /// Whether the current platform is supported. Returns false on iOS, web,
  /// desktop — the iOS SDK is not yet built.
  static bool get _supported => Platform.isAndroid;

  void _ensureSupported() {
    if (!_supported) {
      throw UnsupportedError(
        'Dyplink currently only supports Android. iOS support is coming soon.',
      );
    }
  }
}
