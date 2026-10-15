// Tests for Dyplink.emitDeepLink when nothing has subscribed yet.
//
// A file of its own because the condition under test is the *absence* of the
// deep-link stream controller, and `Dyplink.instance` is a singleton: any
// test that touches `Dyplink.deepLinks` first creates that controller for
// the rest of the file. Each test file is its own process, so this one is
// guaranteed to start with no subscriber — the cold-start case this path
// exists for.

import 'package:dyplink/dyplink.dart';
import 'package:dyplink/src/dyplink_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> logged;

  setUp(() {
    logged = <String>[];
    DyplinkDiagnostics.sink = logged.add;
  });

  tearDown(() {
    DyplinkDiagnostics.enabled = false;
    DyplinkDiagnostics.sink = debugPrint;
    DyplinkPlatform.reset();
  });

  test('drops the link and reports the skip when nothing has subscribed', () {
    DyplinkDiagnostics.enabled = true;

    final published = Dyplink.instance.emitDeepLink(
      const DeepLinkResult(url: 'myapp://from-a-push', isDeferred: false),
    );

    expect(published, isFalse);
    expect(logged, hasLength(1));
    expect(logged.single, contains('skipped'));
    expect(logged.single, contains('Dyplink.emitDeepLink'));
    // The reason has to name the fix, not just the symptom.
    expect(logged.single, contains('Dyplink.deepLinks'));
  });

  test('stays silent while diagnostics are off', () {
    final published = Dyplink.instance.emitDeepLink(
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
      DyplinkPlatform.resolve = () => platform;
      expect(
        () => Dyplink.instance.emitDeepLink(
          const DeepLinkResult(url: 'myapp://x', isDeferred: false),
        ),
        returnsNormally,
      );
    }
  });
}
