package com.swordfm.swordfm

// ============================================================================
// SHARED BLUETOOTH FRAME PROTOCOL (see lib/services/bluetooth_share_service.dart)
// Frame:
//   [ 4-byte uint32 metadataLength ]  (big-endian)
//   [ metadataLength bytes of JSON  ]  { "filename": "example.pdf", "size": 12345 }
//   [ raw file bytes of length `size` ]]
// Reference impl: /home/sword/SwordFM/tools/swordblue
// ============================================================================

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Intent
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.*
import java.util.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import org.json.JSONObject

/**
 * ┌───────────────────────────────────────────────────────────────┐
 * │ SWORDFM RFCOMM FRAME FORMAT (MUST MATCH swordblue / path.md)  │
 * ├───────────────────────────────────────────────────────────────┤
 * │ Every file transfer is a single frame on the socket:          │
 * │                                                               │
 * │   [ 4-byte uint32 metadataLength  ]  (big-endian)             │
 * │   [ metadataLength bytes of JSON  ]                           │
 * │   [ raw file bytes (exactly "size" bytes) ]                   │
 * │                                                               │
 * │ JSON metadata:                                                │
 * │   { "filename": "example.pdf", "size": 12345 }                │
 * │                                                               │
 * │ The sender writes metadata then streams the raw bytes; the    │
 * │ receiver reads the 4-byte length, parses JSON, then reads     │
 * │ exactly "size" raw bytes. Do NOT change this without also     │
 * │ updating the Dart side and /home/sword/SwordFM/tools/swordblue│
 * └───────────────────────────────────────────────────────────────┘
 */

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler {
    private val CHANNEL = "com.swordfm/bluetooth"
    private var methodChannel: MethodChannel? = null

    private val bluetoothAdapter: BluetoothAdapter? by lazy {
        BluetoothAdapter.getDefaultAdapter()
    }

    private val MY_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private const val NAME = "SwordFM_Bluetooth"

    private var serverThread: ServerThread? = null
    private var connectThread: ConnectThread? = null
    private var transferThread: TransferThread? = null
    private var isSending = false

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        flutterEngine?.let {
            methodChannel = MethodChannel(it.dartExecutor.binaryMessenger, CHANNEL)
            methodChannel?.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isBluetoothSupported" -> {
                result.success(bluetoothAdapter != null)
            }
            "isBluetoothEnabled" -> {
                result.success(bluetoothAdapter?.isEnabled == true)
            }
            "requestEnableBluetooth" -> {
                if (bluetoothAdapter != null && !bluetoothAdapter!!.isEnabled) {
                    val enableBtIntent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                    activity.startActivity(enableBtIntent)
                }
                result.success(null)
            }
            "getPairedDevices" -> {
                val devicesList = mutableListOf<Map<String, String>>()
                if (bluetoothAdapter != null && bluetoothAdapter!!.isEnabled) {
                    val pairedDevices: Set<BluetoothDevice>? = bluetoothAdapter!!.bondedDevices
                    pairedDevices?.forEach { device ->
                        devicesList.add(mapOf("name" to device.name, "address" to device.address))
                    }
                }
                result.success(devicesList)
            }
            "startServer" -> {
                stopAllThreads()
                serverThread = ServerThread()
                serverThread?.start()
                result.success(null)
            }
            "stopServer" -> {
                stopAllThreads()
                result.success(null)
            }
            "connectToDevice" -> {
                val address = call.argument<String>("address")
                if (address == null) {
                    result.error("INVALID_ARGUMENT", "Address cannot be null", null)
                    return
                }
                val device = bluetoothAdapter?.getRemoteDevice(address)
                if (device == null) {
                    result.error("DEVICE_NOT_FOUND", "Device not found for address: $address", null)
                    return
                }
                stopAllThreads()
                connectThread = ConnectThread(device)
                connectThread?.start()
                result.success(true)
            }
            "sendFile" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGUMENT", "File path cannot be null", null)
                    return
                }
                val file = File(path)
                if (!file.exists()) {
                    result.error("FILE_NOT_FOUND", "File does not exist: $path", null)
                    return
                }
                if (transferThread == null) {
                    result.error("NO_CONNECTION", "No active connection to send file", null)
                    return
                }
                transferThread?.sendFile(file)
                result.success(null)
            }
            "disconnect" -> {
                stopAllThreads()
                result.success(null)
            }
            "cancelTransfer" -> {
                if (transferThread != null && isSending) {
                    transferThread?.cancel()
                    runOnMain {
                        methodChannel?.invokeMethod("onTransferError", mapOf("message" to "Transfer cancelled by user"))
                    }
                }
                result.success(null)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun stopAllThreads() {
        serverThread?.cancel()
        serverThread = null
        connectThread?.cancel()
        connectThread = null
        transferThread?.cancel()
        transferThread = null
    }

    private fun runOnMain(action: () -> Unit) {
        mainHandler.post(action)
    }

    // Thread for listening to incoming connections
    private inner class ServerThread : Thread() {
        private val mmServerSocket: BluetoothServerSocket? by lazy(LazyThreadSafetyMode.NONE) {
            bluetoothAdapter?.listenUsingRfcommWithServiceRecord(NAME, MY_UUID)
        }

        override fun run() {
            var shouldLoop = true
            runOnMain { methodChannel?.invokeMethod("onServerStarted", null) }
            while (shouldLoop) {
                val socket: BluetoothSocket? = try {
                    mmServerSocket?.accept()
                } catch (e: IOException) {
                    shouldLoop = false
                    null
                }
                socket?.let {
                    runOnMain {
                        mmServerSocket?.close()
                        startTransfer(it)
                    }
                    shouldLoop = false
                }
            }
        }

        fun cancel() {
            try {
                mmServerSocket?.close()
            } catch (e: IOException) {
            }
        }
    }

    companion object {
        private const val CONNECT_TIMEOUT_MS = 30000L
        private const val MAX_CONNECT_RETRIES = 1
    }

    // Thread for connecting to a remote device
    private inner class ConnectThread(val device: BluetoothDevice) : Thread() {
        private val mmSocket: BluetoothSocket? by lazy(LazyThreadSafetyMode.NONE) {
            device.createRfcommSocketToServiceRecord(MY_UUID)
        }

        override fun run() {
            bluetoothAdapter?.cancelDiscovery()
            var lastException: IOException? = null

            // Try initial connect with timeout, then one auto-retry
            for (attempt in 0..MAX_CONNECT_RETRIES) {
                if (attempt > 0) {
                    runOnMain {
                        methodChannel?.invokeMethod("onTransferProgress", mapOf(
                            "filename" to (device.name ?: "Device"),
                            "bytesTransferred" to 0,
                            "totalBytes" to 0,
                            "isSending" to false,
                            "message" to "Reconnecting..."
                        ))
                    }
                    try { Thread.sleep(2000) } catch (_: InterruptedException) { break }
                }
                val socket = try {
                    val latch = CountDownLatch(1)
                    var sock: BluetoothSocket? = null
                    var connException: Exception? = null
                    thread {
                        try {
                            sock = mmSocket
                            sock?.connect()
                            latch.countDown()
                        } catch (e: Exception) {
                            connException = e
                            latch.countDown()
                        }
                    }
                    if (latch.await(CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                        if (connException != null) throw IOException("Connect failed: ${connException.message}", connException)
                        sock
                    } else {
                        throw IOException("Connection timed out after ${CONNECT_TIMEOUT_MS}ms")
                    }
                } catch (e: IOException) {
                    lastException = e
                    try { mmSocket?.close() } catch (_: IOException) {}
                    if (attempt < MAX_CONNECT_RETRIES) continue
                    throw e
                }

                socket?.let {
                    runOnMain { startTransfer(it) }
                    return
                }
            }

            // All retries exhausted
            runOnMain {
                methodChannel?.invokeMethod("onDisconnected", null)
                methodChannel?.invokeMethod("onTransferError", mapOf("message" to "Connection failed: ${lastException?.message}"))
            }
        }

        fun cancel() {
            try {
                mmSocket?.close()
            } catch (e: IOException) {
            }
        }
    }

    private fun startTransfer(socket: BluetoothSocket) {
        val deviceName = socket.remoteDevice.name ?: "Unknown"
        val deviceAddress = socket.remoteDevice.address ?: ""
        methodChannel?.invokeMethod("onConnected", mapOf("name" to deviceName, "address" to deviceAddress))
        transferThread = TransferThread(socket)
        transferThread?.start()
    }

    // Thread for handling file transfers
    private inner class TransferThread(val socket: BluetoothSocket) : Thread() {
        private val mmInStream: InputStream = socket.inputStream
        private val mmOutStream: OutputStream = socket.outputStream
        private var isCancelled = false

        override fun run() {
            val buffer = ByteArray(65536)
            var bytes: Int

            while (!isCancelled) {
                try {
                    // Read 4-byte JSON metadata length (see frame-format comment at top).
                    val lenBuffer = ByteArray(4)
                    readFully(mmInStream, lenBuffer)
                    val metadataLength = DataInputStream(ByteArrayInputStream(lenBuffer)).readInt()
                    if (metadataLength <= 0 || metadataLength > 1024 * 1024) {
                        throw IOException("Invalid metadata length: $metadataLength")
                    }

                    // Read JSON metadata
                    val metaBuffer = ByteArray(metadataLength)
                    readFully(mmInStream, metaBuffer)
                    val metaJson = JSONObject(String(metaBuffer, Charsets.UTF_8))
                    val fileLength = metaJson.getLong("size")
                    val filename = metaJson.getString("filename")

                    runOnMain {
                        methodChannel?.invokeMethod("onTransferStarted", mapOf("filename" to filename, "isSending" to false))
                    }

                    // Setup saving file in Download directory
                    val downloadFolder = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "SwordFM")
                    if (!downloadFolder.exists()) {
                        downloadFolder.mkdirs()
                    }
                    // Handle filename collision: append (1), (2), etc.
                    var outputFile = File(downloadFolder, filename)
                    var collisionCounter = 1
                    while (outputFile.exists()) {
                        val baseName = filename.substringBeforeLast('.')
                        val ext = filename.substringAfterLast('.', "")
                        val newFilename = if (ext.isEmpty) "$filename ($collisionCounter)" else "$baseName ($collisionCounter).$ext"
                        outputFile = File(downloadFolder, newFilename)
                        collisionCounter++
                    }
                    val fileOutputStream = FileOutputStream(outputFile)

                    var totalBytesReceived = 0L
                    var lastUpdate = System.currentTimeMillis()

                    while (totalBytesReceived < fileLength && !isCancelled) {
                        val toRead = Math.min(buffer.size.toLong(), fileLength - totalBytesReceived).toInt()
                        bytes = mmInStream.read(buffer, 0, toRead)
                        if (bytes == -1) throw IOException("Stream cut off prematurely")
                        fileOutputStream.write(buffer, 0, bytes)
                        totalBytesReceived += bytes

                        val now = System.currentTimeMillis()
                        if (now - lastUpdate > 100) { // limit progress updates to 10Hz
                            lastUpdate = now
                            val progressArgs = mapOf(
                                "filename" to filename,
                                "bytesTransferred" to totalBytesReceived,
                                "totalBytes" to fileLength,
                                "isSending" to false
                            )
                            runOnMain { methodChannel?.invokeMethod("onTransferProgress", progressArgs) }
                        }
                    }
                    fileOutputStream.close()

                    if (!isCancelled) {
                        runOnMain {
                            methodChannel?.invokeMethod("onTransferComplete", mapOf("savedPath" to outputFile.absolutePath))
                        }
                    }
                } catch (e: IOException) {
                    if (!isCancelled) {
                        runOnMain {
                            methodChannel?.invokeMethod("onDisconnected", null)
                            methodChannel?.invokeMethod("onTransferError", mapOf("message" to "Connection lost: ${e.message}"))
                        }
                    }
                    break
                } catch (e: Exception) {
                    if (!isCancelled) {
                        runOnMain {
                            methodChannel?.invokeMethod("onDisconnected", null)
                            methodChannel?.invokeMethod("onTransferError", mapOf("message" to "Transfer failed: ${e.message}"))
                        }
                    }
                    break
                }
            }
        }

        fun sendFile(file: File) {
            thread {
                try {
                    val fileLength = file.length()

                    isSending = true
                    runOnMain {
                        methodChannel?.invokeMethod("onTransferStarted", mapOf("filename" to file.name, "isSending" to true))
                    }

                    // Write the JSON metadata frame (see frame-format comment at top).
                    val metadata = JSONObject()
                        .put("filename", file.name)
                        .put("size", fileLength)
                    val metadataBytes = metadata.toString().toByteArray(Charsets.UTF_8)

                    // 4-byte big-endian metadata length
                    val lenBos = ByteArrayOutputStream()
                    DataOutputStream(lenBos).use { it.writeInt(metadataBytes.size) }
                    mmOutStream.write(lenBos.toByteArray())
                    mmOutStream.write(metadataBytes)
                    mmOutStream.flush()

                    val fileInputStream = FileInputStream(file)
                    val buffer = ByteArray(65536)
                    var bytesRead: Int
                    var totalBytesSent = 0L
                    var lastUpdate = System.currentTimeMillis()

                    while (fileInputStream.read(buffer).also { bytesRead = it } != -1 && !isCancelled) {
                        mmOutStream.write(buffer, 0, bytesRead)
                        totalBytesSent += bytesRead

                        val now = System.currentTimeMillis()
                        if (now - lastUpdate > 100) {
                            lastUpdate = now
                            val progressArgs = mapOf(
                                "filename" to file.name,
                                "bytesTransferred" to totalBytesSent,
                                "totalBytes" to fileLength,
                                "isSending" to true
                            )
                            runOnMain { methodChannel?.invokeMethod("onTransferProgress", progressArgs) }
                        }
                    }
                    fileInputStream.close()
                    mmOutStream.flush()

                    if (!isCancelled) {
                        runOnMain {
                            methodChannel?.invokeMethod("onTransferComplete", mapOf("savedPath" to ""))
                        }
                    }
                } catch (e: Exception) {
                    runOnMain {
                        methodChannel?.invokeMethod("onTransferError", mapOf("message" to "Send failed: ${e.message}"))
                    }
                } finally {
                    isSending = false
                }
            }
        }

        fun cancel() {
            isCancelled = true
            try {
                socket.close()
            } catch (e: IOException) {
            }
        }
    }
}

/**
 * Reads exactly [buffer.size] bytes from [stream], blocking until the buffer
 * is full or the stream ends. Used by [TransferThread.run] to read the
 * length-prefixed JSON metadata frame (see frame-format comment at top).
 */
private fun readFully(stream: InputStream, buffer: ByteArray) {
    var offset = 0
    while (offset < buffer.size) {
        val read = stream.read(buffer, offset, buffer.size - offset)
        if (read == -1) throw IOException("Stream closed while reading")
        offset += read
    }
}
