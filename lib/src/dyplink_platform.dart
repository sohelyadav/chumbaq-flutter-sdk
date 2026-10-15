import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Which platform the SDK's gates believe they are running on.
///
/// Every module refuses to call the native bridge where there is none — web,
/// desktop — and two push members refuse on iOS as well. All of those
/// decisions read this one class rather than `dart:io` directly, because
/// `Platform.isAndroid` and `Platform.isIOS` are **both false under
/// `flutter test`**, which runs on the host OS. Asking `dart:io` directly
/// pins every gated member to its unsupported branch for the whole test
/// suite, so none of the code behind a gate can be tested at all — which is
/// how a module's worth of swallowed failures, a mis-wired `isInitialized`
/// and a dead `registerMiPushToken` all came to ship without a single test
/// able to reach them.
///
/// Production never assigns [resolve]: a real app only ever sees
/// [defaultResolve], and behaviour off-platform is exactly what it was when
/// these gates read `dart:io`. Tests swap it to drive both branches:
///
/// ```dart
/// setUp(() => DyplinkPlatform.resolve = () => 'ios');
/// tearDown(DyplinkPlatform.reset);
/// ```
class DyplinkPlatform {
  DyplinkPlatform._();

  /// Resolves the current platform: `'android'`, `'ios'`, or null where the
  /// plugin has no native side.
  ///
  /// Visible for testing — see the class doc for why a seam exists at all.
  @visibleForTesting
  static String? Function() resolve = defaultResolve;

  /// The current platform's name, or null where the plugin has no native
  /// side. The reading side of [resolve], for callers outside this library.
  static String? get name => resolve();

  /// Whether the plugin has a native bridge on this platform.
  static bool get isSupported => resolve() != null;

  /// Whether this is Android, asked by the members that stay Android-only
  /// now that the rest of the plugin runs on iOS: `DyplinkPush.tokens`,
  /// `DyplinkPush.registerMiPushToken` and `DyplinkBannerCarousel`.
  static bool get isAndroid => resolve() == 'android';

  /// What to call this platform in an error message: the resolved name, or
  /// the host OS where there is none.
  static String get description => resolve() ?? Platform.operatingSystem;

  /// The production resolver. The only value a real app ever sees.
  static String? defaultResolve() => Platform.isAndroid
      ? 'android'
      : Platform.isIOS
          ? 'ios'
          : null;

  /// Restores [defaultResolve]. Call from `tearDown`.
  @visibleForTesting
  static void reset() => resolve = defaultResolve;
}
