import CoreLocation
import os

/// Decides where the stationary fence goes. Always on keeps a circle around wherever
/// you've settled, so leaving it wakes the app straight away rather than waiting
/// for a cell tower change, which can take a kilometre or more.
nonisolated struct StationaryFence {
    static let radius = 100.0
    /// Fixes within this of each other count as staying put.
    static let settleRadius = 30.0
    /// Staying put this long counts as settled, even if iOS doesn't say you're stationary.
    static let settleTime: TimeInterval = 2 * 60
    /// Fixes vaguer than this, in metres, are no good for placing it.
    static let worstAccuracy = 50.0

    /// Where the fence is now, if there is one.
    var center: Coordinate?
    private var settling: (point: Coordinate, time: TimeInterval)?

    init(center: Coordinate? = nil) {
        self.center = center
    }

    /// Returns where to put the fence when this fix means you've settled somewhere new.
    /// - Parameters:
    ///   - stationary: iOS says you've stopped moving.
    ///   - walking: a walk is in progress, so the first fix isn't necessarily where you'll stop.
    mutating func add(_ point: Coordinate, time: TimeInterval, accuracy: Double, stationary: Bool, walking: Bool) -> Coordinate? {
        guard accuracy >= 0, accuracy <= Self.worstAccuracy else { return nil }
        if let settling, settling.point.distance(to: point) <= Self.settleRadius, time >= settling.time {
            // Still here.
        } else {
            settling = (point, time)
        }
        let stayed = settling.map { time - $0.time >= Self.settleTime } ?? false
        guard stationary || stayed || (center == nil && !walking) else { return nil }
        if let center, center.distance(to: point) <= Self.settleRadius { return nil }
        center = point
        return point
    }

    mutating func reset() {
        center = nil
        settling = nil
    }
}

/// A circle iOS watches for us, even while the app isn't running.
protocol Geofence: AnyObject {
    /// Called when you leave the circle.
    var onExit: (() -> Void)? { get set }
    /// Called once it's open, with where the circle was left last time.
    var onOpen: ((Coordinate?) -> Void)? { get set }
    func open()
    func place(around center: Coordinate, radius: Double)
    func remove()
}

/// The stationary fence as a CLMonitor. iOS keeps its condition between launches and
/// relaunches the app in the background when it changes, so it has to be opened again
/// by the same name at launch for that event to be delivered.
final class MonitorFence: Geofence {
    /// iOS allows one monitor per name in a process, so every tracker shares this one.
    static let shared = MonitorFence()
    nonisolated private static let log = Logger(subsystem: "com.mikecann.walkies", category: "location")
    /// Letters and digits only: CLMonitor throws on anything else.
    private static let name = "WalkiesStationary"
    private static let identifier = "here"

    var onExit: (() -> Void)?
    var onOpen: ((Coordinate?) -> Void)?
    private var monitor: Task<CLMonitor, Never>?
    private var events: Task<Void, Never>?
    /// The last add or remove, so they reach the monitor in order.
    private var change: Task<Void, Never>?

    private init() {}

    func open() {
        _ = opened()
    }

    func place(around center: Coordinate, radius: Double) {
        let monitor = opened()
        let previous = change
        change = Task {
            await previous?.value
            let condition = CLMonitor.CircularGeographicCondition(center: center.cl, radius: radius)
            await monitor.value.add(condition, identifier: Self.identifier, assuming: .satisfied)
        }
    }

    func remove() {
        let monitor = opened()
        let previous = change
        change = Task {
            await previous?.value
            await monitor.value.remove(Self.identifier)
        }
    }

    private func opened() -> Task<CLMonitor, Never> {
        if let monitor { return monitor }
        let monitor = Task { await CLMonitor(Self.name) }
        self.monitor = monitor
        events = Task { [weak self] in
            let monitor = await monitor.value
            let record = await monitor.record(for: Self.identifier)
            let condition = record?.condition as? CLMonitor.CircularGeographicCondition
            // Already left it: there's no fence to be inside until you settle somewhere new.
            let left = record?.lastEvent.state == .unsatisfied
            self?.onOpen?(left ? nil : condition.map { Coordinate($0.center) })
            do {
                for try await event in await monitor.events {
                    guard event.identifier == Self.identifier else { continue }
                    Self.log.info("Stationary fence: \(String(describing: event.state))")
                    if event.state == .unsatisfied { self?.onExit?() }
                }
            } catch {
                Self.log.error("Stationary fence stopped: \(error)")
            }
        }
        return monitor
    }
}
