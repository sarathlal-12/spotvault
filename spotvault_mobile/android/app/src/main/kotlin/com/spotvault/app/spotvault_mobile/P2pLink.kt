package com.spotvault.app.spotvault_mobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Fast phone-to-phone link between Android phones (Google Nearby Connections:
 * Bluetooth to find each other, then a direct Wi-Fi link for the files).
 * Who may send what is decided in Dart (the Accept prompt), so connections are
 * accepted here automatically.
 */
class P2pLink(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val client: ConnectionsClient = Nearby.getConnectionsClient(context)
    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null
    private var myName = "Phone"

    // File payloads waiting for their name (sent as a message just before).
    private val fileNames = HashMap<Long, String>()
    private val incomingFiles = HashMap<Long, Payload>()

    init {
        MethodChannel(messenger, "spotvault/p2p").setMethodCallHandler(this)
        EventChannel(messenger, "spotvault/p2p/events").setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    private fun emit(map: Map<String, Any?>) {
        main.post { events?.success(map) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                myName = call.argument<String>("name") ?: "Phone"
                val advertise = call.argument<Boolean>("advertise") ?: false
                val discover = call.argument<Boolean>("discover") ?: false
                if (advertise) {
                    client.startAdvertising(myName, SERVICE, lifecycle, AdvertisingOptions.Builder().setStrategy(STRATEGY).build())
                        .addOnFailureListener { emit(mapOf("type" to "error", "message" to (it.message ?: "advertise failed"))) }
                }
                if (discover) {
                    client.startDiscovery(SERVICE, discovery, DiscoveryOptions.Builder().setStrategy(STRATEGY).build())
                        .addOnFailureListener { emit(mapOf("type" to "error", "message" to (it.message ?: "discovery failed"))) }
                }
                result.success(true)
            }
            "stop" -> {
                client.stopAdvertising()
                client.stopDiscovery()
                client.stopAllEndpoints()
                fileNames.clear()
                incomingFiles.clear()
                result.success(true)
            }
            "connect" -> {
                val id = call.argument<String>("id")!!
                client.requestConnection(myName, id, lifecycle)
                    .addOnSuccessListener { result.success(true) }
                    .addOnFailureListener { result.error("connect", it.message, null) }
            }
            "disconnect" -> {
                client.disconnectFromEndpoint(call.argument<String>("id")!!)
                result.success(true)
            }
            "sendMessage" -> {
                val id = call.argument<String>("id")!!
                val data = call.argument<ByteArray>("data")!!
                client.sendPayload(id, Payload.fromBytes(byteArrayOf(KIND_MESSAGE) + data))
                    .addOnSuccessListener { result.success(true) }
                    .addOnFailureListener { result.error("send", it.message, null) }
            }
            "sendFile" -> {
                val id = call.argument<String>("id")!!
                val name = call.argument<String>("name")!!
                val path = call.argument<String>("path")!!
                try {
                    val payload = Payload.fromFile(File(path))
                    // Name first, so the receiver knows what the file is.
                    val header = "${payload.id}|$name".toByteArray()
                    client.sendPayload(id, Payload.fromBytes(byteArrayOf(KIND_FILE_NAME) + header))
                    client.sendPayload(id, payload)
                        .addOnSuccessListener { result.success(payload.id) }
                        .addOnFailureListener { result.error("send", it.message, null) }
                } catch (e: Exception) {
                    result.error("send", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private val discovery = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(id: String, info: DiscoveredEndpointInfo) =
            emit(mapOf("type" to "found", "id" to id, "name" to info.endpointName))

        override fun onEndpointLost(id: String) = emit(mapOf("type" to "lost", "id" to id))
    }

    private val lifecycle = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(id: String, info: ConnectionInfo) {
            client.acceptConnection(id, payloads)
            emit(mapOf("type" to "peer", "id" to id, "name" to info.endpointName))
        }

        override fun onConnectionResult(id: String, res: ConnectionResolution) {
            emit(mapOf("type" to if (res.status.isSuccess) "connected" else "failed", "id" to id))
        }

        override fun onDisconnected(id: String) = emit(mapOf("type" to "disconnected", "id" to id))
    }

    private val payloads = object : PayloadCallback() {
        override fun onPayloadReceived(id: String, payload: Payload) {
            when (payload.type) {
                Payload.Type.BYTES -> {
                    val b = payload.asBytes() ?: return
                    if (b.isEmpty()) return
                    val body = b.copyOfRange(1, b.size)
                    when (b[0]) {
                        KIND_MESSAGE -> emit(mapOf("type" to "message", "id" to id, "data" to body))
                        KIND_FILE_NAME -> {
                            val s = String(body)
                            val bar = s.indexOf('|')
                            if (bar > 0) {
                                val pid = s.substring(0, bar).toLongOrNull() ?: return
                                fileNames[pid] = s.substring(bar + 1)
                            }
                        }
                    }
                }
                Payload.Type.FILE -> incomingFiles[payload.id] = payload
                else -> {}
            }
        }

        override fun onPayloadTransferUpdate(id: String, update: PayloadTransferUpdate) {
            val pid = update.payloadId
            when (update.status) {
                PayloadTransferUpdate.Status.IN_PROGRESS -> if (incomingFiles.containsKey(pid)) {
                    emit(mapOf("type" to "progress", "id" to id, "done" to update.bytesTransferred, "total" to update.totalBytes))
                }
                PayloadTransferUpdate.Status.SUCCESS -> {
                    val p = incomingFiles.remove(pid) ?: return
                    val name = fileNames.remove(pid) ?: return
                    try {
                        // Copy out of Nearby's download area into our cache.
                        val out = File(context.cacheDir, "p2p_$pid")
                        val pfd = p.asFile()?.asParcelFileDescriptor() ?: return
                        android.os.ParcelFileDescriptor.AutoCloseInputStream(pfd).use { input ->
                            out.outputStream().use { input.copyTo(it) }
                        }
                        emit(mapOf("type" to "file", "id" to id, "name" to name, "path" to out.absolutePath))
                    } catch (e: Exception) {
                        emit(mapOf("type" to "error", "message" to (e.message ?: "file failed")))
                    }
                }
                PayloadTransferUpdate.Status.FAILURE, PayloadTransferUpdate.Status.CANCELED -> {
                    if (incomingFiles.remove(pid) != null) {
                        emit(mapOf("type" to "fileFailed", "id" to id, "name" to (fileNames.remove(pid) ?: "")))
                    }
                }
                else -> {}
            }
        }
    }

    companion object {
        private const val SERVICE = "com.spotvault.share"
        private val STRATEGY = Strategy.P2P_POINT_TO_POINT
        private const val KIND_MESSAGE: Byte = 1
        private const val KIND_FILE_NAME: Byte = 2
    }
}
