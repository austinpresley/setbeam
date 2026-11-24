import CoreVideo
import ImageIO
import XCTest
@testable import SetbeamApp

final class LocalFrameExportTests: XCTestCase {
    func testExportCorrectsAnamorphicPixelsAndPreservesPreviousFileOnFailure() throws {
        let packet = PreviewPacket(kind: .video, flags: 0, timestamp: 0, duration: 33_333,
            width: 320, height: 240, channels: 0, sampleRate: 0, aspectNumerator: 4, aspectDenominator: 3, matrix: 1,
            payload: Data(repeating: 128, count: 320 * 240 * 3 / 2))
        let picture = try XCTUnwrap(PreviewPicturePool().makePicture(packet))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("Frame.jpg")
        try Data("existing file".utf8).write(to: destination)
        try LocalFrameExport.save(picture, to: destination)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 427)
        XCTAssertEqual(image.height, 240)

        let saved = try Data(contentsOf: destination)
        let invalid = PreviewPicture(pixelBuffer: picture.pixelBuffer, size: .zero)
        XCTAssertThrowsError(try LocalFrameExport.save(invalid, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), saved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Frame.jpg"])
    }
}
