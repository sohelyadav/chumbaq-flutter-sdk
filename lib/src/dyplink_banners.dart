import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Banner;

import 'dyplink_diagnostics.dart';
import 'dyplink_error.dart';
import 'dyplink_models.dart';
import 'dyplink_platform.dart';
import 'pigeon.g.dart' as pg;

/// Banners module — loads and caches in-app banner categories.
///
/// Two ways to use banners:
///
/// 1. **Embed the native carousel widget** (recommended): drop a
///    [DyplinkBannerCarousel] into your widget tree. Flutter hosts the
///    already-built native `BannerCarouselView` via PlatformView, so the
///    UI matches native Dyplink banners pixel-for-pixel.
///
/// 2. **Load data and render yourself**: call [loadBanners] to get a
///    [BannerCategory] + its [Banner]s, then build any Flutter UI on top.
///
/// Example:
/// ```dart
/// Column(
///   children: [
///     const DyplinkBannerCarousel(
///       categoryId: 'home-top',
///       height: 160,
///     ),
///   ],
/// )
/// ```
class DyplinkBanners {
  DyplinkBanners._();
  static final DyplinkBanners instance = DyplinkBanners._();

  // ignore: public_member_api_docs
  pg.DyplinkBannersHostApi hostApi = pg.DyplinkBannersHostApi();

  /// Load banners for the given [categoryId].
  ///
  /// Results are cached natively; subsequent calls within the cache
  /// window return the cached data.
  Future<BannerCategory> loadBanners(String categoryId) async {
    _ensureSupported();
    return runCatchingDyplink(() async {
      final dto = await hostApi.loadBanners(categoryId);
      return BannerCategory.fromDto(dto);
    });
  }

  /// Clear the native banner cache.
  Future<void> clearCache() {
    _ensureSupported();
    return runCatchingDyplink(hostApi.clearCache);
  }

  static bool get _supported => DyplinkPlatform.isSupported;

  void _ensureSupported() {
    if (!_supported) {
      throw UnsupportedError(
        'DyplinkBanners supports Android and iOS only; this is '
        '${DyplinkPlatform.description}.',
      );
    }
  }
}

/// Flutter widget that embeds the native Dyplink `BannerCarouselView`.
///
/// This is a PlatformView — Flutter hosts the native Android view directly
/// so the carousel matches the look and behavior of the native Dyplink SDK
/// exactly (animations, auto-rotation, click tracking, etc. all run in
/// native code).
///
/// Usage:
/// ```dart
/// SizedBox(
///   height: 160,
///   child: DyplinkBannerCarousel(categoryId: 'home-top'),
/// )
/// ```
///
/// On non-Android platforms this widget renders an empty [SizedBox.shrink]
/// rather than throwing the way the rest of [DyplinkBanners] does: a widget
/// cannot report an unsupported platform out of `build` without replacing
/// the screen with an error box. Turn on [DyplinkDiagnostics] to see it
/// happen.
class DyplinkBannerCarousel extends StatelessWidget {
  const DyplinkBannerCarousel({
    super.key,
    required this.categoryId,
    this.height,
  });

  /// The Dyplink banner category to load.
  final String categoryId;

  /// Optional fixed height for the carousel. If null, the widget fills the
  /// available space from its parent (use a [SizedBox] around it).
  final double? height;

  static const String _viewType = 'com.dyplink.dyplink/banner_carousel';

  @override
  Widget build(BuildContext context) {
    if (!DyplinkPlatform.isAndroid) {
      DyplinkDiagnostics.reportSkipped(
        'DyplinkBannerCarousel',
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
