// Tests for the platform gates themselves, on both sides of each gate.
//
// These are only possible because the gates resolve through
// [ChumbaqPlatform] instead of `dart:io`: under `flutter test` the host is
// neither Android nor iOS, so reading `Platform.isAndroid` directly pinned
// every gated member to its unsupported branch and nothing behind a gate
// could be tested at all.
//
// Scope:
//   * the seam's own default, so a test can never leave it swapped unnoticed
//   * each module's supported branch (the call reaches the HostApi) and
//     unsupported branch (UnsupportedError, naming both platforms)
//   * the two members that stay Android-only, on Android and on iOS
//   * ChumbaqPush.isInitialized asking isPushInitialized and not the core's
//     isInitialized — the bug the Pigeon rename fixed
//   * ChumbaqBannerCarousel rendering nothing off Android, and saying so

import 'package:chumbaq/chumbaq.dart';
import 'package:chumbaq/src/chumbaq_platform.dart';
import 'package:chumbaq/src/pigeon.g.dart' as pg;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_host_apis.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeChumbaqHostApi core;
  late FakePushHostApi push;
  late FakeBannersHostApi banners;
  late FakeMessagesHostApi messages;

  setUp(() {
    core = FakeChumbaqHostApi();
    push = FakePushHostApi();
    banners = FakeBannersHostApi();
    messages = FakeMessagesHostApi();

    Chumbaq.instance.hostApi = core;
    ChumbaqPush.instance.hostApi = push;
    ChumbaqBanners.instance.hostApi = banners;
    ChumbaqMessages.instance.hostApi = messages;
  });

  tearDown(() {
    ChumbaqPlatform.reset();
    ChumbaqDiagnostics.enabled = false;
    Chumbaq.instance.hostApi = pg.ChumbaqHostApi();
    ChumbaqPush.instance.hostApi = pg.ChumbaqPushHostApi();
    ChumbaqBanners.instance.hostApi = pg.ChumbaqBannersHostApi();
    ChumbaqMessages.instance.hostApi = pg.ChumbaqMessagesHostApi();
  });

  group('the seam itself', () {
    test('defaults to the real platform, which is neither under test', () {
      // Guards the production default: if this ever answers non-null here,
      // either a test leaked an override or the default stopped reading
      // dart:io — and every gate test below would be meaningless.
      expect(ChumbaqPlatform.defaultResolve(), isNull);
      expect(ChumbaqPlatform.resolve, same(ChumbaqPlatform.defaultResolve));
      expect(ChumbaqPlatform.isSupported, isFalse);
      expect(ChumbaqPlatform.isAndroid, isFalse);
    });

    test('reset restores the default after an override', () {
      ChumbaqPlatform.resolve = () => 'ios';
      expect(ChumbaqPlatform.isSupported, isTrue);

      ChumbaqPlatform.reset();

      expect(ChumbaqPlatform.isSupported, isFalse);
      expect(ChumbaqPlatform.name, isNull);
    });

    test('describes the host OS where there is no native side', () {
      expect(ChumbaqPlatform.description, isNotEmpty);
      ChumbaqPlatform.resolve = () => 'ios';
      expect(ChumbaqPlatform.description, 'ios');
    });
  });

  group('on iOS', () {
    setUp(() => ChumbaqPlatform.resolve = () => 'ios');

    test('core forwards to the HostApi', () async {
      await Chumbaq.instance.init(_config);
      await Chumbaq.instance.track('evt', properties: const {'k': 'v'});
      await Chumbaq.instance.trackRevenue(1.5);
      await Chumbaq.instance.reset();
      await Chumbaq.instance.flush();

      expect(core.calls, [
        'initialize',
        'track:evt',
        'trackRevenue:1.5:USD',
        'reset',
        'flush',
      ]);
      expect(await Chumbaq.instance.isInitialized, isTrue);
      expect(await Chumbaq.instance.distinctId, 'distinct-1');
    });

    test('messages forward to the HostApi', () async {
      await ChumbaqMessages.instance.onAppOpen();
      await ChumbaqMessages.instance.onScreenView('Home');
      await ChumbaqMessages.instance.onEvent('purchase');

      expect(messages.calls, ['onAppOpen', 'onScreenView:Home', 'onEvent:purchase']);
    });

    test('banners forward to the HostApi', () async {
      final category = await ChumbaqBanners.instance.loadBanners('home-top');
      await ChumbaqBanners.instance.clearCache();

      expect(banners.calls, ['loadBanners:home-top', 'clearCache']);
      expect(category.id, 'cat-1');
      expect(category.banners.single.title, 'Banner one');
    });

    test('push forwards the calls it has on iOS', () async {
      await ChumbaqPush.instance.init();
      await ChumbaqPush.instance.registerToken('apns-token');
      await ChumbaqPush.instance.unregisterToken();

      expect(push.calls, ['initialize', 'registerToken:apns-token', 'unregisterToken']);
    });
  });

  group('where there is no native bridge', () {
    // The default under `flutter test` — web and desktop for a real app.

    test('core, messages and banners throw, naming both platforms', () async {
      for (final call in <Function()>[
        () => Chumbaq.instance.init(_config),
        () => Chumbaq.instance.track('evt'),
        () => Chumbaq.instance.distinctId,
        () => Chumbaq.instance.deepLinks,
        () => ChumbaqMessages.instance.onAppOpen(),
        () => ChumbaqMessages.instance.events,
        () => ChumbaqBanners.instance.loadBanners('home-top'),
        () => ChumbaqPush.instance.init(),
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
      expect(await Chumbaq.instance.isInitialized, isFalse);
      expect(await ChumbaqPush.instance.isInitialized, isFalse);
      expect(await ChumbaqPush.instance.isRegistered, isFalse);

      // Answering, not asking: the HostApi must not be reached at all.
      expect(core.calls, isEmpty);
      expect(push.calls, isEmpty);
    });
  });

  group('ChumbaqPush.isInitialized', () {
    // The push module and the core SDK both have an `isInitialized`. On a
    // native plugin that implements both Pigeon APIs on one object the two
    // collapsed into one, and the push module answered with the core's
    // state. The Dart facade must ask isPushInitialized.

    test('asks isPushInitialized, not the core isInitialized', () async {
      ChumbaqPlatform.resolve = () => 'ios';
      push.pushInitialized = true;

      expect(await ChumbaqPush.instance.isInitialized, isTrue);
      expect(push.calls, ['isPushInitialized']);
    });

    test('reports the push module state even when the core disagrees',
        () async {
      ChumbaqPlatform.resolve = () => 'ios';
      core.initialized = true;
      push.pushInitialized = false;

      expect(await Chumbaq.instance.isInitialized, isTrue);
      expect(await ChumbaqPush.instance.isInitialized, isFalse);
    });
  });

  group('members that stay Android-only', () {
    test('registerMiPushToken forwards the regId on Android', () async {
      ChumbaqPlatform.resolve = () => 'android';

      await ChumbaqPush.instance.registerMiPushToken('mi-regid-1');

      expect(push.calls, ['registerMiPushToken:mi-regid-1']);
    });

    test('registerMiPushToken throws on iOS, naming Xiaomi', () {
      ChumbaqPlatform.resolve = () => 'ios';

      expect(
        () => ChumbaqPush.instance.registerMiPushToken('mi-regid-1'),
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
      ChumbaqPlatform.resolve = () => 'android';

      expect(ChumbaqPush.instance.tokens, isA<Stream<String>>());
    });

    test('the token stream throws on iOS, naming APNs', () {
      ChumbaqPlatform.resolve = () => 'ios';

      expect(
        () => ChumbaqPush.instance.tokens,
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

  group('ChumbaqBannerCarousel', () {
    testWidgets('renders the native view on Android', (tester) async {
      ChumbaqPlatform.resolve = () => 'android';

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 160,
            child: ChumbaqBannerCarousel(categoryId: 'home-top'),
          ),
        ),
      );

      expect(find.byType(AndroidView), findsOneWidget);
    });

    testWidgets('renders nothing off Android, and reports the skip',
        (tester) async {
      ChumbaqPlatform.resolve = () => 'ios';
      final logged = <String>[];
      ChumbaqDiagnostics.enabled = true;
      ChumbaqDiagnostics.sink = logged.add;
      addTearDown(() => ChumbaqDiagnostics.sink = debugPrint);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: ChumbaqBannerCarousel(categoryId: 'home-top'),
        ),
      );

      expect(find.byType(AndroidView), findsNothing);
      expect(find.byType(SizedBox), findsOneWidget);
      expect(logged, hasLength(1));
      expect(logged.single, contains('ChumbaqBannerCarousel'));
      expect(logged.single, contains('home-top'));
    });

    testWidgets('stays silent about the skip while diagnostics are off',
        (tester) async {
      ChumbaqPlatform.resolve = () => 'ios';
      final logged = <String>[];
      ChumbaqDiagnostics.sink = logged.add;
      addTearDown(() => ChumbaqDiagnostics.sink = debugPrint);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: ChumbaqBannerCarousel(categoryId: 'home-top'),
        ),
      );

      expect(logged, isEmpty);
    });
  });
}

ChumbaqConfig get _config => ChumbaqConfig.builder(
      baseUrl: 'https://api.chumbaq.test',
      apiKey: 'test-key',
      projectId: 'project-1',
    ).build();
