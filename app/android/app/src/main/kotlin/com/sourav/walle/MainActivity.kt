package com.sourav.walle

import android.content.Context
import android.media.AudioManager
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Media-key dispatch for media_control() in brain/tools.py (see GitHub
 * issue #10). Termux can't get the signature-level INJECT_EVENTS
 * permission needed to send `input keyevent` media keys itself, but this
 * app -- as an ordinary installed app -- can use the public
 * AudioManager.dispatchMediaKeyEvent() API to simulate a hardware media
 * button press (same mechanism a Bluetooth headset button uses), which
 * needs no special permission at all. bridge_server.dart's /media
 * endpoint calls this via a platform channel.
 */
class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.sourav.walle/media"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "dispatchMediaKey") {
                val keyCode = call.argument<Int>("keyCode")
                if (keyCode == null) {
                    result.error("bad_args", "keyCode is required", null)
                    return@setMethodCallHandler
                }
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
                audioManager.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }
}
