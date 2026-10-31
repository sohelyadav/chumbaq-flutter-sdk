package com.chumbaq.chumbaq

import android.content.Context
import android.view.View
import com.chumbaq.banners.ui.BannerCarouselView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Embeds the native [BannerCarouselView] inside a Flutter widget.
 *
 * Usage from Dart:
 * ```
 * AndroidView(
 *   viewType: 'com.chumbaq.chumbaq/banner_carousel',
 *   creationParams: {'categoryId': 'home-top'},
 *   creationParamsCodec: StandardMessageCodec(),
 * )
 * ```
 *
 * The [ChumbaqBannerCarousel] widget in `lib/chumbaq.dart` wraps this so
 * users never write the AndroidView boilerplate.
 */
internal class BannerCarouselViewFactory :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?> ?: emptyMap()
        val categoryId = params["categoryId"] as? String
        return BannerCarouselPlatformView(context, categoryId)
    }
}

private class BannerCarouselPlatformView(
    context: Context,
    categoryId: String?,
) : PlatformView {

    private val view: BannerCarouselView = BannerCarouselView(context).apply {
        categoryId?.let { setCategoryId(it) }
    }

    override fun getView(): View = view

    override fun dispose() {
        // BannerCarouselView owns its own coroutine scope internally; nothing
        // to tear down from the factory. If/when BannerCarouselView gains a
        // public release() method, call it here.
    }
}
