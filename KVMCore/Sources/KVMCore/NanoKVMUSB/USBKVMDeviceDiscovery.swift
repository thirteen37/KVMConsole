#if os(macOS)
@preconcurrency import AVFoundation
import Foundation
import IOKit
import IOKit.serial

public struct USBSerialPort: Hashable, Sendable {
    public let path: String
    public let displayName: String
}

@MainActor
public enum USBKVMDeviceDiscovery {
    /// Returns USB-attached UVC capture devices (cameras). On macOS 15+ all external
    /// cameras report as `.external`.
    public static func videoDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    /// Returns USB-CDC serial ports suitable for the NanoKVM-USB's CH9329 bridge.
    /// Uses IOKit's service registry so we get the vendor/product display name even
    /// when running under the app sandbox.
    public static func serialPorts() -> [USBSerialPort] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        // Restrict to /dev/cu.* nodes (callout devices, the right side for outbound serial).
        let dict = matching as NSMutableDictionary
        dict[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var ports: [USBSerialPort] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = stringProperty(service, key: kIOCalloutDeviceKey) else { continue }
            guard isLikelyUSBSerial(path: path) else { continue }
            let productName = usbProductName(for: service)
            let displayName = productName.map { "\($0) (\((path as NSString).lastPathComponent))" }
                ?? (path as NSString).lastPathComponent
            ports.append(USBSerialPort(path: path, displayName: displayName))
        }

        return ports.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func isLikelyUSBSerial(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("cu.usbserial")
            || name.hasPrefix("cu.usbmodem")
            || name.hasPrefix("cu.wchusbserial")
            || name.hasPrefix("cu.SLAB_USBtoUART")
    }

    private static func stringProperty(_ service: io_object_t, key: String) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        return raw.takeRetainedValue() as? String
    }

    /// Walks up the IOKit parent chain until we hit a USB device node, then returns
    /// its product/vendor name if available.
    private static func usbProductName(for service: io_object_t) -> String? {
        var current: io_registry_entry_t = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<8 {
            if let name = stringProperty(current, key: "USB Product Name") { return name }
            if let name = stringProperty(current, key: "USB Vendor Name") { return name }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                return nil
            }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }
}
#endif
