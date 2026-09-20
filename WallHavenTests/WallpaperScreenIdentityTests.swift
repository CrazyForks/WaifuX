import XCTest
import CoreGraphics
@testable import WaifuX

final class WallpaperScreenIdentityTests: XCTestCase {
    func testNativePipelineRecoveryIsForcedAfterDisplayWake() {
        XCTAssertTrue(
            VideoWallpaperDisplayRecoveryPolicy.shouldRebuildNativePipeline(
                afterDisplayWake: true,
                displayConfigurationChanged: false,
                externalRenderingActive: false
            )
        )
    }

    func testNativePipelineRecoveryIsForcedWhenDisplayConfigurationChanges() {
        XCTAssertTrue(
            VideoWallpaperDisplayRecoveryPolicy.shouldRebuildNativePipeline(
                afterDisplayWake: false,
                displayConfigurationChanged: true,
                externalRenderingActive: false
            )
        )
    }

    func testExternalRendererDoesNotUseNativeRecoveryPolicy() {
        XCTAssertFalse(
            VideoWallpaperDisplayRecoveryPolicy.shouldRebuildNativePipeline(
                afterDisplayWake: true,
                displayConfigurationChanged: true,
                externalRenderingActive: true
            )
        )
    }

    func testFingerprintWithHardwareSerialIgnoresPosition() {
        let fp = WallpaperScreenIdentity.fingerprint(
            legacyFingerprint: "cg:1:2:12345:external",
            hasHardwareSerial: true,
            position: CGPoint(x: 100, y: 0)
        )
        XCTAssertEqual(fp, "cg:1:2:12345:external")
    }

    func testFingerprintWithoutSerialIncludesPosition() {
        let left = WallpaperScreenIdentity.fingerprint(
            legacyFingerprint: "cg:1:2:noserial:Dell:external",
            hasHardwareSerial: false,
            position: CGPoint(x: -1920, y: 0)
        )
        let right = WallpaperScreenIdentity.fingerprint(
            legacyFingerprint: "cg:1:2:noserial:Dell:external",
            hasHardwareSerial: false,
            position: CGPoint(x: 1920, y: 0)
        )
        XCTAssertEqual(left, "cg:1:2:noserial:Dell:external:position:-1920x0")
        XCTAssertEqual(right, "cg:1:2:noserial:Dell:external:position:1920x0")
        XCTAssertNotEqual(left, right)
    }

    func testFingerprintPositionIsRounded() {
        let fp = WallpaperScreenIdentity.fingerprint(
            legacyFingerprint: "legacy",
            hasHardwareSerial: false,
            position: CGPoint(x: 100.6, y: -0.4)
        )
        XCTAssertEqual(fp, "legacy:position:101x0")
    }

    func testPositionTolerantFingerprintMatch() {
        let old = "cg:1:2:noserial:Dell:external:position:-1920x0"
        let moved = "cg:1:2:noserial:Dell:external:position:0x0"

        XCTAssertTrue(WallpaperScreenIdentity.fingerprintsMatch(old, moved))
        XCTAssertEqual(
            WallpaperScreenIdentity.stableFingerprintPart(old),
            "cg:1:2:noserial:Dell:external"
        )
    }

    func testFingerprintValueResolutionRequiresUniqueCandidate() {
        let values = [
            "cg:1:2:noserial:Dell:external:position:-1920x0": "left",
            "cg:1:2:noserial:Dell:external:position:1920x0": "right"
        ]

        XCTAssertNil(
            WallpaperScreenIdentity.value(
                in: values,
                forFingerprint: "cg:1:2:noserial:Dell:external:position:0x0"
            )
        )
        XCTAssertEqual(
            WallpaperScreenIdentity.value(
                in: ["old:position:0x0": "wallpaper"],
                forFingerprint: "old:position:1920x0"
            ),
            "wallpaper"
        )
    }

    func testFingerprintPositionParsing() {
        let withPosition = WallpaperScreenIdentity.position(
            fromFingerprint: "cg:1:2:noserial:Dell:external:position:-1920x0"
        )
        XCTAssertEqual(withPosition, CGPoint(x: -1920, y: 0))
        // 有序列号 / 旧版短指纹没有 position 后缀
        XCTAssertNil(WallpaperScreenIdentity.position(fromFingerprint: "cg:1:2:12345:external"))
        XCTAssertNil(WallpaperScreenIdentity.position(fromFingerprint: "cg:1:2:noserial:Dell:2560x1440:external"))
        // 残缺后缀按无坐标处理
        XCTAssertNil(WallpaperScreenIdentity.position(fromFingerprint: "legacy:position:abc"))
    }

    /// 复现用户反馈的核心场景：唤醒/重启后主屏锚点变化，两块同型号屏的
    /// 绝对原点整体平移。绝对坐标相等会把 A 的旧指纹精确命中到 B 上
    /// （配置互换）；按组内相对次序配对必须保持 A→A、B→B。
    func testPairByRelativeRankSurvivesMainDisplayAnchorShift() {
        let orphans: [(id: String, position: CGPoint?)] = [
            (id: "old-A", position: CGPoint(x: 0, y: 0)),      // A 原来在左（主屏锚点 0,0）
            (id: "old-B", position: CGPoint(x: 2560, y: 0))    // B 原来在右
        ]
        // 重启后主屏换成 B：B 现在在 0,0，A 被整体平移到 -2560
        let screens: [(id: String, position: CGPoint)] = [
            (id: "new-B", position: CGPoint(x: 0, y: 0)),
            (id: "new-A", position: CGPoint(x: -2560, y: 0))
        ]

        let pairs = WallpaperScreenIdentity.pairByRelativeRank(orphans: orphans, screens: screens)

        XCTAssertEqual(pairs["old-A"], "new-A")
        XCTAssertEqual(pairs["old-B"], "new-B")
    }

    func testPairByRelativeRankMatchesSpatialOrderWhenAnchorStable() {
        let orphans: [(id: String, position: CGPoint?)] = [
            (id: "old-A", position: CGPoint(x: 0, y: 0)),
            (id: "old-B", position: CGPoint(x: 2560, y: 0))
        ]
        let screens: [(id: String, position: CGPoint)] = [
            (id: "new-A", position: CGPoint(x: 0, y: 0)),
            (id: "new-B", position: CGPoint(x: 2560, y: 0))
        ]

        let pairs = WallpaperScreenIdentity.pairByRelativeRank(orphans: orphans, screens: screens)

        XCTAssertEqual(pairs["old-A"], "new-A")
        XCTAssertEqual(pairs["old-B"], "new-B")
    }

    func testPairByRelativeRankOrdersVerticallyStackedScreensByY() {
        // AppKit y 向上：maxY 更大的屏排在前面
        let orphans: [(id: String, position: CGPoint?)] = [
            (id: "old-top", position: CGPoint(x: 0, y: 0)),
            (id: "old-bottom", position: CGPoint(x: 0, y: -1440))
        ]
        let screens: [(id: String, position: CGPoint)] = [
            (id: "new-top", position: CGPoint(x: 0, y: 0)),
            (id: "new-bottom", position: CGPoint(x: 0, y: -1440))
        ]

        let pairs = WallpaperScreenIdentity.pairByRelativeRank(orphans: orphans, screens: screens)

        XCTAssertEqual(pairs["old-top"], "new-top")
        XCTAssertEqual(pairs["old-bottom"], "new-bottom")
    }

    func testPairByRelativeRankTailsOrphansWithoutPosition() {
        // 旧版短指纹没有 position：排在有坐标 orphan 之后，按空间序兜底
        let orphans: [(id: String, position: CGPoint?)] = [
            (id: "old-legacy", position: nil),
            (id: "old-A", position: CGPoint(x: 0, y: 0))
        ]
        let screens: [(id: String, position: CGPoint)] = [
            (id: "new-A", position: CGPoint(x: 0, y: 0)),
            (id: "new-B", position: CGPoint(x: 2560, y: 0))
        ]

        let pairs = WallpaperScreenIdentity.pairByRelativeRank(orphans: orphans, screens: screens)

        XCTAssertEqual(pairs["old-A"], "new-A")
        XCTAssertEqual(pairs["old-legacy"], "new-B")
    }

    func testPairByRelativeRankIgnoresSurplusScreens() {
        let orphans: [(id: String, position: CGPoint?)] = [
            (id: "old-A", position: CGPoint(x: 0, y: 0))
        ]
        let screens: [(id: String, position: CGPoint)] = [
            (id: "new-A", position: CGPoint(x: 0, y: 0)),
            (id: "new-B", position: CGPoint(x: 2560, y: 0))
        ]

        let pairs = WallpaperScreenIdentity.pairByRelativeRank(orphans: orphans, screens: screens)

        XCTAssertEqual(pairs["old-A"], "new-A")
        XCTAssertEqual(pairs.count, 1)
    }
}
