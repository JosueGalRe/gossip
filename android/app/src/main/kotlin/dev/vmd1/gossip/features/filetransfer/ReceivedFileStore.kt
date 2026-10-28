package dev.vmd1.gossip.features.filetransfer

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.IOException

/** Downloads stay invisible until the complete copy is closed; failures remove the pending MediaStore row. */
class ReceivedFileStore(private val context: Context) {
    data class Saved(val uri: Uri, val name: String)

    fun save(partial: File, name: String, mime: String): Saved {
        val resolver = context.contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val names = mutableSetOf<String>()
        resolver.query(collection, arrayOf(MediaStore.Downloads.DISPLAY_NAME),
            "${MediaStore.Downloads.RELATIVE_PATH} = ?", arrayOf(PATH), null)?.use { cursor ->
            while (cursor.moveToNext()) names.add(cursor.getString(0))
        }
        val chosen = FileTransferPolicy.uniqueName(name, names)
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, chosen)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, PATH)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values) ?: throw IOException("Cannot create download")
        try {
            val output = resolver.openOutputStream(uri) ?: throw IOException("Cannot open download")
            output.use { out -> partial.inputStream().use { it.copyTo(out) } }
            val published = resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
            if (published != 1) throw IOException("Cannot publish download")
            return Saved(uri, chosen)
        } catch (e: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw e
        }
    }

    private companion object { val PATH = "${Environment.DIRECTORY_DOWNLOADS}/Gossip/" }
}
