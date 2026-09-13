package com.swordfm.swordfm

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Storage Access Framework (SAF) bridge — the fallback file-access path when
 * the user denies "All files access" (MANAGE_EXTERNAL_STORAGE).
 *
 * Exposes a `com.swordfm/saf` MethodChannel with:
 *   - `openTree`                    → launches ACTION_OPEN_DOCUMENT_TREE, persists
 *                                     the grant, returns {uri, displayName}
 *   - `persistedTrees`              → URIs the app still holds grants for
 *   - `listChildren(treeUri, parentDocumentId?)`
 *                                     → [{documentId, name, mimeType, size,
 *                                         lastModified, isDir}]
 *   - `openDocument(treeUri, documentId)`
 *                                     → materialises the document into the app
 *                                     cache dir and returns the local path so
 *                                     the existing Dart viewers can open it
 *   - `releaseTree(treeUri)`        → drops a persisted grant
 *
 * SAF is read-oriented here by design: the fallback guarantees the user can
 * always *browse and open* files (the red audit finding), while writes stay
 * inside the app sandbox / share root where Dart already handles them.
 */
class SafBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val REQUEST_OPEN_TREE = 1002
        var pendingTreeResult: MethodChannel.Result? = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "openTree" -> openTree(result)
            "persistedTrees" -> result.success(persistedTrees())
            "listChildren" -> {
                val treeUri = call.argument<String>("treeUri") ?: ""
                val parentId = call.argument<String>("parentDocumentId")
                try {
                    result.success(listChildren(treeUri, parentId))
                } catch (e: Exception) {
                    result.error("SAF_LIST_FAILED", e.message, null)
                }
            }
            "openDocument" -> {
                val treeUri = call.argument<String>("treeUri") ?: ""
                val docId = call.argument<String>("documentId") ?: ""
                try {
                    val path = openDocument(treeUri, docId)
                    if (path != null) result.success(path)
                    else result.error("SAF_OPEN_FAILED", "Could not read document", null)
                } catch (e: Exception) {
                    result.error("SAF_OPEN_FAILED", e.message, null)
                }
            }
            "releaseTree" -> {
                val treeUri = call.argument<String>("treeUri") ?: ""
                result.success(releaseTree(treeUri))
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------
    // Tree picker
    // ------------------------------------------------------------------

    private fun openTree(result: MethodChannel.Result) {
        // One picker at a time — complete any stale pending result first so
        // Dart never awaits a callback that will never arrive.
        pendingTreeResult?.let {
            try { it.error("SAF_CANCELLED", "Superseded by a new picker", null) } catch (_: Exception) {}
            pendingTreeResult = null
        }
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
                )
            }
            pendingTreeResult = result
            activity.startActivityForResult(intent, REQUEST_OPEN_TREE)
        } catch (e: Exception) {
            pendingTreeResult = null
            result.error("SAF_NO_PICKER", e.message, null)
        }
    }

    /**
     * Called from MainActivity.onActivityResult. Returns true when the result
     * belonged to the tree picker (whether or not it was consumed).
     */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_OPEN_TREE) return false
        val pending = pendingTreeResult
        pendingTreeResult = null
        if (pending == null) return true
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pending.error("SAF_CANCELLED", "Folder pick cancelled", null)
            return true
        }
        val uri = data.data!!
        try {
            activity.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
            pending.success(mapOf(
                "uri" to uri.toString(),
                "displayName" to displayNameOfTree(uri),
            ))
        } catch (e: Exception) {
            pending.error("SAF_GRANT_FAILED", e.message, null)
        }
        return true
    }

    private fun displayNameOfTree(treeUri: Uri): String {
        return try {
            val docUri = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri),
            )
            var name: String? = null
            activity.contentResolver.query(
                docUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) name = c.getString(0)
            }
            name?.takeIf { it.isNotBlank() } ?: treeUri.lastPathSegment ?: "Shared folder"
        } catch (_: Exception) {
            treeUri.lastPathSegment ?: "Shared folder"
        }
    }

    // ------------------------------------------------------------------
    // Grants
    // ------------------------------------------------------------------

    private fun persistedTrees(): List<Map<String, Any?>> {
        return try {
            activity.contentResolver.persistedUriPermissions.mapNotNull { perm ->
                if (!perm.isReadPermission) return@mapNotNull null
                val uri = perm.uri
                mapOf<String, Any?>(
                    "uri" to uri.toString(),
                    "displayName" to displayNameOfTree(uri),
                )
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun releaseTree(treeUri: String): Boolean {
        return try {
            activity.contentResolver.releasePersistableUriPermission(
                Uri.parse(treeUri),
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    // ------------------------------------------------------------------
    // Listing
    // ------------------------------------------------------------------

    private fun listChildren(
        treeUriStr: String,
        parentDocumentId: String?,
    ): List<Map<String, Any?>> {
        val treeUri = Uri.parse(treeUriStr)
        val parentId = parentDocumentId
            ?: DocumentsContract.getTreeDocumentId(treeUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            parentId,
        )
        val out = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        // Sort by display name; directories-first is applied on the Dart side
        // so both browser surfaces share one ordering rule.
        val sortOrder = "${DocumentsContract.Document.COLUMN_DISPLAY_NAME} ASC"
        activity.contentResolver.query(
            childrenUri,
            projection,
            null, null,
            sortOrder,
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            val modIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            while (cursor.moveToNext()) {
                val mime = if (mimeIdx >= 0) cursor.getString(mimeIdx) else null
                out.add(mapOf(
                    "documentId" to (if (idIdx >= 0) cursor.getString(idIdx) else ""),
                    "name" to (if (nameIdx >= 0) cursor.getString(nameIdx) else "item"),
                    "mimeType" to mime,
                    "size" to (if (sizeIdx >= 0) cursor.getLong(sizeIdx) else 0L),
                    "lastModified" to (if (modIdx >= 0) cursor.getLong(modIdx) else 0L),
                    "isDir" to (mime == DocumentsContract.Document.MIME_TYPE_DIR),
                ))
            }
        }
        return out
    }

    // ------------------------------------------------------------------
    // Materialise for viewing
    // ------------------------------------------------------------------

    private fun openDocument(treeUriStr: String, documentId: String): String? {
        val treeUri = Uri.parse(treeUriStr)
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        var displayName: String? = null
        activity.contentResolver.query(
            docUri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null,
        )?.use { c ->
            if (c.moveToFirst()) displayName = c.getString(0)
        }
        // Basename-only: a hostile provider must not smuggle path separators
        // into our cache dir.
        val safeName = File(displayName ?: documentId.substringAfterLast('/').substringAfterLast(':'))
            .name.ifBlank { "saf_file" }
        val outFile = File(activity.cacheDir, "saf/$safeName")
        outFile.parentFile?.mkdirs()
        activity.contentResolver.openInputStream(docUri)?.use { input ->
            outFile.outputStream().use { output -> input.copyTo(output) }
        } ?: return null
        return if (outFile.exists() && outFile.length() > 0) outFile.absolutePath else null
    }
}
