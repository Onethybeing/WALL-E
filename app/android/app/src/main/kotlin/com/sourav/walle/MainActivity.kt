package com.sourav.walle

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.provider.AlarmClock
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
                else -> result.notImplemented()
            }
        }
    }
}
