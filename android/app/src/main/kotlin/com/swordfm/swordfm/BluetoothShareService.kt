package com.swordfm.swordfm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.MethodChannel
import java.io.*
import java.nio.ByteBuffer
import java.util.*
import kotlin.concurrent.thread
import org.json.JSONObject

/**
 * Foreground service that keeps the Bluetooth RFCOMM server running
 * even when the app is in the background.
 *
 * Permissions required (already in AndroidManifest.xml):
 *   - FOREGROUND_SERVICE
 *   - FOREGROUND_SERVICE_BLUETOOTH
 *   - BLUETOOTH_CONNECT, BLUETOOTH_SCAN, BLUETOOTH_ADVERTISE
 */
class BluetoothShareService : Service() {
    companion object {
        const val CHANNEL_ID = "swordfm_bt_channel"
        const val NOTIFICATION_ID = 1001
        const val EXTRA_UUID = "extra_uuid"
        const val EXTRA_NAME = "extra_name"

        // Shared reference to method channel set by MainActivity
        @JvmStatic
        var methodChannel: MethodChannel? = null

        fun getUuid(): UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        const val SERVER_NAME = "SwordFM_BT"
    }

    private var serverThread: Thread? = null
    private var acceptLoopRunning = false

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val uuid = intent?.getStringExtra(EXTRA_UUID) ?: getUuid().toString()
        val name = intent?.getStringExtra(EXTRA_NAME) ?: SERVER_NAME
        stopAccepting() // ensure single instance
        startAccepting(uuid, name)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        stopAccepting()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Bluetooth Sharing",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "SwordFM Bluetooth file sharing is active"
            }
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("SwordFM Sharing Active")
            .setContentText("Listening for Bluetooth file transfers...")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun startAccepting(uuidStr: String, serverName: String) {
        acceptLoopRunning = true
        thread(name = "BT-Accept") {
            val adapter = BluetoothAdapter.getDefaultAdapter()
            var serverSocket: BluetoothServerSocket? = null
            try {
                serverSocket = adapter.listenUsingRfcommWithServiceRecord(serverName, UUID.fromString(uuidStr))
                notifyMethod("onServerStarted")
                while (acceptLoopRunning) {
                    try {
                        val socket: BluetoothSocket? = serverSocket?.accept(5000)
                        if (socket != null) {
                            acceptLoopRunning = false // stop accepting after first connection
                            val deviceName = socket.remoteDevice.name ?: "Unknown"
                            val deviceAddress = socket.remoteDevice.address
                            notifyMethod("onConnected", mapOf("name" to deviceName, "address" to deviceAddress))
                            TransferWorker(socket, this).start()
                        }
                    } catch (e: IOException) {
                        if (acceptLoopRunning) {
                            // interrupted or timed out, continue loop
                        }
                    }
                }
            } catch (e: Exception) {
                notifyMethod("onTransferError", mapOf("message" to "Server error: ${e.message}"))
            } finally {
                try { serverSocket?.close() } catch (_: IOException) {}
            }
        }
    }

    private fun stopAccepting() {
        acceptLoopRunning = false
        serverThread?.interrupt()
        serverThread = null
    }

    private fun notifyMethod(method: String, args: Map<String, Any>? = null) {
        methodChannel?.invokeMethod(method, args)
    }
}

/** Worker thread handling a single incoming transfer on the server side */
class TransferWorker(private val socket: BluetoothSocket, private val service: BluetoothShareService) : Thread() {
    private var cancelled = false
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    override fun run() {
        val buf = ByteArray(65536)
        var bytes: Int
        try {
            val input = socket.inputStream
            val output = socket.outputStream
            // Read metadata length (4 bytes big-endian)
            val lenBuf = ByteArray(4)
            readFully(input, lenBuf)
            val metaLen = ByteBuffer.wrap(lenBuf).int
            if (metaLen <= 0 || metaLen > 10 * 1024 * 1024) throw IOException("Invalid metadata length: $metaLen")
            val metaBuf = ByteArray(metaLen)
            readFully(input, metaBuf)
            val metaJson = JSONObject(String(metaBuf, Charsets.UTF_8))
            val filename = metaJson.getString("filename")
            val fileSize = metaJson.getLong("size")

            mainHandler.post {
                BluetoothShareService.methodChannel?.invokeMethod("onTransferStarted", mapOf("filename" to filename, "isSending" to false))
            }

            val downloadDir = File(
                android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS),
                "SwordFM"
            )
            if (!downloadDir.exists()) downloadDir.mkdirs()
            var outFile = File(downloadDir, filename)
            var counter = 1
            while (outFile.exists()) {
                val base = filename.substringBeforeLast('.')
                val ext = filename.substringAfterLast('.', "")
                val newFilename = if (ext.isEmpty()) "$filename ($counter)" else "$base ($counter).$ext"
                outFile = File(downloadDir, newFilename)
                counter++
            }

            val fos = FileOutputStream(outFile)
            var totalRead = 0L
            var lastUpdate = System.currentTimeMillis()
            while (totalRead < fileSize && !cancelled) {
                val toRead = minOf(buf.size.toLong(), fileSize - totalRead).toInt()
                bytes = input.read(buf, 0, toRead)
                if (bytes == -1) break
                fos.write(buf, 0, bytes)
                totalRead += bytes
                val now = System.currentTimeMillis()
                if (now - lastUpdate > 100) {
                    lastUpdate = now
                    mainHandler.post {
                        BluetoothShareService.methodChannel?.invokeMethod("onTransferProgress", mapOf(
                            "filename" to filename, "bytesTransferred" to totalRead,
                            "totalBytes" to fileSize, "isSending" to false
                        ))
                    }
                }
            }
            fos.close()
            if (!cancelled) {
                mainHandler.post {
                    BluetoothShareService.methodChannel?.invokeMethod("onTransferComplete", mapOf("savedPath" to outFile.absolutePath))
                }
            }
        } catch (e: Exception) {
            if (!cancelled) {
                mainHandler.post {
                    BluetoothShareService.methodChannel?.invokeMethod("onTransferError", mapOf("message" to "Receive failed: ${e.message}"))
                    BluetoothShareService.methodChannel?.invokeMethod("onDisconnected", null)
                }
            }
        }
    }

    fun cancel() {
        cancelled = true
        try { socket.close() } catch (_: IOException) {}
    }

    private fun readFully(stream: InputStream, buffer: ByteArray) {
        var offset = 0
        while (offset < buffer.size) {
            val n = stream.read(buffer, offset, buffer.size - offset)
            if (n == -1) throw IOException("Stream closed prematurely")
            offset += n
        }
    }
}
