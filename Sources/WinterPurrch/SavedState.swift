import AppKit

/// The snow scene saved between runs, one per screen.
struct SavedState: Codable {
    struct Ball: Codable {
        var uid: Int, x: Float, y: Float, volume: Float
        var ledge: Int?, onBall: Int?
        var ox: Float, oy: Float, seed: Float
    }
    struct Mug: Codable {
        var x: Float, y: Float, ledge: Int?, offset: Float, age: Float
    }

    var ground: [Float]?
    var dock: [Float]?
    var windows: [String: [Float]] = [:]
    var balls: [Ball] = []
    var mugs: [Mug] = []
}

enum SceneStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WinterPurrch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scene.json")
    }

    static func key(for screen: NSScreen) -> String {
        "\(screen.localizedName) \(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    static func load() -> [String: SavedState] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: SavedState].self, from: data)) ?? [:]
    }

    static func save(_ scenes: [String: SavedState]) {
        guard let data = try? JSONEncoder().encode(scenes) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
