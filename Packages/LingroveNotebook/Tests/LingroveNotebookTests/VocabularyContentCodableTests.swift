import Foundation
import Testing
import LingroveNotebook

/// These tests lock down the bytes-on-disk contract for the values shared by the Mac app and
/// other Apple targets. The fixture was encoded from the pre-extraction declarations in
/// `git show HEAD:Lingrove/Models/Vocabulary/VocabularyContentModels.swift` and
/// `git show HEAD:Lingrove/Models/Vocabulary/VocabularyModels.swift`; keeping it literal makes
/// accidental changes to synthesized enum coding or field names visible during review.
struct VocabularyContentCodableTests {
    private static let legacyJSON = #"""
    {
      "content" : [
        {
          "content" : {
            "text" : {
              "_0" : {
                "bold" : true,
                "italic" : false,
                "style" : "heading",
                "text" : "A note about 🐈"
              }
            }
          },
          "id" : "00000000-0000-4000-8000-000000000001"
        },
        {
          "content" : {
            "image" : {
              "_0" : {
                "byteCount" : 12345,
                "digest" : "0123456789abcdef",
                "height" : 480,
                "width" : 640
              },
              "caption" : "First angle"
            }
          },
          "id" : "00000000-0000-4000-8000-000000000002"
        },
        {
          "content" : {
            "image" : {
              "_0" : {
                "byteCount" : 12345,
                "digest" : "0123456789abcdef",
                "height" : 480,
                "width" : 640
              },
              "caption" : "Second angle"
            }
          },
          "id" : "00000000-0000-4000-8000-000000000003"
        },
        {
          "content" : {
            "text" : {
              "_0" : {
                "bold" : false,
                "italic" : true,
                "style" : "paragraph",
                "text" : "café"
              }
            }
          },
          "id" : "00000000-0000-4000-8000-000000000004"
        }
      ],
      "ranges" : [
        {
          "length" : 2,
          "location" : 6
        },
        {
          "length" : 4,
          "location" : 13
        }
      ]
    }
    """#

    @Test func legacyArchiveContentDecodesAndReencodesWithoutWireDrift() throws {
        let fixture = Data(Self.legacyJSON.utf8)
        let envelope = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        let legacyContent = try #require(envelope["content"])
        let contentData = try JSONSerialization.data(withJSONObject: legacyContent, options: [.fragmentsAllowed])
        let blocks = try JSONDecoder().decode([VocabularyContentBlock].self, from: contentData)

        #expect(blocks.map { $0.id.uuidString } == [
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000002",
            "00000000-0000-4000-8000-000000000003",
            "00000000-0000-4000-8000-000000000004"
        ])

        guard case let .text(heading) = blocks[0].content else {
            Issue.record("The first legacy block should remain a text block.")
            return
        }
        #expect(heading.text == "A note about 🐈")
        #expect(heading.style == .heading && heading.bold && !heading.italic)

        guard case let .image(firstReference, firstCaption) = blocks[1].content,
              case let .image(secondReference, secondCaption) = blocks[2].content else {
            Issue.record("The two middle legacy blocks should remain image blocks.")
            return
        }
        #expect(firstReference == secondReference)
        #expect(firstCaption == "First angle")
        #expect(secondCaption == "Second angle")
        #expect(firstReference.filename == "lg-image-0123456789abcdef.png")
        #expect(firstReference.width == 640 && firstReference.height == 480 && firstReference.byteCount == 12345)

        let reencodedContent = try JSONEncoder().encode(blocks)
        let legacyContentJSON = try canonicalJSON(from: legacyContent)
        let currentContentJSON = try canonicalJSON(from: JSONSerialization.jsonObject(with: reencodedContent))
        #expect(currentContentJSON == legacyContentJSON)
    }

    @Test func legacyRangesPreserveUTF16OffsetsAcrossUnicodeAndRoundTrip() throws {
        let fixture = Data(Self.legacyJSON.utf8)
        let envelope = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        let legacyRanges = try #require(envelope["ranges"])
        let rangesData = try JSONSerialization.data(withJSONObject: legacyRanges, options: [.fragmentsAllowed])
        let ranges = try JSONDecoder().decode([VocabularyTextRange].self, from: rangesData)

        let source = "I saw 🐈 and café."
        #expect(source.utf16.count == 18)
        #expect(ranges.count == 2)
        #expect(ranges[0].location == 6 && ranges[0].length == 2)
        #expect(ranges[1].location == 13 && ranges[1].length == 4)
        let catRange = try #require(Range(ranges[0].nsRange, in: source))
        let cafeRange = try #require(Range(ranges[1].nsRange, in: source))
        #expect(String(source[catRange]) == "🐈")
        #expect(String(source[cafeRange]) == "café")

        let reencodedRanges = try JSONEncoder().encode(ranges)
        let legacyRangesJSON = try canonicalJSON(from: legacyRanges)
        let currentRangesJSON = try canonicalJSON(from: JSONSerialization.jsonObject(with: reencodedRanges))
        #expect(currentRangesJSON == legacyRangesJSON)
    }

    @Test func preparedImageCarriesItsReferenceAndDraftBytesAcrossTheModuleBoundary() {
        let reference = VocabularyImageReference(digest: "feedface", width: 3, height: 2, byteCount: 5)
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0A])
        let draft = VocabularyPreparedImage(reference: reference, data: bytes)

        #expect(draft.reference == reference)
        #expect(draft.data == bytes)
    }

    private func canonicalJSON(from value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }
}
