import AppKit
import Carbon.HIToolbox
import ServiceManagement
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    private var shownIcon: String?
    private let power = PowerMonitor()
    private var updater: SPUStandardUpdaterController!
    private var autoItems: [NSMenuItem] = []
    /// Native brightness to restore when an automatic boost ends.
    private var savedNative: Float?
    /// Native brightness may still be ramping right after we set it: don't treat that as a user change.
    private var dropGraceUntil: CFTimeInterval = 0

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

    // Automatic boost options (menu checkboxes).
    private var autoOnBattery: Bool {
        get { defaults.bool(forKey: "autoOnBattery") }
        set { defaults.set(newValue, forKey: "autoOnBattery") }
    }
    private var autoOnAC: Bool {
        get { defaults.bool(forKey: "autoOnAC") }
        set { defaults.set(newValue, forKey: "autoOnAC") }
    }
    private var pauseInLowPower: Bool {
        get { defaults.object(forKey: "pauseInLowPower") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pauseInLowPower") }
    }
    /// Level used by automatic boosts: the last boost the user chose.
    private var boostLevel: Double {
        get { defaults.object(forKey: "boostLevel") as? Double ?? maxNits }
        set { defaults.set(newValue, forKey: "boostLevel") }
    }
    private var paused: Bool { pauseInLowPower && power.lowPower }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        buildMenu()
        registerHotKey()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensChanged),
                                                          name: NSWorkspace.didWakeNotification, object: nil)

        keys.handler = { [weak self] key, fine in self?.handle(key, fine: fine) ?? false }
        if BrightnessKeys.isTrusted { keys.start() } else { BrightnessKeys.requestTrust() }

        booster.onSafetyStop = { [weak self] in
            guard let self else { return }
            self.enabled = false
            self.nits = self.sdrNits
            self.booster.detach()
            CGDisplayRestoreColorSyncSettings()
            self.booster.attach()
            self.updateUI()
        }
        booster.attach()
        if !atNativeMax { nits = sdrNits }
        applyState(animated: false)

        power.onChange = { [weak self] _, _ in self?.powerChanged() }
        power.start()
        powerChanged(atLaunch: true)

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    /// Launched again (Raycast, Spotlight, Finder) while running: open the menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.button?.performClick(nil)
        return false
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
            else if paused { return false } // let macOS show its own "max" HUD
            else { nits = min(maxNits, nits + boostStep) }
        case .down:
            if nits > sdrNits && !paused { nits = max(sdrNits, nits - boostStep) }
            else { native = max(0, (grid - 1) * nativeStep); NativeBrightness.set(id, native) }
        }
        if nits > sdrNits { boostLevel = nits }
        savedNative = nil // the user took over
        NSLog("Lucent: key %@%@ native %.3f -> %.3f, nits %.0f", key == .up ? "up" : "down", fine ? " fine" : "", b, native, nits)
        applyState(animated: true)
        showHUD(native: native)
        return true
    }

    /// Cheap 1 Hz housekeeping; does nothing while idle and the key tap is running.
    private func tick() {
        // Accessibility granted after launch: start listening to the keys.
        if !keys.isRunning, BrightnessKeys.isTrusted, keys.start() { updateUI() }
        // User lowered brightness another way (Control Center, ambient sensor…): drop the boost.
        if enabled, nits > sdrNits, booster.displayID != nil, CACurrentMediaTime() > dropGraceUntil, !atNativeMax {
            NSLog("Lucent: native brightness below max, dropping boost")
            nits = sdrNits
            applyState(animated: true)
        }
    }

    func menuWillOpen(_ menu: NSMenu) { updateUI() }

    private func applyState(animated: Bool) {
        booster.set(nits: enabled && !paused ? nits : sdrNits, animated: animated)
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

    // MARK: Automatic boost

    /// Battery/AC switch or Low Power Mode change: start or end the automatic boost.
    private func powerChanged(atLaunch: Bool = false) {
        let wanted = power.source == .battery ? autoOnBattery : autoOnAC
        NSLog("Lucent: power %@%@, auto boost %@", power.source == .battery ? "battery" : "AC",
              power.lowPower ? " (Low Power Mode)" : "", wanted && !paused ? "on" : "off")
        if wanted && !paused { autoBoostOn() }
        else if !atLaunch { autoBoostOff() }
        updateUI()
    }

    private func autoBoostOn() {
        guard enabled, let id = booster.displayID, let b = NativeBrightness.value(id) else { return }
        if b < 0.995 {
            savedNative = b
            NativeBrightness.set(id, 1)
            dropGraceUntil = CACurrentMediaTime() + 3
        }
        nits = max(boostLevel, sdrNits + step)
        applyState(animated: true)
        showHUD(native: 1)
    }

    private func autoBoostOff() {
        let wasBoosted = nits > sdrNits
        nits = sdrNits
        applyState(animated: true)
        if let id = booster.displayID, let saved = savedNative { NativeBrightness.set(id, saved) }
        savedNative = nil
        if wasBoosted { showHUD() }
    }

    @objc private func toggleAuto(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: autoOnBattery.toggle()
        case 1: autoOnAC.toggle()
        default: pauseInLowPower.toggle()
        }
        if sender.tag == 2 { applyState(animated: true) } else { powerChanged() }
        updateUI()
    }

    @objc private func screensChanged() {
        booster.attach()
        applyState(animated: false)
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Enable Lucent  (⌃⌥⌘V)", action: #selector(toggle), keyEquivalent: "")
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
        let header = NSMenuItem(title: "Automatic Boost", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (tag, title) in ["On Battery", "When Plugged In", "Pause in Low Power Mode"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(toggleAuto(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.indentationLevel = 1
            menu.addItem(item)
            autoItems.append(item)
        }

        menu.addItem(.separator())
        accessItem = NSMenuItem(title: "Allow Brightness Keys…", action: #selector(requestAccess), keyEquivalent: "")
        accessItem.target = self
        menu.addItem(accessItem)
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lucent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func toggle() {
        enabled.toggle()
        applyState(animated: true)
        if enabled && nits > sdrNits { showHUD() }
    }

    @objc private func sliderChanged() {
        nits = slider.doubleValue
        if nits > sdrNits { boostLevel = nits }
        savedNative = nil
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

    /// ⌃⌥⌘V turns Lucent on/off from anywhere.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x4C43_4E54), id: 1) // 'LCNT'
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    private func updateUI() {
        toggleItem.state = enabled ? .on : .off
        slider.doubleValue = nits
        slider.isEnabled = enabled && booster.displayID != nil && !paused
        valueLabel.stringValue = booster.displayID == nil ? "No XDR display"
            : paused ? "Paused in Low Power Mode"
            : nits > sdrNits ? "XDR brightness: \(Int(nits)) nits" : "Native brightness (500 nits)"
        accessItem.isHidden = keys.isRunning
        for (item, on) in zip(autoItems, [autoOnBattery, autoOnAC, pauseInLowPower]) { item.state = on ? .on : .off }
        let icon = enabled && !paused && nits > sdrNits ? "sun.max.fill" : "sun.max"
        if icon != shownIcon {
            shownIcon = icon
            statusItem.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: "Lucent")
        }
    }
}
