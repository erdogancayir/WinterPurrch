import Foundation

final class Preferences {
    static let shared = Preferences()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "intensity": 0.5, "opacity": 1.0,
            "ground": true, "dock": true, "windows": true,
            "melt": true, "cat": true, "friend": true, "skater": true, "birds": true, "batterySaver": true, "catSize": 42.0, "blizzard": false, "screenshots": false,
            "dockTopOffset": -1.0, "dockWidthAdjust": 0.0,
        ])
    }

    var intensity: Float { get { d.float(forKey: "intensity") } set { d.set(newValue, forKey: "intensity") } }
    var opacity: Float { get { d.float(forKey: "opacity") } set { d.set(newValue, forKey: "opacity") } }
    var ground: Bool { get { d.bool(forKey: "ground") } set { d.set(newValue, forKey: "ground") } }
    var dock: Bool { get { d.bool(forKey: "dock") } set { d.set(newValue, forKey: "dock") } }
    var windows: Bool { get { d.bool(forKey: "windows") } set { d.set(newValue, forKey: "windows") } }
    var melt: Bool { get { d.bool(forKey: "melt") } set { d.set(newValue, forKey: "melt") } }
    var blizzard: Bool { get { d.bool(forKey: "blizzard") } set { d.set(newValue, forKey: "blizzard") } }
    var catSize: Float { get { d.float(forKey: "catSize") } set { d.set(newValue, forKey: "catSize") } }
    var batterySaver: Bool { get { d.bool(forKey: "batterySaver") } set { d.set(newValue, forKey: "batterySaver") } }
    var birds: Bool { get { d.bool(forKey: "birds") } set { d.set(newValue, forKey: "birds") } }
    var skater: Bool { get { d.bool(forKey: "skater") } set { d.set(newValue, forKey: "skater") } }
    var friend: Bool { get { d.bool(forKey: "friend") } set { d.set(newValue, forKey: "friend") } }
    var cat: Bool { get { d.bool(forKey: "cat") } set { d.set(newValue, forKey: "cat") } }
    var screenshots: Bool { get { d.bool(forKey: "screenshots") } set { d.set(newValue, forKey: "screenshots") } }
    /// Fine-tuning for the Dock's top edge and width, in points (`defaults write com.erdogancayir.WinterPurrch dockTopOffset -6`).
    var dockTopOffset: Double { d.double(forKey: "dockTopOffset") }
    var dockWidthAdjust: Double { d.double(forKey: "dockWidthAdjust") }

    var settings: Settings {
        Settings(intensity: intensity, opacity: opacity, ground: ground, dock: dock, windows: windows,
                 melt: melt, blizzard: blizzard, cat: cat, friend: friend, skater: skater, birds: birds, catSize: catSize)
    }
}
