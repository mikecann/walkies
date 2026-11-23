import Foundation

/// The launch ordering is shared by foreground launches and fence wakes with no window.
/// Waiting is only for the first unlock after a reboot, not every time the screen locks.
final class AppStartup {
    enum State: Equatable {
        case created
        case waitingForUnlock
        case starting
        case running
    }

    let waitForUnlock: Bool
    private(set) var state: State = .created
    private let openFence: () -> Void
    private let observeUnlock: (@escaping () -> Void) -> (() -> Void)
    private let savedDataReadable: () -> Bool
    private let loadSaved: () -> Void
    private let start: () -> Void
    private var removeObserver: (() -> Void)?

    init(savedDataReadable: @escaping () -> Bool, openFence: @escaping () -> Void,
         observeUnlock: @escaping (@escaping () -> Void) -> (() -> Void),
         loadSaved: @escaping () -> Void, start: @escaping () -> Void) {
        self.waitForUnlock = !savedDataReadable()
        self.openFence = openFence
        self.observeUnlock = observeUnlock
        self.savedDataReadable = savedDataReadable
        self.loadSaved = loadSaved
        self.start = start
    }

    /// Only created → waiting/starting → running are allowed. Mark each move before
    /// calling out, since registering an observer or starting services can call back.
    func launch() {
        guard state == .created else { return }
        state = waitForUnlock ? .waitingForUnlock : .starting
        // Do this even while waiting: CLMonitor has to deliver the exit that woke us.
        openFence()
        if waitForUnlock {
            let remove = observeUnlock { [weak self] in self?.unlocked() }
            // A notification can arrive during observer registration itself.
            if state == .waitingForUnlock { removeObserver = remove }
            else { remove() }
            // It might have unlocked and locked again before the observer was registered.
            // Use the same readability probe, not just the screen's current lock state.
            if savedDataReadable() { unlocked() }
        } else {
            start()
            state = .running
        }
    }

    func unlocked() {
        guard state == .waitingForUnlock else { return }
        state = .starting
        removeObserver?()
        removeObserver = nil
        loadSaved()
        start()
        state = .running
    }
}
