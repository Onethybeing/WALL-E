package com.sourav.walle

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.provider.AlarmClock
import android.provider.Settings
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native Android APIs that Termux itself can't reach, bridged to the
 * Python brain via bridge_server.dart (same pattern as its /photo and
 * /location endpoints, which exist for the same underlying reason):
 *
 * - dispatchMediaKey: media_control() in brain/tools.py (GitHub issue
 *   #10). Termux can't get the signature-level INJECT_EVENTS permission
 *   needed to send `input keyevent` media keys itself, but this app --
 *   as an ordinary installed app -- can use the public
 *   AudioManager.dispatchMediaKeyEvent() API to simulate a hardware media
 *   button press (same mechanism a Bluetooth headset button uses), which
 *   needs no special permission at all.
 * - setAlarm: set_alarm() in brain/tools.py (GitHub issue #12). Termux's
 *   own manifest doesn't declare SET_ALARM at all, so there's nothing to
 *   grant it -- but this app can declare that permission for itself (see
 *   AndroidManifest.xml) and fire the intent directly.
 */
class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.sourav.walle/media"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "dispatchMediaKey" -> {
                    val keyCode = call.argument<Int>("keyCode")
                    if (keyCode == null) {
                        result.error("bad_args", "keyCode is required", null)
                        return@setMethodCallHandler
                    }
                    val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    audioManager.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
                    audioManager.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
                    result.success(true)
                }
                "setAlarm" -> {
                    val hour = call.argument<Int>("hour")
                    val minute = call.argument<Int>("minute")
                    if (hour == null || minute == null) {
                        result.error("bad_args", "hour and minute are required", null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
                        putExtra(AlarmClock.EXTRA_HOUR, hour)
                        putExtra(AlarmClock.EXTRA_MINUTES, minute)
                        putExtra(AlarmClock.EXTRA_MESSAGE, call.argument<String>("label") ?: "")
                        putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    result.success(true)
                }
                "isAccessibilityServiceEnabled" -> {
                    // WallEAccessibilityService.instance != null only tells us the
                    // service is connected to *this* process right now -- it can be
                    // transiently null right after a process restart even though the
                    // person has genuinely enabled it (confirmed live: Settings.Secure
                    // still showed it enabled while `instance` was briefly null after
                    // backgrounding). Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES is
                    // the actual source of truth for "did the person turn this on".
                    val enabledServices = Settings.Secure.getString(
                        contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                    ) ?: ""
                    val serviceId = "$packageName/${WallEAccessibilityService::class.java.name}"
                    result.success(enabledServices.split(':').any { it.equals(serviceId, ignoreCase = true) })
                }
                "openAccessibilitySettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    })
                    result.success(true)
                }
                "a11yGlobalAction" -> {
                    val action = call.argument<String>("action")
                    val service = WallEAccessibilityService.instance
                    if (service == null || action == null) {
                        result.success(false)
                    } else {
                        result.success(service.globalAction(action))
                    }
                }
                "a11yGesture" -> {
                    val service = WallEAccessibilityService.instance
                    val x1 = call.argument<Double>("x1")
                    val y1 = call.argument<Double>("y1")
                    val x2 = call.argument<Double>("x2")
                    val y2 = call.argument<Double>("y2")
                    val durationMs = call.argument<Int>("durationMs") ?: 50
                    if (service == null || x1 == null || y1 == null || x2 == null || y2 == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    service.gesture(x1.toFloat(), y1.toFloat(), x2.toFloat(), y2.toFloat(), durationMs.toLong()) { ok ->
                        result.success(ok)
                    }
                }
                "a11yScreenText" -> {
                    val service = WallEAccessibilityService.instance
                    result.success(service?.screenText() ?: "")
                }
                "a11yFindAndTap" -> {
                    val service = WallEAccessibilityService.instance
                    val needle = call.argument<String>("text")
                    if (service == null || needle == null) {
                        result.success(false)
                    } else {
                        result.success(service.findAndTap(needle))
                    }
                }
                "openAppByName" -> {
                    val name = call.argument<String>("name")
                    if (name == null) {
                        result.error("bad_args", "name is required", null)
                        return@setMethodCallHandler
                    }
                    val pm = packageManager
                    val nameLower = name.lowercase()
                    val match = pm.getInstalledApplications(0).firstOrNull { app ->
                        pm.getApplicationLabel(app).toString().lowercase().contains(nameLower)
                    }
                    val launchIntent = match?.let { pm.getLaunchIntentForPackage(it.packageName) }
                    if (launchIntent == null) {
                        result.success(false)
                    } else {
                        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(launchIntent)
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
