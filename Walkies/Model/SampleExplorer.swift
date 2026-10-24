#if DEBUG
import Foundation

/// A made-up explorer for the App Store screenshots (ScreenshotMode.swift): places
/// built from real streets, and a few weeks of walks from a front door along them, so
/// the map is part uncovered the way a real one is. The secrets they've found are the
/// ones those walks went over, hidden the way the app hides them. Same seed, same walks.
/// Only in Debug builds; nothing here ever touches anyone's real walks.
nonisolated enum SampleExplorer {
    struct Sample: Sendable {
        var cities: [City]
        var walks: [Walk]
        /// The secrets the walks went over, and when.
        var secrets: [String: Date]
    }

    /// One place the explorer walks in.
    struct Trip {
        var place: PlaceResult
        var ways: [OSMWay]
        /// Where every walk there sets off from and comes back to.
        var home: Coordinate
        /// Each walk's day (before `now`; 0 is today) and the hour it set off, oldest first.
        var walks: [(day: Int, hour: Int)]
        /// Somewhere to head for on each walk, in order. Walks past the end of this go
        /// somewhere new round the compass instead.
        var targets: [Coordinate] = []
    }

    /// The made-up explorer's front door: a side street in Fremantle, WA, by Fremantle Park.
    static let fremantleHome = Coordinate(lat: -32.0512, lon: 115.7560)
    /// Where they stayed on a long weekend down in Busselton, a street back from the foreshore.
    static let busseltonStay = Coordinate(lat: -33.6478, lon: 115.3420)

    /// Fremantle mornings over the last few weeks. The last one is today.
    static let fremantleWalks = [-24, -21, -19, -17, -14, -12, -10, -8, -6, -5, -3, -1, 0].map { (day: $0, hour: 7) }
    /// The Busselton weekend: out to the jetty, round the town centre and along the foreshore.
    static let busseltonWalks = [(day: -16, hour: 8), (day: -16, hour: 16), (day: -15, hour: 8)]
    static let busseltonTargets = [
        Coordinate(lat: -33.6444, lon: 115.3449),
        Coordinate(lat: -33.6530, lon: 115.3480),
        Coordinate(lat: -33.6436, lon: 115.3505),
    ]
    /// A stroll, not a hike: about 1.35 m/s.
    static let pace = 1.35

    static func make(_ trips: [Trip], lore: [LoreEntry] = LoreLibrary.bundled, now: Date = .now, seed: UInt64 = 7) -> Sample {
        var rng = Random(seed: seed)
        var cities: [City] = []
        var walks: [Walk] = []
        for trip in trips {
            var city = CityBuilder.build(from: trip.place, ways: trip.ways, walks: [], streetsVersion: WalkableRule.version)
            let firstDay = trip.walks.first?.day ?? 0
            city.createdAt = now.addingTimeInterval(TimeInterval(firstDay - 1) * 86_400)
            walks += self.walks(for: trip, in: city, now: now, rng: &rng)
            cities.append(city)
        }
        // Each place's secrets are hidden when it's added, before any of its tiles are
        // walked, the same way AppModel does it.
        let assigned = LoreLibrary.assign(lore, to: cities) { city, point in
            city.shape().contains(city.grid.projection.project(point))
        }
        for i in cities.indices {
            cities[i].stickers = cities[i].placeStickers(assigned[cities[i].id] ?? [])
        }
        let replay = CityBuilder.replay(walks, through: cities)
        cities = replay.cities
        for i in cities.indices { cities[i].updatedAt = now }
        return Sample(cities: cities, walks: replay.walks, secrets: replay.secrets)
    }

    private static func walks(for trip: Trip, in city: City, now: Date, rng: inout Random) -> [Walk] {
        let graph = Graph(lines: city.roads ?? [], shape: city.shape(), projection: city.grid.projection)
        var walked = Set<Graph.Edge>()
        let calendar = Calendar.current
        var walks: [Walk] = []
        guard let start = graph.nearest(to: trip.home) else { return [] }
        let origin = graph.nodes[start]
        let connected = graph.reachable(from: start)
        for (i, slot) in trip.walks.enumerated() {
            let today = slot.day == 0
            var route: [Coordinate] = []
            if i < trip.targets.count {
                // Out to somewhere in particular, and back another way. Only streets joined
                // up to home count, or a target near a lone path would make an empty walk.
                let destination = graph.nearest(to: trip.targets[i], among: connected) ?? start
                route = graph.loop(from: start, to: destination, walked: &walked)
            } else {
                // Somewhere new each time: round the compass by the golden angle, 600 m to
                // 1.4 km out. Fremantle's sea is to the west, so a try that comes back short
                // goes round again. Today's is the one the celebration shows, so it goes the
                // newest way of all.
                var bestNew = -1.0
                for attempt in 0..<(today ? 16 : 8) {
                    let angle = Double(i * 3 + attempt + 1) * 2.39996
                    let reach = 600 + Double(rng.next() % 800)
                    let target = Coordinate(lat: origin.lat + reach * cos(angle) / 111_320,
                                            lon: origin.lon + reach * sin(angle) / (111_320 * cos(origin.lat * .pi / 180)))
                    var tried = walked
                    let destination = graph.nearest(to: target) ?? start
                    let candidate = graph.loop(from: start, to: destination, walked: &tried)
                    let fresh = Double(tried.subtracting(walked).count)
                    let long = CoverageTracer.distanceAlong(candidate) > 1_800
                    if today ? (long && fresh > bestNew) : (long || attempt == 7) {
                        route = candidate
                        bestNew = fresh
                        if !today { walked = tried; break }
                    }
                }
                if today { walked.formUnion(Graph.edges(of: route, in: graph)) }
            }
            let duration = CoverageTracer.distanceAlong(route) / pace
            let date = now.addingTimeInterval(TimeInterval(slot.day) * 86_400)
            var started = calendar.date(bySettingHour: slot.hour, minute: Int(rng.next() % 40), second: 0, of: date) ?? date
            // Today's has to be over already: before the 9:41 on the screenshots' clock if
            // they're taken later in the day, or else about half an hour ago.
            if today { started = min(started, now.addingTimeInterval(-duration - 1_800)) }
            let points = trackPoints(along: route, from: started)
            let ended = Date(timeIntervalSince1970: points.last?.time ?? started.timeIntervalSince1970)
            var walk = Walk(startedAt: started, endedAt: ended, points: points)
            walk.steps = Int(CoverageTracer.distance(for: points) / 0.74)
            walks.append(walk)
        }
        return walks
    }

    /// GPS fixes every 10 metres or so along the route, at walking pace.
    static func trackPoints(along route: [Coordinate], from start: Date) -> [TrackPoint] {
        guard var prev = route.first else { return [] }
        var time = start.timeIntervalSince1970
        var points = [TrackPoint(lat: prev.lat, lon: prev.lon, time: time, accuracy: 5, speed: pace)]
        for next in route.dropFirst() {
            let d = prev.distance(to: next)
            let n = max(1, Int((d / 10).rounded(.up)))
            for k in 1...n {
                let c = prev.lerp(to: next, Double(k) / Double(n))
                time += d / Double(n) / pace
                points.append(TrackPoint(lat: c.lat, lon: c.lon, time: time, accuracy: 5, speed: pace))
            }
            prev = next
        }
        return points
    }

    /// The streets and paths inside the place, joined where they share a node.
    struct Graph {
        struct Edge: Hashable { var a: Int, b: Int; init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) } }
        var nodes: [Coordinate] = []
        var neighbours: [[Int]] = []

        init(lines: [RoadLine], shape: BoundaryShape, projection: some GeoProjection) {
            var index: [String: Int] = [:]
            func node(_ c: Coordinate) -> Int? {
                guard shape.contains(projection.project(c)) else { return nil }
                let key = "\(Int((c.lat * 1e5).rounded())),\(Int((c.lon * 1e5).rounded()))"
                if let i = index[key] { return i }
                index[key] = nodes.count
                nodes.append(c)
                neighbours.append([])
                return nodes.count - 1
            }
            for line in lines {
                var last: Int?
                for c in line.points {
                    let i = node(c)
                    if let i, let last, i != last, !neighbours[i].contains(last) {
                        neighbours[i].append(last)
                        neighbours[last].append(i)
                    }
                    last = i
                }
            }
        }

        /// The edges a route of node coordinates runs along.
        static func edges(of route: [Coordinate], in graph: Graph) -> Set<Edge> {
            let index = Dictionary(graph.nodes.enumerated().map { ($1, $0) }) { a, _ in a }
            return Set(zip(route, route.dropFirst()).compactMap { a, b in
                guard let i = index[a], let j = index[b] else { return nil }
                return Edge(i, j)
            })
        }

        func nearest(to c: Coordinate) -> Int? {
            nodes.indices.filter { !neighbours[$0].isEmpty }.min { nodes[$0].distance(to: c) < nodes[$1].distance(to: c) }
        }

        func nearest(to c: Coordinate, among candidates: Set<Int>) -> Int? {
            candidates.min { nodes[$0].distance(to: c) < nodes[$1].distance(to: c) }
        }

        /// Every node you can get to from `start` along the streets.
        func reachable(from start: Int) -> Set<Int> {
            var seen: Set = [start]
            var queue = [start]
            while let n = queue.popLast() {
                for m in neighbours[n] where seen.insert(m).inserted { queue.append(m) }
            }
            return seen
        }

        /// Out to `destination` and back by another way, both along streets it hasn't
        /// walked much, the way you'd pick a new bit to explore each time.
        func loop(from start: Int, to destination: Int, walked: inout Set<Edge>) -> [Coordinate] {
            let out = shortestPath(from: start, to: destination, avoiding: walked)
            for (a, b) in zip(out, out.dropFirst()) { walked.insert(Edge(a, b)) }
            let back = shortestPath(from: destination, to: start, avoiding: walked)
            for (a, b) in zip(back, back.dropFirst()) { walked.insert(Edge(a, b)) }
            return (out + back.dropFirst()).map { nodes[$0] }
        }

        /// Dijkstra, with streets already walked counting four times as long.
        func shortestPath(from a: Int, to b: Int, avoiding walked: Set<Edge>) -> [Int] {
            var best = [Double](repeating: .infinity, count: nodes.count)
            var via = [Int](repeating: -1, count: nodes.count)
            var open = Heap()
            open.push(0, a)
            best[a] = 0
            while let (d, n) = open.pop() {
                if n == b { break }
                if d > best[n] { continue }
                for m in neighbours[n] {
                    let length = nodes[n].distance(to: nodes[m]) * (walked.contains(Edge(n, m)) ? 4 : 1)
                    if d + length < best[m] { best[m] = d + length; via[m] = n; open.push(d + length, m) }
                }
            }
            guard a == b || via[b] != -1 else { return [a] }
            var out = [b]
            while out.last != a { out.append(via[out.last!]) }
            return out.reversed()
        }
    }

    /// A binary min-heap of (cost, node).
    struct Heap {
        private var items: [(Double, Int)] = []

        mutating func push(_ cost: Double, _ node: Int) {
            items.append((cost, node))
            var i = items.count - 1
            while i > 0, items[(i - 1) / 2].0 > items[i].0 {
                items.swapAt(i, (i - 1) / 2)
                i = (i - 1) / 2
            }
        }

        mutating func pop() -> (Double, Int)? {
            guard let top = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < items.count, items[l].0 < items[m].0 { m = l }
                    if r < items.count, items[r].0 < items[m].0 { m = r }
                    if m == i { break }
                    items.swapAt(i, m)
                    i = m
                }
            }
            return top
        }
    }

    /// SplitMix64, so the sample is the same every time.
    struct Random {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

nonisolated extension CoverageTracer {
    /// Straight-line length of a route, in metres.
    static func distanceAlong(_ route: [Coordinate]) -> Double {
        zip(route, route.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }
}
#endif
