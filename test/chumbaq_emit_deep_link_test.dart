// Tests for Chumbaq.emitDeepLink when nothing has subscribed yet.
//
// A file of its own because the condition under test is the *absence* of the
// deep-link stream controller, and `Chumbaq.instance` is a singleton: any
// test that touches `Chumbaq.deepLinks` first creates that controller for
// the rest of the file. Each test file is its own process, so this one is
// guaranteed to start with no subscriber — the cold-start case this path
// exists for.

import 'package:chumbaq/chumbaq.dart';
import 'package:chumbaq/src/chumbaq_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> logged;

  setUp(() {
    logged = <String>[];
    ChumbaqDiagnostics.sink = logged.add;
  });

  tearDown(() {
    ChumbaqDiagnostics.enabled = false;
    ChumbaqDiagnostics.sink = debugPrint;
    ChumbaqPlatform.reset();
  });

  test('drops the link and reports the skip when nothing has subscribed', () {
    ChumbaqDiagnostics.enabled = true;

    final published = Chumbaq.instance.emitDeepLink(
      const DeepLinkResult(url: 'myapp://from-a-push', isDeferred: false),
    );

    expect(published, isFalse);
    expect(logged, hasLength(1));
    expect(logged.single, contains('skipped'));
    expect(logged.single, contains('Chumbaq.emitDeepLink'));
    // The reason has to name the fix, not just the symptom.
    expect(logged.single, contains('Chumbaq.deepLinks'));
  });

  test('stays silent while diagnostics are off', () {
    final published = Chumbaq.instance.emitDeepLink(
      const DeepLinkResult(url: 'myapp://from-a-push', isDeferred: false),
    );

    expect(published, isFalse);
    expect(logged, isEmpty);
  });

  test('never throws, on any platform', () {
    // Unlike every other member of the facade this one has no platform gate
    // at all — a push tap must not cost the app an exception on a platform
    // where the stream could not exist in the first place.
    for (final platform in <String?>[null, 'ios', 'android']) {
      ChumbaqPlatform.resolve = () => platform;
      expect(
        () => Chumbaq.instance.emitDeepLink(
          const DeepLinkResult(url: 'myapp://x', isDeferred: false),
        ),
        returnsNormally,
      );
    }
  });
}
