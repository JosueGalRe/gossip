import Foundation

/// The decisions of a file transfer (`file.*` in `schema/message-types.md`), kept free of I/O so they can be tested.
enum FileTransferLogic {
    static let chunkBytes = 1 << 20
    /// Bytes the sender may have sent and not yet had acknowledged.
    static let windowBytes: Int64 = 4 << 20
    static let maxFileBytes: Int64 = 4 << 30
    static let maxNameLength = 200

    /// A received name made safe to save: no path, no control characters, not hidden, not empty.
    static func sanitizedName(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" && $0 != ":"
        }.map(Character.init))
        var trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        trimmed = String(trimmed.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "file" : trimmed
    }

    /// `name`, or `name (2).ext`, `name (3).ext` and so on: the first that `exists` says is free.
    static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for n in 2... {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !exists(candidate) { return candidate }
        }
        return name
    }

    /// What a receiver does with a chunk at `offset` when it holds `received` of `size` bytes.
    enum ChunkDecision: Equatable {
        /// Write it: it is the next slice.
        case write
        /// A duplicate or a slice after a gap: drop it, and acknowledge what is held so the sender finds its place.
        case ignore
        /// It runs past the announced size.
        case reject
    }

    static func decide(offset: Int64, length: Int, received: Int64, size: Int64) -> ChunkDecision {
        guard offset == received else { return .ignore }
        return received + Int64(length) <= size ? .write : .reject
    }

    /// A sender's place in one file: what it has sent and what the receiver acknowledged.
    struct Sending: Equatable {
        let size: Int64
        private(set) var next: Int64 = 0
        private(set) var acked: Int64 = 0

        init(size: Int64) { self.size = size }

        /// `file.accept`: start (again) from where the receiver is.
        mutating func accept(offset: Int64) {
            let offset = min(max(0, offset), size)
            next = offset
            acked = offset
        }

        /// `file.ack`: true when it is progress. Never moves backwards, so a late or duplicate ack changes nothing.
        mutating func ack(received: Int64) -> Bool {
            guard received > acked, received <= size else { return false }
            acked = received
            if next < acked { next = acked }
            return true
        }

        /// The next slice to send, while the window has room.
        var nextChunk: (offset: Int64, length: Int)? {
            guard next < size, next - acked < FileTransferLogic.windowBytes else { return nil }
            return (next, Int(min(Int64(FileTransferLogic.chunkBytes), size - next)))
        }

        mutating func sent(_ length: Int) { next += Int64(length) }

        var isComplete: Bool { acked >= size }
    }
}
