import 'dart:async';

import 'package:flutter/services.dart';

import 'dyplink_diagnostics.dart';
import 'dyplink_error.dart';
import 'dyplink_models.dart';
import 'dyplink_platform.dart';
import 'pigeon.g.dart' as pg;

/// In-app messages module.
///
/// The native Dyplink SDK renders all in-app message UI (modals, bottom
/// sheets, banners, fullscreen overlays) itself — you do not build the UI
/// in Flutter. This class exposes:
///
/// 1. Trigger points ([onAppOpen], [onScreenView], [onEvent]) that ask the
///    native SDK to check for messages and display any that match.
/// 2. A broadcast stream [events] of user interactions with those messages.
///
/// Usage:
/// ```dart
/// // On app foreground:
/// await DyplinkMessages.instance.onAppOpen();
///
/// // On navigation:
/// await DyplinkMessages.instance.onScreenView('HomeScreen');
///
/// // Subscribe to interactions:
/// DyplinkMessages.instance.events.listen((event) {
///   switch (event) {
///     case MessageLifecycleEvent(:final eventType): ...
///     case MessageButtonAction(:final button):      ...
///     case MessageCustomEvent(:final eventName):    ...
///   }
/// });
/// ```
class DyplinkMessages {
  DyplinkMessages._();
  static final DyplinkMessages instance = DyplinkMessages._();

  // ignore: public_member_api_docs
  pg.DyplinkMessagesHostApi hostApi = pg.DyplinkMessagesHostApi();

  StreamController<MessageEvent>? _eventController;
  StreamSubscription<Object?>? _eventSub;

  static const EventChannel _eventChannel =
      EventChannel('com.dyplink.dyplink/message_events');

  /// Check for and display any `on_app_open` or scheduled messages.
  /// Call from the app's foreground lifecycle callback.
  Future<void> onAppOpen() {
    _ensureSupported();
    return runCatchingDyplink(hostApi.onAppOpen);
  }

  /// Check for and display any `on_screen` messages targeting [screen].
  Future<void> onScreenView(String screen) {
    _ensureSupported();
    return runCatchingDyplink(() => hostApi.onScreenView(screen));
  }

  /// Check for and display any `on_event` messages targeting [event].
  Future<void> onEvent(String event) {
    _ensureSupported();
    return runCatchingDyplink(() => hostApi.onEvent(event));
  }

  /// Broadcast stream of in-app message interactions.
  ///
  /// Emits a subclass of [MessageEvent] — use Dart pattern matching to
  /// handle each case.
  Stream<MessageEvent> get events {
    _ensureSupported();
    _eventController ??= StreamController<MessageEvent>.broadcast(
      onListen: _onEventListen,
      onCancel: _onEventCancel,
    );
    return _eventController!.stream;
  }

  Future<void> _onEventListen() async {
    try {
      await hostApi.startMessageEventStream();
    } on PlatformException catch (e) {
      // The stream stays open, so the failure would otherwise look like an
      // app that simply has no messages targeting it.
      DyplinkDiagnostics.reportFailure('DyplinkMessages.events (start)', e);
    }
    _eventSub = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final parsed = _parseEvent(event.cast<Object?, Object?>());
          if (parsed != null) _eventController?.add(parsed);
        }
      },
      onError: (Object err) {
        _eventController?.addError(err);
      },
    );
  }

  Future<void> _onEventCancel() async {
    await _eventSub?.cancel();
    _eventSub = null;
    try {
      await hostApi.stopMessageEventStream();
    } on PlatformException catch (e) {
      DyplinkDiagnostics.reportFailure('DyplinkMessages.events (stop)', e);
    }
  }

  static MessageEvent? _parseEvent(Map<Object?, Object?> raw) {
    final type = raw['type'];
    final rawMessage = raw['message'];
    if (type is! String || rawMessage is! Map) return null;
    final message =
        InAppMessage.fromEventMap(rawMessage.cast<Object?, Object?>());
    switch (type) {
      case 'message_event':
        return MessageLifecycleEvent(
          message: message,
          eventType: raw['eventType'] as String? ?? '',
          buttonId: raw['buttonId'] as String?,
        );
      case 'button_action':
        final rawButton = raw['button'];
        if (rawButton is! Map) return null;
        return MessageButtonAction(
          message: message,
          button: MessageButton.fromEventMap(
            rawButton.cast<Object?, Object?>(),
          ),
        );
      case 'custom_event':
        return MessageCustomEvent(
          message: message,
          eventName: raw['eventName'] as String? ?? '',
        );
      default:
        return null;
    }
  }

  static bool get _supported => DyplinkPlatform.isSupported;

  void _ensureSupported() {
    if (!_supported) {
      throw UnsupportedError(
        'DyplinkMessages supports Android and iOS only; this is '
        '${DyplinkPlatform.description}.',
      );
    }
  }
}
