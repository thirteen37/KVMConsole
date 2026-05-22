import XCTest
import CoreMedia
import CoreVideo
@testable import KVMCore

final class RFBFramebufferTests: XCTestCase {
    func test_applyRawWritesBGRABytesIntoFramebuffer() throws {
        let framebuffer = RFBFramebuffer()
        try framebuffer.resize(width: 2, height: 2)

        let rect = RFBRectangle(x: 0, y: 0, width: 2, height: 2, encoding: RFBEncoding.raw.rawValue)
        let pixels = Data([
            1, 2, 3, 4, 5, 6, 7, 8,
            9, 10, 11, 12, 13, 14, 15, 16,
        ])
        try framebuffer.applyRaw(rect: rect, bytes: pixels)

        XCTAssertEqual(try framebuffer.pixelBytes(), pixels)
    }

    func test_applyCopyRectCopiesOverlappingRegions() throws {
        let framebuffer = RFBFramebuffer()
        try framebuffer.resize(width: 3, height: 1)
        try framebuffer.applyRaw(
            rect: RFBRectangle(x: 0, y: 0, width: 3, height: 1, encoding: RFBEncoding.raw.rawValue),
            bytes: Data([
                1, 1, 1, 255,
                2, 2, 2, 255,
                3, 3, 3, 255,
            ])
        )

        try framebuffer.applyCopyRect(
            rect: RFBRectangle(x: 1, y: 0, width: 2, height: 1, encoding: RFBEncoding.copyRect.rawValue),
            sourceX: 0,
            sourceY: 0
        )

        XCTAssertEqual(
            try framebuffer.pixelBytes(),
            Data([
                1, 1, 1, 255,
                1, 1, 1, 255,
                2, 2, 2, 255,
            ])
        )
    }

    func test_makeSampleBufferExposesImageBufferSize() throws {
        let framebuffer = RFBFramebuffer()
        try framebuffer.resize(width: 4, height: 3)

        let sampleBuffer = try framebuffer.makeSampleBuffer()
        let imageBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sampleBuffer))

        XCTAssertEqual(CVPixelBufferGetWidth(imageBuffer), 4)
        XCTAssertEqual(CVPixelBufferGetHeight(imageBuffer), 3)
    }
}
