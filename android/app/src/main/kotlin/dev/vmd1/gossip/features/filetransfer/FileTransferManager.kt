package dev.vmd1.gossip.features.filetransfer

import android.content.Context
import android.net.Uri
import android.os.SystemClock
import android.provider.OpenableColumns
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.TransportManager
import dev.vmd1.gossip.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Direct-only file transfer, owned by the foreground service rather than the share activity. Receives are serialized
 * off the main thread so a raw frame can never overtake its offer or another append. Sends stream one file at a time
 * and keep only one chunk in app memory; a receiver's accepted offset repairs a lost connection without a second copy.
 */
class FileTransferManager(
    private val context: Context,
    private val transport: TransportManager,
    private val trustedDevices: TrustedDevicesStore,
    private val scope: CoroutineScope
) {
    private data class Key(val peer: String, val id: String)
    private data class Incoming(val name: String, val mime: String, val file: File, val state: FileReceiveState)
    private data class Delivery(val envelope: Envelope, val raw: ByteArray? = null)
    private data class Batch(val peer: String, val uris: List<Uri>)
    private data class Source(val name: String, val mime: String, val size: Long)
    private class TransferFailure(val reason: String, message: String = reason) : IOException(message)

    private val selfId = transport.identityKeyStore.deviceId
    private val directory = File(context.cacheDir, "incoming")
    private val notifications = FileTransferNotifications(context)
    private val downloads = ReceivedFileStore(context)
    private val incoming = mutableMapOf<Key, Incoming>()
    private val completed = LinkedHashMap<Key, Long>()
    // Dropping a congested slice is safe: the contiguous ack stops at the gap, then the sender re-offers to resume.
    private val deliveries = Channel<Delivery>(16)
    private val batches = Channel<Batch>(Channel.UNLIMITED)
    private val outgoing = ConcurrentHashMap<Key, Channel<Envelope>>()
    private val handler = EnvelopeHandler { envelope ->
        if (envelope.type != MessageType.FILE_CHUNK) deliveries.trySend(Delivery(envelope))
    }
    private val rawHandler: (Envelope, ByteArray) -> Unit = { envelope, raw ->
        if (envelope.type == MessageType.FILE_CHUNK) deliveries.trySend(Delivery(envelope, raw))
    }

    init {
        transport.messageRouter.register("file.", handler)
        transport.addOnRawFrameReceived(rawHandler)
        scope.launch(Dispatchers.IO) {
            prunePartials()
            while (isActive) {
                val delivery = withTimeoutOrNull(60_000) { deliveries.receive() }
                if (delivery != null) receive(delivery)
                prunePartials()
            }
        }
        scope.launch(Dispatchers.IO) {
            for (batch in batches) for (uri in batch.uris) sendFile(batch.peer, uri)
        }
    }

    fun enqueue(peer: String, uris: List<Uri>) { batches.trySend(Batch(peer, uris)) }

    fun cancel(id: String) {
        for ((key, signals) in outgoing) if (key.id == id) signals.trySend(
            Envelope(type = MessageType.FILE_CANCEL, senderId = selfId, payload = buildJsonObject { put("reason", "cancelled") })
        )
    }

    fun stop() {
        transport.messageRouter.unregister(handler)
        transport.removeOnRawFrameReceived(rawHandler)
        batches.close()
    }

    private fun isDirectTrusted(peer: String): Boolean = trustedDevices.isTrusted(peer) &&
        !trustedDevices.isProvisional(peer) && transport.connectionPath(peer) == TransportManager.ConnectionPath.DIRECT

    private suspend fun receive(delivery: Delivery) {
        val envelope = delivery.envelope
        if (envelope.recipientId != selfId || envelope.broadcast || envelope.ttl != 0 || !isDirectTrusted(envelope.senderId)) return
        val id = envelope.payload.string("transferId") ?: return
        if (runCatching { UUID.fromString(id).toString().equals(id, ignoreCase = true) }.getOrDefault(false).not()) return
        val key = Key(envelope.senderId, id)
        when (envelope.type) {
            MessageType.FILE_OFFER -> offer(key, envelope.payload)
            MessageType.FILE_CHUNK -> chunk(key, envelope.payload, delivery.raw ?: return)
            MessageType.FILE_ACCEPT, MessageType.FILE_ACK -> outgoing[key]?.trySend(envelope)
            MessageType.FILE_CANCEL -> {
                incoming.remove(key)?.file?.delete()
                outgoing[key]?.trySend(envelope)
            }
        }
    }

    private suspend fun offer(key: Key, payload: JsonObject) {
        completed[key]?.let { ack(key, it, true); return }
        incoming[key]?.let {
            if (it.file.isFile && it.file.length() == it.state.received) {
                ackOrAccept(key, it)
                return
            }
            incoming.remove(key)?.file?.delete()
        }
        val size = payload.number("size") ?: return
        val name = payload.string("name") ?: return
        if (size !in 0..FileTransferPolicy.MAX_SIZE) { sendCancel(key, "too_large"); return }
        try {
            if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Cannot create incoming directory")
            if (directory.usableSpace < size) throw IOException("Not enough storage")
            val owner = UUID.nameUUIDFromBytes(key.peer.toByteArray()).toString()
            val file = File(directory, "$owner-${key.id}.part")
            // shortcut: resume metadata is in memory; persist it if transfers must survive a service restart.
            file.outputStream().close()
            val transfer = Incoming(FileTransferPolicy.sanitizeName(name),
                payload.string("mime")?.takeIf { it.length <= 255 && it.contains('/') } ?: "application/octet-stream",
                file, FileReceiveState(size))
            incoming[key] = transfer
            ackOrAccept(key, transfer)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            incoming.remove(key)?.file?.delete()
            sendCancel(key, "storage")
        }
    }

    private suspend fun ackOrAccept(key: Key, transfer: Incoming) {
        if (transfer.state.complete) finishIncoming(key, transfer)
        else send(key, MessageType.FILE_ACCEPT, buildJsonObject { put("offset", transfer.state.received) })
    }

    private suspend fun chunk(key: Key, payload: JsonObject, bytes: ByteArray) {
        completed[key]?.let { ack(key, it, true); return }
        val transfer = incoming[key] ?: run { sendCancel(key, "unknown"); return }
        val offset = payload.number("offset") ?: return
        try {
            if (!transfer.file.isFile || transfer.file.length() != transfer.state.received) throw IOException("Partial file was evicted")
            when (transfer.state.chunk(offset, bytes.size)) {
                FileReceiveState.Chunk.WRITE -> {
                    transfer.file.appendBytes(bytes)
                    transfer.state.appended(bytes.size)
                }
                FileReceiveState.Chunk.IGNORE -> Unit
                FileReceiveState.Chunk.INVALID -> throw IOException("Invalid chunk length")
            }
            if (transfer.state.complete) finishIncoming(key, transfer)
            else ack(key, transfer.state.received)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            incoming.remove(key)?.file?.delete()
            sendCancel(key, "storage")
        }
    }

    private suspend fun finishIncoming(key: Key, transfer: Incoming) {
        if (transfer.file.length() != transfer.state.size) throw IOException("Incomplete partial file")
        val saved = downloads.save(transfer.file, transfer.name, transfer.mime)
        incoming.remove(key)
        completed[key] = transfer.state.size
        while (completed.size > 64) completed.remove(completed.keys.first())
        transfer.file.delete()
        notifications.received(key.id, saved.name, peerName(key.peer), saved.uri, transfer.mime)
        ack(key, transfer.state.size, true)
    }

    private fun prunePartials() {
        val cutoff = System.currentTimeMillis() - FileTransferPolicy.PARTIAL_TTL_MS
        incoming.entries.removeAll { (_, transfer) ->
            (transfer.file.lastModified() < cutoff).also { if (it) transfer.file.delete() }
        }
        directory.listFiles()?.filter { it.isFile && it.name.endsWith(".part") && it.lastModified() < cutoff }
            ?.forEach { it.delete() }
    }

    private suspend fun ack(key: Key, received: Long, complete: Boolean = false) = send(key, MessageType.FILE_ACK,
        buildJsonObject { put("received", received); if (complete) put("complete", true) })

    private suspend fun sendCancel(key: Key, reason: String) = send(key, MessageType.FILE_CANCEL,
        buildJsonObject { put("reason", reason) })

    /** The send check applies to every control message too, not just the initial offer. */
    private suspend fun send(key: Key, type: String, payload: JsonObject, raw: ByteArray? = null): Boolean {
        if (!isDirectTrusted(key.peer)) return false
        return try {
            val envelope = Envelope(type = type, senderId = selfId, recipientId = key.peer, ttl = 0,
                hasRawFollowup = raw != null,
                payload = JsonObject(payload + ("transferId" to JsonPrimitive(key.id))))
            if (raw == null) transport.send(envelope) else transport.send(envelope, raw)
            true
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            Log.w("FileTransfer", "Could not send $type: ${e.message}")
            false
        }
    }

    private suspend fun sendFile(peer: String, uri: Uri) {
        val key = Key(peer, UUID.randomUUID().toString())
        var name = "file"
        var input: InputStream? = null
        val signals = Channel<Envelope>(16)
        try {
            val source = source(uri)
            name = source.name
            if (source.size < 0) throw IOException("Shared file size is unavailable")
            if (source.size > FileTransferPolicy.MAX_SIZE) throw TransferFailure("too_large", "Files must be at most 4 GiB")
            if (!isDirectTrusted(peer)) throw TransferFailure("unknown", "Your Mac must be connected on the same network")
            outgoing[key] = signals
            val window = FileSendWindow(source.size, SystemClock.elapsedRealtime())
            suspend fun sendOffer() {
                window.offered(SystemClock.elapsedRealtime())
                send(key, MessageType.FILE_OFFER, buildJsonObject {
                    put("name", name); put("size", source.size); put("mime", source.mime)
                })
            }
            notifications.sending(key.id, name, peerName(peer), 0)
            sendOffer()
            var streamPosition = -1L
            var shownProgress = 0
            while (!window.complete) {
                currentCoroutineContext().ensureActive()
                val now = SystemClock.elapsedRealtime()
                if (window.timedOut(now)) throw TransferFailure("timeout")
                if (window.shouldOffer(now)) sendOffer()
                val signal = signals.tryReceive().getOrNull() ?: if (window.nextChunkSize() == 0 || !isDirectTrusted(peer))
                    withTimeoutOrNull(250) { signals.receive() } else null
                if (signal != null) {
                    when (signal.type) {
                        MessageType.FILE_CANCEL -> throw TransferFailure(signal.payload.string("reason") ?: "cancelled")
                        MessageType.FILE_ACCEPT -> signal.payload.number("offset")?.let { window.accept(it, now) }
                        MessageType.FILE_ACK -> signal.payload.number("received")?.let {
                            window.acknowledge(it, (signal.payload["complete"] as? JsonPrimitive)?.booleanOrNull == true, now)
                        }
                    }
                    val progress = if (source.size == 0L) 0 else (window.received * 100 / source.size).toInt()
                    if (progress != shownProgress && !window.complete) {
                        notifications.sending(key.id, name, peerName(peer), progress)
                        shownProgress = progress
                    }
                    continue
                }
                val count = window.nextChunkSize()
                if (count == 0 || !isDirectTrusted(peer)) continue
                if (streamPosition != window.position) {
                    input?.close()
                    input = context.contentResolver.openInputStream(uri) ?: throw IOException("Cannot read shared file")
                    skipTo(input, window.position)
                    streamPosition = window.position
                }
                val bytes = ByteArray(count)
                var read = 0
                while (read < count) {
                    currentCoroutineContext().ensureActive()
                    val n = input!!.read(bytes, read, count - read)
                    if (n <= 0) throw IOException("Shared file ended before its advertised size")
                    read += n
                }
                streamPosition += count
                if (send(key, MessageType.FILE_CHUNK, buildJsonObject { put("offset", window.position) }, bytes)) window.sent(count)
                else window.pause()
            }
            notifications.sent(key.id, name, peerName(peer))
        } catch (e: Exception) {
            if (e is CancellationException) {
                notifications.failed(key.id, name, "Gossip stopped")
                throw e
            }
            val reason = (e as? TransferFailure)?.reason ?: "storage"
            sendCancel(key, reason)
            notifications.failed(key.id, name, e.message ?: reason)
        } finally {
            outgoing.remove(key)
            signals.close()
            runCatching { input?.close() }
        }
    }

    private fun source(uri: Uri): Source {
        if (uri.scheme != "content") throw IOException("Only content Uris can be shared")
        var name = "file"
        var size = -1L
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameColumn >= 0 && !cursor.isNull(nameColumn)) name = cursor.getString(nameColumn)
                if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn)
            }
        }
        if (size < 0) size = context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1
        if (size < 0) size = context.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1
        return Source(FileTransferPolicy.sanitizeName(name), context.contentResolver.getType(uri) ?: "application/octet-stream", size)
    }

    private suspend fun skipTo(input: InputStream, offset: Long) {
        var remaining = offset
        val discard = ByteArray(8192)
        while (remaining > 0) {
            currentCoroutineContext().ensureActive()
            val skipped = input.skip(remaining)
            val consumed = if (skipped > 0) skipped else input.read(discard, 0, minOf(remaining, discard.size.toLong()).toInt()).toLong()
            if (consumed <= 0) throw IOException("Cannot resume shared file")
            remaining -= consumed
        }
    }

    private fun peerName(peer: String): String = trustedDevices.getDevice(peer)?.deviceName ?: "Paired device"
}

private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
private fun JsonObject.number(key: String): Long? = (this[key] as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull
