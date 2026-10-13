import AppKit

/// Scales the display gamma ramp above 1.0. Only effective while an EDR
/// surface keeps the panel in extended-range mode (see EDROverlay).
enum Brightness {
    static func apply(_ factor: Float, to display: CGDirectDisplayID) {
        CGSetDisplayTransferByFormula(display, 0, factor, 1, 0, factor, 1, 0, factor, 1)
    }

    static func reset() {
        CGDisplayRestoreColorSyncSettings()
    }

    /// Highest value the panel can display relative to SDR white.
    static func headroom(of screen: NSScreen) -> CGFloat {
        screen.maximumPotentialExtendedDynamicRangeColorComponentValue
    }
}
