import AppKit
import ApplicationServices

/// Reads where the ordinary windows are, front to back, in global Cocoa coordinates (y up).
enum WindowList {
    struct Entry {
        let id: Int
        let frame: CGRect
    }

    static func current() -> [Entry] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        var result: [Entry] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  rect.width >= 80, rect.height >= 40
            else { continue }
            let flipped = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
            result.append(Entry(id: id, frame: flipped))
        }
        return result
    }
}

/// Finds the Dock's glass: exactly through Accessibility when allowed, otherwise from the Dock's own settings.
enum DockLocator {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The Dock's frame in global Cocoa coordinates, or nil when it hides or doesn't sit at the bottom.
    static func frame() -> CGRect? {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        if dock?.bool(forKey: "autohide") == true { return nil }
        let orientation = dock?.string(forKey: "orientation") ?? "bottom"
        guard orientation == "bottom" else { return nil }
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.minY - $0.frame.minY > 20 }) else {
            return nil
        }
        if let exact = windowServerFrame() { return exact }
        if trusted, let exact = accessibilityFrame() { return exact }
        return estimate(on: screen, dock)
    }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias GetDockRect = @convention(c) (Int32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<Int32>) -> Int32

    /// The window server knows the room the Dock keeps; no permission is needed to ask.
    private static let skyLight: (connection: Int32, getRect: GetDockRect)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let main = dlsym(handle, "SLSMainConnectionID"),
              let get = dlsym(handle, "SLSGetDockRectWithReason")
        else { return nil }
        let connection = unsafeBitCast(main, to: MainConnection.self)()
        return (connection, unsafeBitCast(get, to: GetDockRect.self))
    }()

    private static func windowServerFrame() -> CGRect? {
        guard let skyLight else { return nil }
        var room = CGRect.zero
        var reason: Int32 = 0
        guard skyLight.getRect(skyLight.connection, &room, &reason) == 0, room.width > 40, room.height > 20 else {
            return nil
        }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let bottom = primaryHeight - room.maxY
        // The glass floats a few points above the screen edge and ends a point under the room's top.
        return CGRect(x: room.minX, y: bottom + 6, width: room.width, height: room.height - 7)
    }

    private static func accessibilityFrame() -> CGRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        for child in list {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            guard (role as? String) == (kAXListRole as String) else { continue }
            var pos: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &pos) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &size) == .success
            else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
            AXValueGetValue(size as! AXValue, .cgSize, &s)
            guard s.width > 40 else { continue }
            // The icon row; the glass around it reaches a little higher.
            let pad = CGFloat(Preferences.shared.dockTopOffset) + 4
            return CGRect(x: p.x - 6, y: primaryHeight - (p.y + s.height), width: s.width + 12, height: s.height + pad)
        }
        return nil
    }

    private static func estimate(on screen: NSScreen, _ dock: UserDefaults?) -> CGRect {
        let tile = CGFloat(dock?.double(forKey: "tilesize") ?? 0).nonZero ?? 64
        let persistentApps = (dock?.array(forKey: "persistent-apps") as? [[String: Any]]) ?? []
        let persistentIDs = Set(persistentApps.compactMap {
            ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
        })
        let others = (dock?.array(forKey: "persistent-others") as? [Any])?.count ?? 0
        let showRecents = dock?.object(forKey: "show-recents") as? Bool ?? true
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != "com.apple.finder"
                && !persistentIDs.contains($0.bundleIdentifier ?? "")
        }
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        var recent = 0
        if showRecents {
            let recents = (dock?.array(forKey: "recent-apps") as? [[String: Any]]) ?? []
            recent = min(3, recents.filter {
                let id = ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String ?? ""
                return !persistentIDs.contains(id) && !runningIDs.contains(id)
            }.count)
        }
        let extra = running.count + recent
        let tiles = CGFloat(1 + persistentApps.count + extra + others + 1)
        let separators: CGFloat = extra > 0 ? 2 : 1
        let width = tiles * tile + separators * tile * 0.3 + tile * 0.3
            + CGFloat(Preferences.shared.dockWidthAdjust)
        let inset = screen.visibleFrame.minY - screen.frame.minY
        let height = inset + CGFloat(Preferences.shared.dockTopOffset)
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.minY, width: width, height: height)
    }
}

private extension CGFloat {
    var nonZero: CGFloat? { self > 0 ? self : nil }
}
