import Foundation

/// Reads what Dove needs from a `.torrent` file without decoding all of it.
///
/// Private trackers mark their torrents with `private = 1` in the `info` dictionary (BEP 27): clients then use
/// only the tracker (no DHT or PEX), and the tracker expects the client to seed back. Debrid services that never
/// seed (Real-Debrid, TorBox below its top plans, Offcloud) get accounts banned on such trackers, so Dove sends
/// these torrents only to services that seed (`LibraryBackend.takesPrivateTorrents`, Debrid-Link).
public enum TorrentFile {
    /// True when the file's `info` dictionary has `private` set to 1. False for anything unreadable.
    public static func isPrivate(_ data: Data) -> Bool {
        let reader = BencodeReader(bytes: [UInt8](data))
        guard let info = try? reader.value(forKey: "info", inDictionaryAt: 0),
              let flag = try? reader.value(forKey: "private", inDictionaryAt: info)
        else { return false }
        return (try? reader.integer(at: flag)) == 1
    }
}

extension Source {
    /// A `.torrent` file from a private tracker. Magnets and links cannot tell; resolve links first
    /// (`IndexerTorrent.prepare`).
    public var isPrivateTorrent: Bool {
        guard case .torrentFile(let data, _) = self else { return false }
        return TorrentFile.isPrivate(data)
    }
}

/// Just enough bencode to walk dictionaries and skip everything else.
private struct BencodeReader {
    struct Malformed: Error {}

    let bytes: [UInt8]

    /// Offset of the value stored under `key` in the dictionary that starts at `start`, or nil when absent.
    func value(forKey key: String, inDictionaryAt start: Int) throws -> Int? {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "d") else { throw Malformed() }
        let wanted = Array(key.utf8)
        var offset = start + 1
        while offset < bytes.count, bytes[offset] != UInt8(ascii: "e") {
            let (name, valueStart) = try string(at: offset)
            if name == wanted { return valueStart }
            offset = try skip(at: valueStart)
        }
        return nil
    }

    func integer(at offset: Int) throws -> Int {
        guard offset < bytes.count, bytes[offset] == UInt8(ascii: "i"),
              let end = bytes[offset...].firstIndex(of: UInt8(ascii: "e")),
              let value = Int(String(decoding: bytes[(offset + 1)..<end], as: UTF8.self))
        else { throw Malformed() }
        return value
    }

    /// A byte string (`4:spam`) and the offset right after it.
    private func string(at offset: Int) throws -> ([UInt8], Int) {
        guard let colon = bytes[offset...].prefix(20).firstIndex(of: UInt8(ascii: ":")),
              let length = Int(String(decoding: bytes[offset..<colon], as: UTF8.self)),
              length >= 0, colon + 1 + length <= bytes.count
        else { throw Malformed() }
        let start = colon + 1
        return (Array(bytes[start..<(start + length)]), start + length)
    }

    /// The offset right after the value that starts at `offset`.
    private func skip(at offset: Int) throws -> Int {
        guard offset < bytes.count else { throw Malformed() }
        switch bytes[offset] {
        case UInt8(ascii: "i"):
            guard let end = bytes[offset...].firstIndex(of: UInt8(ascii: "e")) else { throw Malformed() }
            return end + 1
        case UInt8(ascii: "l"), UInt8(ascii: "d"):
            var next = offset + 1
            while next < bytes.count, bytes[next] != UInt8(ascii: "e") {
                next = try skip(at: next)
            }
            guard next < bytes.count else { throw Malformed() }
            return next + 1
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try string(at: offset).1
        default:
            throw Malformed()
        }
    }
}
