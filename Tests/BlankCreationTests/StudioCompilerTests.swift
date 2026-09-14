import XCTest
import Foundation
import KDNACore
@testable import KDNAStudioCore

final class StudioCompilerTests: XCTestCase {
    func testPrivateEvidenceSpellingAndExactUnicode() throws {
        let value: KDNAValue = ["😀": 1, "\u{E000}": 2, "a": ["\n", "é", "e\u{301}", -0.0, 1e-7]]
        let encoded = String(decoding: try StudioValues.canonicalEvidence(value), as: UTF8.self)
        XCTAssertEqual(encoded, "{\"a\":[\"\\n\",\"é\",\"e\u{301}\",0,1e-7],\"😀\":1,\"\u{E000}\":2}")
        XCTAssertFalse(StudioValues.sameText("é", "e\u{301}"))
        XCTAssertEqual(try StudioValues.text("\u{85}", "text"), "\u{85}")
        XCTAssertThrowsError(try StudioValues.text("\u{FEFF}", "text"))
        XCTAssertThrowsError(try StudioValues.text(.string(String(repeating: "a", count: 1048577)), "text"))
        XCTAssertEqual(StudioValues.sha256(Data("abc".utf8)),
                       "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testTextResultUsesModernThreeMemberContainerAndActualCore() throws {
        let result = try compilerFixture()
        let names = try localMembers(result.bytes)
        XCTAssertEqual(names, ["mimetype", "kdna.json", "payload.kdnab"])
        XCTAssertEqual(result.manifest["format_version"], "0.2.0")
        XCTAssertEqual(result.payload["profile_version"], "0.2.0")
        XCTAssertEqual(result.payload["judgments"].list.count, 1)
        XCTAssertEqual(result.payload["judgments"].list[0]["result"]["value"]["value"], "保留照片中的原始日期，并注明无法确定的地点。")
        XCTAssertFalse(result.manifest.has("creation"))
        XCTAssertFalse(result.payload.has("human_messages"))
        let admission = KDNACore.admitBytes(result.bytes)
        XCTAssertEqual(admission.result["status"], "accepted")
        let view = try XCTUnwrap(admission.snapshot).inspect()
        XCTAssertEqual(view["digests"], result.digests)
        XCTAssertEqual(view["digests"]["A"]["observed"].text, StudioValues.sha256(result.bytes))

        var corrupted = result.bytes
        corrupted[38] ^= 1 // The stored mimetype body, without updating its CRC.
        XCTAssertNil(KDNACore.admitBytes(corrupted).snapshot)
    }

    func testWriterOnlyAcceptsBoundedCompilerSlice() throws {
        XCTAssertThrowsError(try StudioCompiler.encodeCBOR(-1))
        XCTAssertThrowsError(try StudioCompiler.encodeCBOR(1.5))
        XCTAssertThrowsError(try StudioCompiler.encodeCBOR(.number(.infinity)))
        XCTAssertThrowsError(try StudioCompiler.encodeCBOR(.string(String(repeating: "x", count: 5 * 1024 * 1024))))
        XCTAssertThrowsError(try StudioCompiler.storedZIP([("other", Data())]))
        XCTAssertEqual(try StudioCompiler.encodeCBOR(["a": 1]), Data([0xa1, 0x61, 0x61, 0x01]))
    }

    private func compilerFixture() throws -> StudioCompiledArtifact {
        try StudioCompiler.compile(
            brief: ["title": "照片整理规则", "scope": "家庭照片的日期和地点记录"],
            candidates: [["title": "保留日期", "subject": "整理家庭照片的人", "scope": "日期可见但地点不确定的照片",
                          "statement": "保留照片中的原始日期，并注明无法确定的地点。", "rationale": "材料要求区分可见事实与猜测。"]],
            asset: ["asset_id": "asset:studio-compiler-test", "asset_uid": "urn:uuid:ba16483e-5c72-4dce-9858-62297280df11", "version": "0.1.4"],
            createdAt: "2026-09-10T05:00:00.000Z", syntheticFixture: true)
    }

    // Test-only independent header traversal, not a production ZIP reader.
    private func localMembers(_ bytes: Data) throws -> [String] {
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        var position = 0, names: [String] = []
        while position + 30 <= bytes.count && u32(position) == 0x04034b50 {
            let size = u32(position + 18), nameLength = u16(position + 26), extraLength = u16(position + 28)
            let body = position + 30 + nameLength + extraLength
            XCTAssertEqual(u16(position + 8), 0)
            XCTAssertLessThanOrEqual(body + size, bytes.count)
            names.append(try XCTUnwrap(String(data: bytes[(position + 30)..<(position + 30 + nameLength)], encoding: .utf8)))
            position = body + size
        }
        XCTAssertEqual(u32(position), 0x02014b50)
        return names
    }
}
