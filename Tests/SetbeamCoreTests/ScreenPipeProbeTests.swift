import CoreMedia
import VideoToolbox
import XCTest
@testable import SetbeamCore

/// Full-range random 4K detail made VideoToolbox emit an 11.6 MB keyframe. VideoPipeWriter and
/// MediaMTX each refuse pictures above 8 MiB, so the screen source restarted without a picture.
final class ScreenPipeProbeTests: XCTestCase {
    private final class Units: @unchecked Sendable { var data: [Data] = [] }

    private func randomFrame(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(image, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(image, plane) { arc4random_buf(base.advanced(by: row * stride), width) }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        return image
    }

    func testExtreme4KDetailStaysWithinThePipeAndRelayLimitsAndDecodes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = ProcessInfo.processInfo.environment["SETBEAM_TEST_TOOLS"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Vendor/bin")
        let ffmpeg = tools.appendingPathComponent("ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw XCTSkip("Bundled media tools are required for the screen pipe check.") }
        let queue = DispatchQueue(label: "test.screen-encoder")
        let units = Units()
        let encoder = try ScreenEncoder(width: 3840, height: 2160, fps: 60, queue: queue) { units.data.append($0) }
        let image = try randomFrame(width: 3840, height: 2160)
        let start = Date()
        for frame in 0..<120 {
            queue.sync { encoder.encode(image) }
            Thread.sleep(until: start.addingTimeInterval(Double(frame + 1) / 60))
        }
        encoder.flush(); queue.sync {}
        queue.sync { encoder.invalidate() }

        let largest = try XCTUnwrap(units.data.map(\.count).max())
        XCTAssertLessThanOrEqual(largest, 6 * 1024 * 1024, "VideoPipeWriter and MediaMTX each refuse pictures above 8 MiB")
        XCTAssertEqual(units.data.first.map { $0[4] & 0x1f }, 7, "The first picture must carry its parameter sets")

        let input = Pipe(), errors = Pipe()
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error"] + MediaRuntime.screenInputArguments(frameRate: 60) + ["-f", "null", "-"]
        process.standardInput = input; process.standardError = errors; process.standardOutput = FileHandle.nullDevice
        try process.run()
        for unit in units.data { try input.fileHandleForWriting.write(contentsOf: unit) }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, message)
        XCTAssertFalse(message.contains("[h264"), "Withheld pictures must not leave dependent pictures: \(message.prefix(400))")
        XCTAssertGreaterThan(units.data.count, 30)
    }
}

final class KeyframeBudgetTests: XCTestCase {
    func testOversizedPicturesRaiseTheFloorAndWithholdDependentsUntilAKeyframeFits() {
        var budget = KeyframeBudget()
        let large = KeyframeBudget.limit + 1
        XCTAssertEqual(budget.observe(bytes: 1_000_000, keyframe: true), .send)
        XCTAssertEqual(budget.observe(bytes: large, keyframe: true), .restart(minimumQP: 20, sending: false))
        XCTAssertEqual(budget.observe(bytes: 10_000, keyframe: false), .withhold)
        XCTAssertEqual(budget.observe(bytes: large, keyframe: true), .restart(minimumQP: 26, sending: false))
        XCTAssertEqual(budget.observe(bytes: 5_000_000, keyframe: true), .send)
        XCTAssertEqual(budget.observe(bytes: 10_000, keyframe: false), .send)
        XCTAssertEqual(budget.minimumQP, 26)
        // A scene change can make a P picture oversized too.
        XCTAssertEqual(budget.observe(bytes: large, keyframe: false), .restart(minimumQP: 32, sending: false))
        for _ in 0..<10 { _ = budget.observe(bytes: large, keyframe: true) }
        XCTAssertEqual(budget.minimumQP, KeyframeBudget.highestFloor)
    }
    func testTheFloorStepsDownOnlyWhenTheLowerFloorLeavesRoom() {
        var budget = KeyframeBudget()
        _ = budget.observe(bytes: KeyframeBudget.limit + 1, keyframe: true)
        _ = budget.observe(bytes: KeyframeBudget.limit + 1, keyframe: true)
        XCTAssertEqual(budget.minimumQP, 26)
        XCTAssertEqual(budget.observe(bytes: KeyframeBudget.limit / 2 + 1, keyframe: true), .send)
        XCTAssertEqual(budget.observe(bytes: KeyframeBudget.limit / 2, keyframe: false), .send)
        XCTAssertEqual(budget.observe(bytes: KeyframeBudget.limit / 2, keyframe: true), .restart(minimumQP: 20, sending: true))
        XCTAssertEqual(budget.observe(bytes: 1_000_000, keyframe: true), .restart(minimumQP: nil, sending: true))
        XCTAssertEqual(budget.observe(bytes: 1_000_000, keyframe: true), .send)
        XCTAssertNil(budget.minimumQP)
    }
}
