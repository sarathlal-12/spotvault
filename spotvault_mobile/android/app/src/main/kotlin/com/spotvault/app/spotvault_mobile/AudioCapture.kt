package com.spotvault.app.spotvault_mobile

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs

/**
 * Short recordings for song recognition, as 16 kHz mono 16-bit PCM.
 *
 * Dart calls "spotvault/capture" record {source, ms}:
 *  - "mic": the microphone (needs the microphone permission, asked in Dart)
 *  - "system": what the phone is playing (Android 10+). Android asks the user
 *    to allow "recording or casting" each time; some apps block it.
 */
class AudioCapture(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        const val REQUEST = 7311
        const val RATE = 16000
        var instance: AudioCapture? = null
    }

    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var pendingMs = 10000

    init {
        instance = this
        MethodChannel(messenger, "spotvault/capture").setMethodCallHandler { call, result ->
            if (call.method != "record") return@setMethodCallHandler result.notImplemented()
            if (pending != null) return@setMethodCallHandler result.error("busy", "Already listening", null)
            val source = call.argument<String>("source") ?: "mic"
            val ms = (call.argument<Int>("ms") ?: 10000).coerceIn(1000, 20000)
            pending = result
            pendingMs = ms
            if (source == "mic") {
                Thread { finish(recordMic(ms)) }.start()
            } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                finish(Err("Listening to the phone's sound needs Android 10 or newer. Use the microphone instead."))
            } else {
                val mpm = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                activity.startActivityForResult(mpm.createScreenCaptureIntent(), REQUEST)
            }
        }
    }

    sealed class Outcome
    class Ok(val pcm: ByteArray) : Outcome()
    class Err(val message: String) : Outcome()

    fun finish(o: Outcome) {
        main.post {
            val r = pending ?: return@post
            pending = null
            when (o) {
                is Ok -> r.success(o.pcm)
                is Err -> r.error("capture", o.message, null)
            }
        }
    }

    /** The "allow recording?" answer for the phone's own sound. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        if (resultCode != Activity.RESULT_OK || data == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            finish(Err("Listening was not allowed."))
            return true
        }
        // Android 14+: the projection must be used from a foreground service.
        val i = Intent(activity, CaptureService::class.java)
            .putExtra("code", resultCode).putExtra("data", data).putExtra("ms", pendingMs)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) activity.startForegroundService(i) else activity.startService(i)
        return true
    }

    private fun recordMic(ms: Int): Outcome = try {
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        @Suppress("MissingPermission")
        val rec = AudioRecord(MediaRecorder.AudioSource.MIC, RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, RATE))
        readAll(rec, ms, "The microphone heard only silence.")
    } catch (e: SecurityException) {
        Err("SpotVault needs the microphone permission.")
    } catch (e: Exception) {
        Err("Couldn't use the microphone.")
    }
}

/** Records [ms] of audio from a ready AudioRecord as 16-bit little-endian bytes. */
fun readAll(rec: AudioRecord, ms: Int, silentMessage: String): AudioCapture.Outcome {
    if (rec.state != AudioRecord.STATE_INITIALIZED) {
        rec.release()
        return AudioCapture.Err("Couldn't start listening.")
    }
    val samples = ShortArray(AudioCapture.RATE * ms / 1000)
    rec.startRecording()
    var n = 0
    val deadline = System.currentTimeMillis() + ms + 2000
    while (n < samples.size && System.currentTimeMillis() < deadline) {
        val got = rec.read(samples, n, minOf(2048, samples.size - n))
        if (got < 0) break
        n += got
    }
    rec.stop()
    rec.release()
    var peak = 0
    for (i in 0 until n) peak = maxOf(peak, abs(samples[i].toInt()))
    if (n < samples.size / 3 || peak < 100) return AudioCapture.Err(silentMessage)
    val out = ByteArray(n * 2)
    for (i in 0 until n) {
        out[i * 2] = (samples[i].toInt() and 0xff).toByte()
        out[i * 2 + 1] = ((samples[i].toInt() shr 8) and 0xff).toByte()
    }
    return AudioCapture.Ok(out)
}

/** Foreground service that records the phone's own sound (Android 10+). */
class CaptureService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel("listen", "Song recognition", NotificationManager.IMPORTANCE_LOW))
        }
        val note = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, "listen") else @Suppress("DEPRECATION") Notification.Builder(this))
            .setContentTitle("Listening for the song…")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(73, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(73, note)
        }
        val code = intent?.getIntExtra("code", 0) ?: 0
        @Suppress("DEPRECATION")
        val data: Intent? = intent?.getParcelableExtra("data")
        val ms = intent?.getIntExtra("ms", 10000) ?: 10000
        Thread {
            val outcome = record(code, data, ms)
            AudioCapture.instance?.finish(outcome)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE) else @Suppress("DEPRECATION") stopForeground(true)
            stopSelf()
        }.start()
        return START_NOT_STICKY
    }

    private fun record(code: Int, data: Intent?, ms: Int): AudioCapture.Outcome {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || data == null) return AudioCapture.Err("Listening was not allowed.")
        var projection: MediaProjection? = null
        return try {
            val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            projection = mpm.getMediaProjection(code, data)
            if (projection == null) return AudioCapture.Err("Listening was not allowed.")
            if (Build.VERSION.SDK_INT >= 34) projection.registerCallback(object : MediaProjection.Callback() {}, Handler(Looper.getMainLooper()))
            val config = AudioPlaybackCaptureConfiguration.Builder(projection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(AudioCapture.RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()
            @Suppress("MissingPermission")
            val rec = AudioRecord.Builder().setAudioFormat(format).setAudioPlaybackCaptureConfig(config).build()
            readAll(rec, ms, "Nothing is playing, or that app doesn't let other apps hear it. Try the microphone.")
        } catch (e: SecurityException) {
            AudioCapture.Err("SpotVault needs the microphone permission to hear the phone's sound.")
        } catch (e: Exception) {
            AudioCapture.Err("Couldn't listen to the phone's sound.")
        } finally {
            projection?.stop()
        }
    }
}
