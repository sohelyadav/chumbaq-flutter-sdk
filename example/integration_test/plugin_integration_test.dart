// Integration tests for the Chumbaq Flutter plugin.
//
// These run on a real device/emulator against the real native SDK. They
// exercise the *bridge*, not the SDK's business logic — that's covered
// by the Android SDK's own tests.

import 'package:chumbaq/chumbaq.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('isInitialized returns false before init', (tester) async {
    // On a freshly launched test process, the native SDK hasn't been
    // initialized yet, so isInitialized() must be false.
    final initialized = await Chumbaq.instance.isInitialized;
    expect(initialized, isFalse);
  });

  testWidgets('init -> isInitialized -> reset round-trip', (tester) async {
    final config = ChumbaqConfig.builder(
      baseUrl: 'https://api.chumbaq.example',
      apiKey: 'test-key',
      projectId: 'test-project',
    ).logLevel(ChumbaqLogLevel.none).build();

    await Chumbaq.instance.init(config);
    expect(await Chumbaq.instance.isInitialized, isTrue);

    final fp = await Chumbaq.instance.deviceFingerprint;
    expect(fp, isNotEmpty);

    // reset() should not throw and distinctId should still be reachable.
    await Chumbaq.instance.reset();
    final distinct = await Chumbaq.instance.distinctId;
    expect(distinct, isNotEmpty);
  });
}
