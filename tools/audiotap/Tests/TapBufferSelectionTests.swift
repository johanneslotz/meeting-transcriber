@testable import AudioTapLib
import XCTest

final class TapBufferSelectionTests: XCTestCase {
    func testALoneBufferIsTheTap() {
        XCTAssertEqual(TapBufferSelection.tapBufferIndex(bufferCount: 1), 0)
    }

    /// A sub-device with input streams (a USB headset with one UID for both
    /// directions) comes first; reading buffer 0 recorded its microphone as app
    /// audio.
    func testTheTapIsAfterTheSubDeviceInputs() {
        XCTAssertEqual(TapBufferSelection.tapBufferIndex(bufferCount: 2), 1)
        XCTAssertEqual(TapBufferSelection.tapBufferIndex(bufferCount: 3), 2)
    }

    func testNoBuffersMeansNoTap() {
        XCTAssertNil(TapBufferSelection.tapBufferIndex(bufferCount: 0))
    }
}
