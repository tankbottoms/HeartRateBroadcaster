import XCTest
import SwiftUI

/// Phase 0 smoke test — proves the test target links `Shared/` and runs.
/// `HeartRateFrameTests` is the one that matters.
final class ThemeSmokeTests: XCTestCase {

    func testHexInitializerUnpacksChannelsInOrder() throws {
        // 0x34C759 is the spec's "active" green. A red/blue channel swap is the
        // classic bug here and would still produce a plausible-looking colour.
        let resolved = Color(hex: 0x34C759).resolve(in: EnvironmentValues())
        XCTAssertEqual(Double(resolved.red),   52 / 255, accuracy: 0.01)
        XCTAssertEqual(Double(resolved.green), 199 / 255, accuracy: 0.01)
        XCTAssertEqual(Double(resolved.blue),   89 / 255, accuracy: 0.01)
    }

    func testWatchFlagIsFalseOnIOSTestTarget() {
        XCTAssertFalse(Theme.isWatch)
    }
}
