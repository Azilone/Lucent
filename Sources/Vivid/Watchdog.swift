import AppKit

/// Emergency brake. Runs on its own queue so it still works when the main thread or
/// the GPU is stuck: if the app's main thread stalls, or a captured frame isn't on
/// screen in time, the boost is disabled and the process exits, which makes
/// WindowServer drop the overlay instantly.
final class Watchdog {
    static let mainStallLimit: CFTimeInterval = 1.0
    static let frameLagLimit: CFTimeInterval = 0.75

    private let queue = DispatchQueue(label: "vivid.watchdog", qos: .userInteractive)
    private let lock = NSLock()
    private var mainBeat = CACurrentMediaTime()
    private var lastTick = CACurrentMediaTime()
    private var pendingSince: CFTimeInterval?
    private var timer: DispatchSourceTimer?
    private var heartbeat: Timer?

    func start() {
        stop()
        reset()
        let hb = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.beat() }
        RunLoop.main.add(hb, forMode: .common)
        heartbeat = hb

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    func stop() {
        heartbeat?.invalidate(); heartbeat = nil
        timer?.cancel(); timer = nil
    }

    func framePending() { lock.lock(); if pendingSince == nil { pendingSince = CACurrentMediaTime() }; lock.unlock() }
    func framePresented() { lock.lock(); pendingSince = nil; lock.unlock() }

    private func beat() { lock.lock(); mainBeat = CACurrentMediaTime(); lock.unlock() }

    private func reset() {
        lock.lock(); let now = CACurrentMediaTime()
        mainBeat = now; lastTick = now; pendingSince = nil; lock.unlock()
    }

    private func check() {
        let now = CACurrentMediaTime()
        lock.lock()
        // A long gap in our own ticks means the machine slept or we were suspended: not a stall.
        if now - lastTick > 2 { mainBeat = now; pendingSince = nil }
        lastTick = now
        let mainStall = now - mainBeat
        let frameLag = pendingSince.map { now - $0 } ?? 0
        lock.unlock()

        if mainStall > Self.mainStallLimit { trip(String(format: "main thread stalled %.2fs", mainStall)) }
        if frameLag > Self.frameLagLimit { trip(String(format: "frame not presented after %.2fs", frameLag)) }
    }

    static func trip(_ reason: String) -> Never {
        NSLog("Vivid: EMERGENCY STOP – \(reason)")
        let d = UserDefaults.standard
        d.set(false, forKey: "enabled")
        d.set("\(Date()): \(reason)", forKey: "lastEmergency")
        d.synchronize()
        _exit(1)
    }

    private func trip(_ reason: String) { Self.trip(reason) }
}
