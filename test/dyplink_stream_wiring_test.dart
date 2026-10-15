// Tests for the three EventChannel-backed streams and the diagnostics they
// report through.
//
// None of this was reachable before the gates resolved through
// [DyplinkPlatform]: every stream getter threw `UnsupportedError` under
// `flutter test`, so the start/stop lifecycle, the decode of what the native
// side sends, and every swallowed failure behind them had no test at all.
//
// Scope:
//   * start/stop of the native listener on first-listen and last-cancel
//   * decoding what each channel emits into the typed Dart model
//   * the swallowed failures: a start or stop that throws leaves the stream
//     open and reports through DyplinkDiagnostics instead
//   * publishing onto an already-open deep-link stream

import 'package:dyplink/dyplink.dart';
import 'package:dyplink/src/dyplink_platform.dart';
import 'package:dyplink/src/pigeon.g.dart' as pg;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_host_apis.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeDyplinkHostApi core;
  late FakePushHostApi push;
  late FakeMessagesHostApi messages;
  late List<String> logged;
  late _Channel deepLinkChannel;
  late _Channel messageChannel;
  late _Channel tokenChannel;

  setUp(() {
    DyplinkPlatform.resolve = () => 'ios';

    core = FakeDyplinkHostApi();
    push = FakePushHostApi();
    messages = FakeMessagesHostApi();
    Dyplink.instance.hostApi = core;
    DyplinkPush.instance.hostApi = push;
    DyplinkMessages.instance.hostApi = messages;

    logged = <String>[];
    DyplinkDiagnostics.enabled = true;
    DyplinkDiagnostics.sink = logged.add;

    deepLinkChannel = _Channel('com.dyplink.dyplink/deep_links');
    messageChannel = _Channel('com.dyplink.dyplink/message_events');
    tokenChannel = _Channel('com.dyplink.dyplink/push_tokens');
  });

  tearDown(() {
    deepLinkChannel.dispose();
    messageChannel.dispose();
    tokenChannel.dispose();
    DyplinkPlatform.reset();
    DyplinkDiagnostics.enabled = false;
    DyplinkDiagnostics.sink = debugPrint;
    Dyplink.instance.hostApi = pg.DyplinkHostApi();
    DyplinkPush.instance.hostApi = pg.DyplinkPushHostApi();
    DyplinkMessages.instance.hostApi = pg.DyplinkMessagesHostApi();
  });

  group('Dyplink.deepLinks', () {
    test('attaches the native listener on first listen, detaches on cancel',
        () async {
      final sub = Dyplink.instance.deepLinks.listen((_) {});
      await pumpEventQueue();
      expect(core.calls, contains('startDeepLinkStream'));

      await sub.cancel();
      await pumpEventQueue();
      expect(core.calls, contains('stopDeepLinkStream'));
      expect(logged, isEmpty);
    });

    test('decodes what the native side emits', () async {
      final received = <DeepLinkResult>[];
      final sub = Dyplink.instance.deepLinks.listen(received.add);
      await pumpEventQueue();

      deepLinkChannel.emit(<Object?, Object?>{
        'url': 'dyplinkexample://aB3dE?x=1',
        'shortCode': 'aB3dE',
        'params': <Object?, Object?>{'x': '1'},
        'isDeferred': false,
      });
      await pumpEventQueue();

      expect(received, hasLength(1));
      expect(received.single.url, 'dyplinkexample://aB3dE?x=1');
      expect(received.single.shortCode, 'aB3dE');
      expect(received.single.params, <String, Object?>{'x': '1'});
      expect(received.single.isDeferred, isFalse);
      expect(received.single.linkId, isNull);

      await sub.cancel();
    });

    test('reports a failed attach instead of taking the stream down',
        () async {
      core.failures['startDeepLinkStream'] =
          PlatformException(code: 'UNSUPPORTED_ON_IOS', message: 'nope');

      final sub = Dyplink.instance.deepLinks.listen((_) {});
      await pumpEventQueue();

      // The subscriber is still live — the stream must not have closed.
      expect(sub.isPaused, isFalse);
      expect(logged, hasLength(1));
      expect(logged.single, contains('Dyplink.deepLinks (start)'));
      expect(logged.single, contains('UNSUPPORTED_ON_IOS'));

      await sub.cancel();
    });

    test('reports a failed detach', () async {
      core.failures['stopDeepLinkStream'] =
          PlatformException(code: 'UNSUPPORTED_ON_IOS', message: 'nope');

      final sub = Dyplink.instance.deepLinks.listen((_) {});
      await pumpEventQueue();
      await sub.cancel();
      await pumpEventQueue();

      expect(logged, hasLength(1));
      expect(logged.single, contains('Dyplink.deepLinks (stop)'));
    });

    test('stays silent about a failed attach while diagnostics are off',
        () async {
      DyplinkDiagnostics.enabled = false;
      core.failures['startDeepLinkStream'] =
          PlatformException(code: 'UNSUPPORTED_ON_IOS', message: 'nope');

      final sub = Dyplink.instance.deepLinks.listen((_) {});
      await pumpEventQueue();

      expect(logged, isEmpty);
      await sub.cancel();
    });

    test('publishes an out-of-band link to an open stream', () async {
      final received = <DeepLinkResult>[];
      final sub = Dyplink.instance.deepLinks.listen(received.add);
      await pumpEventQueue();

      final published = Dyplink.instance.emitDeepLink(
        const DeepLinkResult(url: 'myapp://from-a-push', isDeferred: false),
      );
      await pumpEventQueue();

      expect(published, isTrue);
      expect(received.single.url, 'myapp://from-a-push');
      // A publish is not a skip: nothing to report.
      expect(logged, isEmpty);

      await sub.cancel();
    });
  });

  group('DyplinkMessages.events', () {
    test('attaches and detaches the native listener', () async {
      final sub = DyplinkMessages.instance.events.listen((_) {});
      await pumpEventQueue();
      expect(messages.calls, contains('startMessageEventStream'));

      await sub.cancel();
      await pumpEventQueue();
      expect(messages.calls, contains('stopMessageEventStream'));
    });

    test('decodes each of the three event shapes', () async {
      final received = <MessageEvent>[];
      final sub = DyplinkMessages.instance.events.listen(received.add);
      await pumpEventQueue();

      messageChannel.emit(<Object?, Object?>{
        'type': 'message_event',
        'message': _message,
        'eventType': 'cta_click',
        'buttonId': 'b-1',
      });
      messageChannel.emit(<Object?, Object?>{
        'type': 'button_action',
        'message': _message,
        'button': <Object?, Object?>{
          'id': 'b-1',
          'text': 'Shop',
          'action': 'deep_link',
          'actionUrl': 'myapp://sale',
          'style': 'primary',
        },
      });
      messageChannel.emit(<Object?, Object?>{
        'type': 'custom_event',
        'message': _message,
        'eventName': 'subscribed',
      });
      await pumpEventQueue();

      expect(received, hasLength(3));
      final lifecycle = received[0] as MessageLifecycleEvent;
      expect(lifecycle.eventType, 'cta_click');
      expect(lifecycle.buttonId, 'b-1');
      expect(lifecycle.message.title, 'Sale');
      final action = received[1] as MessageButtonAction;
      expect(action.button.actionUrl, 'myapp://sale');
      final custom = received[2] as MessageCustomEvent;
      expect(custom.eventName, 'subscribed');

      await sub.cancel();
    });

    test('drops an event shape it does not know', () async {
      final received = <MessageEvent>[];
      final sub = DyplinkMessages.instance.events.listen(received.add);
      await pumpEventQueue();

      messageChannel.emit(<Object?, Object?>{
        'type': 'something_new',
        'message': _message,
      });
      messageChannel.emit(<Object?, Object?>{'type': 'message_event'});
      await pumpEventQueue();

      expect(received, isEmpty);

      await sub.cancel();
    });

    test('reports a failed attach and a failed detach', () async {
      messages.failures['startMessageEventStream'] =
          PlatformException(code: 'NOT_INITIALIZED', message: 'no');
      messages.failures['stopMessageEventStream'] =
          PlatformException(code: 'NOT_INITIALIZED', message: 'no');

      final sub = DyplinkMessages.instance.events.listen((_) {});
      await pumpEventQueue();
      await sub.cancel();
      await pumpEventQueue();

      expect(logged, hasLength(2));
      expect(logged.first, contains('DyplinkMessages.events (start)'));
      expect(logged.last, contains('DyplinkMessages.events (stop)'));
    });
  });

  group('DyplinkPush.tokens', () {
    setUp(() => DyplinkPlatform.resolve = () => 'android');

    test('attaches, emits and detaches', () async {
      final received = <String>[];
      final sub = DyplinkPush.instance.tokens.listen(received.add);
      await pumpEventQueue();
      expect(push.calls, contains('startTokenStream'));

      tokenChannel.emit('fcm-token-1');
      await pumpEventQueue();
      expect(received, ['fcm-token-1']);

      await sub.cancel();
      await pumpEventQueue();
      expect(push.calls, contains('stopTokenStream'));
    });

    test('reports a failed attach', () async {
      push.failures['startTokenStream'] =
          PlatformException(code: 'UNSUPPORTED_ON_IOS', message: 'no stream');

      final sub = DyplinkPush.instance.tokens.listen((_) {});
      await pumpEventQueue();

      expect(logged, hasLength(1));
      expect(logged.single, contains('DyplinkPush.tokens (start)'));

      await sub.cancel();
    });
  });
}

/// A mock EventChannel the test can push events onto.
class _Channel {
  _Channel(this.name) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      EventChannel(name),
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          _sink = events;
        },
        onCancel: (Object? arguments) => _sink = null,
      ),
    );
  }

  final String name;
  MockStreamHandlerEventSink? _sink;

  void emit(Object? event) => _sink?.success(event);

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(EventChannel(name), null);
    _sink = null;
  }
}

Map<Object?, Object?> get _message => <Object?, Object?>{
      'id': 'm-1',
      'messageType': 'modal',
      'title': 'Sale',
      'imagePosition': 'top',
      'dismissOnTapOutside': true,
      'triggerDelay': 0,
    };
