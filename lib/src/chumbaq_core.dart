import 'dart:async';

import 'package:flutter/services.dart';

import 'chumbaq_diagnostics.dart';
import 'chumbaq_error.dart';
import 'chumbaq_models.dart';
import 'chumbaq_platform.dart';
import 'pigeon.g.dart' as pg;

/// Main entry point for the Chumbaq Flutter SDK.
///
/// Initialize once at app startup:
/// ```dart
/// final config = ChumbaqConfig.builder(
///   baseUrl: 'https://api.chumbaq.com',
///   apiKey: 'your-api-key',
///   projectId: 'your-project-id',
/// ).logLevel(ChumbaqLogLevel.debug).build();
///
/// await Chumbaq.instance.init(config);
/// ```
class Chumbaq {
  Chumbaq._();
  static final Chumbaq instance = Chumbaq._();

  // Visible for testing — lets tests inject a mock HostApi.
  // ignore: public_member_api_docs
  pg.ChumbaqHostApi hostApi = pg.ChumbaqHostApi();

  /// The configuration most recently applied via [init], or null if [init]
  /// has not yet succeeded.
  ///
  /// Not part of the package's curated public API (see `lib/chumbaq.dart`),
  /// but left public within the library so other modules — e.g.
  /// `ChumbaqPush` push-event reporting — can reach baseUrl/apiKey/projectId
  /// without the host app having to supply them a second time.
  // ignore: public_member_api_docs
  ChumbaqConfig? currentConfig;

  // Deep link stream state. We own a broadcast StreamController so multiple
  // subscribers share a single native listener, and we wire start/stop of
  // the native listener to the first-listen / last-cancel edges.
  StreamController<DeepLinkResult>? _deepLinkController;
  StreamSubscription<Object?>? _deepLinkSub;

  static const EventChannel _deepLinkChannel =
      EventChannel('com.chumbaq.chumbaq/deep_links');

  /// Whether the SDK has been successfully initialized on the native side.
  ///
  /// Answers false rather than throwing on a platform the native plugin does
  /// not support, so feature detection does not need a `try`. See the
  /// README's platform-support section for the full list of members that
  /// answer instead of throwing.
  Future<bool> get isInitialized =>
      _supported ? runCatchingChumbaq(hostApi.isInitialized) : Future.value(false);

  /// The current distinct ID (anonymous or identified).
  ///
  /// Throws [ChumbaqNotInitialized] if called before [init].
  Future<String> get distinctId {
    _ensureSupported();
    return runCatchingChumbaq(hostApi.distinctId);
  }

  /// The stable device fingerprint UUID.
  ///
  /// Throws [ChumbaqNotInitialized] if called before [init].
  Future<String> get deviceFingerprint {
    _ensureSupported();
    return runCatchingChumbaq(hostApi.deviceFingerprint);
  }

  /// Initialize the SDK. Safe to call more than once — subsequent calls are
  /// no-ops on the native side. Throws [ChumbaqInvalidConfig] if config is
  /// missing required fields.
  Future<void> init(ChumbaqConfig config) {
    _ensureSupported();
    return runCatchingChumbaq(() async {
      await hostApi.initialize(config.toDto());
      currentConfig = config;
    });
  }

  /// Identify the current user with the given parameters.
  ///
  /// Throws [ChumbaqNotInitialized], [ChumbaqNetworkError], or
  /// [ChumbaqApiError] on failure.
  Future<IdentifyResult> identify(IdentifyParams params) async {
    _ensureSupported();
    return runCatchingChumbaq(() async {
      final dto = await hostApi.identify(params.toDto());
      return IdentifyResult.fromDto(dto);
    });
  }

  /// Track a custom event. Fire-and-forget — events are queued natively and
  /// flushed in batches.
  Future<void> track(String eventName, {Map<String, Object>? properties}) {
    _ensureSupported();
    return runCatchingChumbaq(
      () => hostApi.track(eventName, properties),
    );
  }

  /// Track a conversion event with attribution data.
  Future<void> trackConversion(TrackConversionParams params) {
    _ensureSupported();
    return runCatchingChumbaq(
      () => hostApi.trackConversion(params.toDto()),
    );
  }

  /// Track a revenue event for the current device.
  Future<void> trackRevenue(double amount, {String currency = 'USD'}) {
    _ensureSupported();
    return runCatchingChumbaq(
      () => hostApi.trackRevenue(amount, currency),
    );
  }

  /// Attempt a deferred deep link match against the Chumbaq backend.
  ///
  /// Typically called once on first launch after install. If the user
  /// clicked a Chumbaq before installing, the server returns the original
  /// link params here.
  Future<DeferredMatchResult> matchDeferredDeepLink() async {
    _ensureSupported();
    return runCatchingChumbaq(() async {
      final dto = await hostApi.matchDeferredDeepLink();
      return DeferredMatchResult.fromDto(dto);
    });
  }

  /// Returns the attributed short code from a prior deferred match, or null.
  Future<String?> getAttributedShortCode() {
    _ensureSupported();
    return runCatchingChumbaq(hostApi.getAttributedShortCode);
  }

  /// Returns the attributed link ID from a prior deferred match, or null.
  Future<String?> getAttributedLinkId() {
    _ensureSupported();
    return runCatchingChumbaq(hostApi.getAttributedLinkId);
  }

  /// Reset identity. Call on user logout — generates a fresh anonymous ID.
  Future<void> reset() {
    _ensureSupported();
    return runCatchingChumbaq(hostApi.reset);
  }

  /// Immediately flush all queued events to the backend.
  Future<void> flush() {
    _ensureSupported();
    return runCatchingChumbaq(hostApi.flush);
  }

  /// Broadcast stream of deep link events (both direct and deferred).
  ///
  /// Subscribe from a `StatefulWidget`:
  /// ```dart
  /// Chumbaq.instance.deepLinks.listen((link) {
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
    } on PlatformException catch (e) {
      // Swallow — the stream will still be open; we just won't emit events.
      // Which is indistinguishable from "no links arrived", hence the report.
      ChumbaqDiagnostics.reportFailure('Chumbaq.deepLinks (start)', e);
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
    } on PlatformException catch (e) {
      ChumbaqDiagnostics.reportFailure('Chumbaq.deepLinks (stop)', e);
    }
  }

  /// Publishes [link] on the [deepLinks] stream, but only if that stream has
  /// already been opened. Returns whether the event was actually published.
  ///
  /// Deliberately does *not* create the controller the way the [deepLinks]
  /// getter does: creating it here would attach the native deep-link listener
  /// as a side effect of an unrelated call. So this is best-effort by design
  /// — a caller that must not lose the link needs its own delivery path.
  ///
  /// Unlike [deepLinks] this never throws, on any platform.
  ///
  /// Not part of the package's curated public API (see `lib/chumbaq.dart`),
  /// but left public within the library so other modules — e.g. `ChumbaqPush`
  /// routing the destination of a tapped push notification — can feed the
  /// stream apps already listen to.
  bool emitDeepLink(DeepLinkResult link) {
    final controller = _deepLinkController;
    if (controller == null || controller.isClosed) {
      ChumbaqDiagnostics.reportSkipped(
        'Chumbaq.emitDeepLink',
        'nothing has subscribed to Chumbaq.deepLinks yet, so the link was '
            'not published — use the value returned by the call that '
            'produced it',
      );
      return false;
    }
    controller.add(link);
    return true;
  }

  // ── Platform support ────────────────────────────────────────────────────

  /// Whether the current platform is supported. False on web and desktop —
  /// the plugin has a native bridge for Android and iOS only.
  ///
  /// Resolved through [ChumbaqPlatform] rather than `dart:io` so tests can
  /// reach both branches; see that class for why.
  static bool get _supported => ChumbaqPlatform.isSupported;

  void _ensureSupported() {
    if (!_supported) {
      throw UnsupportedError(
        'Chumbaq supports Android and iOS only; this is '
        '${ChumbaqPlatform.description}.',
      );
    }
  }
}
