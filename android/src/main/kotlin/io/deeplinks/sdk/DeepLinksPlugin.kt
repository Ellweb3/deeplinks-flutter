package io.deeplinks.sdk

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.Locale
import java.util.TimeZone
import kotlin.math.roundToInt

class DeepLinksPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener {

    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var store: InstallStore
    private lateinit var referrer: InstallReferrerFetcher
    private var activityBinding: ActivityPluginBinding? = null
    private var sink: EventChannel.EventSink? = null
    private val pendingLinks = ArrayDeque<String>()
    private var initialLink: String? = null
    private var initialLinkRequested = false
    private var launchIntentHandled = false
    private var lastLink: String? = null
    private var lastLinkAt = 0L

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        store = InstallStore(context.noBackupFilesDir)
        referrer = InstallReferrerFetcher(context, store)
        methods = MethodChannel(binding.binaryMessenger, "io.deeplinks/sdk")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "io.deeplinks/links")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceInfo" -> result.success(deviceInfo(call.argument<String>("app_key") ?: ""))
            "storageGet" -> result.success(call.argument<String>("key")?.let { store.get(it) })
            "storageSet" -> {
                val key = call.argument<String>("key")
                val value = call.argument<String>("value")
                if (key != null && value != null) store.put(key, value)
                result.success(null)
            }
            "storageRemove" -> {
                call.argument<String>("key")?.let { store.remove(it) }
                result.success(null)
            }
            "installReferrer" -> referrer.fetch { result.success(it) }
            "clipboardLink" -> result.success(null)
            "initialLink" -> {
                initialLinkRequested = true
                result.success(initialLink)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        while (pendingLinks.isNotEmpty()) {
            events.success(pendingLinks.removeFirst())
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attach(binding)
        if (!launchIntentHandled) {
            launchIntentHandled = true
            receive(binding.activity.intent)
        }
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attach(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detach()
    }

    override fun onDetachedFromActivity() {
        detach()
    }

    override fun onNewIntent(intent: Intent): Boolean {
        receive(intent)
        return false
    }

    private fun attach(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
    }

    private fun detach() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    private fun receive(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val link = intent.dataString ?: return
        val now = SystemClock.elapsedRealtime()
        if (link == lastLink && now - lastLinkAt < DUPLICATE_WINDOW_MS) return
        lastLink = link
        lastLinkAt = now
        if (!initialLinkRequested && initialLink == null) {
            initialLink = link
            return
        }
        sink?.success(link) ?: pendingLinks.addLast(link)
    }

    private fun deviceInfo(appKey: String): Map<String, Any?> {
        val metrics = context.resources.displayMetrics
        val density = metrics.density.takeIf { it > 0f } ?: 1f
        val (widthPx, heightPx) = screenSizePx(activityBinding?.activity, metrics.widthPixels, metrics.heightPixels)
        val androidId = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
        return mapOf(
            "device_id" to DeviceIdentity.resolve(androidId, appKey, store),
            "platform" to "android",
            "os_version" to Build.VERSION.RELEASE,
            "device_model" to Build.MODEL,
            "screen_w" to (widthPx / density).roundToInt(),
            "screen_h" to (heightPx / density).roundToInt(),
            "dpr" to density.toDouble(),
            "timezone" to TimeZone.getDefault().id,
            "language" to Locale.getDefault().toLanguageTag(),
            "app_version" to appVersion(),
        )
    }

    private fun screenSizePx(activity: Activity?, fallbackWidth: Int, fallbackHeight: Int): Pair<Int, Int> {
        if (activity != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = activity.windowManager.maximumWindowMetrics.bounds
            return bounds.width() to bounds.height()
        }
        return fallbackWidth to fallbackHeight
    }

    private fun appVersion(): String? = try {
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, 0)
        }
        info.versionName
    } catch (_: Exception) {
        null
    }

    companion object {
        private const val DUPLICATE_WINDOW_MS = 1000L
    }
}
