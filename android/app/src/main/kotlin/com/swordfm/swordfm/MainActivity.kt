package com.swordfm.swordfm

// ============================================================================
// SHARED BLUETOOTH FRAME PROTOCOL (see lib/services/bluetooth_share_service.dart)
// Frame: [8-byte file-length LE uint64][4-byte filename-length LE int32]
//        [N-byte UTF-8 filename][raw file bytes of length `file-length`]
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
import kotlin.concurrent.thread

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler {
    private val CHANNEL = "com.swordfm/bluetooth"
    private var methodChannel: MethodChannel? = null

    private val bluetoothAdapter: BluetoothAdapter? by lazy {
        BluetoothAdapter.getDefaultAdapter()
    }

    private val MY_UUID: UUID = UUID.fromString("809a2503-bc81-4235-8669-026857147b1e")
    private const val NAME = "SwordFM_Bluetooth"

    private var serverThread: ServerThread? = null
    private var connectThread: ConnectThread? = null
    private var transferThread: TransferThread? = null

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

    // Thread for connecting to a remote device
    private inner class ConnectThread(val device: BluetoothDevice) : Thread() {
        private val mmSocket: BluetoothSocket? by lazy(LazyThreadSafetyMode.NONE) {
            device.createRfcommSocketToServiceRecord(MY_UUID)
        }

        override fun run() {
            bluetoothAdapter?.cancelDiscovery()

            try {
                mmSocket?.let { socket ->
                    socket.connect()
                    runOnMain { startTransfer(socket) }
                }
            } catch (e: IOException) {
                runOnMain {
                    methodChannel?.invokeMethod("onDisconnected", null)
                    methodChannel?.invokeMethod("onTransferError", mapOf("message" to "Connection failed: ${e.message}"))
                }
                try {
                    mmSocket?.close()
                } catch (closeException: IOException) {
                }
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
                    // Protocol header: 8 bytes file length, 4 bytes filename length
                    val headerBuffer = ByteArray(12)
                    var headerBytesRead = 0
                    while (headerBytesRead < 12 && !isCancelled) {
                        val read = mmInStream.read(headerBuffer, headerBytesRead, 12 - headerBytesRead)
                        if (read == -1) throw IOException("Socket closed")
                        headerBytesRead += read
                    }
                    if (isCancelled) break

                    val dataInputStream = DataInputStream(ByteArrayInputStream(headerBuffer))
                    val fileLength = dataInputStream.readLong()
                    val nameLength = dataInputStream.readInt()

                    // Read filename
                    val nameBuffer = ByteArray(nameLength)
                    var nameBytesRead = 0
                    while (nameBytesRead < nameLength && !isCancelled) {
                        val read = mmInStream.read(nameBuffer, nameBytesRead, nameLength - nameBytesRead)
                        if (read == -1) throw IOException("Socket closed")
                        nameBytesRead += read
                    }
                    if (isCancelled) break

                    val filename = String(nameBuffer, Charsets.UTF_8)
                    runOnMain {
                        methodChannel?.invokeMethod("onTransferStarted", mapOf("filename" to filename, "isSending" to false))
                    }

                    // Setup saving file in Download directory
                    val downloadFolder = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "SwordFM")
                    if (!downloadFolder.exists()) {
                        downloadFolder.mkdirs()
                    }
                    val outputFile = File(downloadFolder, filename)
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
                }
            }
        }

        fun sendFile(file: File) {
            thread {
                try {
                    val fileLength = file.length()
                    val filenameBytes = file.name.toByteArray(Charsets.UTF_8)
                    val nameLength = filenameBytes.size

                    runOnMain {
                        methodChannel?.invokeMethod("onTransferStarted", mapOf("filename" to file.name, "isSending" to true))
                    }

                    // Write header (8 bytes file length + 4 bytes filename length)
                    val bos = ByteArrayOutputStream()
                    val dos = DataOutputStream(bos)
                    dos.writeLong(fileLength)
                    dos.writeInt(nameLength)
                    mmOutStream.write(bos.toByteArray())
                    mmOutStream.write(filenameBytes)
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
                            methodChannel?.invokeMethod("onTransferComplete", mapOf("savedPath" to file.absolutePath))
                        }
                    }
                } catch (e: Exception) {
                    runOnMain {
                        methodChannel?.invokeMethod("onTransferError", mapOf("message" to "Send failed: ${e.message}"))
                    }
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
