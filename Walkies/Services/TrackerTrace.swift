import Foundation

/// A short log of always on's decisions in Library/Caches, for working out what happened
/// on a real walk: Release builds don't keep the app's os_log lines, and reading the
/// phone's own log needs root. Copy it off with `xcrun devicectl device copy from`.
/// TEMPORARY while the tap-to-start walk question is being tried (Nov 2026).
enum TrackerTrace {
    /// Every always-on fix, in its own file so the decisions above stay readable. Walks
    /// on 12 Nov 2026 were thrown away as never confirmed and there was no route to see why.
    nonisolated static func fix(_ point: TrackPoint, walk: Bool, pending: Bool) {
        let line = String(format: "%.0f %.6f %.6f acc=%.0f spd=%.1f wheels=%@ still=%@ walk=%@ pending=%@",
                          point.time, point.lat, point.lon, point.accuracy, point.speed ?? -1,
                          "\(point.wheels ?? false)", "\(point.still ?? false)", "\(walk)", "\(pending)")
        append(line + "\n", to: "tracker-fixes.log", limit: 2_000_000)
    }

    /// Why an automatic walk ended and whether it was kept. A dropped one's route goes to
    /// Caches/dropped-walks, since nothing else keeps it.
    nonisolated static func walkEnded(_ walk: Walk, kept: Bool, pending: Bool, reason: String, displacement: Double) {
        let minutes = (walk.points.last.map { $0.time } ?? walk.startedAt.timeIntervalSince1970) - walk.startedAt.timeIntervalSince1970
        write("auto walk ended (\(reason)): \(kept ? "kept" : "dropped") pending=\(pending) points=\(walk.points.count) "
              + "farthest=\(Int(displacement)) m distance=\(Int(walk.distance)) m length=\(Int(minutes / 60)) min")
        guard !kept, !walk.points.isEmpty,
              let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appending(path: "dropped-walks") else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(walk) {
            try? data.write(to: dir.appending(path: "\(walk.id).json"))
        }
    }

    nonisolated static func write(_ text: String) {
        append("\(Date.now.formatted(date: .numeric, time: .standard)) \(text)\n", to: "tracker-trace.log", limit: 300_000)
    }

    private nonisolated static func append(_ line: String, to name: String, limit: Int) {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = dir.appending(path: name)
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > limit {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
