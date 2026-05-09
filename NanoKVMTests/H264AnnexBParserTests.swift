import XCTest
@testable import NanoKVM

final class H264AnnexBParserTests: XCTestCase {
    func test_parsesThreeByteStartCode() {
        let units = H264AnnexBParser.parseNALUnits(from: Data([0, 0, 1, 0x65, 0x88]))

        XCTAssertEqual(units, [H264NALUnit(type: 5, data: Data([0x65, 0x88]))])
    }

    func test_parsesFourByteStartCode() {
        let units = H264AnnexBParser.parseNALUnits(from: Data([0, 0, 0, 1, 0x41, 0x9A]))

        XCTAssertEqual(units, [H264NALUnit(type: 1, data: Data([0x41, 0x9A]))])
    }

    func test_parsesMultipleNALUnits() {
        let data = Data([0, 0, 0, 1, 0x67, 0x01, 0, 0, 1, 0x68, 0x02, 0, 0, 0, 1, 0x65, 0x03])
        let units = H264AnnexBParser.parseNALUnits(from: data)

        XCTAssertEqual(units.map(\.type), [7, 8, 5])
        XCTAssertEqual(units.map(\.data), [Data([0x67, 0x01]), Data([0x68, 0x02]), Data([0x65, 0x03])])
    }

    func test_detectsSPSAndPPS() {
        let units = H264AnnexBParser.parseNALUnits(from: Data([0, 0, 1, 0x67, 0, 0, 1, 0x68]))

        XCTAssertTrue(units[0].isSPS)
        XCTAssertTrue(units[1].isPPS)
    }

    func test_ignoresLeadingAndTrailingZeroBytes() {
        let units = H264AnnexBParser.parseNALUnits(from: Data([0, 0, 0, 0, 1, 0x65, 0x04, 0, 0]))

        XCTAssertEqual(units, [H264NALUnit(type: 5, data: Data([0x65, 0x04]))])
    }
}
