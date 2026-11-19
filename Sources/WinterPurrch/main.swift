import AppKit

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--selftest") {
    let dir = i + 1 < arguments.count ? arguments[i + 1] : FileManager.default.currentDirectoryPath
    exit(SelfTest.run(outputDirectory: dir))
}

if let i = arguments.firstIndex(of: "--settingsshot") {
    exit(SettingsSnapshot.run(path: i + 1 < arguments.count ? arguments[i + 1] : "settings.png"))
}
if let i = arguments.firstIndex(of: "--icon") {
    exit(SelfTest.icon(outputDirectory: i + 1 < arguments.count ? arguments[i + 1] : "."))
}
if let i = arguments.firstIndex(of: "--catsheet") {
    exit(SelfTest.catSheet(outputDirectory: i + 1 < arguments.count ? arguments[i + 1] : "."))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
