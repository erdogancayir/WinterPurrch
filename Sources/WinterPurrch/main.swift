import AppKit

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--selftest") {
    let dir = i + 1 < arguments.count ? arguments[i + 1] : FileManager.default.currentDirectoryPath
    exit(SelfTest.run(outputDirectory: dir))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
