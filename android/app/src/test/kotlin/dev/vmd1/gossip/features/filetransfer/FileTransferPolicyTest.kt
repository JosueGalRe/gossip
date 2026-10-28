package dev.vmd1.gossip.features.filetransfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FileTransferPolicyTest {
    @Test fun `names cannot escape Downloads or become hidden`() {
        assertEquals("evilname.txt", FileTransferPolicy.sanitizeName("../\\.evil\u0000name\n.txt"))
        assertEquals("file", FileTransferPolicy.sanitizeName(".../\\\u007f"))
    }

    @Test fun `name limit counts Unicode characters without splitting surrogate pairs`() {
        val name = "😀".repeat(201)
        assertEquals("😀".repeat(200), FileTransferPolicy.sanitizeName(name))
        assertEquals(200, FileTransferPolicy.sanitizeName("a".repeat(201)).length)
    }

    @Test fun `duplicate names keep extension and start suffix at two`() {
        assertEquals("a (3).zip", FileTransferPolicy.uniqueName("a.zip", setOf("a.zip", "a (2).zip")))
        assertEquals("file (2)", FileTransferPolicy.uniqueName("file", setOf("file")))
        assertEquals("a.zip", FileTransferPolicy.uniqueName("a.zip", emptySet()))
    }

    @Test fun `only contiguous chunks advance receiver ack`() {
        val state = FileReceiveState(10)
        assertEquals(FileReceiveState.Chunk.IGNORE, state.chunk(5, 5))
        assertEquals(0L, state.received)
        assertEquals(FileReceiveState.Chunk.WRITE, state.chunk(0, 5))
        state.appended(5)
        assertEquals(FileReceiveState.Chunk.IGNORE, state.chunk(0, 5))
        assertEquals(5L, state.received)
        state.appended(5)
        assertTrue(state.complete)
    }

    @Test fun `receiver rejects empty oversized and overflowing frames`() {
        val state = FileReceiveState(5)
        assertEquals(FileReceiveState.Chunk.INVALID, state.chunk(0, 0))
        assertEquals(FileReceiveState.Chunk.INVALID, state.chunk(0, FileTransferPolicy.CHUNK_SIZE + 1))
        assertEquals(FileReceiveState.Chunk.INVALID, state.chunk(0, 6))
        assertTrue(FileReceiveState(0).complete)
    }

    @Test fun `sender cannot send before acceptance or exceed four MiB unacked`() {
        val state = FileSendWindow(10L * FileTransferPolicy.CHUNK_SIZE, 0)
        assertEquals(0, state.nextChunkSize())
        state.accept(0, 0)
        repeat(4) { state.sent(state.nextChunkSize()) }
        assertEquals(0, state.nextChunkSize())
        state.acknowledge(FileTransferPolicy.CHUNK_SIZE.toLong(), false, 1)
        assertEquals(FileTransferPolicy.CHUNK_SIZE, state.nextChunkSize())
    }

    @Test fun `resume resets the read position and window to receiver offset`() {
        val state = FileSendWindow(100, 0)
        state.accept(0, 0); state.sent(100)
        state.offered(10_000)
        assertEquals(0, state.nextChunkSize())
        state.accept(40, 10_001)
        assertEquals(40L, state.position)
        assertEquals(40L, state.received)
        assertEquals(60, state.nextChunkSize())
        assertFalse(state.accept(101, 10_002))
    }

    @Test fun `acks are monotonic and completion requires a saved full file`() {
        val state = FileSendWindow(100, 0)
        state.accept(0, 0); state.sent(100)
        assertTrue(state.acknowledge(50, true, 1))
        assertFalse(state.complete)
        assertFalse(state.acknowledge(40, false, 2))
        assertFalse(state.acknowledge(101, true, 2))
        state.acknowledge(100, false, 3)
        assertFalse(state.complete)
        state.acknowledge(100, true, 4)
        assertTrue(state.complete)
    }

    @Test fun `duplicate accepts are a no-op but reoffer can resume from the same offset`() {
        val state = FileSendWindow(100, 0)
        state.accept(0, 0); state.sent(100)
        state.acknowledge(50, false, 1)
        state.accept(0, 2)
        assertEquals(100L, state.position)
        assertEquals(50L, state.received)
        state.offered(10_000)
        state.accept(0, 10_001)
        assertEquals(0L, state.position)
        assertEquals(0L, state.received)
    }

    @Test fun `recently completed receiver can finish sender without resending bytes`() {
        val state = FileSendWindow(100, 0)
        assertTrue(state.acknowledge(100, true, 1))
        assertTrue(state.complete)
        val empty = FileSendWindow(0, 0)
        empty.acknowledge(0, true, 1)
        assertTrue(empty.complete)
    }

    @Test fun `retry every ten seconds but duplicate responses do not avoid sixty second timeout`() {
        val state = FileSendWindow(100, 0)
        assertFalse(state.shouldOffer(9_999))
        assertTrue(state.shouldOffer(10_000))
        state.offered(10_000)
        assertFalse(state.shouldOffer(10_001))
        assertTrue(state.shouldOffer(20_000))
        state.accept(0, 59_000)
        assertTrue(state.timedOut(60_000))
    }

    @Test fun `real ack progress resets timeout and invalid acks cannot open window`() {
        val state = FileSendWindow(100, 0)
        state.accept(0, 0)
        assertFalse(state.acknowledge(100, false, 1))
        state.sent(50)
        state.acknowledge(50, false, 59_000)
        assertFalse(state.timedOut(60_000))
        assertTrue(state.timedOut(119_000))
    }

    @Test fun `four GiB sizes and last partial chunk use Long offsets`() {
        val state = FileSendWindow(FileTransferPolicy.MAX_SIZE, 0)
        state.accept(FileTransferPolicy.MAX_SIZE - 7, 1)
        assertEquals(7, state.nextChunkSize())
        state.sent(7)
        assertEquals(FileTransferPolicy.MAX_SIZE, state.position)
    }
}
