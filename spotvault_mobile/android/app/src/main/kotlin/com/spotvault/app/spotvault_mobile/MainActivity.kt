package com.spotvault.app.spotvault_mobile

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

// AudioServiceActivity keeps playback alive in the background (lock screen, notification).
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Bluetooth sharing between Android phones (see P2pLink.kt).
        P2pLink(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }
}
