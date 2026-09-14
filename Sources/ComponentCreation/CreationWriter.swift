import Foundation
import KDNACore

// Bounded creation-owned encoder. Public Core alone decodes and interprets.
enum CreationWriter {
    // This writer only encodes compiler-owned JSON-domain values. It does not
    // decode CBOR, accept arbitrary wire assets or replace Core validation.
    static func encodeCBOR(_ value: KDNAValue) throws -> Data {
        var bytes = Data()
        func head(_ major: UInt8, _ value: UInt64) {
            if value < 24 { bytes.append(major << 5 | UInt8(value)); return }
            let width: Int
            let suffix: UInt8
            if value <= 0xff { width = 1; suffix = 24 }
            else if value <= 0xffff { width = 2; suffix = 25 }
            else if value <= 0xffffffff { width = 4; suffix = 26 }
            else { width = 8; suffix = 27 }
            bytes.append(major << 5 | suffix)
            for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
            }
        }
        func encode(_ item: KDNAValue) throws {
            switch item {
            case .null: bytes.append(0xf6)
            case .bool(let value): bytes.append(value ? 0xf5 : 0xf4)
            case .string(let value):
                let encoded = Data(value.utf8)
                head(3, UInt64(encoded.count)); bytes.append(encoded)
            case .number(let value):
                guard value.isFinite else {
                    throw CreationValues.fail("COMPILER_VALUE_UNSUPPORTED", "Creation JSON numbers must be finite.")
                }
                if value.rounded() == value && abs(value) <= 9007199254740991 {
                    if value >= 0 { head(0, UInt64(value)) }
                    else { head(1, UInt64(-1 - value)) }
                } else {
                    bytes.append(0xfb)
                    let bits = value.bitPattern
                    for shift in stride(from: 56, through: 0, by: -8) {
                        bytes.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
                    }
                }
            case .array(let values):
                head(4, UInt64(values.count))
                for value in values { try encode(value) }
            case .object(let fields):
                let keys = fields.keys.sorted { $0.text.utf16.lexicographicallyPrecedes($1.text.utf16) }
                head(5, UInt64(keys.count))
                for key in keys { try encode(.string(key.text)); try encode(fields[key]!) }
            }
            guard bytes.count <= 5 * 1024 * 1024 else {
                throw CreationValues.fail("COMPILER_ENTRY_TOO_LARGE", "Compiler entry exceeds the Core limit.")
            }
        }
        try encode(value)
        return bytes
    }

    static func storedZIP(_ entries: [(String, Data)]) throws -> Data {
        guard entries.map({ $0.0 }) == ["mimetype", "kdna.json", "payload.kdnab"] else {
            throw CreationValues.fail("COMPILER_MEMBERS_INVALID", "The compiler writes exactly three runtime members.")
        }
        var local = Data(), central = Data()
        func u16(_ value: UInt16, into data: inout Data) {
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func u32(_ value: UInt32, into data: inout Data) {
            for shift in stride(from: 0, through: 24, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
        }
        for (name, content) in entries {
            guard content.count <= 5 * 1024 * 1024 else {
                throw CreationValues.fail("COMPILER_ENTRY_TOO_LARGE", "Compiler entry exceeds the Core limit.")
            }
            let nameBytes = Data(name.utf8), checksum = crc32(content), offset = UInt32(local.count)
            u32(0x04034b50, into: &local); u16(20, into: &local); u16(0x800, into: &local)
            u16(0, into: &local); u16(0, into: &local); u16(0, into: &local)
            u32(checksum, into: &local); u32(UInt32(content.count), into: &local); u32(UInt32(content.count), into: &local)
            u16(UInt16(nameBytes.count), into: &local); u16(0, into: &local)
            local.append(nameBytes); local.append(content)

            u32(0x02014b50, into: &central); u16(20, into: &central); u16(20, into: &central)
            u16(0x800, into: &central); u16(0, into: &central); u16(0, into: &central); u16(0, into: &central)
            u32(checksum, into: &central); u32(UInt32(content.count), into: &central); u32(UInt32(content.count), into: &central)
            u16(UInt16(nameBytes.count), into: &central); u16(0, into: &central); u16(0, into: &central)
            u16(0, into: &central); u16(0, into: &central); u32(0, into: &central); u32(offset, into: &central)
            central.append(nameBytes)
        }
        var end = Data()
        u32(0x06054b50, into: &end); u16(0, into: &end); u16(0, into: &end)
        u16(UInt16(entries.count), into: &end); u16(UInt16(entries.count), into: &end)
        u32(UInt32(central.count), into: &end); u32(UInt32(local.count), into: &end); u16(0, into: &end)
        local.append(central); local.append(end)
        return local
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        return crc ^ 0xffffffff
    }
}
