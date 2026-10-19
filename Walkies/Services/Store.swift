import Foundation
import os

/// Plain JSON files in Application Support. One file for cities, one per walk.
nonisolated struct Store {
    private static let log = Logger(subsystem: "com.mikecann.walkies", category: "store")

    private let root = URL.applicationSupportDirectory.appending(path: "Walkies", directoryHint: .isDirectory)
    private var citiesURL: URL { root.appending(path: "cities.json") }
    private var walksDir: URL { root.appending(path: "walks", directoryHint: .isDirectory) }

    init() {
        try? FileManager.default.createDirectory(at: walksDir, withIntermediateDirectories: true)
    }

    func loadCities() -> [City] {
        read([City].self, from: citiesURL) ?? []
    }

    func save(_ cities: [City]) {
        write(cities, to: citiesURL)
    }

    func loadWalks() -> [Walk] {
        let files = (try? FileManager.default.contentsOfDirectory(at: walksDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { read(Walk.self, from: $0) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func save(_ walk: Walk) {
        write(walk, to: walksDir.appending(path: "\(walk.id.uuidString).json"))
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Self.log.error("Couldn't read \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            Self.log.error("Couldn't save \(url.lastPathComponent): \(error)")
        }
    }
}
