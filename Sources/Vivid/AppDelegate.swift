import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let booster = Booster()
    private let keys = BrightnessKeys()
    private let hud = HUD()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var accessItem: NSMenuItem!
    private var valueLabel: NSTextField!
    private var slider: NSSlider!
    private var hotKey: EventHotKeyRef?
    private var poll: Timer?

    private let step: Double = 50
    private var sdrNits: Double { Booster.sdrNits }
    private var maxNits: Double { defaults.object(forKey: "maxNits") as? Double ?? 1000 }

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    /// Target brightness when boosted; 500 = native maximum, no boost.
    private var nits: Double {
        get { defaults.object(forKey: "nits") as? Double ?? Booster.sdrNits }
        set { defaults.set(newValue, forKey: "nits") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.removeObject(forKey: "factor")
        defaults.removeObject(forKey: "lastEmergency")
        buildMenu()
        registerHotKey()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensChanged),
                                                          name: NSWorkspace.didWakeNotification, object: nil)

        keys.handler = { [weak self] key, fine in self?.handle(key, fine: fine) ?? false }
        if BrightnessKeys.isTrusted { keys.start() } else { BrightnessKeys.requestTrust() }

        booster.attach()
        if !atNativeMax { nits = sdrNits }
        applyState(animated: false)

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    func applicationWillTerminate(_ notification: Notification) {
        booster.detach()
    }

    // MARK: Brightness logic

    private var atNativeMax: Bool {
        guard let id = booster.displayID, let v = NativeBrightness.value(id) else { return false }
        return v >= 0.995
    }

    /// One continuous scale driven by the brightness keys: the native range (0–500 nits),
    /// then the XDR boost (500–1000). The keys are swallowed so only our HUD shows.
    private func handle(_ key: BrightnessKeys.Key, fine: Bool) -> Bool {
        guard enabled, let id = booster.displayID, let b = NativeBrightness.value(id) else { return false }
        let nativeStep: Float = fine ? 1.0 / 64 : 1.0 / 16
        let boostStep = fine ? step / 4 : step
        let grid = (b / nativeStep).rounded()
        var native = b
        switch key {
        case .up:
            if b < 0.995 { native = min(1, (grid + 1) * nativeStep); NativeBrightness.set(id, native) }
            else { nits = min(maxNits, nits + boostStep) }
        case .down:
            if nits > sdrNits { nits = max(sdrNits, nits - boostStep) }
            else { native = max(0, (grid - 1) * nativeStep); NativeBrightness.set(id, native) }
        }
        applyState(animated: true)
        showHUD(native: native)
        return true
    }

    private func tick() {
        // Accessibility granted after launch: start listening to the keys.
        if BrightnessKeys.isTrusted { keys.start() }
        // User lowered brightness another way (Control Center, ambient sensor…): drop the boost.
        if nits > sdrNits, booster.displayID != nil, !atNativeMax {
            nits = sdrNits
            applyState(animated: true)
        }
        updateUI()
    }

    private func applyState(animated: Bool) {
        booster.set(nits: enabled ? nits : sdrNits, animated: animated)
        updateUI()
    }

    /// Left half of the bar = native range, right half = XDR boost.
    private func showHUD(native: Float? = nil) {
        guard let (screen, id) = Booster.xdrScreen() else { return }
        let b = Double(native ?? NativeBrightness.value(id) ?? 1)
        if nits > sdrNits {
            hud.show(nits: nits, fraction: 0.5 + 0.5 * (nits - sdrNits) / (maxNits - sdrNits), xdr: true, on: screen)
        } else {
            // Approximate panel output for the native range (perceptual slider ≈ gamma 2.2).
            hud.show(nits: sdrNits * pow(b, 2.2), fraction: 0.5 * b, xdr: false, on: screen)
        }
    }

    @objc private func screensChanged() {
        booster.attach()
        applyState(animated: false)
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Activer Vivid  (⌃⌥⌘V)", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
        valueLabel = NSTextField(labelWithString: "")
        valueLabel.frame = NSRect(x: 18, y: 26, width: 210, height: 16)
        valueLabel.font = .menuFont(ofSize: 13)
        slider = NSSlider(value: nits, minValue: sdrNits, maxValue: maxNits, target: self, action: #selector(sliderChanged))
        slider.numberOfTickMarks = Int((maxNits - sdrNits) / step) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.frame = NSRect(x: 18, y: 4, width: 206, height: 20)
        box.addSubview(valueLabel); box.addSubview(slider)
        let sliderItem = NSMenuItem(); sliderItem.view = box
        menu.addItem(sliderItem)

        menu.addItem(.separator())
        accessItem = NSMenuItem(title: "Autoriser les touches de luminosité…", action: #selector(requestAccess), keyEquivalent: "")
        accessItem.target = self
        menu.addItem(accessItem)
        let login = NSMenuItem(title: "Lancer au démarrage", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter Vivid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggle() {
        enabled.toggle()
        applyState(animated: true)
        if enabled && nits > sdrNits { showHUD() }
    }

    @objc private func sliderChanged() {
        nits = slider.doubleValue
        applyState(animated: true)
    }

    @objc private func requestAccess() {
        BrightnessKeys.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("Login item: \(error)") }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// ⌃⌥⌘V turns Vivid on/off from anywhere.
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

    private func updateUI() {
        toggleItem.state = enabled ? .on : .off
        slider.doubleValue = nits
        slider.isEnabled = enabled && booster.displayID != nil
        valueLabel.stringValue = booster.displayID == nil ? "Aucun écran XDR"
            : nits > sdrNits ? "Luminosité XDR : \(Int(nits)) nits" : "Luminosité native (500 nits)"
        accessItem.isHidden = BrightnessKeys.isTrusted
        let boosted = enabled && nits > sdrNits
        statusItem.button?.image = NSImage(systemSymbolName: boosted ? "sun.max.fill" : "sun.max",
                                           accessibilityDescription: "Vivid")
    }
}
