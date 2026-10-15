// Tests for the platform gates themselves, on both sides of each gate.
//
// These are only possible because the gates resolve through
// [DyplinkPlatform] instead of `dart:io`: under `flutter test` the host is
// neither Android nor iOS, so reading `Platform.isAndroid` directly pinned
// every gated member to its unsupported branch and nothing behind a gate
// could be tested at all.
//
// Scope:
//   * the seam's own default, so a test can never leave it swapped unnoticed
//   * each module's supported branch (the call reaches the HostApi) and
//     unsupported branch (UnsupportedError, naming both platforms)
//   * the two members that stay Android-only, on Android and on iOS
//   * DyplinkPush.isInitialized asking isPushInitialized and not the core's
//     isInitialized — the bug the Pigeon rename fixed
//   * DyplinkBannerCarousel rendering nothing off Android, and saying so

import 'package:dyplink/dyplink.dart';
import 'package:dyplink/src/dyplink_platform.dart';
import 'package:dyplink/src/pigeon.g.dart' as pg;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_host_apis.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeDyplinkHostApi core;
  late FakePushHostApi push;
  late FakeBannersHostApi banners;
  late FakeMessagesHostApi messages;

  setUp(() {
    core = FakeDyplinkHostApi();
    push = FakePushHostApi();
    banners = FakeBannersHostApi();
    messages = FakeMessagesHostApi();

    Dyplink.instance.hostApi = core;
    DyplinkPush.instance.hostApi = push;
    DyplinkBanners.instance.hostApi = banners;
    DyplinkMessages.instance.hostApi = messages;
  });

  tearDown(() {
    DyplinkPlatform.reset();
    DyplinkDiagnostics.enabled = false;
    Dyplink.instance.hostApi = pg.DyplinkHostApi();
    DyplinkPush.instance.hostApi = pg.DyplinkPushHostApi();
    DyplinkBanners.instance.hostApi = pg.DyplinkBannersHostApi();
    DyplinkMessages.instance.hostApi = pg.DyplinkMessagesHostApi();
  });

  group('the seam itself', () {
    test('defaults to the real platform, which is neither under test', () {
      // Guards the production default: if this ever answers non-null here,
      // either a test leaked an override or the default stopped reading
      // dart:io — and every gate test below would be meaningless.
      expect(DyplinkPlatform.defaultResolve(), isNull);
      expect(DyplinkPlatform.resolve, same(DyplinkPlatform.defaultResolve));
      expect(DyplinkPlatform.isSupported, isFalse);
      expect(DyplinkPlatform.isAndroid, isFalse);
    });

    test('reset restores the default after an override', () {
      DyplinkPlatform.resolve = () => 'ios';
      expect(DyplinkPlatform.isSupported, isTrue);

      DyplinkPlatform.reset();

      expect(DyplinkPlatform.isSupported, isFalse);
      expect(DyplinkPlatform.name, isNull);
    });

    test('describes the host OS where there is no native side', () {
      expect(DyplinkPlatform.description, isNotEmpty);
      DyplinkPlatform.resolve = () => 'ios';
      expect(DyplinkPlatform.description, 'ios');
    });
  });

  group('on iOS', () {
    setUp(() => DyplinkPlatform.resolve = () => 'ios');

    test('core forwards to the HostApi', () async {
      await Dyplink.instance.init(_config);
      await Dyplink.instance.track('evt', properties: const {'k': 'v'});
      await Dyplink.instance.trackRevenue(1.5);
      await Dyplink.instance.reset();
      await Dyplink.instance.flush();

      expect(core.calls, [
        'initialize',
        'track:evt',
        'trackRevenue:1.5:USD',
        'reset',
        'flush',
      ]);
      expect(await Dyplink.instance.isInitialized, isTrue);
      expect(await Dyplink.instance.distinctId, 'distinct-1');
    });

    test('messages forward to the HostApi', () async {
      await DyplinkMessages.instance.onAppOpen();
      await DyplinkMessages.instance.onScreenView('Home');
      await DyplinkMessages.instance.onEvent('purchase');

      expect(messages.calls, ['onAppOpen', 'onScreenView:Home', 'onEvent:purchase']);
    });

    test('banners forward to the HostApi', () async {
      final category = await DyplinkBanners.instance.loadBanners('home-top');
      await DyplinkBanners.instance.clearCache();

      expect(banners.calls, ['loadBanners:home-top', 'clearCache']);
      expect(category.id, 'cat-1');
      expect(category.banners.single.title, 'Banner one');
    });

    test('push forwards the calls it has on iOS', () async {
      await DyplinkPush.instance.init();
      await DyplinkPush.instance.registerToken('apns-token');
      await DyplinkPush.instance.unregisterToken();

      expect(push.calls, ['initialize', 'registerToken:apns-token', 'unregisterToken']);
    });
  });

  group('where there is no native bridge', () {
    // The default under `flutter test` — web and desktop for a real app.

    test('core, messages and banners throw, naming both platforms', () async {
      for (final call in <Function()>[
        () => Dyplink.instance.init(_config),
        () => Dyplink.instance.track('evt'),
        () => Dyplink.instance.distinctId,
        () => Dyplink.instance.deepLinks,
        () => DyplinkMessages.instance.onAppOpen(),
        () => DyplinkMessages.instance.events,
        () => DyplinkBanners.instance.loadBanners('home-top'),
        () => DyplinkPush.instance.init(),
      ]) {
        expect(
          call,
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              allOf(contains('Android'), contains('iOS')),
            ),
          ),
        );
      }

      expect(core.calls, isEmpty);
      expect(messages.calls, isEmpty);
      expect(banners.calls, isEmpty);
      expect(push.calls, isEmpty);
    });

    test('the feature-detection predicates answer false', () async {
      expect(await Dyplink.instance.isInitialized, isFalse);
      expect(await DyplinkPush.instance.isInitialized, isFalse);
      expect(await DyplinkPush.instance.isRegistered, isFalse);

      // Answering, not asking: the HostApi must not be reached at all.
      expect(core.calls, isEmpty);
      expect(push.calls, isEmpty);
    });
  });

  group('DyplinkPush.isInitialized', () {
    // The push module and the core SDK both have an `isInitialized`. On a
    // native plugin that implements both Pigeon APIs on one object the two
    // collapsed into one, and the push module answered with the core's
    // state. The Dart facade must ask isPushInitialized.

    test('asks isPushInitialized, not the core isInitialized', () async {
      DyplinkPlatform.resolve = () => 'ios';
      push.pushInitialized = true;

      expect(await DyplinkPush.instance.isInitialized, isTrue);
      expect(push.calls, ['isPushInitialized']);
    });

    test('reports the push module state even when the core disagrees',
        () async {
      DyplinkPlatform.resolve = () => 'ios';
      core.initialized = true;
      push.pushInitialized = false;

      expect(await Dyplink.instance.isInitialized, isTrue);
      expect(await DyplinkPush.instance.isInitialized, isFalse);
    });
  });

  group('members that stay Android-only', () {
    test('registerMiPushToken forwards the regId on Android', () async {
      DyplinkPlatform.resolve = () => 'android';

      await DyplinkPush.instance.registerMiPushToken('mi-regid-1');

      expect(push.calls, ['registerMiPushToken:mi-regid-1']);
    });

    test('registerMiPushToken throws on iOS, naming Xiaomi', () {
      DyplinkPlatform.resolve = () => 'ios';

      expect(
        () => DyplinkPush.instance.registerMiPushToken('mi-regid-1'),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            allOf(contains('Android-only'), contains('Xiaomi'), contains('ios')),
          ),
        ),
      );
      expect(push.calls, isEmpty);
    });

    test('the token stream is a stream on Android', () async {
      DyplinkPlatform.resolve = () => 'android';

      expect(DyplinkPush.instance.tokens, isA<Stream<String>>());
    });

    test('the token stream throws on iOS, naming APNs', () {
      DyplinkPlatform.resolve = () => 'ios';

      expect(
        () => DyplinkPush.instance.tokens,
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            allOf(contains('Android-only'), contains('APNs')),
          ),
        ),
      );
    });
  });

  group('DyplinkBannerCarousel', () {
    testWidgets('renders the native view on Android', (tester) async {
      DyplinkPlatform.resolve = () => 'android';

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 160,
            child: DyplinkBannerCarousel(categoryId: 'home-top'),
          ),
        ),
      );

      expect(find.byType(AndroidView), findsOneWidget);
    });

    testWidgets('renders nothing off Android, and reports the skip',
        (tester) async {
      DyplinkPlatform.resolve = () => 'ios';
      final logged = <String>[];
      DyplinkDiagnostics.enabled = true;
      DyplinkDiagnostics.sink = logged.add;
      addTearDown(() => DyplinkDiagnostics.sink = debugPrint);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: DyplinkBannerCarousel(categoryId: 'home-top'),
        ),
      );

      expect(find.byType(AndroidView), findsNothing);
      expect(find.byType(SizedBox), findsOneWidget);
      expect(logged, hasLength(1));
      expect(logged.single, contains('DyplinkBannerCarousel'));
      expect(logged.single, contains('home-top'));
    });

    testWidgets('stays silent about the skip while diagnostics are off',
        (tester) async {
      DyplinkPlatform.resolve = () => 'ios';
      final logged = <String>[];
      DyplinkDiagnostics.sink = logged.add;
      addTearDown(() => DyplinkDiagnostics.sink = debugPrint);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: DyplinkBannerCarousel(categoryId: 'home-top'),
        ),
      );

      expect(logged, isEmpty);
    });
  });
}

DyplinkConfig get _config => DyplinkConfig.builder(
      baseUrl: 'https://api.dyplink.test',
      apiKey: 'test-key',
      projectId: 'project-1',
    ).build();
