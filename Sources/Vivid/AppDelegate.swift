import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let overlay = EDROverlay()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var valueLabel: NSTextField!
    private var slider: NSSlider!
    private var hotKey: EventHotKeyRef?

    static let minFactor: Double = 1.0
    static let maxFactor: Double = 1.6

    private var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var factor: Double {
        get { defaults.object(forKey: "factor") as? Double ?? 1.2 }
        set { defaults.set(newValue, forKey: "factor") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(restart), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(restart), name: NSWorkspace.didWakeNotification, object: nil)
        registerHotKey()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.stop()
    }

    /// ⌃⌥⌘V toggles the boost from anywhere (no Accessibility permission needed).
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x5649_5644), id: 1) // 'VIVD'
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Activer XDR  (⌃⌥⌘V)", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 44))
        valueLabel = NSTextField(labelWithString: "")
        valueLabel.frame = NSRect(x: 16, y: 24, width: 188, height: 16)
        valueLabel.font = .menuFont(ofSize: 12)
        slider = NSSlider(value: factor, minValue: Self.minFactor, maxValue: Self.maxFactor,
                          target: self, action: #selector(sliderChanged))
        slider.frame = NSRect(x: 16, y: 4, width: 188, height: 18)
        slider.isContinuous = true
        box.addSubview(valueLabel); box.addSubview(slider)
        let sliderItem = NSMenuItem(); sliderItem.view = box
        menu.addItem(sliderItem)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Lancer au démarrage", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter Vivid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggle() { enabled.toggle(); refresh() }

    @objc private func sliderChanged() {
        factor = (slider.doubleValue * 20).rounded() / 20
        overlay.factor = Float(factor)
        updateUI()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("Login item: \(error)") }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: State

    private var xdrScreen: (NSScreen, CGDirectDisplayID)? {
        NSScreen.screens
            .filter { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
            .sorted { a, _ in a == NSScreen.main }
            .compactMap { s in (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { (s, $0) } }
            .first
    }

    @objc private func restart() { overlay.stop(); refresh() }

    private func refresh() {
        updateUI()
        guard enabled, let (screen, id) = xdrScreen else { overlay.stop(); return }
        overlay.factor = Float(min(factor, Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)))
        guard overlay.displayID != id else { return }

        guard CGPreflightScreenCaptureAccess() else {
            enabled = false; updateUI()
            CGRequestScreenCaptureAccess()
            let alert = NSAlert()
            alert.messageText = "Autorisation requise"
            alert.informativeText = "Active Vivid dans Réglages Système › Confidentialité et sécurité › Enregistrement de l'écran, puis relance Vivid."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        Task { @MainActor in
            do {
                try await overlay.start(on: screen, displayID: id)
                if ProcessInfo.processInfo.environment["VIVID_TEST_STALL"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Thread.sleep(forTimeInterval: 5) }
                }
            }
            catch { NSLog("Vivid: start failed: \(error)"); overlay.stop() }
        }
    }

    private func updateUI() {
        toggleItem.state = enabled ? .on : .off
        slider.doubleValue = factor
        slider.isEnabled = enabled
        valueLabel.stringValue = String(format: "Luminosité ×%.2f", factor)
        let name = enabled ? "sun.max.fill" : "sun.max"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Vivid")
    }
}
