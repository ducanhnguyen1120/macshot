import Foundation

/// Moves the `moov` box of a finished MP4 in front of `mdat` ("fast start").
///
/// AVAssetWriter in real-time mode writes the index last. Players that start
/// before the whole file is available (Zalo, Discord, other chat and web
/// uploaders) can then play a long recording without its audio track.
/// Only chunk offsets change; no sample data is touched.
nonisolated enum MP4FastStart {

    enum Failure: Error { case malformed, offsetOverflow }

    private struct Box {
        let type: String
        let offset: UInt64
        let size: UInt64
    }

    /// Best effort: on any failure the original file is left untouched.
    static func optimizeInPlace(_ url: URL) {
        guard ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased()) else { return }
        try? optimize(url)
    }

    static func optimize(_ url: URL) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let fileSize = try input.seekToEnd()
        let boxes = try readBoxes(input, fileSize: fileSize)

        guard let moov = boxes.first(where: { $0.type == "moov" }),
              let firstMdat = boxes.first(where: { $0.type == "mdat" }),
              moov.offset > firstMdat.offset,
              let ftyp = boxes.first, ftyp.type == "ftyp",
              moov.size < 64 * 1024 * 1024 else { return }

        try input.seek(toOffset: moov.offset)
        guard let moovData = try input.read(upToCount: Int(moov.size)), moovData.count == Int(moov.size) else {
            throw Failure.malformed
        }
        var moovBytes = [UInt8](moovData)
        try shiftChunkOffsets(in: &moovBytes, start: 8, end: moovBytes.count, by: moov.size)

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".faststart-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw Failure.malformed }
        do {
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            try copy(input, from: ftyp.offset, count: ftyp.size, to: output)
            try output.write(contentsOf: Data(moovBytes))
            for box in boxes where box.type != "moov" && box.offset != ftyp.offset {
                try copy(input, from: box.offset, count: box.size, to: output)
            }
            try output.synchronize()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func readBoxes(_ handle: FileHandle, fileSize: UInt64) throws -> [Box] {
        var boxes: [Box] = []
        var position: UInt64 = 0
        while position + 8 <= fileSize {
            try handle.seek(toOffset: position)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
            let bytes = [UInt8](header)
            var size = UInt64(bytes[0]) << 24 | UInt64(bytes[1]) << 16 | UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            let type = String(decoding: bytes[4..<8], as: UTF8.self)
            var headerSize: UInt64 = 8
            if size == 1 {
                guard bytes.count >= 16 else { throw Failure.malformed }
                size = bytes[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
                headerSize = 16
            } else if size == 0 {
                size = fileSize - position
            }
            guard size >= headerSize, position + size <= fileSize else { throw Failure.malformed }
            boxes.append(Box(type: type, offset: position, size: size))
            position += size
        }
        return boxes
    }

    private static func shiftChunkOffsets(in bytes: inout [UInt8], start: Int, end: Int, by shift: UInt64) throws {
        var position = start
        while position + 8 <= end {
            var size = Int(readUInt32(bytes, position))
            let type = String(decoding: bytes[(position + 4)..<(position + 8)], as: UTF8.self)
            var headerSize = 8
            if size == 1 {
                guard position + 16 <= end else { throw Failure.malformed }
                size = Int(readUInt64(bytes, position + 8))
                headerSize = 16
            } else if size == 0 {
                size = end - position
            }
            guard size >= headerSize, position + size <= end else { throw Failure.malformed }
            let body = position + headerSize
            switch type {
            case "trak", "mdia", "minf", "stbl":
                try shiftChunkOffsets(in: &bytes, start: body, end: position + size, by: shift)
            case "stco":
                guard body + 8 <= position + size else { throw Failure.malformed }
                let count = Int(readUInt32(bytes, body + 4))
                guard body + 8 + count * 4 <= position + size else { throw Failure.malformed }
                for index in 0..<count {
                    let at = body + 8 + index * 4
                    let shifted = UInt64(readUInt32(bytes, at)) + shift
                    guard shifted <= UInt64(UInt32.max) else { throw Failure.offsetOverflow }
                    writeUInt32(&bytes, at, UInt32(shifted))
                }
            case "co64":
                guard body + 8 <= position + size else { throw Failure.malformed }
                let count = Int(readUInt32(bytes, body + 4))
                guard body + 8 + count * 8 <= position + size else { throw Failure.malformed }
                for index in 0..<count {
                    let at = body + 8 + index * 8
                    writeUInt64(&bytes, at, readUInt64(bytes, at) + shift)
                }
            default:
                break
            }
            position += size
        }
    }

    private static func copy(_ input: FileHandle, from offset: UInt64, count: UInt64, to output: FileHandle) throws {
        try input.seek(toOffset: offset)
        var remaining = count
        let chunk: UInt64 = 8 * 1024 * 1024
        while remaining > 0 {
            let length = Int(min(remaining, chunk))
            guard let data = try input.read(upToCount: length), !data.isEmpty else { throw Failure.malformed }
            try output.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
    }

    private static func readUInt32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    private static func readUInt64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        bytes[at..<(at + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func writeUInt32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        for index in 0..<4 { bytes[at + index] = UInt8(truncatingIfNeeded: value >> UInt32(24 - 8 * index)) }
    }

    private static func writeUInt64(_ bytes: inout [UInt8], _ at: Int, _ value: UInt64) {
        for index in 0..<8 { bytes[at + index] = UInt8(truncatingIfNeeded: value >> UInt64(56 - 8 * index)) }
    }
}
