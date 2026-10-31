import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Banner;

import 'chumbaq_diagnostics.dart';
import 'chumbaq_error.dart';
import 'chumbaq_models.dart';
import 'chumbaq_platform.dart';
import 'pigeon.g.dart' as pg;

/// Banners module — loads and caches in-app banner categories.
///
/// Two ways to use banners:
///
/// 1. **Embed the native carousel widget** (recommended): drop a
///    [ChumbaqBannerCarousel] into your widget tree. Flutter hosts the
///    already-built native `BannerCarouselView` via PlatformView, so the
///    UI matches native Chumbaq banners pixel-for-pixel.
///
/// 2. **Load data and render yourself**: call [loadBanners] to get a
///    [BannerCategory] + its [Banner]s, then build any Flutter UI on top.
///
/// Example:
/// ```dart
/// Column(
///   children: [
///     const ChumbaqBannerCarousel(
///       categoryId: 'home-top',
///       height: 160,
///     ),
///   ],
/// )
/// ```
class ChumbaqBanners {
  ChumbaqBanners._();
  static final ChumbaqBanners instance = ChumbaqBanners._();

  // ignore: public_member_api_docs
  pg.ChumbaqBannersHostApi hostApi = pg.ChumbaqBannersHostApi();

  /// Load banners for the given [categoryId].
  ///
  /// Results are cached natively; subsequent calls within the cache
  /// window return the cached data.
  Future<BannerCategory> loadBanners(String categoryId) async {
    _ensureSupported();
    return runCatchingChumbaq(() async {
      final dto = await hostApi.loadBanners(categoryId);
      return BannerCategory.fromDto(dto);
    });
  }

  /// Clear the native banner cache.
  Future<void> clearCache() {
    _ensureSupported();
    return runCatchingChumbaq(hostApi.clearCache);
  }

  static bool get _supported => ChumbaqPlatform.isSupported;

  void _ensureSupported() {
    if (!_supported) {
      throw UnsupportedError(
        'ChumbaqBanners supports Android and iOS only; this is '
        '${ChumbaqPlatform.description}.',
      );
    }
  }
}

/// Flutter widget that embeds the native Chumbaq `BannerCarouselView`.
///
/// This is a PlatformView — Flutter hosts the native Android view directly
/// so the carousel matches the look and behavior of the native Chumbaq SDK
/// exactly (animations, auto-rotation, click tracking, etc. all run in
/// native code).
///
/// Usage:
/// ```dart
/// SizedBox(
///   height: 160,
///   child: ChumbaqBannerCarousel(categoryId: 'home-top'),
/// )
/// ```
///
/// On non-Android platforms this widget renders an empty [SizedBox.shrink]
/// rather than throwing the way the rest of [ChumbaqBanners] does: a widget
/// cannot report an unsupported platform out of `build` without replacing
/// the screen with an error box. Turn on [ChumbaqDiagnostics] to see it
/// happen.
class ChumbaqBannerCarousel extends StatelessWidget {
  const ChumbaqBannerCarousel({
    super.key,
    required this.categoryId,
    this.height,
  });

  /// The Chumbaq banner category to load.
  final String categoryId;

  /// Optional fixed height for the carousel. If null, the widget fills the
  /// available space from its parent (use a [SizedBox] around it).
  final double? height;

  static const String _viewType = 'com.chumbaq.chumbaq/banner_carousel';

  @override
  Widget build(BuildContext context) {
    if (!ChumbaqPlatform.isAndroid) {
      ChumbaqDiagnostics.reportSkipped(
        'ChumbaqBannerCarousel',
        'the native carousel view exists on Android only, so nothing was '
            'rendered for category "$categoryId"',
      );
      return const SizedBox.shrink();
    }

    final view = AndroidView(
      viewType: _viewType,
      layoutDirection: Directionality.of(context),
      creationParams: <String, dynamic>{'categoryId': categoryId},
      creationParamsCodec: const StandardMessageCodec(),
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
    );

    if (height != null) {
      return SizedBox(height: height, child: view);
    }
    return view;
  }
}
