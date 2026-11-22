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
    private let protectedDataAvailable: () -> Bool
    private let loadSaved: () -> Void
    private let start: () -> Void
    private var removeObserver: (() -> Void)?

    init(waitForUnlock: Bool, openFence: @escaping () -> Void,
         observeUnlock: @escaping (@escaping () -> Void) -> (() -> Void),
         protectedDataAvailable: @escaping () -> Bool,
         loadSaved: @escaping () -> Void, start: @escaping () -> Void) {
        self.waitForUnlock = waitForUnlock
        self.openFence = openFence
        self.observeUnlock = observeUnlock
        self.protectedDataAvailable = protectedDataAvailable
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
            // It might also have unlocked just before the observer was registered.
            if protectedDataAvailable() { unlocked() }
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
