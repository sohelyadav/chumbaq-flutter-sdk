// Chumbaq Flutter SDK — example app.
//
// Demonstrates:
//   * Chumbaq.init() with a ChumbaqConfig
//   * identify() with user traits
//   * track() custom events
//   * trackConversion() attribution
//   * matchDeferredDeepLink() for first-launch attribution
//   * Stream<DeepLinkResult> subscription
//   * ChumbaqBannerCarousel PlatformView widget
//   * ChumbaqPush token registration
//   * ChumbaqMessages trigger points and event stream

import 'dart:async';
import 'dart:io' show Platform;

import 'package:chumbaq/chumbaq.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const ChumbaqExampleApp());
}

const String _baseUrl = String.fromEnvironment(
  'CHUMBAQ_BASE_URL',
  defaultValue: 'https://api.chumbaq.com',
);
const String _apiKey = String.fromEnvironment(
  'CHUMBAQ_API_KEY',
  defaultValue: 'YOUR_API_KEY',
);
const String _projectId = String.fromEnvironment(
  'CHUMBAQ_PROJECT_ID',
  defaultValue: 'YOUR_PROJECT_ID',
);

class ChumbaqExampleApp extends StatelessWidget {
  const ChumbaqExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chumbaq Example',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  final _logs = <String>[];
  StreamSubscription<DeepLinkResult>? _deepLinkSub;
  StreamSubscription<MessageEvent>? _messageSub;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initChumbaq();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deepLinkSub?.cancel();
    _messageSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _initialized) {
      // Poll for "on_app_open" messages whenever the app foregrounds.
      ChumbaqMessages.instance.onAppOpen().ignore();
    }
  }

  Future<void> _initChumbaq() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      _log('Chumbaq has a native bridge for Android and iOS only.');
      return;
    }

    // Replace with your real credentials from the Chumbaq dashboard, or pass
    // them at launch so nothing has to be edited in (or committed to) this
    // file:
    //
    //   flutter run \
    //     --dart-define=CHUMBAQ_BASE_URL=http://localhost:3010 \
    //     --dart-define=CHUMBAQ_API_KEY=... \
    //     --dart-define=CHUMBAQ_PROJECT_ID=...
    final config = ChumbaqConfig.builder(
      baseUrl: _baseUrl,
      apiKey: _apiKey,
      projectId: _projectId,
    )
        .logLevel(ChumbaqLogLevel.debug)
        .flushInterval(const Duration(seconds: 30))
        .deepLinkHosts(const ['example.chumbaq.com', 'links.example.com'])
        .customScheme('chumbaqexample')
        .build();

    try {
      await Chumbaq.instance.init(config);
      _log('Chumbaq initialized');

      // Listen for deep links (both direct and deferred). The native listener
      // is attached here and detached when this widget disposes.
      _deepLinkSub = Chumbaq.instance.deepLinks.listen(
        (link) => _log('deep link: ${link.url} deferred=${link.isDeferred}'),
        onError: (Object e) => _log('deep link error: $e'),
      );

      // Push (optional)
      await ChumbaqPush.instance.init();
      _log('Push initialized, registered=${await ChumbaqPush.instance.isRegistered}');

      // In-app messages — subscribe to interaction events.
      _messageSub = ChumbaqMessages.instance.events.listen(
        (event) => _log('message event: ${event.runtimeType}'),
      );

      // Attempt a deferred deep link match (only meaningful on first launch
      // after a fresh install).
      final deferred = await Chumbaq.instance.matchDeferredDeepLink();
      _log('deferred match: matched=${deferred.matched} code=${deferred.shortCode ?? "-"}');

      if (mounted) setState(() => _initialized = true);
    } on ChumbaqError catch (e) {
      _log('init failed: $e');
    } catch (e) {
      _log('init exception: $e');
    }
  }

  Future<void> _identify() async {
    try {
      final params = IdentifyParams.builder()
          .externalUserId('user-123')
          .firstName('Jane')
          .lastName('Doe')
          .phone('+15551234567')
          .emailOptIn(true)
          .traits(const {'plan': 'pro', 'age': 34})
          .build();
      final result = await Chumbaq.instance.identify(params);
      _log('identified: ${result.id} fp=${result.deviceFingerprint}');
    } on ChumbaqError catch (e) {
      _log('identify failed: $e');
    }
  }

  Future<void> _trackEvent() async {
    await Chumbaq.instance.track(
      'button_click',
      properties: const {'button_id': 'hello', 'screen': 'home'},
    );
    _log('tracked event: button_click');
  }

  Future<void> _trackRevenue() async {
    await Chumbaq.instance.trackRevenue(9.99);
    _log('tracked revenue: 9.99 USD');
  }

  Future<void> _checkMessages() async {
    try {
      await ChumbaqMessages.instance.onScreenView('HomeScreen');
      _log('messages: asked for on_screen "HomeScreen"');
    } on ChumbaqError catch (e) {
      _log('messages check failed: $e');
    }
  }

  Future<void> _loadBanners() async {
    try {
      final category = await ChumbaqBanners.instance.loadBanners('home-top');
      _log('banners: ${category.banners.length} in "${category.name}"');
    } on ChumbaqError catch (e) {
      _log('banners failed: $e');
    }
  }

  Future<void> _resetIdentity() async {
    await Chumbaq.instance.reset();
    _log('identity reset');
  }

  Future<void> _flushNow() async {
    try {
      await Chumbaq.instance.flush();
      _log('flushed');
    } on ChumbaqError catch (e) {
      _log('flush failed: $e');
    }
  }

  void _log(String message) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, message);
      if (_logs.length > 100) _logs.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chumbaq Example')),
      body: Column(
        children: [
          // Banner carousel — embeds the native BannerCarouselView.
          if (_initialized)
            const SizedBox(
              height: 160,
              child: ChumbaqBannerCarousel(categoryId: 'home-top'),
            ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(onPressed: _identify, child: const Text('Identify')),
                FilledButton(onPressed: _trackEvent, child: const Text('Track event')),
                FilledButton(onPressed: _trackRevenue, child: const Text('Track revenue')),
                FilledButton(onPressed: _checkMessages, child: const Text('Check messages')),
                FilledButton(onPressed: _loadBanners, child: const Text('Load banners')),
                FilledButton(onPressed: _flushNow, child: const Text('Flush')),
                FilledButton(onPressed: _resetIdentity, child: const Text('Reset')),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _logs.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_logs[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
