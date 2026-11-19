import AppKit
import ServiceManagement
import SwiftUI

/// The settings, bound to the preferences; every change is applied at once.
final class SettingsModel: ObservableObject {
    private let prefs = Preferences.shared
    var apply: () -> Void = {}
    var setPaused: (Bool) -> Void = { _ in }
    var clearSnow: () -> Void = {}
    var callSkater: () -> Void = {}

    @Published var intensity: Double { didSet { prefs.intensity = Float(intensity); apply() } }
    @Published var opacity: Double { didSet { prefs.opacity = Float(opacity); apply() } }
    @Published var blizzard: Bool { didSet { prefs.blizzard = blizzard; apply() } }
    @Published var melt: Bool { didSet { prefs.melt = melt; apply() } }
    @Published var ground: Bool { didSet { prefs.ground = ground; apply() } }
    @Published var dock: Bool { didSet { prefs.dock = dock; apply() } }
    @Published var windows: Bool { didSet { prefs.windows = windows; apply() } }
    @Published var cat: Bool { didSet { prefs.cat = cat; apply() } }
    @Published var friend: Bool { didSet { prefs.friend = friend; apply() } }
    @Published var catSize: Double { didSet { prefs.catSize = Float(catSize); apply() } }
    @Published var screenshots: Bool { didSet { prefs.screenshots = screenshots; apply() } }
    @Published var skater: Bool { didSet { prefs.skater = skater; apply() } }
    @Published var batterySaver: Bool { didSet { prefs.batterySaver = batterySaver; apply() } }
    @Published var paused = false { didSet { setPaused(paused) } }
    @Published var openAtLogin: Bool {
        didSet {
            guard openAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                loginError = error.localizedDescription
                openAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    @Published var loginError: String?

    init() {
        intensity = Double(prefs.intensity)
        opacity = Double(prefs.opacity)
        blizzard = prefs.blizzard
        melt = prefs.melt
        ground = prefs.ground
        dock = prefs.dock
        windows = prefs.windows
        cat = prefs.cat
        friend = prefs.friend
        catSize = Double(prefs.catSize)
        screenshots = prefs.screenshots
        skater = prefs.skater
        batterySaver = prefs.batterySaver
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Picks up changes made from the menu bar.
    func reload(paused: Bool) {
        let fresh = SettingsModel()
        let keep = (apply, setPaused, clearSnow, callSkater)
        apply = {}
        setPaused = { _ in }
        intensity = fresh.intensity
        opacity = fresh.opacity
        blizzard = fresh.blizzard
        melt = fresh.melt
        ground = fresh.ground
        dock = fresh.dock
        windows = fresh.windows
        cat = fresh.cat
        friend = fresh.friend
        catSize = fresh.catSize
        screenshots = fresh.screenshots
        skater = fresh.skater
        batterySaver = fresh.batterySaver
        self.paused = paused
        (apply, setPaused, clearSnow, callSkater) = keep
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section(L("Snow")) {
                LabeledContent(L("Intensity")) { Slider(value: $model.intensity, in: 0.05...1) }
                LabeledContent(L("Opacity")) { Slider(value: $model.opacity, in: 0.25...1) }
                Toggle(L("Blizzard"), isOn: $model.blizzard)
                Toggle(L("Melt Snow"), isOn: $model.melt)
                LabeledContent(L("Accumulate")) {
                    HStack {
                        Toggle(L("Ground"), isOn: $model.ground)
                        Toggle(L("Dock"), isOn: $model.dock)
                        Toggle(L("Windows"), isOn: $model.windows)
                    }
                    .toggleStyle(.checkbox)
                }
                Button(L("Clear Snow")) { model.clearSnow() }
            }
            Section(L("Cats")) {
                Toggle(L("Cat"), isOn: $model.cat)
                Toggle(L("Friend"), isOn: $model.friend).disabled(!model.cat)
                LabeledContent(L("Cat Size")) { Slider(value: $model.catSize, in: 16...80) }.disabled(!model.cat)
                Text(L("Click a cat to startle it; rest or stroke the cursor on it to pet it. Hold ⌥ and drag snow to make snowballs."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section(L("Skater")) {
                Toggle(L("Skater shows up when the snow is deep"), isOn: $model.skater)
                Button(L("Call the Skater")) { model.callSkater() }.disabled(!model.skater)
            }
            Section(L("General")) {
                Toggle(L("Pause"), isOn: $model.paused)
                Toggle(L("Open at Login"), isOn: $model.openAtLogin)
                Toggle(L("Save battery: slower on battery, paused when it runs low"), isOn: $model.batterySaver)
                Toggle(L("Show in Screenshots"), isOn: $model.screenshots)
                if let error = model.loginError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            Section {
                HStack {
                    Text(L("To come back here, open WinterPurrch again from Spotlight or Launchpad."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Quit WinterPurrch")) { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The settings window, reachable without the menu bar (whose icon can hide behind the notch).
final class SettingsWindowController {
    let model = SettingsModel()
    private var window: NSWindow?

    func show(paused: Bool) {
        model.reload(paused: paused)
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = L("WinterPurrch Settings")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// `--settingsshot <file.png>`: draws the settings window to a picture, to check its layout.
enum SettingsSnapshot {
    static func run(path: String) -> Int32 {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: SettingsView(model: SettingsModel()))
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return 0
    }
}
