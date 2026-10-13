import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let overlay = EDROverlay()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var valueLabel: NSTextField!
    private var slider: NSSlider!

    static let minFactor: Double = 1.0
    static let maxFactor: Double = 1.6

    private var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var factor: Double {
        get { defaults.object(forKey: "factor") as? Double ?? 1.5 }
        set { defaults.set(newValue, forKey: "factor") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        wnc.addObserver(self, selector: #selector(refresh), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.hide()
        Brightness.reset()
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Activer XDR", action: #selector(toggle), keyEquivalent: "")
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
        if enabled { refresh() } else { updateUI() }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("Login item: \(error)") }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: State

    @objc private func refresh() {
        defer { updateUI() }
        guard enabled else { overlay.hide(); Brightness.reset(); return }

        let xdr = NSScreen.screens.filter { Brightness.headroom(of: $0) > 1.0 }
        guard let main = xdr.first(where: { $0 == NSScreen.main }) ?? xdr.first else {
            overlay.hide(); Brightness.reset(); return
        }
        overlay.show(on: main)
        for screen in xdr {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            Brightness.apply(Float(min(factor, Double(Brightness.headroom(of: screen)))), to: id)
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
