import Foundation

/// Where a walk is in its life. Every move between stages goes through `after(_:)`,
/// and shared/fixtures/walk-stages.json lists the same moves for both platforms.
/// docs/walk-lifecycle.md has the diagram and why each stage exists.
nonisolated enum WalkStage: String, Codable, Sendable, CaseIterable {
    /// Always on has seen you set off, but you're not far enough from the start
    /// for it to count. It uncovers nothing yet, and is dropped if it ends like this.
    case tentative
    /// Recording, and uncovering tiles on the map (not yet in saved places).
    case walking
    /// Closed: route, end and tile credit are in the walk's own file. Its credit
    /// may not be in the saved places yet.
    case sealed
    /// Its credit is in the saved places too. Nothing more happens to it apart from
    /// steps arriving late, which don't change its stage.
    case done

    enum Event: String, Codable, Sendable, CaseIterable {
        /// Far enough from where a tentative walk started.
        case confirmed
        /// A gap, a quiet spell, a ride somewhere else, End walk, or always on
        /// turned off, and the walk counts (or you pressed End).
        case ended
        /// A tentative walk that ended without counting. Its file goes.
        case dropped
        /// Its credit was saved into places.
        case committed
    }

    /// The stage after `event`, or nil when that move isn't allowed and the event
    /// must be ignored. Dropping is allowed from `tentative` and leaves no stage.
    func after(_ event: Event) -> WalkStage? {
        switch (self, event) {
        case (.tentative, .confirmed): .walking
        case (.tentative, .ended), (.walking, .ended): .sealed
        case (.sealed, .committed): .done
        default: nil
        }
    }

    func allows(_ event: Event) -> Bool {
        after(event) != nil || (self == .tentative && event == .dropped)
    }

    /// Still recording.
    var isOpen: Bool { self == .tentative || self == .walking }
}
