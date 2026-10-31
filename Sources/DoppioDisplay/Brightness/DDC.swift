import CoreGraphics
import Foundation
import IOKit

/// DDC/CI over the Apple Silicon IOAVService I2C bridge.
/// Protocol details and service matching follow MonitorControl's Arm64DDC (MIT).
/// The built-in HDMI port on M1/M1 Pro Macs does not pass DDC; USB-C/Thunderbolt does.
final class DDCService: @unchecked Sendable {
    enum VCP: UInt8 {
        case brightness = 0x10
        case contrast = 0x12
        case inputSource = 0x60
        case volume = 0x62
        case mute = 0x8D
    }

    /// Common MCCS input source values; monitors vary, so unknown values show as numbers.
    static let inputNames: [UInt16: String] = [
        0x01: "VGA 1", 0x02: "VGA 2", 0x03: "DVI 1", 0x04: "DVI 2",
        0x0F: "DisplayPort 1", 0x10: "DisplayPort 2", 0x11: "HDMI 1", 0x12: "HDMI 2", 0x1B: "USB-C",
    ]

    private static let address: UInt32 = 0x37
    private static let dataAddress: UInt8 = 0x51

    private let service: CFTypeRef

    private init(service: CFTypeRef) {
        self.service = service
    }

    /// Reads current and maximum value of a VCP code. Slow (~100 ms); call off the main thread.
    func read(_ code: VCP) -> (current: UInt16, max: UInt16)? {
        var reply = [UInt8](repeating: 0, count: 11)
        guard communicate(send: [code.rawValue], reply: &reply) else { return nil }
        let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return max > 0 ? (current, max) : nil
    }

    @discardableResult
    func write(_ code: VCP, _ value: UInt16) -> Bool {
        var reply: [UInt8] = []
        return communicate(send: [code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)], reply: &reply)
    }

    private func communicate(send: [UInt8], reply: inout [UInt8], attempts: Int = 3) -> Bool {
        guard let writeI2C = PrivateDisplayAPI.avServiceWriteI2C, let readI2C = PrivateDisplayAPI.avServiceReadI2C else {
            return false
        }
        var packet = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        let seed = send.count == 1 ? UInt8(Self.address << 1) : UInt8(Self.address << 1) ^ Self.dataAddress
        packet[packet.count - 1] = Self.checksum(seed, packet[0..<(packet.count - 1)])

        for _ in 0..<attempts {
            usleep(10_000)
            var success = packet.withUnsafeMutableBytes { buffer in
                writeI2C(service, Self.address, UInt32(Self.dataAddress), buffer.baseAddress!, UInt32(buffer.count)) == kIOReturnSuccess
            }
            if success, !reply.isEmpty {
                usleep(50_000)
                let count = reply.count
                success = reply.withUnsafeMutableBytes { buffer in
                    readI2C(service, Self.address, 0, buffer.baseAddress!, UInt32(count)) == kIOReturnSuccess
                } && Self.checksum(0x50, reply[0..<(count - 1)]) == reply[count - 1]
            }
            if success { return true }
            usleep(20_000)
        }
        return false
    }

    private static func checksum(_ seed: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    // MARK: Matching CGDirectDisplayID to an IOAVService

    private struct Candidate {
        let framebufferPath: String
        let productName: String
        let service: CFTypeRef
    }

    /// Walks the IOService plane: each external `DCPAVServiceProxy` follows the
    /// framebuffer (`AppleCLCD2` / `IOMobileFramebufferShim`) it belongs to.
    static func services(for displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDCService] {
        guard let create = PrivateDisplayAPI.avServiceCreate else { return [:] }
        var candidates: [Candidate] = []
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var framebufferPath = ""
        var productName = ""
        let name = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        let path = UnsafeMutablePointer<CChar>.allocate(capacity: 512)
        defer {
            name.deallocate()
            path.deallocate()
        }
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, name) == KERN_SUCCESS else { continue }
            let entryName = String(cString: name)
            if entryName == "AppleCLCD2" || entryName == "IOMobileFramebufferShim" {
                framebufferPath = IORegistryEntryGetPath(entry, kIOServicePlane, path) == KERN_SUCCESS ? String(cString: path) : ""
                let attributes = property(entry, "DisplayAttributes") as? [String: Any]
                productName = (attributes?["ProductAttributes"] as? [String: Any])?["ProductName"] as? String ?? ""
            } else if entryName == "DCPAVServiceProxy",
                      property(entry, "Location") as? String == "External",
                      let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                candidates.append(Candidate(framebufferPath: framebufferPath, productName: productName, service: service))
            }
        }

        var result: [CGDirectDisplayID: DDCService] = [:]
        var unmatched = displays
        // 1. Exact framebuffer location, 2. product name, 3. a single leftover pair.
        for display in displays {
            guard let info = PrivateDisplayAPI.infoDictionary(display) else { continue }
            let location = info["IODisplayLocation"] as? String
            let names = info["DisplayProductName"] as? [String: String]
            let displayName = (names?["en_US"] ?? names?.values.first)?.lowercased()
            let index = candidates.firstIndex { $0.framebufferPath == location && location != nil }
                ?? candidates.firstIndex { !$0.productName.isEmpty && $0.productName.lowercased() == displayName }
            if let index {
                result[display] = DDCService(service: candidates.remove(at: index).service)
                unmatched.removeAll { $0 == display }
            }
        }
        if unmatched.count == 1, candidates.count == 1 {
            result[unmatched[0]] = DDCService(service: candidates[0].service)
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively))?.takeRetainedValue()
    }
}
