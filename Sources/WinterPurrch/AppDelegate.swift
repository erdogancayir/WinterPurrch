import AppKit
import IOKit.ps
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = Preferences.shared
    private var statusItem: NSStatusItem!
    private var screens: [ScreenSnow] = []
    private var pollTimer: Timer?
    private var lastPoll = CACurrentMediaTime()
    private var lastWindows: [Int: CGRect] = [:]
    private var busyUntil: CFTimeInterval = 0
    private var tick = 0
    private var spaceChangedAt: CFTimeInterval = 0
    private var dockFrame: CGRect?
    private var dockCheckedAt: CFTimeInterval = 0
    private var paused = false
    private var screensAsleep = false
    private let settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "WinterPurrch")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        rebuildScreens()
        let model = settingsWindow.model
        model.apply = { [weak self] in
            self?.applySettings()
            self?.applyFrameRate()
            self?.refreshVisibility()
        }
        model.setPaused = { [weak self] value in
            self?.paused = value
            self?.refreshVisibility()
        }
        model.clearSnow = { [weak self] in self?.clearSnow() }
        model.callSkater = { [weak self] in self?.callSkater() }
        // The first time, show where everything is: the menu bar icon may well be hidden behind the notch.
        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showSettings() }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.saveScene() }
        checkPower()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.checkPower() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(pollTimer!, forMode: .common)

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in self?.rebuildScreens()
        }
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyFrameRate()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.spaceChangedAt = CACurrentMediaTime()
        }
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
            [weak self] _ in self?.screensAsleep = true; self?.refreshVisibility()
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.screensAsleep = false; self?.refreshVisibility()
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.dockCheckedAt = 0
            }
        }
    }

    /// Opened again while already running (from Spotlight, Launchpad or Finder): show the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc private func showSettings() { settingsWindow.show(paused: paused) }

    /// Keeps the drifts, snowmen and mugs for next time.
    private func saveScene() {
        var scenes = SceneStore.load()
        for s in screens { scenes[SceneStore.key(for: s.screen)] = s.simulation.savedState() }
        SceneStore.save(scenes)
    }

    func applicationWillTerminate(_ notification: Notification) { saveScene() }

    // MARK: - Screens

    private func rebuildScreens() {
        if !screens.isEmpty { saveScene() }
        screens.forEach { $0.close() }
        screens = NSScreen.screens.compactMap { ScreenSnow(screen: $0, settings: prefs.settings) }
        let saved = SceneStore.load()
        for s in screens {
            if let state = saved[SceneStore.key(for: s.screen)] { s.simulation.restore(state) }
        }
        dockCheckedAt = 0
        applyFrameRate()
        refreshVisibility()
    }

    private func refreshVisibility() {
        let resting = paused || screensAsleep || (prefs.batterySaver && power.low)
        for s in screens {
            if resting { s.hide() } else { s.show(screenshots: prefs.screenshots) }
        }
    }

    private func applyFrameRate() {
        let slow = ProcessInfo.processInfo.isLowPowerModeEnabled || (prefs.batterySaver && power.onBattery)
        screens.forEach { $0.setFrameRate(slow ? 30 : 60) }
    }

    /// On battery, and whether the battery is running low (under a fifth, not charging).
    private var power = (onBattery: false, low: false)

    private func checkPower() {
        var state = (onBattery: false, low: false)
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                let onBattery = d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
                let level = d[kIOPSCurrentCapacityKey] as? Int ?? 100
                state = (onBattery, onBattery && level < 20)
            }
        }
        guard state != power else { return }
        power = state
        applyFrameRate()
        refreshVisibility()
    }

    private func applySettings() {
        let s = prefs.settings
        screens.forEach { $0.simulation.applySettings(s) }
        lastWindows.removeAll()
        busyUntil = CACurrentMediaTime() + 1
    }

    // MARK: - Windows

    /// Reads the windows often while they move and seldom while all is still.
    private func poll() {
        guard !paused, !screensAsleep else { return }
        let now = CACurrentMediaTime()
        tick += 1
        if now > busyUntil && tick % 5 != 0 { return }
        let windows = WindowList.current()
        var map: [Int: CGRect] = [:]
        for w in windows { map[w.id] = w.frame }
        if map != lastWindows { busyUntil = now + 1.2 }
        lastWindows = map

        if now - dockCheckedAt > 3 {
            dockCheckedAt = now
            dockFrame = DockLocator.frame()
        }
        let dt = Float(now - lastPoll)
        lastPoll = now
        let keep = now - spaceChangedAt < 1.5
        for s in screens {
            s.updateSurfaces(windows: windows, dock: dockFrame, dt: dt, keepVanished: keep)
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let title = NSMenuItem(title: "WinterPurrch", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let open = item(L("Open Settings…"), #selector(showSettings))
        open.keyEquivalent = ","
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(sliderItem(L("Intensity"), value: prefs.intensity, range: 0.05...1) { [weak self] v in
            self?.prefs.intensity = v
            self?.applySettings()
        })
        menu.addItem(sliderItem(L("Opacity"), value: prefs.opacity, range: 0.25...1) { [weak self] v in
            self?.prefs.opacity = v
            self?.applySettings()
        })
        menu.addItem(.separator())

        let accumulate = NSMenuItem(title: L("Accumulate"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(toggle(L("Ground"), prefs.ground) { $0.ground.toggle() })
        sub.addItem(toggle(L("Dock"), prefs.dock) { $0.dock.toggle() })
        sub.addItem(toggle(L("Windows"), prefs.windows) { $0.windows.toggle() })
        accumulate.submenu = sub
        menu.addItem(accumulate)
        menu.addItem(toggle(L("Blizzard"), prefs.blizzard) { $0.blizzard.toggle() })
        menu.addItem(toggle(L("Melt Snow"), prefs.melt) { $0.melt.toggle() })
        menu.addItem(toggle(L("Cat"), prefs.cat) { $0.cat.toggle() })
        if prefs.cat {
            menu.addItem(toggle(L("Friend"), prefs.friend) { $0.friend.toggle() })
            menu.addItem(sliderItem(L("Cat Size"), value: prefs.catSize, range: 16...80) { [weak self] v in
                self?.prefs.catSize = v
                self?.applySettings()
            })
        }
        menu.addItem(.separator())

        let hint = NSMenuItem(title: L("Snowball: hold ⌥, grab the snow and throw"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        let hint2 = NSMenuItem(title: L("Stack the balls to build a snowman ☃︎"), action: nil, keyEquivalent: "")
        hint2.isEnabled = false
        menu.addItem(hint2)
        let hint3 = NSMenuItem(title: L("Cat: click to startle it, hover to pet it"), action: nil, keyEquivalent: "")
        hint3.isEnabled = false
        menu.addItem(hint3)
        menu.addItem(item(L("Clear Snow"), #selector(clearSnow)))
        if prefs.skater { menu.addItem(item(L("Call the Skater"), #selector(callSkater))) }
        menu.addItem(item(paused ? L("Resume") : L("Pause"), #selector(togglePause)))
        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("Settings"), action: nil, keyEquivalent: "")
        let more = NSMenu()
        more.addItem(toggle(L("Show in Screenshots"), prefs.screenshots) { $0.screenshots.toggle() })
        let login = item(L("Open at Login"), #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        more.addItem(login)
        if !DockLocator.trusted {
            more.addItem(item(L("Measure the Dock Exactly (Accessibility)…"), #selector(askAccessibility)))
        }
        settings.submenu = more
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private var toggles: [NSMenuItem: (Preferences) -> Void] = [:]

    private func toggle(_ title: String, _ on: Bool, _ change: @escaping (Preferences) -> Void) -> NSMenuItem {
        let i = item(title, #selector(toggled(_:)))
        i.state = on ? .on : .off
        toggles[i] = change
        return i
    }

    @objc private func toggled(_ sender: NSMenuItem) {
        toggles[sender]?(prefs)
        toggles.removeAll()
        applySettings()
        refreshVisibility()
    }

    private func sliderItem(_ title: String, value: Float, range: ClosedRange<Float>,
                            onChange: @escaping (Float) -> Void) -> NSMenuItem {
        let i = NSMenuItem()
        i.view = SliderMenuView(title: title, value: value, range: range, onChange: onChange)
        return i
    }

    @objc func callSkater() { screens.forEach { $0.simulation.callSkater() } }

    @objc func clearSnow() { screens.forEach { $0.simulation.clear() } }

    @objc private func togglePause() {
        paused.toggle()
        refreshVisibility()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Couldn't set Open at Login")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func askAccessibility() {
        DockLocator.requestAccess()
        dockCheckedAt = 0
    }
}

/// A labelled slider inside the menu.
final class SliderMenuView: NSView {
    private let onChange: (Float) -> Void

    init(title: String, value: Float, range: ClosedRange<Float>, onChange: @escaping (Float) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 46))
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 24, width: 230, height: 18)
        addSubview(label)
        let slider = NSSlider(value: Double(value), minValue: Double(range.lowerBound),
                              maxValue: Double(range.upperBound), target: nil, action: nil)
        slider.frame = NSRect(x: 14, y: 2, width: 232, height: 22)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed(_:))
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed(_ sender: NSSlider) { onChange(Float(sender.doubleValue)) }
}

/// A menu string in the user's language.
func L(_ english: String) -> String { NSLocalizedString(english, comment: "") }
