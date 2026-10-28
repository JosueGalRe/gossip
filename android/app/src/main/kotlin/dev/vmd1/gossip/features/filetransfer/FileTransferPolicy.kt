package dev.vmd1.gossip.features.filetransfer

/** Wire limits and disk names are kept independent of Android so both boundaries can be tested. */
object FileTransferPolicy {
    const val MAX_SIZE = 4L * 1024 * 1024 * 1024
    const val CHUNK_SIZE = 1024 * 1024
    const val WINDOW_SIZE = 4L * CHUNK_SIZE
    const val RETRY_MS = 10_000L
    const val TIMEOUT_MS = 60_000L
    const val PARTIAL_TTL_MS = 10 * 60_000L

    fun sanitizeName(name: String): String {
        val result = StringBuilder()
        val points = name.codePoints().iterator()
        var count = 0
        while (points.hasNext() && count < 200) {
            val point = points.nextInt()
            if (point == '/'.code || point == '\\'.code || Character.isISOControl(point)) continue
            if (point == '.'.code && result.isEmpty()) continue
            result.appendCodePoint(point)
            count++
        }
        return result.toString().ifEmpty { "file" }
    }

    fun uniqueName(name: String, existing: Set<String>): String {
        val dot = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
        var candidate = name
        var suffix = 2
        while (candidate in existing) {
            candidate = "${name.take(dot)} (${suffix++})${name.substring(dot)}"
        }
        return candidate
    }
}

/** A receiver never seeks: only the next contiguous slice can change the acknowledged offset. */
class FileReceiveState(val size: Long) {
    var received = 0L
        private set
    val complete: Boolean get() = received == size

    init { require(size in 0..FileTransferPolicy.MAX_SIZE) }

    enum class Chunk { WRITE, IGNORE, INVALID }

    fun chunk(offset: Long, length: Int): Chunk = when {
        length !in 1..FileTransferPolicy.CHUNK_SIZE -> Chunk.INVALID
        offset != received -> Chunk.IGNORE
        length > size - received -> Chunk.INVALID
        else -> Chunk.WRITE
    }

    /** Called only after the append succeeds; a failed write must never be acknowledged. */
    fun appended(length: Int) {
        require(chunk(received, length) == Chunk.WRITE)
        received += length
    }
}

/** Sender offsets, bounded window and retry clocks; an accept is authoritative after reconnecting. */
class FileSendWindow(val size: Long, now: Long) {
    var received = 0L
        private set
    var position = 0L
        private set
    var complete = false
        private set
    private var accepted = false
    private var lastAcceptedOffset: Long? = null
    private var lastProgress = now
    private var lastResponse = now
    private var lastOffer = now

    init { require(size in 0..FileTransferPolicy.MAX_SIZE) }

    fun offered(now: Long) { accepted = false; lastOffer = now }
    fun pause() { accepted = false }

    fun accept(offset: Long, now: Long): Boolean {
        if (offset !in 0..size) return false
        if (accepted && offset == lastAcceptedOffset) return true
        if (offset > received) lastProgress = now
        received = offset
        position = offset
        accepted = true
        lastAcceptedOffset = offset
        lastResponse = now
        return true
    }

    fun acknowledge(offset: Long, saved: Boolean, now: Long): Boolean {
        if (offset !in received..size || (offset > position && !(saved && offset == size))) return false
        if (offset > received) lastProgress = now
        received = offset
        lastResponse = now
        complete = complete || (saved && offset == size)
        return true
    }

    fun nextChunkSize(): Int = if (!accepted || complete) 0 else
        minOf(FileTransferPolicy.CHUNK_SIZE.toLong(), size - position,
            FileTransferPolicy.WINDOW_SIZE - (position - received)).toInt()

    fun sent(length: Int) {
        require(length in 1..nextChunkSize())
        position += length
    }

    fun shouldOffer(now: Long): Boolean = now - lastResponse >= FileTransferPolicy.RETRY_MS &&
        now - lastOffer >= FileTransferPolicy.RETRY_MS

    fun timedOut(now: Long): Boolean = now - lastProgress >= FileTransferPolicy.TIMEOUT_MS
}
