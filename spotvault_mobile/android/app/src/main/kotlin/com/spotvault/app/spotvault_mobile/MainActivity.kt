package com.spotvault.app.spotvault_mobile

import com.ryanheise.audioservice.AudioServiceActivity
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine

// AudioServiceActivity keeps playback alive in the background (lock screen, notification).
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Bluetooth sharing between Android phones (see P2pLink.kt).
        P2pLink(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        // Song recognition: microphone and the phone's own sound (see AudioCapture.kt).
        AudioCapture(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    @Deprecated("Flutter still routes results through onActivityResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (AudioCapture.instance?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }
}
