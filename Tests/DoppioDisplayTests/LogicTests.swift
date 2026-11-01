import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import DoppioDisplay

@Suite("Preview geometry")
struct PreviewGeometryTests {
    static let samples = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.25, y: 0.7), CGPoint(x: 0.9, y: 0.1)]

    @Test("view → content → view is the identity for every rotation, flip and crop",
          arguments: 0..<4, [false, true])
    func roundTrip(turns: Int, flipped: Bool) {
        var geometry = PreviewGeometry(quarterTurns: turns, flipped: flipped)
        geometry.crop = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        for point in Self.samples {
            let back = geometry.viewPoint(fromContent: geometry.contentPoint(fromView: point))
            #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9)
        }
    }

    @Test func quarterTurnSwapsAspect() {
        let size = CGSize(width: 1920, height: 1080)
        #expect(PreviewGeometry().aspect(for: size) == size)
        #expect(PreviewGeometry(quarterTurns: 1).aspect(for: size) == CGSize(width: 1080, height: 1920))
    }

    @Test func clockwiseTurnMapsTopLeftToTopRight() {
        // Rotated 90° clockwise, the content's top-left corner is drawn at the view's top-right.
        let geometry = PreviewGeometry(quarterTurns: 1)
        #expect(geometry.viewPoint(fromContent: .zero) == CGPoint(x: 1, y: 0))
    }

    @Test func nestedCropNarrowsTheVisibleArea() {
        var geometry = PreviewGeometry()
        geometry.cropToViewRect(CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        geometry.cropToViewRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(geometry.crop == CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25))
    }
}

@Suite("Arrangement snapping")
struct SnapTests {
    let builtin = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func snapsToTheRightEdgeAndAlignsTops() {
        let dragged = CGRect(x: 1540, y: 30, width: 1920, height: 1080)
        let snapped = ArrangementMap.snap(dragged, to: [builtin])
        #expect(snapped == CGRect(x: 1512, y: 0, width: 1920, height: 1080))
    }

    @Test func snapsAboveWhenDraggedOverTheTop() {
        let dragged = CGRect(x: 200, y: -1200, width: 1280, height: 720)
        let snapped = try! #require(ArrangementMap.snap(dragged, to: [builtin]))
        #expect(snapped.maxY == builtin.minY)
        #expect(!snapped.insetBy(dx: 1, dy: 1).intersects(builtin))
    }

    @Test func neverOverlapsAnotherDisplay() {
        let right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        for x in stride(from: -2000.0, through: 3500, by: 250) {
            let dragged = CGRect(x: x, y: 100, width: 1280, height: 720)
            if let snapped = ArrangementMap.snap(dragged, to: [builtin, right]) {
                #expect(!snapped.insetBy(dx: 1, dy: 1).intersects(builtin))
                #expect(!snapped.insetBy(dx: 1, dy: 1).intersects(right))
            }
        }
    }
}

@Suite("Saved settings")
struct DecodingTests {
    @Test func configFromVersion02DecodesWithDefaults() throws {
        // Written by VDisplay 0.2, before placement, position and keep-awake existed.
        let json = #"""
        [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"Virtual 1","width":1920,"height":1080,
          "hiDPI":false,"refreshRate":60,"isEnabled":true,"mirrorTargets":[]}]
        """#
        let configs = try JSONDecoder().decode([VirtualDisplayConfig].self, from: Data(json.utf8))
        #expect(configs.count == 1)
        #expect(configs[0].placement == .automatic)
        #expect(configs[0].relativeOrigin == nil)
        #expect(configs[0].keepAwake == .never)
        #expect(configs[0].hiDPI == false)
    }

    @Test func serialIsStableAndNonZero() {
        let config = VirtualDisplayConfig(name: "A", width: 1920, height: 1080)
        #expect(config.serial == config.serial)
        #expect(config.serial != 0)
    }

    @Test func onlyModeFieldsChangeTheMode() {
        let base = VirtualDisplayConfig(name: "A", width: 1920, height: 1080)
        var renamed = base
        renamed.name = "B"
        renamed.keepAwake = .whileOn
        #expect(!renamed.needsModeChange(comparedTo: base))
        var resized = base
        resized.width = 2560
        #expect(resized.needsModeChange(comparedTo: base))
    }

    @Test func profileWithoutTriggerIsManual() throws {
        let json = #"""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3302","name":"Desk","displays":[],"brightness":{"1-2-3":0.5}}
        """#
        let profile = try JSONDecoder().decode(DisplayProfile.self, from: Data(json.utf8))
        #expect(profile.trigger == .manual)
    }

    @Test(arguments: [ProfileTrigger.manual, .anyExternal, .noExternal, .connected(key: "1-2-3", name: "LG")])
    func triggerRoundTrips(trigger: ProfileTrigger) throws {
        let data = try JSONEncoder().encode(trigger)
        #expect(try JSONDecoder().decode(ProfileTrigger.self, from: data) == trigger)
    }
}

@Suite("Small helpers")
struct HelperTests {
    @Test func refreshRateTitles() {
        #expect(DisplayModes.rateTitle(60) == "60 Hz")
        #expect(DisplayModes.rateTitle(59.94) == "59.94 Hz")
        #expect(DisplayModes.rateTitle(47.952) == "47.95 Hz")
        #expect(DisplayModes.rateTitle(120, builtin: true) == "ProMotion")
        #expect(DisplayModes.rateTitle(120) == "120 Hz")
        #expect(DisplayModes.rateTitle(0) == "Default")
    }

    @Test func ddcChecksumIsXor() {
        // VCP read request for brightness to the display at 0x37 (0x6E on the wire).
        let packet: [UInt8] = [0x81, 0x01, 0x10]
        #expect(DDCService.checksum(0x6E, packet[...]) == 0x6E ^ 0x81 ^ 0x01 ^ 0x10)
    }

    @Test func colorCanBeParsedFromHex() {
        let color = NSColor(hex: "#1E9CFF")
        #expect(abs(color.redComponent - 30.0 / 255) < 0.001)
        #expect(abs(color.blueComponent - 1) < 0.001)
    }
}
