package com.dyplink.dyplink

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMethodCodec
import io.flutter.plugin.platform.PlatformViewRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.mockito.ArgumentCaptor
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentMatchers.eq
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Unit tests for the plugin's Pigeon and EventChannel entry points.
 *
 * These drive the real bridge: a mocked [BinaryMessenger] stands in for the
 * Flutter engine, so an `EventChannel` registration is a captured message
 * handler and an emitted event is an outgoing `send` that can be decoded with
 * the same codec Dart would use. Nothing here reimplements the plugin's
 * wiring — it is exercised through the same surface the engine uses.
 *
 * What is deliberately *not* covered: anything that needs an initialised
 * native SDK. `Dyplink.init` wants a real `Context` and does storage work, so
 * forwarding calls like `track` or `identify` have no meaningful assertion on
 * a plain JVM beyond "it threw where it should". The token stream, the HostApi
 * surface and the error mapping are all reachable without it, and those are
 * what this file covers.
 */
internal class DyplinkPluginTest {

    private val pushTokenChannel = "com.dyplink.dyplink/push_tokens"

    private lateinit var plugin: DyplinkPlugin
    private lateinit var messenger: BinaryMessenger
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding

    @BeforeTest
    fun setUp() {
        // The plugin's scope is Dispatchers.Main, which has no implementation
        // on a plain JVM.
        Dispatchers.setMain(StandardTestDispatcher())

        messenger = mock(BinaryMessenger::class.java)
        binding = mock(FlutterPlugin.FlutterPluginBinding::class.java)
        `when`(binding.binaryMessenger).thenReturn(messenger)
        `when`(binding.applicationContext).thenReturn(mock(Context::class.java))
        `when`(binding.platformViewRegistry)
            .thenReturn(mock(PlatformViewRegistry::class.java))

        plugin = DyplinkPlugin()
        // EventSinks are normally fed via a main-thread Handler, which needs a
        // Looper. Run the dispatch inline instead.
        plugin.postToMain = { it.run() }
    }

    @AfterTest
    fun tearDown() {
        // Always detach: the token observer list is static, so a test that
        // left one registered would bleed into the next.
        runCatching { plugin.onDetachedFromEngine(binding) }
        Dispatchers.resetMain()
    }

    // ── Push token stream ──────────────────────────────────────────────────

    @Test
    fun `a refreshed token reaches the push token EventChannel`() {
        plugin.onAttachedToEngine(binding)
        openPushTokenStream()
        plugin.startTokenStream()

        DyplinkFlutterMessagingService.publishToken("fcm-token-1")

        assertEquals(listOf("fcm-token-1"), emittedTokens())
    }

    @Test
    fun `no token is emitted before startTokenStream`() {
        plugin.onAttachedToEngine(binding)
        openPushTokenStream()

        // Subscribing to the EventChannel alone must not make the plugin an
        // observer — the Dart facade calls startTokenStream on first listen,
        // and that is the call that arms the bridge.
        DyplinkFlutterMessagingService.publishToken("fcm-token-1")

        assertTrue(emittedTokens().isEmpty())
    }

    @Test
    fun `stopTokenStream stops delivery`() {
        plugin.onAttachedToEngine(binding)
        openPushTokenStream()
        plugin.startTokenStream()
        plugin.stopTokenStream()

        DyplinkFlutterMessagingService.publishToken("fcm-token-1")

        assertTrue(emittedTokens().isEmpty())
    }

    @Test
    fun `startTokenStream twice still emits a token once`() {
        plugin.onAttachedToEngine(binding)
        openPushTokenStream()
        plugin.startTokenStream()
        plugin.startTokenStream()

        DyplinkFlutterMessagingService.publishToken("fcm-token-1")

        // A second registration would double every token. Guarded by the
        // tokenStreamActive flag; DyplinkFlutterMessagingService.addObserver
        // de-duplicates as well, as defence in depth.
        assertEquals(listOf("fcm-token-1"), emittedTokens())
    }

    @Test
    fun `onDetachedFromEngine unregisters the token observer`() {
        plugin.onAttachedToEngine(binding)
        openPushTokenStream()
        plugin.startTokenStream()
        assertEquals(1, DyplinkFlutterMessagingService.observerCount)

        plugin.onDetachedFromEngine(binding)

        // Asserted on the registry, not on the absence of an emission: detach
        // also nulls the EventSink, so a token delivered to a leaked observer
        // goes nowhere and looks exactly like one never delivered. The
        // registry is static and outlives the engine, so a plugin left in it
        // is a real leak.
        assertEquals(0, DyplinkFlutterMessagingService.observerCount)
    }

    @Test
    fun `a Firebase token refresh reaches the observers`() {
        plugin.onAttachedToEngine(binding)
        openPushTokenStream()
        plugin.startTokenStream()

        // Through the override itself, not through publishToken: this is the
        // link that makes the stream have a producer at all. The native SDK's
        // DyplinkPush.onTokenRefresh is internal to its module, so this
        // override is the only public hook on a refresh.
        DyplinkFlutterMessagingService().onDyplinkTokenRefresh("fcm-token-1")

        assertEquals(listOf("fcm-token-1"), emittedTokens())
    }

    // ── Mi Push ────────────────────────────────────────────────────────────

    @Test
    fun `registerMiPushToken reports the native failure as a typed FlutterError`() {
        // A real latch, not the test scheduler: the plugin hops to
        // Dispatchers.IO to make the suspending native call, and that hop
        // leaves the test dispatcher's control — advanceUntilIdle would
        // return before the callback ran.
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val plugin = DyplinkPlugin()

        val done = CountDownLatch(1)
        var result: Result<Unit>? = null
        plugin.registerMiPushToken("mi-regid-1") {
            result = it
            done.countDown()
        }
        assertTrue(done.await(5, TimeUnit.SECONDS), "callback never fired")

        // DyplinkPush is uninitialised here, so the native call rejects it.
        // The point is that the bridge *reached* it and rewrapped the
        // exception with a stable code rather than letting it escape raw.
        val error = result?.exceptionOrNull()
        assertTrue(error is FlutterError, "expected a FlutterError, got $error")
        assertEquals("INVALID_STATE", error.code)
    }

    // ── HostApi surface ────────────────────────────────────────────────────

    @Test
    fun `no two HostApis this plugin implements declare the same method`() {
        // The plugin implements all four Pigeon HostApis on one object, so two
        // interfaces declaring the same name and parameter types collapse into
        // a single override that silently answers both channels. That is how
        // DyplinkPushHostApi.isInitialized came to return the *core* SDK's
        // state: one `isInitialized()` satisfied both interfaces, and the push
        // module's own flag was unreachable from Dart.
        //
        // Overloads are fine — DyplinkHostApi.initialize(config) and
        // DyplinkPushHostApi.initialize() differ in parameters, so Kotlin
        // keeps them apart. Only an identical signature is a collision.
        val hostApis = listOf(
            DyplinkHostApi::class.java,
            DyplinkPushHostApi::class.java,
            DyplinkBannersHostApi::class.java,
            DyplinkMessagesHostApi::class.java,
        )

        val seen = mutableMapOf<String, String>()
        val collisions = mutableListOf<String>()
        for (api in hostApis) {
            for (method in api.declaredMethods) {
                val signature =
                    method.name + method.parameterTypes.joinToString(",") { it.name }
                val owner = seen.put(signature, api.simpleName)
                if (owner != null) {
                    collisions += "${method.name} on $owner and ${api.simpleName}"
                }
            }
        }

        assertTrue(
            collisions.isEmpty(),
            "HostApi methods collapse into one implementation: $collisions",
        )
    }

    @Test
    fun `the push module exposes its own initialised state`() {
        // Guards the rename rather than the value: with DyplinkPush
        // uninitialised, both modules answer false, so only the wiring can be
        // asserted here. Pair with the collision test above.
        assertTrue(
            DyplinkPushHostApi::class.java.declaredMethods
                .any { it.name == "isPushInitialized" },
            "DyplinkPushHostApi should ask for the push module's own state",
        )
        assertEquals(false, plugin.isPushInitialized())
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    /**
     * Sends the EventChannel's `listen` handshake for the push-token channel,
     * which is what hands the plugin its EventSink.
     */
    private fun openPushTokenStream() {
        val captor = ArgumentCaptor.forClass(BinaryMessenger.BinaryMessageHandler::class.java)
        verify(messenger).setMessageHandler(eq(pushTokenChannel), captor.capture())

        val listen = StandardMethodCodec.INSTANCE
            .encodeMethodCall(io.flutter.plugin.common.MethodCall("listen", null))
        listen.flip()
        captor.value.onMessage(listen) { }
    }

    /** Every token the plugin has written to the push-token channel so far. */
    private fun emittedTokens(): List<String> {
        val captor = ArgumentCaptor.forClass(ByteBuffer::class.java)
        // `never()` would fail the call itself, so count the invocations by
        // capturing and tolerate zero.
        val sent = mutableListOf<String>()
        try {
            verify(messenger, org.mockito.Mockito.atLeastOnce())
                .send(eq(pushTokenChannel), captor.capture())
        } catch (_: AssertionError) {
            return emptyList()
        }
        for (buffer in captor.allValues) {
            buffer.position(0)
            val decoded = StandardMethodCodec.INSTANCE.decodeEnvelope(buffer)
            sent += decoded as String
        }
        return sent
    }
}
