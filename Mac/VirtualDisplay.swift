import CoreGraphics
import Foundation

/// A macOS virtual display sized for the iPad. The display disappears when this object is released.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    let displayID: CGDirectDisplayID
    let pointWidth: Int
    let pointHeight: Int

    /// - Parameters: point size of the display; it is created in HiDPI (2x) mode.
    init?(name: String, pointWidth: Int, pointHeight: Int, diagonalInches: Double, serial: UInt32 = 1) {
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.name = name
        desc.maxPixelsWide = UInt32(pointWidth * 2)
        desc.maxPixelsHigh = UInt32(pointHeight * 2)
        let aspect = Double(pointWidth) / Double(pointHeight)
        let heightIn = diagonalInches / (1 + aspect * aspect).squareRoot()
        desc.sizeInMillimeters = CGSize(width: heightIn * aspect * 25.4, height: heightIn * 25.4)
        desc.vendorID = 0x5247 // "RG"
        desc.productID = 0x1D15
        desc.serialNum = serial
        desc.terminationHandler = { _, _ in NSLog("Virtual display terminated by the system") }

        guard let d = CGVirtualDisplay(descriptor: desc) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        // With hiDPI on, macOS offers the mode at half the given pixel size as a Retina mode.
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(pointWidth * 2), height: UInt(pointHeight * 2), refreshRate: 60),
            CGVirtualDisplayMode(width: UInt(pointWidth), height: UInt(pointHeight), refreshRate: 60),
        ]
        guard d.apply(settings) else { return nil }
        display = d
        displayID = d.displayID
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        selectRetinaMode()
    }

    /// Prefer the HiDPI mode whose point size matches the iPad.
    private func selectRetinaMode() {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else { return }
        let match = modes.first {
            $0.width == pointWidth && $0.height == pointHeight && $0.pixelWidth == pointWidth * 2
        }
        if let m = match {
            var cfg: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&cfg)
            CGConfigureDisplayWithDisplayMode(cfg, displayID, m, nil)
            CGCompleteDisplayConfiguration(cfg, .permanently)
        }
    }

    var pixelSize: (Int, Int) {
        guard let m = CGDisplayCopyDisplayMode(displayID) else { return (pointWidth * 2, pointHeight * 2) }
        return (m.pixelWidth, m.pixelHeight)
    }

    /// Current bounds in global (points) coordinates.
    var bounds: CGRect { CGDisplayBounds(displayID) }
}
