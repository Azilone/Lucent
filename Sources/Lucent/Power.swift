import Foundation
import IOKit.ps

/// Watches the power source (battery / AC) and Low Power Mode.
final class PowerMonitor {
    enum Source { case battery, ac }

    /// Called on the main thread whenever the source or Low Power Mode actually changes.
    var onChange: ((_ source: Source, _ lowPower: Bool) -> Void)?
    private(set) var source = PowerMonitor.currentSource
    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var runLoopSource: CFRunLoopSource?

    static var currentSource: Source {
        let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String?
        return type == kIOPMBatteryPowerKey ? .battery : .ac
    }

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let rls = IOPSNotificationCreateRunLoopSource({ ctx in
            Unmanaged<PowerMonitor>.fromOpaque(ctx!).takeUnretainedValue().refresh()
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), rls, .commonModes)
            runLoopSource = rls
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    // IOPS also fires on every battery-percentage change: only report real transitions.
    private func refresh() {
        let s = Self.currentSource, lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard s != source || lpm != lowPower else { return }
        source = s; lowPower = lpm
        DispatchQueue.main.async { self.onChange?(s, lpm) }
    }
}
