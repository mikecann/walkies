import Foundation
import Testing
@testable import Walkies

@MainActor
struct FirstUnlockTests {
    @Test func aLockedPhoneStartsWhenTheSavedProbeIsReadable() {
        var wrote = false
        #expect(FirstUnlock.happened(protectedDataAvailable: false, readProbe: { true }, makeProbe: {
            wrote = true
            return false
        }))
        #expect(!wrote)
    }

    @Test func beforeTheFirstUnlockNeitherReadingNorCreatingTheProbeWorks() {
        #expect(!FirstUnlock.happened(protectedDataAvailable: false, readProbe: { false }, makeProbe: { false }))
    }

    @Test func aMissingProbeCanBeCreatedWhileLockedAfterTheFirstUnlock() {
        var writes = 0
        #expect(FirstUnlock.happened(protectedDataAvailable: false, readProbe: { false }, makeProbe: {
            writes += 1
            return true
        }))
        #expect(writes == 1)
    }

    @Test func anUnlockedPhoneDoesNotNeedAProbe() {
        var touched = false
        #expect(FirstUnlock.happened(protectedDataAvailable: true, readProbe: {
            touched = true
            return false
        }, makeProbe: {
            touched = true
            return false
        }))
        #expect(!touched)
    }
}

@MainActor
struct StartupTests {
    private final class Launch {
        var events: [String] = []
        var available = false
        var callback: (() -> Void)?
        var unlockWhileObserving = false
        var unlockBeforeObserving = false
        lazy var startup = AppStartup(
            waitForUnlock: waitForUnlock,
            openFence: {
                self.events.append("fence")
                if self.unlockBeforeObserving { self.available = true }
            },
            observeUnlock: { callback in
                self.events.append("observe")
                self.callback = callback
                if self.unlockWhileObserving { callback() }
                return { self.events.append("unobserve") }
            },
            protectedDataAvailable: { self.available },
            loadSaved: { self.events.append(contentsOf: ["account", "model", "sync"]) },
            start: { self.events.append("start") }
        )
        let waitForUnlock: Bool
        init(waitForUnlock: Bool) { self.waitForUnlock = waitForUnlock }
    }

    @Test func lockedButReadableStartsWithoutWaitingForTheScreenToUnlock() {
        let readable = FirstUnlock.happened(protectedDataAvailable: false, readProbe: { true }, makeProbe: { false })
        let launch = Launch(waitForUnlock: !readable)
        launch.startup.launch()
        #expect(launch.events == ["fence", "start"])
        #expect(launch.startup.state == .running)
    }

    @Test func beforeFirstUnlockItOpensTheFenceButDoesNotLoadOrStart() {
        let launch = Launch(waitForUnlock: true)
        launch.startup.launch()
        #expect(launch.events == ["fence", "observe"])
        #expect(launch.startup.state == .waitingForUnlock)
        launch.callback?()
        #expect(launch.events == ["fence", "observe", "unobserve", "account", "model", "sync", "start"])
        #expect(launch.startup.state == .running)
    }

    @Test func unlockJustBeforeObserverRegistrationIsCaughtByTheRecheck() {
        let launch = Launch(waitForUnlock: true)
        launch.unlockBeforeObserving = true
        launch.startup.launch()
        #expect(launch.events == ["fence", "observe", "unobserve", "account", "model", "sync", "start"])
        #expect(launch.startup.state == .running)
    }

    @Test func unlockDuringObserverRegistrationStillRemovesTheObserver() {
        let launch = Launch(waitForUnlock: true)
        launch.unlockWhileObserving = true
        launch.startup.launch()
        #expect(launch.events == ["fence", "observe", "account", "model", "sync", "start", "unobserve"])
        #expect(launch.startup.state == .running)
    }

    @Test func launchAndUnlockCallbacksCanBeRepeatedWithoutStartingTwice() {
        for waiting in [false, true] {
            let launch = Launch(waitForUnlock: waiting)
            launch.startup.unlocked()
            #expect(launch.startup.state == .created)
            launch.startup.launch()
            launch.startup.launch()
            launch.callback?()
            launch.callback?()
            launch.startup.launch()
            #expect(launch.events.filter { $0 == "start" }.count == 1)
            #expect(launch.events.filter { $0 == "fence" }.count == 1)
            #expect(launch.events.filter { $0 == "model" }.count == (waiting ? 1 : 0))
        }
    }

    @Test func callbacksDuringLoadingCannotStartTheServicesAgain() {
        var starts = 0
        var loads = 0
        var startup: AppStartup!
        startup = AppStartup(waitForUnlock: true, openFence: {}, observeUnlock: { _ in {} },
                             protectedDataAvailable: { true }, loadSaved: {
            loads += 1
            startup.launch()
            startup.unlocked()
        }, start: {
            starts += 1
            startup.unlocked()
        })
        startup.launch()
        #expect(loads == 1)
        #expect(starts == 1)
        #expect(startup.state == .running)
    }
}
