import Foundation

// Wire format spoken by ApogeeGlue on 127.0.0.1:53435 (reverse engineered from
// Apogee Control 2 1.21.x traffic).
//
// Frame:    juce::InterprocessConnection header: u32 magic 0xf2b49e2c, u32 length (LE)
// Payload:  [type][size: 1/2/4 bytes LE][crc8(type+size)][body][crc8(body)]
//           type bits 6-7 select the size width (0x00=1, 0x40=2, 0x80=4 bytes).
// Property keys are juce::String::hashCode() of "/path/to/tree/property", where
// the path omits the server's "root" node, e.g. "/dev/<uid>/hwout/hwout0/gain".
enum GlueMessageType: UInt8 {
    case setProperty = 0x03
    case hello = 0x21 // asks the server for the entire tree
    case setSubtree = 0x22
    case addTree = 0x24
    case entireTree = 0x26
    case meters = 0x28
    case ack = 0x29
}

enum GlueProtocol {
    static let port: UInt16 = 53435
    static let magic: UInt32 = 0xf2b4_9e2c

    static func crc8(_ bytes: some Sequence<UInt8>) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }

    static func key(_ path: String) -> UInt32 {
        var hash: UInt32 = 0
        for scalar in path.unicodeScalars {
            hash = hash &* 31 &+ scalar.value
        }
        return hash
    }

    static func frame(type: GlueMessageType, body: [UInt8]) -> Data {
        var head: [UInt8]
        switch body.count {
        case ..<0x100:
            head = [type.rawValue, UInt8(body.count)]
        case ..<0x10000:
            head = [type.rawValue | 0x40]
            head += withUnsafeBytes(of: UInt16(body.count).littleEndian, Array.init)
        default:
            head = [type.rawValue | 0x80]
            head += withUnsafeBytes(of: UInt32(body.count).littleEndian, Array.init)
        }
        let payload = head + [crc8(head)] + body + [crc8(body)]

        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: magic.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).littleEndian, Array.init))
        data.append(contentsOf: payload)
        return data
    }

    static func setProperty(path: String, value: GlueValue) -> Data {
        var body = [value.typeMarker]
        body += withUnsafeBytes(of: key(path).littleEndian, Array.init)
        body += value.payload
        return frame(type: .setProperty, body: body)
    }

    /// Splits complete frames off the front of `buffer`.
    static func takeMessages(from buffer: inout Data) -> [(type: UInt8, body: Data)] {
        var messages: [(UInt8, Data)] = []
        while buffer.count >= 8 {
            let start = buffer.startIndex
            let length = Int(buffer.readUInt32(at: start + 4))
            guard buffer.readUInt32(at: start) == magic else {
                buffer.removeAll()
                break
            }
            guard buffer.count >= 8 + length else { break }

            let payload = buffer.subdata(in: (start + 8)..<(start + 8 + length))
            buffer.removeSubrange(start..<(start + 8 + length))

            guard let first = payload.first else { continue }
            let sizeWidth = [0x00: 1, 0x40: 2, 0x80: 4][Int(first & 0xC0)] ?? 1
            let bodyStart = payload.startIndex + 2 + sizeWidth
            let bodyEnd = payload.endIndex - 1
            guard bodyStart <= bodyEnd else { continue }
            messages.append((first & 0x3F, payload.subdata(in: bodyStart..<bodyEnd)))
        }
        return messages
    }

    /// Bodies of tree messages are zlib streams; Foundation only inflates raw deflate.
    static func inflate(_ zlib: Data) -> Data? {
        guard zlib.count > 6 else { return nil }
        return try? (zlib.dropFirst(2) as NSData).decompressed(using: .zlib) as Data
    }
}

enum GlueValue: Equatable {
    case int(Int32)
    case bool(Bool)
    case double(Double)
    case string(String)
    case int64(Int64)
    case unsupported

    // juce::var binary markers
    var typeMarker: UInt8 {
        switch self {
        case .int: 1
        case .bool(let value): value ? 2 : 3
        case .double: 4
        case .string: 5
        case .int64: 6
        case .unsupported: 0
        }
    }

    var payload: [UInt8] {
        switch self {
        case .int(let value): withUnsafeBytes(of: value.littleEndian, Array.init)
        case .bool, .unsupported: []
        case .double(let value): withUnsafeBytes(of: value.bitPattern.littleEndian, Array.init)
        case .string(let value): Array(value.utf8) + [0]
        case .int64(let value): withUnsafeBytes(of: value.littleEndian, Array.init)
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .bool(let value): value ? 1 : 0
        case .double(let value): value
        case .string(let value): Double(value.trimmingCharacters(in: .whitespaces))
        case .int64(let value): Double(value)
        case .unsupported: nil
        }
    }

    var boolValue: Bool? {
        if case .string(let value) = self, value.lowercased() == "true" { return true }
        return doubleValue.map { $0 != 0 }
    }

    static func decode(marker: UInt8, bytes: Data) -> GlueValue {
        switch marker {
        case 1 where bytes.count >= 4: .int(Int32(bitPattern: bytes.readUInt32(at: bytes.startIndex)))
        case 2: .bool(true)
        case 3: .bool(false)
        case 4 where bytes.count >= 8: .double(Double(bitPattern: bytes.readUInt64(at: bytes.startIndex)))
        case 5: .string(String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self))
        case 6 where bytes.count >= 8: .int64(Int64(bitPattern: bytes.readUInt64(at: bytes.startIndex)))
        default: .unsupported
        }
    }

    /// Body of a setProperty message: [marker][u32 key][value bytes].
    /// Unlike juce::var streams, ApogeeGlue sends booleans as marker 3 plus one
    /// value byte (e.g. mute echoes back as `03 <key> 01`).
    static func decodeSetProperty(_ body: Data) -> (key: UInt32, value: GlueValue)? {
        guard body.count >= 5 else { return nil }
        let start = body.startIndex
        let key = body.readUInt32(at: start + 1)
        let bytes = body.subdata(in: (start + 5)..<body.endIndex)
        if body[start] == 3, let flag = bytes.first {
            return (key, .bool(flag != 0))
        }
        return (key, decode(marker: body[start], bytes: bytes))
    }
}

/// juce::ValueTree::writeToStream format.
struct GlueTree {
    let name: String
    var properties: [String: GlueValue]
    var children: [GlueTree]

    func child(_ name: String) -> GlueTree? {
        children.first { $0.name == name }
    }

    static func parse(_ data: Data) -> GlueTree? {
        var reader = Reader(bytes: [UInt8](data))
        return reader.tree()
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        mutating func tree() -> GlueTree? {
            guard let name = string(), let propertyCount = compressedInt() else { return nil }
            var properties: [String: GlueValue] = [:]
            for _ in 0..<max(propertyCount, 0) {
                guard let key = string(), let value = variant() else { return nil }
                properties[key] = value
            }
            guard let childCount = compressedInt() else { return nil }
            var children: [GlueTree] = []
            for _ in 0..<max(childCount, 0) {
                guard let child = tree() else { return nil }
                children.append(child)
            }
            return GlueTree(name: name, properties: properties, children: children)
        }

        mutating func string() -> String? {
            guard let end = bytes[index...].firstIndex(of: 0) else { return nil }
            defer { index = end + 1 }
            return String(decoding: bytes[index..<end], as: UTF8.self)
        }

        mutating func compressedInt() -> Int? {
            guard index < bytes.count else { return nil }
            let header = bytes[index]
            let count = Int(header & 0x7F)
            index += 1
            guard count <= 4, index + count <= bytes.count else { return nil }
            var value = 0
            for offset in 0..<count {
                value |= Int(bytes[index + offset]) << (8 * offset)
            }
            index += count
            return header & 0x80 != 0 ? -value : value
        }

        mutating func variant() -> GlueValue? {
            guard let size = compressedInt(), size >= 0, index + size <= bytes.count else { return nil }
            guard size > 0 else { return .unsupported }
            let marker = bytes[index]
            let payload = Data(bytes[(index + 1)..<(index + size)])
            index += size
            return GlueValue.decode(marker: marker, bytes: payload)
        }
    }
}

extension Data {
    func readUInt32(at offset: Index) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[offset + $1]) << (8 * $1) }
    }

    func readUInt64(at offset: Index) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(self[offset + $1]) << (8 * $1) }
    }
}
