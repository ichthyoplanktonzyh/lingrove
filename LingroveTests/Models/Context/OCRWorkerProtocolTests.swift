import Foundation
import Testing
@testable import Lingrove

/// These guards sit before native buffer allocation and IPC reads. Extreme metadata must be
/// rejected with no multiplication overflow or allocation, including corrupt helper frames.
struct OCRWorkerProtocolTests {
    @Test(arguments: [(0, 4), (4, 0), (-1, 4), (Int.max, 4), (4, Int.max), (Int.max, Int.max)])
    func invalidDimensionsCannotProduceAnAllocation(width: Int, height: Int) {
        let request = OCRWorkerRequest(id: "test", width: width, height: height, maximumCharacters: 100,
            capturesWordBounds: false, minimumTextHeight: 0.008, detectsLanguageAutomatically: false)
        #expect(request.imageByteCount == nil)
    }

    @Test func versionAndOptionsAreValidatedBeforeAllocation() {
        var request = OCRWorkerRequest(id: "test", width: 4, height: 4, maximumCharacters: 100,
            capturesWordBounds: false, minimumTextHeight: 0.008, detectsLanguageAutomatically: false)
        #expect(request.imageByteCount == 64)
        request.version = -1
        #expect(request.imageByteCount == nil)
    }

    @Test(arguments: [1, 255, 65_536, OCRWorkerProtocol.maximumResponseBytes])
    func frameLengthsUseNetworkByteOrder(count: Int) {
        let bytes = OCRWorkerProtocol.lengthPrefix(count)
        #expect(bytes.count == 4)
        #expect(OCRWorkerProtocol.length(in: bytes) == count)
    }
}
