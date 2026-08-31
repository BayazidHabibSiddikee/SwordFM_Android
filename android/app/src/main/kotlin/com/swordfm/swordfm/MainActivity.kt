package com.swordfm.swordfm

// ============================================================================
// SHARED BLUETOOTH FRAME PROTOCOL (see lib/services/bluetooth_share_service.dart)
// Frame:
//   [ 4-byte uint32 metadataLength ]  (big-endian)
//   [ metadataLength bytes of JSON  ]  { "filename": "example.pdf", "size": 12345, "checksum": "<sha256 hex>" }
//   [ raw file bytes of length `size` ]]
// Reference impl: /home/sword/SwordFM/tools/swordblue
// Sender MUST include "checksum"; receiver verifies and deletes on mismatch.
// ============================================================================

import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.Settings
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.storage.StorageManager
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.*
import java.util.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import org.json.JSONObject
import java.security.MessageDigest

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
 * │   { "filename": "example.pdf", "size": 12345,                 │
 * │     "checksum": "<64-hex SHA-256 of file contents>" }         │
 * │                                                               │
 * │ The sender writes metadata then streams the raw bytes; the    │
 * │ receiver reads the 4-byte length, parses JSON, then reads     │
 * │ exactly "size" raw bytes, hashes them, and verifies against   │
 * │ "checksum" (deleting the file on mismatch). Do NOT change     │
 * │ this without also updating the Dart side and                  │
 * │ /home/sword/SwordFM/tools/swordblue                           │
 * └───────────────────────────────────────────────────────────────┘
 */

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler {
    companion object {
        private const val REQUEST_PICK_FILE = 1001
        private var lastResultPaths: List<String>? = null
        private const val CONNECT_TIMEOUT_MS = 30000L
        private const val MAX_CONNECT_RETRIES = 1
        private const val NAME = "SwordFM_Bluetooth"

        fun computeFileSha256(path: String): String? {
            return try {
                val file = java.io.File(path)
                if (!file.exists()) return null
                val bytes = file.readBytes()
                val digest = MessageDigest.getInstance("SHA-256")
                digest.update(bytes)
                digest.digest().joinToString("") { "%02x".format(it) }
            } catch (e: Exception) {
                null
            }
        }
    }

    private var pendingInstallResult: MethodChannel.Result? = null

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_PICK_FILE && resultCode == RESULT_OK && data != null) {
            val paths = mutableListOf<String>()
            // Handle multi-select
            val clipData = data.clipData
            if (clipData != null) {
                for (i in 0 until clipData.itemCount) {
                    val uri = clipData.getItemAt(i).uri
                    paths.add(uri.path ?: "")
                }
            } else {
                val uri = data.data
                if (uri != null) paths.add(uri.path ?: "")
            }
            if (paths.isNotEmpty()) {
                lastResultPaths = paths
                methodChannel?.invokeMethod("onFilePicked", mapOf("paths" to paths))
            }
        }
    }
    private val CHANNEL = "com.swordfm/bluetooth"
    private var methodChannel: MethodChannel? = null

    private val bluetoothAdapter: BluetoothAdapter? by lazy {
        BluetoothAdapter.getDefaultAdapter()
    }

    private val MY_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

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
            // "Open With…" app chooser + "Open Terminal Here" (Termux) live on
            // their own channels so the bluetooth channel stays focused.
            MethodChannel(it.dartExecutor.binaryMessenger, "com.swordfm/openwith")
                .setMethodCallHandler(this)
            MethodChannel(it.dartExecutor.binaryMessenger, "com.swordfm/terminal")
                .setMethodCallHandler(this)
            MethodChannel(it.dartExecutor.binaryMessenger, "com.swordfm/share")
                .setMethodCallHandler(this)
            // Storage volumes + "All files access" permission live here.
            MethodChannel(it.dartExecutor.binaryMessenger, "com.swordfm/devices")
                .setMethodCallHandler(this)
            // APK / XAPK installation via PackageInstaller.
            MethodChannel(it.dartExecutor.binaryMessenger, "com.swordfm/installer")
                .setMethodCallHandler(this)
            // Cloud storage OAuth redirect delivery + swordfm:// deep links.
            MethodChannel(it.dartExecutor.binaryMessenger, "com.swordfm/cloud")
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getCloudCallbackScheme" -> result.success("storagesfm://dropbox-callback")
                        else -> result.notImplemented()
                    }
                    true
                }
            // Cast stub — returns empty list until Cast SDK is integrated.
            MethodChannel(it.dartExecutor.binaryMessenger, "com.swordfm/cast")
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "discoverDevices" -> result.success(emptyList<Map<String, Any>>())
                        "connect" -> result.success(false)
                        "disconnect" -> result.success(true)
                        "castUrl" -> result.success(false)
                        else -> result.notImplemented()
                    }
                    true
                }
        }

        // Cold start via a deep link (swordfm://...). The Flutter engine may not
        // be ready to accept an invokeMethod instantly, so deliver it once the
        // first frame is up.
        intent.data?.let { uri ->
            if (uri.scheme == "swordfm" && uri.host == "open") {
                val path = uri.getQueryParameter("path")
                if (path != null) {
                    flutterEngine?.let { engine ->
                        engine.dartExecutor.binaryMessenger.let { messenger ->
                            MethodChannel(messenger, "com.swordfm/deeplink").invokeMethod(
                                "onOpenPath",
                                mapOf("uri" to uri.toString(), "path" to path)
                            )
                        }
                    }
                }
            }
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
                try {
                    // Android 12+ requires BLUETOOTH_CONNECT before touching
                    // bondedDevices or device.name — calling without it throws
                    // SecurityException and crashes the app (fixed: guarded).
                    val canAccess = bluetoothAdapter != null && bluetoothAdapter!!.isEnabled && (
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                            androidx.core.content.ContextCompat.checkSelfPermission(
                                activity, android.Manifest.permission.BLUETOOTH_CONNECT
                            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
                        )
                    if (canAccess) {
                        val pairedDevices: Set<BluetoothDevice>? = bluetoothAdapter!!.bondedDevices
                        pairedDevices?.forEach { device ->
                            val name = try { device.name } catch (_: SecurityException) { device.address }
                            devicesList.add(mapOf("name" to (name ?: device.address), "address" to device.address))
                        }
                    }
                } catch (e: SecurityException) {
                    // Missing runtime permission — return an empty list instead
                    // of crashing; the Dart side surfaces the permission flow.
                } catch (e: Exception) {
                    // Ignore adapter errors.
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
            "pickFile" -> {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                }
                activity.startActivityForResult(intent, 1001)
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
            "computeSha256" -> {
                val path = call.argument<String>("path") ?: ""
                val hash = computeFileSha256(path)
                result.success(hash)
            }
            "openWithApp" -> {
                val path = call.argument<String>("path") ?: ""
                try {
                    result.success(openFileWithChooser(path))
                } catch (e: Exception) {
                    result.error("OPEN_FAILED", e.message, null)
                }
            }
            "openWithChooser" -> {
                val path = call.argument<String>("path") ?: ""
                try {
                    result.success(openFileWithChooser(path))
                } catch (e: Exception) {
                    result.error("OPEN_FAILED", e.message, null)
                }
            }
            "openTerminalAt" -> {
                val path = call.argument<String>("path") ?: ""
                try {
                    openTerminalAt(path)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("TERMUX_FAILED", e.message, null)
                }
            }
            "shareFiles" -> {
                @Suppress("UNCHECKED_CAST")
                val paths = call.argument<List<String>>("paths") ?: emptyList()
                try {
                    result.success(shareFiles(paths))
                } catch (e: Exception) {
                    result.error("SHARE_FAILED", e.message, null)
                }
            }
            "getStorageVolumes" -> {
                val volumes = mutableListOf<Map<String, Any?>>()
                val sm = getSystemService(STORAGE_SERVICE) as? StorageManager
                sm?.storageVolumes?.forEach { vol ->
                    val path = vol.directory?.absolutePath
                    if (!path.isNullOrEmpty()) {
                        volumes.add(mapOf(
                            "path" to path,
                            "label" to vol.getDescription(this),
                            "removable" to vol.isRemovable,
                        ))
                    }
                }
                // Always include the primary emulated volume
                if (volumes.isEmpty()) {
                    val dir = Environment.getExternalStorageDirectory()
                    if (dir.exists()) {
                        volumes.add(mapOf("path" to dir.absolutePath, "label" to "Internal storage", "removable" to false))
                    }
                }
                result.success(volumes)
            }
            "allFilesAccessGranted" -> {
                result.success(allFilesAccessGranted())
            }
            "requestAllFilesAccess" -> {
                result.success(requestAllFilesAccess())
            }
            "shareFile" -> {
                val path = call.argument<String>("path") ?: ""
                try {
                    val file = File(path)
                    if (!file.exists()) {
                        result.error("FILE_NOT_FOUND", "File not found: $path", null)
                        return
                    }
                    val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                    val shareIntent = Intent(Intent.ACTION_SEND).apply {
                        type = contentResolver.getType(uri) ?: "*/*"
                        putExtra(Intent.EXTRA_STREAM, uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(Intent.createChooser(shareIntent, "Share via"))
                    result.success(true)
                } catch (e: Exception) {
                    result.error("SHARE_FAILED", e.message, null)
                }
            }
            "installApk" -> {
                val path = call.argument<String>("path") ?: ""
                pendingInstallResult = result
                installApks(listOf(path))
                // result will be completed by InstallReceiver
            }
            "installApks" -> {
                @Suppress("UNCHECKED_CAST")
                val paths = call.argument<List<String>>("paths") ?: emptyList()
                pendingInstallResult = result
                installApks(paths)
                // result will be completed by InstallReceiver
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    /**
     * Handles deep-link / OAuth redirect intents.
     * When Dropbox redirects to storagesfm://dropbox-callback we forward the URI
     * to Dart so CloudBrowserScreen can complete the token exchange.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val uri = intent.data ?: return
        if (uri.scheme == "storagesfm" && (uri.host == "dropbox-callback" || uri.host == "opendrive-callback")) {
            // Use the dedicated cloud channel so MainActivity keeps its
            // existing bluetooth-channel focus for file-picker calls.
            MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, "com.swordfm/cloud")
                .invokeMethod("onOAuthRedirect", mapOf("uri" to uri.toString()))
        } else if (uri.scheme == "swordfm") {
            // "Show QR Code" deep link — swordfm://open?path=<encoded>
            // Forward to Dart so MainScreen can navigate to the shared file/folder.
            val path = uri.getQueryParameter("path") ?: return
            MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, "com.swordfm/deeplink")
                .invokeMethod("onOpenPath", mapOf("uri" to uri.toString(), "path" to path))
        }
    }

    /** True when this app may create PackageInstaller sessions (API 26+). */
    private fun installPermissionGranted(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    /**
     * Installs [paths] (a single APK, or base + split APKs for XAPK) via
     * PackageInstaller, streaming each file. A single APK without install
     * permission falls back to the system installer UI (ACTION_VIEW).
     */
    private fun installApks(paths: List<String>): Boolean {
        val files = paths.filter { File(it).exists() }
        if (files.isEmpty()) return false
        if (files.size == 1 && !installPermissionGranted()) {
            return try {
                openFileWithChooser(files.first())
            } catch (_: Exception) {
                false
            }
        }
        return try {
            val packageInstaller = packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            )
            val sessionId = packageInstaller.createSession(params)
            val session = packageInstaller.openSession(sessionId)
            for (path in files) {
                val file = File(path)
                val pfd = ParcelFileDescriptor.open(
                    file,
                    ParcelFileDescriptor.MODE_READ_ONLY
                )
                val stream = session.openWrite(file.name, 0, file.length())
                FileInputStream(file).use { input ->
                    val buffer = ByteArray(65536)
                    var n: Int
                    while (input.read(buffer).also { n = it } != -1) {
                        stream.write(buffer, 0, n)
                    }
                }
                session.fsync(stream)
                stream.close()
                pfd.close()
            }
            // Store pending result so InstallReceiver can complete it
            val pendingResult = pendingInstallResult
            if (pendingResult != null) {
                InstallReceiver.pendingResult = pendingResult
                pendingInstallResult = null
            }
            val pi = PendingIntent.getBroadcast(
                this,
                sessionId,
                Intent(this, InstallReceiver::class.java)
                    .putExtra("sessionId", sessionId),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            session.commit(pi.intentSender)
            session.close()
            true
        } catch (_: Exception) {
            try {
                if (files.size == 1) openFileWithChooser(files.first())
                false
            } catch (_: Exception) {
                false
            }
        }
    }

    /**
     * Opens [path] through Android's "Open with" app chooser.
     * Returns true when the chooser was launched. Paths that are already
     * content:// URIs (SAF / file_picker) are passed through directly.
     */
    private fun openFileWithChooser(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) return false
        val uri: Uri = if (path.startsWith("content://")) {
            Uri.parse(path)
        } else {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        }
        val ext = file.extension
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
        val viewIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(viewIntent, "Open with")
        chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(chooser)
        return true
    }

    /** Shares [paths] through Android's share sheet (ACTION_SEND_MULTIPLE). */
    private fun shareFiles(paths: List<String>): Boolean {
        val uris = paths.mapNotNull { path ->
            Uri.parse(path).takeIf { it.scheme == "content" }
                ?: File(path).takeIf { it.exists() }?.let {
                    FileProvider.getUriForFile(this, "$packageName.fileprovider", it)
                }
        }
        if (uris.isEmpty()) return false
        val firstMime = paths.firstOrNull()?.let {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(File(it).extension)
        } ?: "*/*"
        val sendIntent = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            type = firstMime
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
        }
        if (uris.size == 1) {
            sendIntent.action = Intent.ACTION_SEND
            sendIntent.putExtra(Intent.EXTRA_STREAM, uris.first())
        }
        val chooser = Intent.createChooser(sendIntent, "Share via")
        chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(chooser)
        return true
    }

    /** Opens a Termux session running bash at [path] via the RUN_COMMAND intent. */
    private fun openTerminalAt(path: String) {
        val intent = Intent("com.termux.RUN_COMMAND").apply {
            setClassName("com.termux", "com.termux.app.RunCommandService")
            putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash")
            putExtra("com.termux.RUN_COMMAND_WORKDIR", path)
            putExtra("com.termux.RUN_COMMAND_BACKGROUND", false)
            putExtra("com.termux.RUN_COMMAND_SESSION_ACTION", 0) // 0 = new session
        }
        startService(intent)
    }

    /** True when the app has "All files access" (MANAGE_EXTERNAL_STORAGE). */
    private fun allFilesAccessGranted(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            // Pre-Android 11 the legacy permission flows through the normal
            // runtime permission; treat app as granted once we're passed here.
            true
        }
    }

    /** Opens the system "All files access" settings screen. Returns true when
     *  the intent could be launched. */
    private fun requestAllFilesAccess(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
                true
            } else {
                true
            }
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                true
            } catch (_: Exception) {
                false
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
                    // Optional SHA-256 checksum (see frame-format comment at top).
                    // Absent with legacy peers → verification is skipped, file still accepted.
                    val expectedChecksum = if (metaJson.has("checksum")) metaJson.getString("checksum").lowercase() else null

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
                        val newFilename = if (ext.isEmpty()) "$filename ($collisionCounter)" else "$baseName ($collisionCounter).$ext"
                        outputFile = File(downloadFolder, newFilename)
                        collisionCounter++
                    }
                    val fileOutputStream = FileOutputStream(outputFile)

                    var totalBytesReceived = 0L
                    var lastUpdate = System.currentTimeMillis()
                    // Compute SHA-256 while writing so we never re-read the whole file.
                    val digest = MessageDigest.getInstance("SHA-256")

                    while (totalBytesReceived < fileLength && !isCancelled) {
                        val toRead = Math.min(buffer.size.toLong(), fileLength - totalBytesReceived).toInt()
                        bytes = mmInStream.read(buffer, 0, toRead)
                        if (bytes == -1) throw IOException("Stream cut off prematurely")
                        fileOutputStream.write(buffer, 0, bytes)
                        digest.update(buffer, 0, bytes)
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
                        val sha256 = digest.digest().joinToString("") { "%02x".format(it) }
                        val verified = expectedChecksum != null && sha256 == expectedChecksum
                        if (expectedChecksum != null && !verified) {
                            // Corrupt transfer — delete and notify, matching swordblue.
                            outputFile.delete()
                            runOnMain {
                                methodChannel?.invokeMethod("onTransferError", mapOf(
                                    "message" to "Checksum mismatch for $filename — file deleted"
                                ))
                                methodChannel?.invokeMethod("onDisconnected", null)
                            }
                            break
                        }
                        runOnMain {
                            methodChannel?.invokeMethod("onTransferComplete", mapOf(
                                "savedPath" to outputFile.absolutePath,
                                "sha256" to sha256,
                                "verified" to verified
                            ))
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

                    // SHA-256 of the file, computed by streaming once (pass 1).
                    // We then rewind the same stream and send (pass 2), so there is
                    // no TOCTOU window and no whole-file readBytes() in memory.
                    val fileInputStream = FileInputStream(file)
                    val fileChannel = fileInputStream.channel
                    val buffer = ByteArray(65536)
                    val digest = MessageDigest.getInstance("SHA-256")
                    var bytesRead: Int
                    while (fileInputStream.read(buffer).also { bytesRead = it } != -1) {
                        digest.update(buffer, 0, bytesRead)
                    }
                    fileChannel.position(0)

                    // Write the JSON metadata frame (see frame-format comment at top).
                    val sha256 = digest.digest().joinToString("") { "%02x".format(it) }
                    val metadata = JSONObject()
                        .put("filename", file.name)
                        .put("size", fileLength)
                        .put("checksum", sha256)
                    val metadataBytes = metadata.toString().toByteArray(Charsets.UTF_8)

                    // 4-byte big-endian metadata length
                    val lenBos = ByteArrayOutputStream()
                    DataOutputStream(lenBos).use { it.writeInt(metadataBytes.size) }
                    mmOutStream.write(lenBos.toByteArray())
                    mmOutStream.write(metadataBytes)
                    mmOutStream.flush()

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
                            methodChannel?.invokeMethod("onTransferComplete", mapOf(
                                "savedPath" to "",
                                "sha256" to sha256,
                                "verified" to true
                            ))
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

/** Receives the PackageInstaller session result broadcast and surfaces it. */
class InstallReceiver : BroadcastReceiver() {
    companion object {
        var pendingResult: MethodChannel.Result? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)
        val message = when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirm != null) {
                    context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                return
            }
            PackageInstaller.STATUS_SUCCESS -> "App installed"
            PackageInstaller.STATUS_FAILURE_ABORTED -> "Install aborted"
            PackageInstaller.STATUS_FAILURE_BLOCKED -> "Install blocked by policy"
            PackageInstaller.STATUS_FAILURE_CONFLICT -> "Conflict with existing package"
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "Incompatible with this device"
            PackageInstaller.STATUS_FAILURE_INVALID -> "Invalid APK"
            PackageInstaller.STATUS_FAILURE_STORAGE -> "Storage error"
            else -> "Install failed ($status)"
        }

        // Send result back to Dart if a pending result exists
        val result = pendingResult
        if (result != null) {
            pendingResult = null
            if (status == PackageInstaller.STATUS_SUCCESS) {
                result.success(true)
            } else {
                result.success(false)
            }
        }

        Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
    }
}
