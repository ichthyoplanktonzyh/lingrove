import Foundation
import Testing
@testable import MDictReader

struct MDictFileTests {
    private func file(_ data: Data, perform: (MDictFile) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mdx")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try perform(MDictFile(url: url))
    }

    @Test(arguments: [DictionaryFixture.v1, DictionaryFixture.v2])
    func readsUncompressedV1AndZlibV2(_ data: Data) throws {
        try file(data) { reader in
            #expect(reader.title == "Lingrove Test")
            #expect(reader.entryCount == 3)
            let hello = try reader.definitions(for: "hello")
            #expect(hello.first?.contains("Hello") == true)
            let alias = try reader.definitions(for: "alias")
            #expect(alias == ["@@@LINK=hello"])
            let absent = try reader.definitions(for: "absent")
            #expect(absent.isEmpty)
        }
    }

    @Test func mddUTF16KeysReturnOriginalBinary() throws {
        try file(DictionaryFixture.mdd) { reader in
            let data = try #require(try reader.resource(for: "\\test.png"))
            #expect(data.prefix(8) == Data([137,80,78,71,13,10,26,10]))
        }
    }

    @Test func truncationAtEveryOffsetIsRejectedWithoutTrapping() throws {
        let fixture = DictionaryFixture.v2
        for count in 0..<fixture.count {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(fixture.prefix(count)).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(throws: (any Error).self) { _ = try MDictFile(url: url) }
        }
    }

    @Test func emptyCompressedSourcesAndBombsAreRejected() {
        #expect(throws: (any Error).self) {
            _ = try MDictReader.decompressBlock(Data([2,0,0,0,0,0,0,0]), decompressedSize: 0)
        }
        #expect(throws: (any Error).self) {
            _ = try MDictReader.decompressBlock(Data(repeating: 0, count: 8), decompressedSize: Int.max)
        }
        #expect(throws: (any Error).self) { _ = try MDictReader.checkedReadUInt64BE(Data(), at: Int.max) }
    }

    @Test func adversarialHeaderAndCountsAreRejected() throws {
        for offset in [0, 5, 20] {
            var data = DictionaryFixture.v2
            if offset == 0 { data.replaceSubrange(0..<4, with: [255,255,255,255]) }
            else {
                let header = Int(MDictReader.readUInt32BE(data, at: 0))
                let start = 8 + header + (offset == 5 ? 0 : 8)
                data.replaceSubrange(start..<start+8, with: repeatElement(UInt8(255), count: 8))
            }
            #expect(throws: (any Error).self) { try file(data) { _ in } }
        }
    }

    @Test func lzoLiteralAndInvalidBackReference() throws {
        // LZO1X initial literal followed by EOF; this format uses the same decoder as MDict.
        let payload = Data([22]) + Data("hello".utf8) + Data([17,0,0])
        let block = Data([1,0,0,0,0,0,0,0]) + payload
        #expect(try MDictReader.decompressBlock(block, decompressedSize: 5) == Data("hello".utf8))
        #expect(throws: (any Error).self) {
            _ = try MDictReader.decompressBlock(Data([1,0,0,0,0,0,0,0,17,1,0]), decompressedSize: 8)
        }
    }

    @Test func keyBlockWorkAndCompressedSizesAreBounded() throws {
        #expect(throws: (any Error).self) { try file(DictionaryFixture.oversize) { _ in } }
        #expect(throws: (any Error).self) { try file(DictionaryFixture.reversed) { _ in } }
        try file(DictionaryFixture.overlap) { reader in
            #expect(throws: (any Error).self) { _ = try reader.definitions(for: "hello") }
        }
    }
}
