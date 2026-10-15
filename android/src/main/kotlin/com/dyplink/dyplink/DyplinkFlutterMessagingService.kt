package com.dyplink.dyplink

import com.dyplink.push.DyplinkMessagingService
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The [DyplinkMessagingService] the Flutter plugin installs, so a token
 * refresh can reach Dart.
 *
 * The native SDK's own `DyplinkPush.onTokenRefresh` is `internal`, and the
 * only public hook on a refresh is [DyplinkMessagingService.onDyplinkTokenRefresh]
 * — an override point, not a listener. So the plugin subclasses the service
 * and republishes what it is handed. `super.onNewToken` still runs first, so
 * the backend registration and the default notification behaviour are
 * unchanged; this only adds the fan-out.
 *
 * The plugin's `AndroidManifest.xml` swaps this in for the SDK's service, so
 * an app that uses the Flutter plugin gets it without doing anything. An app
 * that registers a `FirebaseMessagingService` of its own instead must call
 * [publishToken] from its `onNewToken`, or `DyplinkPush.tokens` stays silent.
 *
 * [observers] is static because the service and the Flutter engine are
 * separate objects with unrelated lifecycles: Firebase constructs a fresh
 * service instance per delivery, and it may construct one when no engine is
 * attached at all. A refresh that arrives with no observers registered is
 * dropped — the native registration has already happened by then, so there
 * is nothing to replay and nobody to replay it to.
 */
class DyplinkFlutterMessagingService : DyplinkMessagingService() {

    override fun onDyplinkTokenRefresh(token: String) {
        super.onDyplinkTokenRefresh(token)
        publishToken(token)
    }

    /** Notified on the thread the refresh arrived on. */
    internal fun interface TokenRefreshObserver {
        fun onTokenRefresh(token: String)
    }

    companion object {
        // Copy-on-write because a refresh can land on Firebase's background
        // thread while the Dart side is subscribing on the main one, and
        // registration is far rarer than iteration.
        private val observers = CopyOnWriteArrayList<TokenRefreshObserver>()

        /**
         * Republishes [token] to every registered observer.
         *
         * Public so an app with its own `FirebaseMessagingService` can keep
         * `DyplinkPush.tokens` working — call it from `onNewToken`, after
         * forwarding to `DyplinkPush.onTokenRefresh`.
         */
        @JvmStatic
        fun publishToken(token: String) {
            observers.forEach { it.onTokenRefresh(token) }
        }

        internal fun addObserver(observer: TokenRefreshObserver) {
            observers.addIfAbsent(observer)
        }

        internal fun removeObserver(observer: TokenRefreshObserver) {
            observers.remove(observer)
        }

        /**
         * How many observers are registered. Visible for testing.
         *
         * A leaked observer is otherwise unobservable: a detached plugin
         * nulls its EventSink, so a token it still receives goes nowhere and
         * looks exactly like one it never received.
         */
        internal val observerCount: Int get() = observers.size
    }
}
