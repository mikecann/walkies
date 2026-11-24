import CoreLocation
import Foundation
import Observation
import os

@Observable
final class AppModel {
    private(set) var cities: [City] = []
    private(set) var walks: [Walk] = []
    private(set) var teams: [Team] = []
    var pendingTeamInvite: String?
    /// A tapped notification's destination, held here because a tap can launch the app
    /// before there's any screen to take it. ContentView takes it when it's up.
    var notificationTarget: NotificationTarget?
    var teamNotice: String?
    private(set) var teamMembershipRevision = 0
    var selectedCityID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedCityID?.uuidString, forKey: "selectedCity")
        }
    }
    /// Bumps when the map should fly to the selected place: when you pick or add one,
    /// not when it changes because you've walked into it.
    private(set) var flyToSelected = 0
    /// Where you were at the last GPS fix, for things like sorting secrets by distance.
    private(set) var lastLocation: CLLocation?
    /// Set when the app opens, so the next fix selects the place you're in. Otherwise the
    /// selection only follows you on a walk, so looking at another place sticks.
    @ObservationIgnored var placeYouOnNextFix = true
    private(set) var activeWalk: Walk? {
        didSet {
            updateLiveSteps()
            scheduleStaleWalkCheck()
            if (activeWalk == nil) != (oldValue == nil) || autoWalkPending != (oldValue?.stage == .tentative) {
                tracker.refreshWatch()
            }
        }
    }
    /// Accepted fixes from the current walk, for drawing the line on the map.
    private(set) var activePath: [Coordinate] = []
    /// Tiles uncovered on the current walk, per city, so the map can make a fuss of them.
    private(set) var freshTiles: [UUID: Set<Hex>] = [:]
    /// Bumps whenever any city's tiles change.
    private(set) var tilesRevision = 0
    /// Bumps for every newly uncovered tile, to drive haptics.
    private(set) var revealCount = 0
    /// Set when a walk ends, to play the celebration.
    var recap: WalkRecap?
    /// The map is always tilted, isometric-style, with Apple's 3D buildings and trees.
    let tilted3D = true
    /// Whether the first-run setup (location, motion, notifications, Always on) is done.
    var setupDone = UserDefaults.standard.bool(forKey: "setupDone") {
        didSet { UserDefaults.standard.set(setupDone, forKey: "setupDone") }
    }
    /// Record walks by themselves in the background, so there's no Start walk to press.
    var alwaysOn = false {
        didSet {
            guard alwaysOn != oldValue, !loading, !locked else { return }
            UserDefaults.standard.set(alwaysOn, forKey: "alwaysOn")
            alwaysOn ? turnOnAlwaysOn() : turnOffAlwaysOn()
        }
    }

    /// In always-on mode, a walk ends after this long without moving on foot.
    /// Overridable with `-autoWalkGap <seconds>` for testing in the simulator (Debug only).
    static var autoWalkGap: TimeInterval {
        #if DEBUG
        let override = UserDefaults.standard.double(forKey: "autoWalkGap")
        if override > 0 { return override }
        #endif
        return 10 * 60
    }

    /// Shorter than this and it wasn't really a walk: pottering round the house, or
    /// GPS drift. Any tiles it uncovered stay uncovered.
    static let minimumAutoWalk = 300.0

    /// Seconds the tracer's last spot can be old and still start a new always-on walk.
    static let freshStart = 120.0

    /// An always-on walk only counts once you've got this far (metres, as the crow
    /// flies) from where it started. GPS indoors can wander tens of metres back and
    /// forth, which adds up as distance but never carries you this far away.
    static let autoWalkConfirmDistance = 150.0

    /// True while an always-on walk has started but you haven't gone far enough yet to
    /// be sure it's a real one. Nothing gets uncovered until it's sure.
    var autoWalkPending: Bool { activeWalk?.stage == .tentative }

    let tracker: LocationTracker
    let motion = MotionMonitor()
    let stepCounter = StepCounter()
    var countSteps = UserDefaults.standard.object(forKey: "countSteps") as? Bool ?? true {
        didSet {
            guard countSteps != oldValue else { return }
            UserDefaults.standard.set(countSteps, forKey: "countSteps")
            stepSettingRevision += 1
            stepCounter.clear()
            updateLiveSteps()
            Task { await refreshStepsToday() }
        }
    }
    @ObservationIgnored private var stepsInForeground = false
    @ObservationIgnored private var stepSettingRevision = 0
    /// Tests can supply a delayed count without Core Motion.
    @ObservationIgnored var querySteps: ((Date, Date) async -> Int?)?
    /// Tests can say when you set off without Core Motion.
    @ObservationIgnored var querySetOff: ((Date) async -> Date?)?

    func stepsForeground(_ foreground: Bool) {
        stepsInForeground = foreground
        updateLiveSteps()
        if foreground { Task { await refreshStepsToday() } }
    }

    private func updateLiveSteps() {
        stepCounter.updateLive(from: servicesEnabled && countSteps && stepsInForeground ? activeWalk?.startedAt : nil)
    }

    func refreshStepsToday() async {
        await stepCounter.refreshToday(enabled: servicesEnabled && countSteps && setupDone)
    }

    /// Steps are asked for once a walk has closed, never before: by then it's saved and
    /// the tracker is free for the next outing. They fill in when the motion chip answers
    /// (or at the next launch, if the app stopped first), and the walk syncs again.
    private func askForSteps(_ id: UUID) {
        guard countSteps, servicesEnabled || querySteps != nil,
              let walk = walks.first(where: { $0.id == id }), walk.stepsPending == true,
              let end = walk.endedAt, !askingSteps.contains(id) else { return }
        askingSteps.insert(id)
        let generation = dataGeneration
        let setting = stepSettingRevision
        Task {
            defer { askingSteps.remove(id) }
            let count: Int?
            if let querySteps { count = await querySteps(walk.startedAt, end) }
            else { count = await stepCounter.count(from: walk.startedAt, to: end) }
            guard generation == dataGeneration, let i = walks.firstIndex(where: { $0.id == id }),
                  walks[i].stepsPending == true else { return }
            walks[i].steps = countSteps && setting == stepSettingRevision ? count : nil
            walks[i].stepsPending = nil
            store.save(walks[i])
            // The celebration may be showing already: its count fills in.
            if recap?.walk.id == id { recap?.walk.steps = walks[i].steps }
            historyRevision += 1
            walksChanged?([id])
            requestSync?()
        }
    }
    @ObservationIgnored private let store: Store
    /// Wired by the app with Account.client(), just like sync. Tests leave it nil.
    @ObservationIgnored var makePlaceClient: (() async -> ConvexClient?)?
    @ObservationIgnored private var warmedNeighbourIds: [Int]?
    @ObservationIgnored private var warmingNeighbours = false
    @ObservationIgnored private let servicesEnabled: Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var tracer = CoverageTracer()
    @ObservationIgnored private var shapes: [UUID: BoundaryShape] = [:]
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var startWhenAllowed = false

    @ObservationIgnored private var historyTask: Task<Void, Never>?
    private(set) var historyReady = false
    private(set) var worldGridResetPending = false
    @ObservationIgnored private var dataGeneration = 0
    @ObservationIgnored private var recapRequest = 0
    @ObservationIgnored private var historyRevision = 0
    @ObservationIgnored private var placesRevision = 0
    @ObservationIgnored private var batchingProgress = false
    @ObservationIgnored private var countingTilesByPlace: [UUID: Int] = [:]
    @ObservationIgnored private(set) var questTileCounts: [UUID: [UUID: Int]] = [:]
    @ObservationIgnored private var addedTiles: [UUID: Set<Hex>] = [:]

    /// True when iOS launched the app in the background before the phone's first unlock
    /// since it started. Saved files can't be read yet, so nothing is loaded or saved
    /// until `loadSaved()`, or empty data would overwrite them.
    @ObservationIgnored private(set) var locked = false
    /// Loading sets these as they were saved, which isn't turning them on or off.
    @ObservationIgnored private var loading = false

    init(store: Store = Store(), servicesEnabled: Bool = true, alwaysOn: Bool? = nil, waitForUnlock: Bool = false, stepQuery: ((Date, Date) async -> Int?)? = nil, tracker: LocationTracker = LocationTracker(), now: @escaping () -> Date = { .now }) {
        self.store = store
        self.tracker = tracker
        self.now = now
        self.servicesEnabled = servicesEnabled
        self.querySteps = stepQuery
        tracker.onLocation = { [weak self] in self?.record($0) }
        tracker.onAuthorizationChange = { [weak self] in self?.authorizationChanged() }
        tracker.isWalking = { [weak self] in self?.activeWalk != nil }
        tracker.isOnConfirmedWalk = { [weak self] in self.map { $0.activeWalk != nil && !$0.autoWalkPending } ?? false }
        tracker.isOnManualWalk = { [weak self] in self?.activeWalk?.isAutomatic == false }
        tracker.isOnScreen = { [weak self] in self.map { $0.inForeground && $0.mapVisible } ?? false }
        tracker.isInForeground = { [weak self] in self?.inForeground ?? false }
        tracker.isOnWheels = { [weak self] in self?.motion.onWheels ?? false }
        tracker.isStill = { [weak self] in self?.motion.still ?? false }
        tracker.isOnFoot = { [weak self] in self?.motion.onFoot ?? false }
        motion.onChange = { [weak self] in self?.tracker.motionChanged() }
        locked = waitForUnlock
        if !waitForUnlock { load(alwaysOn: alwaysOn) }
    }

    /// Loads what was saved, once the phone's been unlocked.
    func loadSaved() {
        guard locked else { return }
        setupDone = UserDefaults.standard.bool(forKey: "setupDone")
        countSteps = UserDefaults.standard.object(forKey: "countSteps") as? Bool ?? true
        load(alwaysOn: nil)
        locked = false
    }

    private func load(alwaysOn: Bool?) {
        loading = true
        defer { loading = false }
        do { try store.prepareWorldGridReset() }
        catch { Self.log.error("Couldn't prepare world grid reset: \(error)") }
        worldGridResetPending = store.needsWorldGridReset
        if worldGridResetPending { UserDefaults.standard.removeObject(forKey: "lastSynced") }
        ledger = worldGridResetPending ? Ledger() : store.loadProgress()
        cities = worldGridResetPending ? [] : store.loadCities()
        autoPlaces = store.loadAutoPlaces() ?? AutoPlaces()
        if autoPlaces.walksSince == nil {
            // Walks from before this version are left alone.
            autoPlaces.walksSince = .now
            store.save(autoPlaces: autoPlaces)
        }
        teams = store.loadTeams()
        self.alwaysOn = alwaysOn ?? UserDefaults.standard.bool(forKey: "alwaysOn")

        let savedWalks = store.loadWalks()
        let saved = UserDefaults.standard.string(forKey: "selectedCity").flatMap(UUID.init)
        selectedCityID = cities.first { $0.id == saved }?.id ?? cities.first?.id

        if servicesEnabled { fetchMissingRoads() }
        foundStickers = worldGridResetPending ? [:] : store.loadStickers()
        // Before placing stickers, so the server's secrets are still wanted.
        serverLore = store.loadServerLore() ?? ServerLore()
        LoreLibrary.useServer(serverLore, stickers: store.serverStickers)
        placeStickers()
        refreshNeighbours()
        // Migration can be sizeable on an older phone. Never trace saved routes
        // while opening the app, reading balance or processing a location fix,
        // apart from the one walk that's still recording.
        loadWalks(savedWalks)
        rebuildCountingTiles()
        let generation = dataGeneration
        historyTask = Task {
            guard generation == dataGeneration else { return }
            await prepareHistory()
        }
        fillInLastWalked()
    }

    /// Picks up where the app left off (docs/walk-lifecycle.md): closes what older versions
    /// left open, finishes closing anything sealed, and carries on with the walk that
    /// was recording if it's recent enough, or closes it.
    private func loadWalks(_ saved: [Walk]) {
        var saved = saved
        if worldGridResetPending {
            // Every route is traced again under the new grid, so credit doesn't matter here.
            walks = saved.filter { $0.short != true }.map { walk in
                var walk = walk
                if walk.endedAt == nil { walk.endedAt = walk.points.last.map { Date(timeIntervalSince1970: $0.time) } ?? walk.startedAt }
                walk.stage = .done
                walk.pendingFinish = nil
                return walk
            }.sorted { $0.startedAt < $1.startedAt }
            return
        }
        let ids = Set(saved.map(\.id))
        for legacy in saved.filter(\.isLegacyOpen) {
            saved.removeAll { $0.id == legacy.id }
            saved += closeLegacy(legacy, existing: ids)
        }
        saved.sort(by: Progression.walkedFirst)
        let open = saved.filter { $0.currentStage.isOpen }
        walks = saved.filter { !$0.currentStage.isOpen && $0.short != true }
        for walk in saved where walk.stage == .sealed {
            commitAfterRelaunch(walk)
        }
        // Only ever one, but a crash at the wrong moment could leave an older one too.
        for (i, walk) in open.enumerated() {
            if i == open.count - 1, canResume(walk) {
                resume(walk)
            } else {
                resume(walk)
                let end = walk.points.last.map { Date(timeIntervalSince1970: $0.time) } ?? walk.startedAt
                closeWalk(at: end, reason: .recovered, byYou: !walk.isAutomatic)
            }
        }
        askForPendingSteps()
    }

    @ObservationIgnored private var askingSteps: Set<UUID> = []

    private func askForPendingSteps() {
        for walk in walks where walk.stepsPending == true && !askingSteps.contains(walk.id) {
            askForSteps(walk.id)
        }
    }

    private func canResume(_ walk: Walk) -> Bool {
        guard walk.currentStage.isOpen, !walk.isLegacyOpen, !worldGridResetPending,
              alwaysOn, walk.isAutomatic, let last = walk.points.last else { return false }
        return now().timeIntervalSince1970 - last.time < Self.autoWalkGap
    }

    /// Carries on with a walk the app was recording when it stopped. Saved places don't
    /// have its tiles (docs/walk-lifecycle.md), so they go back on the map from what it
    /// saved, and its route is traced again for anything after that.
    private func resume(_ walk: Walk) {
        activeWalk = walk
        tracer = CoverageTracer()
        if let anchor = walk.resumeAnchor ?? (walk.rideSeen == true ? nil : walk.points.last) {
            tracer.restart(from: anchor)
        }
        freshTiles = [:]
        addedTiles = [:]
        activePath = walk.stage == .tentative ? [] : walk.points.map(\.coordinate)
        guard walk.stage != .tentative, let last = walk.points.last else { return }
        // What it had uncovered by its last save, then anything since.
        for i in cities.indices {
            let key = cities[i].id.uuidString
            guard let hexes = walk.newTileHexesByPlace?[key], !hexes.isEmpty else { continue }
            let added = walk.addedTilesByPlace?[key] ?? []
            cities[i].visited.formUnion(hexes)
            cities[i].tiles.formUnion(added)
            freshTiles[cities[i].id] = hexes
            addedTiles[cities[i].id] = added
        }
        _ = visit(CoverageTracer.samples(for: walk.points), at: last.time, quietly: true)
    }

    /// The places as saved: without the open walk's new tiles, which only count once
    /// it closes. That way saved places only ever hold finished walks, and a walk's
    /// credit is worked out against everything before it and nothing after.
    private var committedCities: [City] {
        guard activeWalk != nil, !freshTiles.isEmpty else { return cities }
        return cities.map { city in
            guard let fresh = freshTiles[city.id], !fresh.isEmpty else { return city }
            var saved = city
            saved.visited.subtract(fresh)
            saved.tiles.subtract(addedTiles[city.id] ?? [])
            return saved
        }
    }

    private func saveCities() {
        store.save(committedCities)
    }

    /// Ends the open walk now and closes it straight away (docs/walk-lifecycle.md):
    /// its file, then its credit into saved places. Steps are asked for afterwards.
    /// - Parameter byYou: you pressed End walk, so it's kept however short.
    /// - Parameter keepTracer: the next outing starts from where the tracer is now.
    @discardableResult
    private func closeWalk(at end: Date, reason: Walk.EndReason, byYou: Bool, keepTracer: Bool = false) -> Bool {
        guard var walk = activeWalk, walk.currentStage.isOpen else { return false }
        let wasTentative = walk.stage == .tentative
        walk.distance = CoverageTracer.distance(for: walk.points)
        if wasTentative && !byYou {
            // Never far enough from the start to count, so it uncovered nothing.
            precondition(walk.currentStage.allows(.dropped))
            walk.endedAt = end
            walk.endReason = reason
            TrackerTrace.walkEnded(walk, kept: false, pending: true, reason: reason.rawValue,
                                   displacement: Self.displacement(of: walk.points))
            store.delete(walk)
            clearOpenWalk(keepTracer: keepTracer)
            return true
        }
        if wasTentative {
            // Pressing End makes even a short outing intentional, including its tiles.
            _ = visit(CoverageTracer.samples(for: walk.points), at: walk.points.last?.time ?? walk.startedAt.timeIntervalSince1970)
        }
        // Measure again by today's rules, so GPS wobble at home doesn't get kept as a
        // walk. Tiles it uncovered still count.
        let kept = !walk.isAutomatic || byYou || walk.distance >= Self.minimumAutoWalk
        walk.endedAt = end
        walk.endReason = reason
        walk.rideSeen = nil
        walk.resumeAnchor = nil
        walk.short = kept ? nil : true
        walk.stepsPending = kept && countSteps && (servicesEnabled || querySteps != nil) ? true : nil
        finishCoverage(of: &walk)
        walk.move(.ended)
        // If this can't be written, the walk stays open and closes on the next try.
        guard store.saveWalkCheckpoint(walk) else { return false }
        TrackerTrace.walkEnded(walk, kept: kept, pending: false, reason: reason.rawValue,
                               displacement: Self.displacement(of: walk.points))
        let fresh = freshTiles
        clearOpenWalk(keepTracer: keepTracer)
        if kept {
            let history = walks
            let counts = questTileCounts
            walks.append(walk)
            questTileCounts[walk.id] = fresh.mapValues(\.count)
            historyRevision += 1
            // If it ended by itself while the phone was in your pocket, this plays the
            // next time you open the app.
            recapRequest += 1
            recap = WalkRecap.make(walk: walk, cities: cities, fresh: fresh, found: foundStickers, history: history, counts: counts)
        } else if !fresh.isEmpty {
            // Doesn't count for walk history, distance, days or streaks, but its tiles do.
            questTileCounts[walk.id] = fresh.mapValues(\.count)
            historyRevision += 1
        }
        commit(walk)
        askForSteps(walk.id)
        refreshProgressPicks()
        requestSync?()
        addPlacesYouveBeen()
        return true
    }

    private func clearOpenWalk(keepTracer: Bool) {
        activeWalk = nil
        activePath = []
        freshTiles = [:]
        addedTiles = [:]
        if !keepTracer { tracer = CoverageTracer() }
        tilesRevision += 1
    }

    /// The rest of closing a walk: its credit saved into places, then it's done.
    /// A short outing keeps its tiles as a TileCredit on each place, and its file
    /// goes only once that's on disk.
    private func commit(_ sealed: Walk) {
        guard sealed.stage == .sealed, activeWalk == nil else { return }
        var walk = sealed
        if walk.short == true {
            for i in cities.indices {
                guard let hexes = walk.newTileHexesByPlace?[cities[i].id.uuidString], !hexes.isEmpty,
                      !(cities[i].tileCredits ?? []).contains(where: { $0.id == walk.id }) else { continue }
                cities[i].tileCredits = (cities[i].tileCredits ?? []) + [City.TileCredit(id: walk.id, at: walk.startedAt, hexes: hexes)]
                cities[i].updatedAt = .now
            }
        }
        saveCities()
        store.flush()
        walk.move(.committed)
        if walk.short == true {
            store.delete(walk)
        } else {
            store.save(walk)
            if let i = walks.firstIndex(where: { $0.id == walk.id }) { walks[i] = walk }
        }
    }

    /// A walk that closed just before the app stopped, whose credit may not have
    /// reached the saved places. Adding it again changes nothing if it did.
    private func commitAfterRelaunch(_ walk: Walk) {
        for i in cities.indices {
            let key = cities[i].id.uuidString
            guard let hexes = walk.newTileHexesByPlace?[key], !hexes.isEmpty else { continue }
            cities[i].visited.formUnion(hexes)
            cities[i].tiles.formUnion(walk.addedTilesByPlace?[key] ?? [])
            cities[i].updatedAt = .now
            _ = unlockStickers(in: cities[i], on: hexes, notify: false, popUp: false)
        }
        commit(walk)
    }

    /// Older versions saved tiles into places as you walked, and only closed a walk once
    /// its steps came in, carrying the next outing inside it. Close each of those now with
    /// the credit it had saved: its tiles are already in the saved places. One that was
    /// still recording, or never saved credit, comes back open, to be traced again and
    /// carried on or closed like any other.
    private func closeLegacy(_ walk: Walk, existing: Set<UUID>) -> [Walk] {
        let request = walk.pendingFinish
        let carried = (request?.carried ?? []).filter { !existing.contains($0.id) }
        var closed: [Walk] = []
        for var outing in [walk] + carried {
            let isFirst = outing.id == walk.id
            let byYou = isFirst && request?.byYou == true
            outing.pendingFinish = nil
            outing.endedAt = (isFirst ? request?.at : nil) ?? outing.points.last.map { Date(timeIntervalSince1970: $0.time) } ?? outing.startedAt
            outing.endReason = (isFirst ? request?.reason : nil) ?? .recovered
            outing.resumeAnchor = nil
            outing.distance = CoverageTracer.distance(for: outing.points)
            let credited = (outing.newTileHexesByPlace ?? [:]).values.contains { !$0.isEmpty }
            var reopened = outing
            reopened.endedAt = nil
            reopened.stage = credited || !outing.isAutomatic
                || Self.displacement(of: outing.points) >= Self.autoWalkConfirmDistance ? .walking : .tentative
            // Still recording when the app stopped and recent enough to carry on, or saved
            // before its tiles reached the places (a next outing it carried, or the moment
            // after a ride): open again, to be traced and carried on or closed like any other.
            if outing.newTileHexesByPlace == nil || (isFirst && request == nil && canResume(reopened)) {
                guard store.saveWalkCheckpoint(reopened) else { continue }
                closed.append(reopened)
                continue
            }
            let kept = !outing.isAutomatic || byYou || Self.countsAsAutoWalk(outing.points)
            if !kept && !credited { store.delete(outing); continue }
            outing.short = kept ? nil : true
            outing.stepsPending = kept && countSteps ? true : nil
            outing.stage = .sealed
            guard store.saveWalkCheckpoint(outing) else { continue }
            closed.append(outing)
        }
        return closed
    }

    /// Sync calls this before uploading anything. If the cache/network is unavailable,
    /// keep the descriptor file and retry on the next sync instead of accepting old tiles.
    func rebuildWorldGrid(using client: ConvexClient) async throws {
        guard worldGridResetPending else { return }
        await historyTask?.value
        try store.prepareWorldGridReset()
        let generation = dataGeneration
        var pending = try store.pendingResetPlaces()
        // Older City saves never retained osmId. Look each name up once, a second
        // apart as Nominatim asks, and keep what's found so a retry carries on from there.
        var searched = false
        for i in pending.indices where pending[i].osmId == nil {
            if searched { try await Task.sleep(for: .seconds(1.2)) }
            searched = true
            let saved = pending[i]
            let matches = try await OSMClient.searchPlaces("\(saved.name), \(saved.detail)", session: client.session)
            if let match = matches.first(where: {
                $0.name.caseInsensitiveCompare(saved.name) == .orderedSame
                    && $0.boundary.centre.distance(to: saved.boundary.centre) < 10_000
            }) {
                pending[i].osmId = match.osmId
                try store.savePendingResetPlaces(pending)
            }
        }
        var rebuilt: [City] = []
        for saved in pending {
            var place = PlaceResult(id: 0, name: saved.name, detail: saved.detail, kind: "suburb",
                                    boundary: saved.boundary, area: 0, osmId: saved.osmId)
            let city: City
            if let osmId = place.osmId {
                let cached = try await CachedPlaceData.fetch(osmId: osmId, client: client)
                place.boundary = cached.boundary
                city = await Task.detached(priority: .utility) {
                    CityBuilder.build(from: place, ways: cached.ways, walks: [], streetsVersion: cached.streetsVersion)
                }.value
            } else {
                // Custom/retired boundaries can still be rebuilt from current OSM ways.
                city = try await CityBuilder.build(from: place, walks: [], client: client, status: { _ in })
            }
            var restored = city
            restored.id = saved.id
            restored.createdAt = saved.createdAt
            restored.updatedAt = .now
            rebuilt.append(restored)
        }
        guard generation == dataGeneration else { throw CancellationError() }
        cities = rebuilt
        shapes = [:]
        foundStickers = [:]
        ledger = Ledger()
        placeStickers()
        let replayCities = cities
        let replayWalks = walks
        let replayed = await Task.detached(priority: .utility) {
            CityBuilder.replay(replayWalks, through: replayCities)
        }.value
        guard generation == dataGeneration else { throw CancellationError() }
        cities = replayed.cities
        let savedSelection = UserDefaults.standard.string(forKey: "selectedCity").flatMap(UUID.init)
        if let id = cities.first(where: { $0.id == savedSelection })?.id ?? cities.first?.id { select(id) }
        walks = replayed.walks
        foundStickers = replayed.secrets
        stickerQueue = []
        secretsAlreadyWalked = 0
        // Remove the retry marker only after all rebuilt files are on disk.
        try store.finishWorldGridReset(cities: cities, walks: walks, stickers: foundStickers, progress: ledger)
        worldGridResetPending = false
        placesRevision += 1
        tilesRevision += 1
        rebuildCountingTiles()
        await prepareHistory()
        fillInLastWalked()
        if servicesEnabled { resumeAlwaysOn(); refreshNeighbours() }
    }

    private func rebuildCountingTiles() {
        countingTilesByPlace = Dictionary(cities.map { ($0.id, $0.tiles.intersection($0.visited).count) }, uniquingKeysWith: max)
    }

    func waitForHistory() async { await historyTask?.value }

    private func prepareHistory() async {
        guard !worldGridResetPending else { return }
        let generation = dataGeneration
        // The open walk's tiles are counted live, from freshTiles, until it closes.
        let savedWalks = walks
        let savedCities = committedCities
        let repaired = await Task.detached(priority: .utility) {
            Progression.backfill(walks: savedWalks, cities: savedCities)
        }.value
        guard generation == dataGeneration else { return }
        installBackfill(repaired)
        historyReady = true
        historyRevision += 1
        refreshProgressPicks()
    }

    private func installBackfill(_ repaired: Progression.Backfill) {
        let byID = Dictionary(repaired.walks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for i in walks.indices {
            guard let recovered = byID[walks[i].id] else { continue }
            let newTiles = recovered.newTileHexesByPlace.map { $0.values.reduce(0) { $0 + $1.count } } ?? recovered.newTiles
            if walks[i].newTiles != newTiles || walks[i].newTilesByPlace != recovered.newTilesByPlace || walks[i].newTileHexesByPlace != recovered.newTileHexesByPlace {
                walks[i].newTiles = newTiles
                walks[i].newTilesByPlace = recovered.newTilesByPlace
                walks[i].newTileHexesByPlace = recovered.newTileHexesByPlace
                store.save(walks[i])
            }
        }
        questTileCounts = repaired.counts
        for walk in walks where questTileCounts[walk.id] == nil {
            questTileCounts[walk.id] = Dictionary((walk.newTilesByPlace ?? [:]).compactMap { key, n in UUID(uuidString: key).map { ($0, n) } }, uniquingKeysWith: +)
        }
    }

    /// Cities saved before we kept road lines get them fetched again in the background.
    private func fetchMissingRoads() {
        for city in cities where city.roads == nil {
            let id = city.id
            let b = city.boundary.bounds
            Task {
                guard let ways = try? await OSMClient.walkableWays(south: b.south, west: b.west, north: b.north, east: b.east),
                      let i = cities.firstIndex(where: { $0.id == id })
                else { return }
                cities[i].roads = CityBuilder.roadLines(from: ways)
                cities[i].updatedAt = .now
                tilesRevision += 1
                saveCities()
            }
        }
    }

    @ObservationIgnored private var refreshingStreets = false

    /// Places built before the current WalkableRule (busy roads used to count) get
    /// their street tiles worked out again, once each, quietly in the background.
    /// Visited tiles, credits, stickers and secrets are kept; only which tiles count,
    /// and so the clouds and %, change. Waits for a server that has the new streets.
    /// Walks carry on recording meanwhile: only the tile sets are swapped at the end.
    func refreshStreets() {
        Task { await updateStreets() }
    }

    func updateStreets() async {
        guard !locked, !worldGridResetPending, !refreshingStreets, let makePlaceClient,
              cities.contains(where: { ($0.streetsVersion ?? 0) < WalkableRule.version }) else { return }
        refreshingStreets = true
        defer { refreshingStreets = false }
        let generation = dataGeneration
        guard let client = await makePlaceClient() else { return }
        for id in cities.filter({ ($0.streetsVersion ?? 0) < WalkableRule.version }).map(\.id) {
            guard generation == dataGeneration, let city = cities.first(where: { $0.id == id }) else { return }
            let ways: [OSMWay], version: Int
            do {
                if let osmId = city.osmId {
                    let cached = try await CachedPlaceData.fetch(osmId: osmId, client: client)
                    // An older server's streets aren't filtered yet. Try again another time.
                    guard let streets = cached.streetsVersion else { return }
                    (ways, version) = (cached.ways, streets)
                } else {
                    let b = city.boundary.bounds
                    ways = try await OSMClient.walkableWays(south: b.south, west: b.west, north: b.north, east: b.east, session: client.session)
                    version = WalkableRule.version
                }
            } catch {
                Self.log.info("Couldn't update the streets for \(city.name): \(error)")
                continue
            }
            let boundary = city.boundary
            let (tiles, roads) = await Task.detached(priority: .utility) {
                let grid = HexGrid.world
                let inside = City.hexes(inside: BoundaryShape(boundary, projection: grid.projection), grid: grid)
                return (CityBuilder.streetTiles(from: ways, inside: inside), CityBuilder.roadLines(from: ways))
            }.value
            guard generation == dataGeneration, !worldGridResetPending,
                  let i = cities.firstIndex(where: { $0.id == id }), (cities[i].streetsVersion ?? 0) < version else { continue }
            cities[i].replaceStreetTiles(tiles, roads: roads, version: version)
            cities[i].updatedAt = .now
            placesRevision += 1
            tilesRevision += 1
            rebuildCountingTiles()
            saveCities()
            requestSync?()
        }
    }

    var selectedCity: City? { cities.first { $0.id == selectedCityID } }

    /// What the cloud layer draws: every place at once. Working out which tiles are
    /// clouded takes a moment on a big place, so after the first time it's redone off
    /// the main thread when the tiles change, with the last one showing until it's ready.
    @ObservationIgnored private var clouds: (key: String, field: CloudField)?
    @ObservationIgnored private var buildingClouds = false
    private var cloudsBuilt = 0

    var cloudKey: String { currentClouds.key }
    var cloudField: CloudField { currentClouds.field }

    /// Also changes as time passes, for tiles misting over while the app's open.
    private var wantedCloudKey: String { "\(tilesRevision)-\(cities.count)-\(Mist.epoch(.now, days: Mist.days))" }

    private var currentClouds: (key: String, field: CloudField) {
        _ = cloudsBuilt
        let key = wantedCloudKey
        guard let clouds else {
            let first = (key, CloudField(cities: cities, mistAt: .now))
            clouds = first
            return first
        }
        if clouds.key != key { buildClouds(key) }
        return clouds
    }

    /// One at a time. When it's done, the map reads the clouds again and starts the
    /// next if the tiles have changed since.
    private func buildClouds(_ key: String) {
        guard !buildingClouds else { return }
        buildingClouds = true
        let cities = cities
        let generation = dataGeneration
        Task {
            let field = await Task.detached(priority: .userInitiated) { CloudField(cities: cities, mistAt: .now) }.value
            buildingClouds = false
            if generation == dataGeneration { clouds = (key, field) }
            cloudsBuilt += 1
        }
    }

    /// Every world tile a finished walk has been through, cleared from the world's clouds
    /// (`WorldClouds`). Worked out off the main thread when the walks change, with the
    /// last one showing until it's ready. The walk going now is added by the map.
    @ObservationIgnored private var walkedTiles: (key: String, hexes: Set<Hex>)?
    @ObservationIgnored private var buildingWalked = false
    private var walkedBuilt = 0

    var walkedHexes: Set<Hex> {
        _ = walkedBuilt
        let key = "\(dataGeneration)-\(walks.count)-\(walks.reduce(0) { $0 + $1.points.count })"
        if walkedTiles?.key != key, !buildingWalked {
            buildingWalked = true
            let walks = walks
            Task {
                let hexes = await Task.detached(priority: .utility) { CoverageTracer.worldTiles(of: walks) }.value
                buildingWalked = false
                walkedTiles = (key, hexes)
                walkedBuilt += 1
            }
        }
        return walkedTiles?.hexes ?? []
    }

    // MARK: Walks

    func startWalk() {
        guard !locked, !worldGridResetPending, activeWalk == nil, !alwaysOn else { return }
        if servicesEnabled {
            switch tracker.authorization {
            case .notDetermined:
                startWhenAllowed = true
                tracker.requestPermissionIfNeeded()
                return
            case .denied, .restricted:
                return
            default:
                break
            }
        }
        activeWalk = Walk(startedAt: .now, newTilesByPlace: [:], newTileHexesByPlace: [:], addedTilesByPlace: [:])
        activePath = []
        freshTiles = [:]
        addedTiles = [:]
        tracer = CoverageTracer()
        if servicesEnabled {
            tracker.start()
            Notifier.requestPermission()
        }
    }

    func endWalk() {
        guard activeWalk != nil else { return }
        tracker.stop()
        closeWalk(at: now(), reason: .you, byYou: true)
    }

    /// Plays an old walk's replay again, from walk history. Which tiles were new
    /// on it is worked out again: the tiles under its route that no earlier walk crossed.
    /// It's marked as a rewatch, so it only recaps the walk and awards nothing.
    func replay(_ walk: Walk) {
        let earlier = walks.filter { $0.id != walk.id && $0.startedAt < walk.startedAt }
        let savedCities = cities
        let counts = questTileCounts
        let found = foundStickers
        let generation = dataGeneration
        recapRequest += 1
        let request = recapRequest
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var fresh: [UUID: Set<Hex>] = [:]
                var before = savedCities
                for i in before.indices {
                    var city = before[i]
                    city.visited = []
                    let shape = city.shape()
                    for old in earlier { _ = city.visit(CoverageTracer.samples(for: old.points), within: shape) }
                    let new = city.visit(CoverageTracer.samples(for: walk.points), within: shape)
                    if !new.isEmpty { fresh[city.id] = new }
                    before[i] = city
                }
                var recap = WalkRecap.make(walk: walk, cities: before, fresh: fresh, found: found, history: earlier, counts: counts)
                recap.isRewatch = true
                recap.earnings = Progression.WalkEarnings()
                return recap
            }.value
            if generation == dataGeneration, request == recapRequest { recap = result }
        }
    }

    #if DEBUG
    /// Screenshot mode (ScreenshotMode.swift): you're at `location`, and with `recap` the
    /// latest walk has just finished, so its celebration plays as if it were new.
    func showSample(at location: CLLocation, recap showRecap: Bool) {
        lastLocation = location
        guard showRecap, let walk = walks.last(where: { $0.endedAt != nil }) else { return }
        let fresh = Dictionary(uniqueKeysWithValues: (walk.newTileHexesByPlace ?? [:]).compactMap { key, hexes in
            UUID(uuidString: key).map { ($0, hexes) }
        })
        let history = walks.filter { $0.id != walk.id && $0.startedAt < walk.startedAt }
        recapRequest += 1
        recap = WalkRecap.make(walk: walk, cities: cities, fresh: fresh, found: foundStickers, history: history)
    }
    #endif

    /// The End walk button on an always-on walk: ends it now and plays the celebration.
    func endAutoWalk() {
        guard activeWalk?.isAutomatic == true else { return }
        closeWalk(at: now(), reason: .you, byYou: true)
    }

    private func finishCoverage(of walk: inout Walk) {
        walk.newTilesByPlace = freshTiles.countsByPlaceID
        walk.newTileHexesByPlace = Dictionary(uniqueKeysWithValues: freshTiles.map { ($0.key.uuidString, $0.value) })
        walk.addedTilesByPlace = Dictionary(uniqueKeysWithValues: addedTiles.map { ($0.key.uuidString, $0.value) })
        walk.newTiles = freshTiles.values.reduce(0) { $0 + $1.count }
    }

    /// - Parameter waiting: finish writing before returning, for when the app is about to be suspended.
    func saveNow(waiting: Bool = false) {
        guard !locked else { return }
        if var walk = activeWalk {
            finishCoverage(of: &walk)
            walk.resumeAnchor = tracer.anchor
            activeWalk = walk
            store.save(walk)
        }
        saveCities()
        saveTeams()
        lastSave = now()
        if waiting { store.flush() }
    }

    private func record(_ location: CLLocation) {
        // iOS can hand over a cached fix from wherever you last were when tracking starts.
        guard !locked, !worldGridResetPending, location.timestamp.timeIntervalSinceNow > -10 else { return }
        lastLocation = location
        var point = TrackPoint(location)
        if motion.onWheels { point.wheels = true }
        if motion.still { point.still = true }
        if alwaysOn {
            recordAlwaysOn(point)
        } else if activeWalk != nil {
            recordWalk(point)
        }
        if activeWalk != nil || placeYouOnNextFix {
            placeYouOnNextFix = false
            followIntoPlace(at: point.coordinate)
        }
        noteWhereYouAre(location)
    }

    /// On a walk, whichever of your places you're in becomes the selected one, so the
    /// percentage and secrets are for where you are. The map doesn't jump to it.
    private func followIntoPlace(at point: Coordinate) {
        if let current = selectedCity, shape(for: current).contains(current.grid.projection.project(point)) { return }
        if let here = cities.first(where: { shape(for: $0).contains($0.grid.projection.project(point)) }) {
            selectedCityID = here.id
        }
    }

    /// Picks a place to look at, and flies the map there.
    func select(_ id: UUID) {
        selectedCityID = id
        flyToSelected += 1
    }

    private func recordWalk(_ point: TrackPoint) {
        guard var walk = activeWalk, walk.currentStage.isOpen else { return }
        walk.points.append(point)
        apply(tracer.add(point), at: point, to: &walk)
        activeWalk = walk
        saveIfDue()
    }

    private func recordAlwaysOn(_ point: TrackPoint) {
        TrackerTrace.fix(point, walk: activeWalk != nil, pending: autoWalkPending)
        if let last = activeWalk?.points.last, point.time - last.time >= Self.autoWalkGap {
            closeWalk(at: Date(timeIntervalSince1970: last.time), reason: .gap, byYou: false)
        }
        if var walk = activeWalk, walk.points.count == 1, let first = walk.points.first,
           point.time - first.time > Self.freshStart, Self.canAnchor(point) {
            walk.startedAt = Date(timeIntervalSince1970: point.time)
            walk.points = [point]
            walk.distance = 0
            tracer = CoverageTracer()
            tracer.restart(from: point)
            activeWalk = walk
            saveNow(waiting: true)
            return
        }
        // In a car or on a bike, by the motion chip or a trustworthy GPS speed.
        if Self.isRide(point) { noteRide() }
        let anchor = tracer.anchor
        let step = tracer.add(point)
        guard !step.samples.isEmpty else {
            // An unconfirmed arrival isn't a walking point, but it decides where the
            // next outing begins after a relaunch.
            if activeWalk != nil, anchor != tracer.anchor { saveNow(waiting: true) }
            return
        }
        // Only decided once you're walking on from the new spot, so one bad fix can't
        // end a walk. The next outing starts where you turned up.
        if let last = activeWalk?.points.last, let anchor, rode(from: last, to: anchor) {
            closeWalk(at: Date(timeIntervalSince1970: last.time), reason: .rode, byYou: false, keepTracer: true)
        }
        // The tracer's last spot can be hours old when the GPS has been off (the first fix
        // after a restart, then nothing until you head out). Start from this fix instead, or
        // the walk says it began back then: Dad's 16:20 walk on 30 Oct 2026 ran from 11:00.
        if activeWalk == nil, let anchor, point.time - anchor.time > Self.freshStart {
            TrackerTrace.write("fix skipped: tracer's last spot is \(Int(point.time - anchor.time)) s old")
            return
        }
        if activeWalk == nil {
            activeWalk = Walk(startedAt: Date(timeIntervalSince1970: anchor?.time ?? point.time), newTilesByPlace: [:],
                              newTileHexesByPlace: [:], addedTilesByPlace: [:], automatic: true, stage: .tentative)
            activePath = []
            freshTiles = [:]
            addedTiles = [:]
            TrackerTrace.write("auto walk started, pending until \(Int(Self.autoWalkConfirmDistance)) m from here")
            startFromWhenYouSetOff()
        }
        guard var walk = activeWalk else { return }
        // The fix this step started from, so replaying the points gives the same
        // route, distance and tiles as recording them did.
        if let anchor, walk.points.last != anchor { walk.points.append(anchor) }
        walk.points.append(point)
        walk.rideSeen = nil
        walk.resumeAnchor = tracer.anchor
        if walk.stage == .tentative {
            walk.distance += step.distance
            if Self.displacement(of: walk.points) >= Self.autoWalkConfirmDistance {
                // It's a real walk: uncover everything since it started in one go.
                TrackerTrace.write("auto walk confirmed after \(walk.points.count) points")
                walk.move(.confirmed)
                let samples = CoverageTracer.samples(for: walk.points)
                activePath = samples
                let uncovered = visit(samples, at: point.time)
                walk.newTiles += uncovered
                revealCount += uncovered
            }
        } else {
            apply(step, at: point, to: &walk)
        }
        activeWalk = walk
        saveIfDue()
    }

    /// The first fix can come well after you left, so ask the motion chip when you really did.
    /// The start time and steps go back to then. The route can't: there's no GPS to show for it.
    private func startFromWhenYouSetOff() {
        guard let id = activeWalk?.id, let now = activeWalk?.startedAt, servicesEnabled || querySetOff != nil else { return }
        Task {
            let found = if let querySetOff { await querySetOff(now) } else { await motion.setOff(before: now) }
            guard let found, var walk = activeWalk, walk.id == id else { return }
            // Not into the walk before this one, if you stopped for a bit between them.
            let earliest = walks.last?.endedAt ?? .distantPast
            let start = max(found, earliest)
            guard start < walk.startedAt else { return }
            walk.startedAt = start
            activeWalk = walk
            saveNow()
        }
    }

    private func rode(from last: TrackPoint, to start: TrackPoint) -> Bool {
        let distance = last.coordinate.distance(to: start.coordinate)
        guard distance > CoverageTracer.maxGap else { return false }
        let elapsed = start.time - last.time
        return activeWalk?.rideSeen == true || elapsed <= 0 || distance / elapsed > CoverageTracer.maxSpeed
    }

    #if DEBUG
    func recordAlwaysOnForTesting(_ point: TrackPoint) {
        recordAlwaysOn(point)
    }
    #endif

    private static func isRide(_ point: TrackPoint) -> Bool {
        point.wheels == true || (point.accuracy >= 0 && point.accuracy <= CoverageTracer.maxAccuracy
            && (point.speed ?? 0) > CoverageTracer.maxSpeed)
    }

    private static func canAnchor(_ point: TrackPoint) -> Bool {
        !isRide(point) && point.still != true && point.accuracy >= 0
            && point.accuracy <= CoverageTracer.maxAccuracy
            && (point.speed == nil || point.speed! >= CoverageTracer.minSpeed)
    }

    /// A ride since the last walking fix. Saved straight away, so a relaunch in the car
    /// still knows the next walking fix may be somewhere else entirely.
    private func noteRide() {
        guard var walk = activeWalk, walk.isAutomatic else { return }
        // Any arrival the tracer had is from before this ride, so it goes too.
        let hadArrival = tracer.anchor != nil
        tracer = CoverageTracer()
        guard walk.rideSeen != true || hadArrival else { return }
        walk.rideSeen = true
        activeWalk = walk
        saveNow(waiting: true)
    }

    /// How far a pending walk has got from where it started, in metres.
    var pendingWalkDistance: Double {
        activeWalk.map { Self.displacement(of: $0.points) } ?? 0
    }

    /// Far enough from where it started, and long enough, to be a walk.
    static func countsAsAutoWalk(_ points: [TrackPoint]) -> Bool {
        countsAsAutoWalk(displacement: displacement(of: points), distance: CoverageTracer.distance(for: points))
    }

    static func countsAsAutoWalk(displacement: Double, distance: Double) -> Bool {
        displacement >= autoWalkConfirmDistance && distance >= minimumAutoWalk
    }

    /// How far the furthest point gets from the first, in metres.
    static func displacement(of points: [TrackPoint]) -> Double {
        guard let first = points.first?.coordinate else { return 0 }
        return points.map { first.distance(to: $0.coordinate) }.max() ?? 0
    }

    private func apply(_ step: CoverageTracer.Step, at point: TrackPoint, to walk: inout Walk) {
        walk.distance += step.distance
        guard !step.samples.isEmpty else { return }
        if let origin = step.origin, activePath.last != origin { activePath.append(origin) }
        activePath.append(point.coordinate)
        let uncovered = visit(step.samples, at: point.time)
        if uncovered > 0 {
            walk.newTiles += uncovered
            revealCount += uncovered
        }
    }

    private func saveIfDue() {
        if now().timeIntervalSince(lastSave) > 30 {
            saveNow()
        }
    }

    @ObservationIgnored private var staleWalkCheck: Task<Void, Never>?

    /// Fixes can stop altogether once you're home (the light watch only sends one every
    /// 25 m), so a quiet walk also ends on the clock. Otherwise it kept holding the
    /// background session, and the blue arrow, for the rest of the day.
    private func scheduleStaleWalkCheck() {
        staleWalkCheck?.cancel()
        guard activeWalk?.isAutomatic == true else { staleWalkCheck = nil; return }
        staleWalkCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoWalkGap + 5))
            guard !Task.isCancelled else { return }
            self?.finishStaleAutoWalk()
        }
    }

    func finishStaleAutoWalk() {
        guard activeWalk?.isAutomatic == true, let last = activeWalk?.points.last,
              now().timeIntervalSince1970 - last.time >= Self.autoWalkGap
        else { return }
        closeWalk(at: Date(timeIntervalSince1970: last.time), reason: .quiet, byYou: false)
    }

    // MARK: Always on

    /// Called at launch, including when iOS relaunches the app in the background.
    func resumeAlwaysOn() {
        guard !locked, !worldGridResetPending else { return }
        askForPendingSteps()
        // Starting motion asks for permission, so leave that to the setup the first time.
        if setupDone { motion.start() }
        if alwaysOn {
            tracker.startAlwaysOn()
        } else {
            tracker.removeFence()
        }
    }

    private func turnOnAlwaysOn() {
        guard !worldGridResetPending else { return }
        Notifier.requestPermission()
        // Hand over from a walk you started yourself, without the summary popping up.
        if activeWalk != nil {
            endWalk()
            recap = nil
        }
        tracer = CoverageTracer()
        if !tracker.hasAlwaysPermission {
            tracker.requestAlwaysPermission()
        }
        tracker.startAlwaysOn()
    }

    private func turnOffAlwaysOn() {
        tracker.stopAlwaysOn()
        guard activeWalk?.isAutomatic == true else { return }
        let end = activeWalk?.points.last.map { Date(timeIntervalSince1970: $0.time) } ?? activeWalk?.startedAt ?? now()
        closeWalk(at: end, reason: .alwaysOnOff, byYou: false)
    }

    /// Marks these points as visited in every city, walked at `time` (seconds since
    /// 1970). Returns how many tiles were new.
    /// - Parameter quietly: tracing a resumed walk again, so no pop-ups or alerts.
    private func visit(_ points: [Coordinate], at time: Double, quietly: Bool = false) -> Int {
        var uncovered = 0
        let mistDays = Mist.days
        for i in cities.indices {
            var city = cities[i]
            let originalTiles = city.tiles
            let fresh = city.visit(points, within: shape(for: city))
            // Every tile walked gets today's date, clearing any mist over it. That
            // changes nothing else: no tiles, %, shells or quests.
            let walked = city.noteWalked(points, at: time, mistDays: mistDays)
            if walked.changed, fresh.isEmpty {
                city.updatedAt = .now
                cities[i] = city
                if !walked.cleared.isEmpty { tilesRevision += 1 }
            }
            guard !fresh.isEmpty else { continue }
            city.updatedAt = .now
            cities[i] = city
            freshTiles[city.id, default: []].formUnion(fresh)
            addedTiles[city.id, default: []].formUnion(fresh.subtracting(originalTiles))
            countingTilesByPlace[city.id, default: 0] += fresh.count
            tilesRevision += 1
            uncovered += fresh.count
            unlockStickers(in: city, on: fresh, notify: !quietly, popUp: !quietly)
        }
        if uncovered > 0 { refreshProgressPicks() }
        return uncovered
    }

    // MARK: Mist

    /// Places whose last-walked dates haven't been worked out from the saved walks yet.
    @ObservationIgnored private var lastWalkedPending: Set<UUID> = []
    @ObservationIgnored private var fillingLastWalked = false

    /// Works out when each tile was last walked from the saved walks, once for each
    /// place saved before that was kept (or added since), in the background. Walks carry
    /// on recording meanwhile: the dates are merged in, the later one winning.
    private func fillInLastWalked() {
        lastWalkedPending.formUnion(cities.filter { $0.lastWalked == nil }.map(\.id))
        lastWalkedPending.formIntersection(cities.map(\.id))
        guard !fillingLastWalked, !worldGridResetPending, !lastWalkedPending.isEmpty else { return }
        fillingLastWalked = true
        let ids = lastWalkedPending
        let generation = dataGeneration
        let places = cities.filter { ids.contains($0.id) }
        let routes = walks
        Task {
            let found = await Task.detached(priority: .utility) { City.lastWalked(for: places, from: routes) }.value
            fillingLastWalked = false
            guard generation == dataGeneration else { return }
            for i in cities.indices {
                guard let walked = found[cities[i].id] else { continue }
                cities[i].mergeLastWalked(walked)
            }
            lastWalkedPending.subtract(ids)
            if found.values.contains(where: { !$0.isEmpty }) { tilesRevision += 1 }
            // Not marked as changed: the other phone works out the same from the same
            // walks, and it goes up with the place's next change.
            saveCities()
            fillInLastWalked()
        }
    }

    /// Waits for `fillInLastWalked`, for tests.
    func waitForLastWalked() async {
        while fillingLastWalked { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: Stickers

    /// When each sticker was found, by lore id.
    private(set) var foundStickers: [String: Date] = [:] {
        didSet { secretsRevision += 1 }
    }
    private var secretsRevision = 0
    /// Stickers just found, waiting to pop up.
    var stickerQueue: [LoreEntry] = []
    /// Secrets that turned up under tiles you'd already walked, say from an update or
    /// a newly added place. Too many to pop up one by one, so the map just says how many.
    var secretsAlreadyWalked = 0

    /// Every sticker hidden in the selected city, found or not.
    var stickersHere: [(entry: LoreEntry, hex: Hex)] {
        guard let placed = selectedCity?.stickers else { return [] }
        return placed
            .compactMap { id, hex in loreEntry(id).map { ($0, hex) } }
            .sorted { $0.entry.title < $1.entry.title }
    }

    /// A pin another phone put down for one of the server's secrets, before this phone
    /// has heard from the server about that place. It stays, so the secret keeps the
    /// same tile on every phone.
    private func waitingForServer(_ id: String, in city: City) -> Bool {
        guard let osmId = city.osmId else { return false }
        return id.hasPrefix("osm\(osmId)-") && !serverLore.hasAnswered(osmId)
    }

    /// A secret by id, bundled or from the server. This model's own server secrets,
    /// rather than what LoreLibrary was last handed, so tests' models side by side
    /// don't mix theirs up.
    private func loreEntry(_ id: String) -> LoreEntry? {
        LoreLibrary.bundledEntry(id: id) ?? serverLore.entry(id: id)
    }

    /// Hides each place's secrets under its tiles. A secret that now belongs to a
    /// different place (say its suburb's just been added) moves there, unless you've
    /// already found it, when it stays where you found it. Secrets under tiles you've
    /// already walked are yours straight away.
    private func placeStickers() {
        let assigned = LoreLibrary.assign(server: serverLore.byPlace, to: cities) { city, point in
            shape(for: city).contains(city.grid.projection.project(point))
        }
        var changed = false
        for i in cities.indices {
            let wanted = Set((assigned[cities[i].id] ?? []).map(\.id))
            guard var placed = cities[i].stickers else { continue }
            let leaving = placed.keys.filter { !wanted.contains($0) && foundStickers[$0] == nil && !waitingForServer($0, in: cities[i]) }
            guard !leaving.isEmpty else { continue }
            for id in leaving { placed[id] = nil }
            cities[i].stickers = placed
            cities[i].updatedAt = .now
            changed = true
        }
        let hidden = Set(cities.flatMap { $0.stickers?.keys.map { $0 } ?? [] })
        for i in cities.indices {
            let missing = (assigned[cities[i].id] ?? []).filter { !hidden.contains($0.id) }
            guard !missing.isEmpty else { continue }
            let placed = cities[i].stickers ?? [:]
            cities[i].stickers = placed.merging(cities[i].placeStickers(missing, avoiding: Set(placed.values))) { old, _ in old }
            cities[i].updatedAt = .now
            changed = true
            secretsAlreadyWalked += unlockStickers(in: cities[i], on: cities[i].visited, notify: false, popUp: false)
        }
        if changed {
            tilesRevision += 1
            saveCities()
        }
    }

    /// Returns how many were found.
    @discardableResult
    private func unlockStickers(in city: City, on hexes: Set<Hex>, notify: Bool, popUp: Bool) -> Int {
        guard let placed = city.stickers else { return 0 }
        let ids = placed.filter { hexes.contains($0.value) && foundStickers[$0.key] == nil }.map(\.key)
        guard !ids.isEmpty else { return 0 }
        let entries = ids.sorted().compactMap(loreEntry)
        for entry in entries { foundStickers[entry.id] = notify ? .now : Progression.exploredSecretDate }
        store.save(stickers: foundStickers)
        if popUp { stickerQueue.append(contentsOf: entries) }
        if notify { Notifier.stickersFound(entries) }
        refreshProgressPicks()
        requestSync?()
        return entries.count
    }

    // MARK: Secrets from the server

    /// What the server's said about your places that have no bundled secrets, saved in
    /// server-lore.json (ServerLore, shared/lore-api.md).
    private(set) var serverLore = ServerLore()
    /// Secrets that have just come from the server, or a place that's turned out
    /// quiet, for a note on the map.
    var loreNotice: LoreNotice?

    struct LoreNotice: Equatable {
        /// The place they're in.
        var id: UUID
        var name: String
        /// How many arrived. None means there wasn't much to find there.
        var count: Int
    }

    @ObservationIgnored private var refreshingLore = false
    /// Places to ask about straight after the ask that's going.
    @ObservationIgnored private var loreAgain: Set<Int> = []
    /// Tests stand in for lore:forPlace and the sticker download.
    @ObservationIgnored var askForLore: ((Int) async throws -> ServerLore.Answer)?
    @ObservationIgnored var downloadSticker: ((URL) async throws -> Data)?

    /// One of your places the server's still looking for secrets in, the selected one
    /// first, for a line on the map.
    var lookingForSecrets: City? {
        let looking = cities.filter { city in city.osmId.flatMap(serverLore.place)?.status.isLooking == true }
        return looking.first { $0.id == selectedCityID } ?? looking.first
    }

    /// Asks the server about your places without bundled secrets that are due a look
    /// (ServerLore.due), and `now` straight away. Called when the app opens, after each
    /// sync and every couple of minutes while it's open. With none of those places, or
    /// none due, it makes no calls at all.
    func refreshLore(now osmId: Int? = nil) {
        Task { await updateLore(now: osmId) }
    }

    func updateLore(now forced: Int? = nil) async {
        guard !locked, !worldGridResetPending else { return }
        if let forced { loreAgain.insert(forced) }
        guard !refreshingLore else { return }
        // On a copy, so the map isn't told of a change every time when there's none.
        var trimmed = serverLore
        let unused = trimmed.keepOnly(Set(cities.compactMap(\.osmId)), found: foundStickers)
        if trimmed != serverLore { serverLore = trimmed }
        if !unused.isEmpty {
            for id in unused { store.deleteServerSticker(for: id) }
            loreChanged(arrived: [])
        }
        let askable = serverLore.askable(cities)
        var due = serverLore.due(askable, now: .now)
        due += loreAgain.filter { askable.contains($0) && !due.contains($0) }.sorted()
        loreAgain = []
        guard !due.isEmpty else { return }
        refreshingLore = true
        defer { refreshingLore = false }
        let generation = dataGeneration
        let ask: (Int) async throws -> ServerLore.Answer
        if let askForLore {
            ask = askForLore
        } else if servicesEnabled, let client = await makePlaceClient?() {
            ask = { osmId in try await client.query("lore:forPlace", ["osmId": osmId]) }
        } else {
            return
        }
        // Storage URLs need no sign-in.
        let download = downloadSticker ?? { url in try await ConvexClient().download(url) }
        var arrived: [(osmId: Int, change: ServerLore.Change)] = []
        var changed = false
        for osmId in due {
            guard generation == dataGeneration else { return }
            let answer: ServerLore.Answer
            do {
                answer = try await ask(osmId)
            } catch {
                guard generation == dataGeneration else { return }
                Self.log.info("Couldn't ask about secrets for \(osmId): \(error)")
                serverLore.noteAsked(osmId, at: .now)
                continue
            }
            guard generation == dataGeneration else { return }
            let version = serverLore.place(osmId)?.version
            let change = serverLore.take(answer, for: osmId, at: .now, found: foundStickers)
            if serverLore.place(osmId)?.version != version { changed = true }
            for (id, url) in change.stickers.sorted(by: { $0.key < $1.key }) {
                // One that won't download is tried again on the next ask.
                guard let png = try? await download(url), ServerLore.isPNG(png) else { continue }
                guard generation == dataGeneration else { return }
                store.save(serverSticker: png, for: id)
                serverLore.savedStickers[id] = url
                changed = true
            }
            if !change.arrived.isEmpty || change.quiet { arrived.append((osmId, change)) }
        }
        store.save(serverLore: serverLore)
        // Most asks just say it's the same as before, and change nothing on the map.
        if changed || !arrived.isEmpty { loreChanged(arrived: arrived) }
        if !loreAgain.isEmpty { refreshLore() }
    }

    /// The server's secrets have changed: hand them to the views, hide the new ones
    /// under their place's tiles (leaving every sticker already placed where it is, and
    /// dropping any taken down that you hadn't found), and say what's arrived.
    private func loreChanged(arrived: [(osmId: Int, change: ServerLore.Change)]) {
        LoreLibrary.useServer(serverLore, stickers: store.serverStickers)
        placeStickers()
        unlockArrivedSecrets()
        for (osmId, change) in arrived {
            guard let city = cities.first(where: { $0.osmId == osmId }) else { continue }
            loreNotice = LoreNotice(id: city.id, name: city.name, count: change.arrived.count)
            break
        }
    }

    /// Pins already down for server secrets that hadn't arrived yet (say another phone
    /// placed them) on tiles you've walked. Walking there couldn't find a secret this
    /// phone didn't have, and placeStickers keeps the pin rather than placing it again,
    /// so they're yours now, counted like newly placed ones.
    private func unlockArrivedSecrets() {
        for city in cities {
            guard let placed = city.stickers else { continue }
            let arrived = placed.filter { id, hex in
                foundStickers[id] == nil && city.visited.contains(hex)
                    && LoreLibrary.bundledEntry(id: id) == nil && serverLore.entry(id: id) != nil
            }
            guard !arrived.isEmpty else { continue }
            // Just these pins, so a bundled one under a walked tile is left as it was.
            var only = city
            only.stickers = arrived
            secretsAlreadyWalked += unlockStickers(in: only, on: city.visited, notify: false, popUp: false)
        }
    }

    private func authorizationChanged() {
        guard startWhenAllowed, tracker.authorization != .notDetermined else { return }
        startWhenAllowed = false
        startWalk()
    }

    // MARK: Cities

    /// - Parameters:
    ///   - selecting: pick it and fly there. Places that add themselves while you've
    ///     got others don't take you away from what you're looking at.
    ///   - builtFrom: the walks it was built with (`walksToBuildWith`). The rest, ones
    ///     that have ended since and ones the auto-add hadn't finished with, are walked
    ///     into it here, and the tiles they uncover are new on them, so they count for
    ///     those walks' quests too.
    func add(_ city: City, selecting: Bool = true, builtFrom: [Walk]? = nil) {
        // Already one of yours: the same suburb added by hand and found by itself, or
        // added on another phone and synced meanwhile. Just go there.
        if let have = cities.first(where: { $0.id == city.id || (city.osmId != nil && $0.osmId == city.osmId) }) {
            if selecting { select(have.id) }
            return
        }
        var city = city
        let shape = city.shape()
        var uncovered: [UUID: (tiles: Set<Hex>, added: Set<Hex>)] = [:]
        if let builtFrom {
            let had = Set(builtFrom.map(\.id))
            // In the order they were walked, so a tile two of them crossed is the first one's.
            for walk in walks.filter({ !had.contains($0.id) }).sorted(by: Progression.walkedFirst) {
                let tiles = city.tiles
                let fresh = city.visit(CoverageTracer.samples(for: walk.points), within: shape)
                if !fresh.isEmpty { uncovered[walk.id] = (fresh, fresh.subtracting(tiles)) }
            }
        }
        walkActiveWalk(into: &city, within: shape)
        city.updatedAt = .now
        cities.append(city)
        placesRevision += 1
        rebuildCountingTiles()
        credit(uncovered, in: city.id)
        shapes[city.id] = shape
        // Its dates for the mist come from your walks, even if the walk you're on gave it some.
        lastWalkedPending.insert(city.id)
        if selecting { select(city.id) }
        placeStickers()
        tilesRevision += 1
        saveCities()
        refreshProgressPicks()
        requestSync?()
        refreshNeighbours()
        fillInLastWalked()
    }

    /// The walks a place is built with: all but the ones the auto-add hasn't finished
    /// with yet, the walk that's just ended say, which `add` walks into it afterwards so
    /// the tiles they uncover there count for their quests. Older walks only uncover its
    /// tiles, as they always have for a place added by hand, rather than changing quests
    /// from weeks ago.
    private var walksToBuildWith: [Walk] {
        let due = Set(autoPlaces.due(walks, now: .now).map(\.id))
        return walks.filter { !due.contains($0.id) }
    }

    /// Tiles a place that's just been added uncovered on finished walks it wasn't built
    /// with. They're new on those walks, as if it had been one of your places when you
    /// walked them, so they count for their quests. A tile a walk already had for this
    /// place (it was deleted and added again, say) isn't counted twice.
    private func credit(_ uncovered: [UUID: (tiles: Set<Hex>, added: Set<Hex>)], in placeID: UUID) {
        let key = placeID.uuidString
        var changed: [UUID] = []
        for i in walks.indices {
            guard let (tiles, added) = uncovered[walks[i].id], var hexes = walks[i].newTileHexesByPlace else { continue }
            let had = hexes[key] ?? []
            let all = had.union(tiles)
            guard all.count > had.count else { continue }
            hexes[key] = all
            var counts = walks[i].newTilesByPlace ?? [:]
            counts[key] = all.count
            walks[i].newTileHexesByPlace = hexes
            walks[i].newTilesByPlace = counts
            if !added.isEmpty { walks[i].addedTilesByPlace = (walks[i].addedTilesByPlace ?? [:]).merging([key: added]) { $0.union($1) } }
            walks[i].newTiles += all.count - had.count
            store.save(walks[i])
            changed.append(walks[i].id)
        }
        guard !changed.isEmpty else { return }
        // Deduplicated against every other walk the way the next launch's backfill does,
        // so the two always agree.
        for (id, n) in Progression.placeCounts(placeID, walks: walks, cities: cities) {
            questTileCounts[id, default: [:]][placeID] = n
        }
        historyRevision += 1
        // Already uploaded, most likely, so they go up again with the new tiles.
        walksChanged?(changed)
    }

    /// A place added partway through a walk gets the walk so far, as if it had been
    /// there all along: its tiles count, and are new on this walk.
    private func walkActiveWalk(into city: inout City, within shape: BoundaryShape) {
        // A walk that adds itself uncovers everything since it started once it's sure
        // it's a walk, and this place will be among them then.
        guard var walk = activeWalk, !autoWalkPending else { return }
        let (samples, times) = CoverageTracer.timedSamples(for: walk.points)
        let tiles = city.tiles
        let fresh = city.visit(samples, within: shape)
        if let last = times.last { city.noteWalked(samples, at: last, mistDays: Mist.days) }
        guard !fresh.isEmpty else { return }
        freshTiles[city.id, default: []].formUnion(fresh)
        addedTiles[city.id, default: []].formUnion(fresh.subtracting(tiles))
        walk.newTiles += fresh.count
        activeWalk = walk
    }

    func deleteCity(_ id: UUID) {
        guard let i = cities.firstIndex(where: { $0.id == id }) else { return }
        deleteCities(at: IndexSet(integer: i))
    }

    func deleteCities(at offsets: IndexSet) {
        let removed = offsets.map { cities[$0].id }
        // Deleted on purpose, so it doesn't add itself again next time you walk there.
        for i in offsets { autoPlaces.decline(cities[i]) }
        saveAutoPlaces()
        placesDeleted?(removed)
        cities.remove(atOffsets: offsets)
        placesRevision += 1
        rebuildCountingTiles()
        for id in removed { shapes[id] = nil }
        if let selectedCityID, removed.contains(selectedCityID) {
            if let next = cities.first?.id { select(next) } else { self.selectedCityID = nil }
        }
        tilesRevision += 1
        placeStickers()
        saveCities()
        refreshProgressPicks()
        requestSync?()
    }

    // MARK: Getting ahead

    /// The suburbs around you last asked about, and when.
    @ObservationIgnored private var prepared: (ids: [Int], at: Date)?
    @ObservationIgnored private var preparing = false
    /// Stands in for lore:prepare in tests.
    @ObservationIgnored var askToPrepare: (([Int]) async throws -> Void)?

    /// Asks the server to research secrets for the suburb you're in and the ones next to
    /// it (`AroundYou`), so they're ready before you walk into them. Fire and forget:
    /// the server checks each one, and a failure just waits for the next fix.
    func prepareAround(_ point: Coordinate, now: Date = .now) {
        guard !locked, !worldGridResetPending, !preparing else { return }
        let ids = AroundYou.suburbs(at: point, places: cities, nearby: nearby)
        guard AroundYou.due(ids, last: prepared, now: now) else { return }
        let ask: ([Int]) async throws -> Void
        if let askToPrepare {
            ask = askToPrepare
        } else if servicesEnabled, let makePlaceClient {
            ask = { ids in
                guard let client = await makePlaceClient() else { throw CancellationError() }
                let _: Nothing = try await client.mutation("lore:prepare", ["osmIds": ids])
            }
        } else {
            return
        }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                try await ask(ids)
                prepared = (ids, now)
            } catch {
                Self.log.info("Couldn't ask for secrets around you: \(error)")
            }
        }
    }

    // MARK: Neighbours

    /// Suburbs around your places, fetched from OpenStreetMap.
    private(set) var nearby: [PlaceResult] = []
    @ObservationIgnored private var fetchingNearby = false
    @ObservationIgnored private var nearbyRetries = 0
    nonisolated private static let log = Logger(subsystem: "com.mikecann.walkies", category: "places")

    /// How far around your places to know the suburbs, in metres. Twice this is fetched
    /// and kept, so the next suburb over adds itself without fetching again.
    static let neighbourhood = 5000.0

    /// The box around your places, grown by this many metres each way. When they're
    /// spread far apart (a holiday suburb that added itself, say), it's just the ones
    /// near the selected place, so the suburbs nearby are looked up for one area at a
    /// time rather than for everywhere in between.
    private func box(around metres: Double) -> (south: Double, west: Double, north: Double, east: Double)? {
        let all = neighbourhoodPlaces.map(\.boundary.bounds)
        guard let south = all.map(\.south).min(), let west = all.map(\.west).min(),
              let north = all.map(\.north).max(), let east = all.map(\.east).max()
        else { return nil }
        let dLat = metres / 111_320
        let dLon = dLat / max(0.1, cos((south + north) / 2 * .pi / 180))
        return (south - dLat, west - dLon, north + dLat, east + dLon)
    }

    /// Your places close enough together to share one list of neighbours.
    private var neighbourhoodPlaces: [City] {
        let all = cities.map(\.boundary.bounds)
        guard let south = all.map(\.south).min(), let west = all.map(\.west).min(),
              let north = all.map(\.north).max(), let east = all.map(\.east).max(),
              Coordinate(lat: south, lon: west).distance(to: Coordinate(lat: north, lon: east)) > Self.neighbourhoodSpan,
              let centre = (selectedCity ?? cities.first)?.boundary.centre
        else { return cities }
        return cities.filter { $0.boundary.centre.distance(to: centre) <= Self.neighbourhoodSpan / 2 }
    }

    /// Metres corner to corner. Places spread wider than this get neighbours only
    /// around the selected one.
    static let neighbourhoodSpan = 60_000.0

    /// Uses the saved list if it still covers your places and is under a month old.
    /// Otherwise asks Overpass, which is quick when it's up, and falls back to asking
    /// Nominatim point by point when it isn't. Tries again a few times if both fail,
    /// and again whenever the app comes back.
    func refreshNeighbours() {
        guard servicesEnabled, !locked, !fetchingNearby, let wanted = box(around: Self.neighbourhood), let fetch = box(around: Self.neighbourhood * 2) else { return }
        if let saved = store.loadNearby(),
           saved.covers(south: wanted.south, west: wanted.west, north: wanted.north, east: wanted.east),
           saved.fetchedAt.timeIntervalSinceNow > -30 * 24 * 3600 {
            nearby = saved.places
            warmNeighbours()
            return
        }
        fetchingNearby = true
        let points = samplePoints(in: wanted)
        Task {
            defer { fetchingNearby = false }
            var found: (places: [PlaceResult], box: (south: Double, west: Double, north: Double, east: Double))?
            do {
                found = (try await OSMClient.placesNear(south: fetch.south, west: fetch.west, north: fetch.north, east: fetch.east), fetch)
            } catch {
                Self.log.error("Overpass couldn't list suburbs, asking Nominatim instead: \(error)")
                do {
                    found = (try await OSMClient.placesAt(points), wanted)
                } catch {
                    Self.log.error("Nominatim couldn't list suburbs either: \(error)")
                }
            }
            guard let found else {
                if nearbyRetries < 3 {
                    nearbyRetries += 1
                    try? await Task.sleep(for: .seconds(90))
                    refreshNeighbours()
                }
                return
            }
            nearbyRetries = 0
            nearby = found.places
            warmNeighbours()
            store.save(nearby: NearbyPlaces(
                south: found.box.south, west: found.box.west, north: found.box.north, east: found.box.east,
                fetchedAt: .now, places: found.places
            ))
        }
    }

    /// One background warm per loaded list. Failed/offline attempts can retry on
    /// the next refresh, and signing in can warm a list loaded before authentication.
    private func warmNeighbours() {
        let ids = Array(Set(nearby.compactMap(\.osmId))).sorted()
        guard !ids.isEmpty, ids != warmedNeighbourIds, !warmingNeighbours, let makePlaceClient else { return }
        warmingNeighbours = true
        Task {
            defer {
                warmingNeighbours = false
                // A newer list may have arrived while this request was running.
                if warmedNeighbourIds != nil, ids != Array(Set(nearby.compactMap(\.osmId))).sorted() { warmNeighbours() }
            }
            guard let client = await makePlaceClient() else { return }
            do {
                // Keep each request bounded for larger neighbourhoods.
                for start in stride(from: 0, to: ids.count, by: 100) {
                    let _: Nothing = try await client.action("places:warm", ["osmIds": Array(ids[start..<min(start + 100, ids.count)])])
                }
                warmedNeighbourIds = ids
            } catch {
                Self.log.info("Couldn't warm nearby streets: \(error)")
            }
        }
    }

    /// Points about 2.5 km apart across the box, leaving out the ones inside places
    /// you've already got, for asking Nominatim which suburb each is in.
    private func samplePoints(in box: (south: Double, west: Double, north: Double, east: Double)) -> [Coordinate] {
        let step = 2500.0 / 111_320
        let lonStep = step / max(0.1, cos((box.south + box.north) / 2 * .pi / 180))
        var points: [Coordinate] = []
        for lat in stride(from: box.south + step / 2, to: box.north, by: step) {
            for lon in stride(from: box.west + lonStep / 2, to: box.east, by: lonStep) {
                let point = Coordinate(lat: lat, lon: lon)
                let inside = cities.contains { shape(for: $0).contains($0.grid.projection.project(point)) }
                if !inside { points.append(point) }
            }
        }
        return points
    }

    // MARK: Places that add themselves

    /// What's been looked up so far, saved in auto-places.json.
    @ObservationIgnored private(set) var autoPlaces = AutoPlaces()
    /// Whether the app's on screen. Only a fix while it is can add where you are: one in
    /// the background could be from a car.
    @ObservationIgnored private(set) var inForeground = false
    @ObservationIgnored private var mapVisible = false

    func mapVisibility(_ visible: Bool) {
        guard mapVisible != visible else { return }
        mapVisible = visible
        tracker.refreshWatch()
    }
    /// Set when the app comes to the front, so the next good fix is checked for a suburb
    /// to add, and cleared when it goes. Never when iOS relaunches it in the background
    /// for always-on: only walks add places then.
    @ObservationIgnored var checkSpotOnNextFix = false
    /// Where you were when the app opened, until it's been checked.
    @ObservationIgnored private var spotToCheck: AutoPlaces.Spot?
    /// Every place in the account has come down since the app opened or you signed in,
    /// so a suburb that adds itself can't be a second copy of one the account has.
    @ObservationIgnored private(set) var accountPulled = false
    @ObservationIgnored private var autoAdding = false
    @ObservationIgnored private var autoAddAgain = false
    /// While your first place is being found and built, for the place chip.
    private(set) var findingFirstPlace = false
    /// A place that's just added itself while you had others, for a note on the map.
    var addedPlaceNotice: AddedPlace?

    struct AddedPlace: Equatable {
        var id: UUID
        var name: String
    }

    /// Tests stand in for OpenStreetMap and the street download (for adding by hand too).
    @ObservationIgnored var lookUpSuburb: ((Coordinate) async throws -> AutoPlaces.Lookup)?
    @ObservationIgnored var buildPlace: ((PlaceResult, [Walk]) async throws -> City)?

    /// Until your first tile clears, the map says to go for a walk. Tiles only ever get
    /// uncovered, so once one has this never shows again.
    var showWalkHint: Bool { !cities.isEmpty && !cities.contains { !$0.visited.isEmpty } }

    /// The app's come to the front, or gone from it. Coming back looks again at where
    /// you are; going clears that, so a fix from later (in a car, say) can't count.
    func foreground(_ active: Bool) {
        inForeground = active
        checkSpotOnNextFix = active
        if !active { spotToCheck = nil }
        if active { askForPendingSteps() }
        tracker.refreshWatch()
    }

    /// The first good fix after the app comes to the front, from GPS or the map's blue
    /// dot. If it's not in one of your places, or near one, its suburb adds itself.
    /// Fixes moving faster than a walk, or that the motion chip says are on wheels,
    /// are passed over for the next.
    func noteWhereYouAre(_ location: CLLocation) {
        if inForeground, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 {
            prepareAround(Coordinate(location.coordinate))
        }
        guard checkSpotOnNextFix, inForeground, !locked, location.timestamp.timeIntervalSinceNow > -60,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= AutoPlaces.spotAccuracy,
              !motion.onWheels, location.speed <= CoverageTracer.maxSpeed
        else { return }
        checkSpotOnNextFix = false
        spotToCheck = AutoPlaces.Spot(point: Coordinate(location.coordinate), accuracy: location.horizontalAccuracy)
        addPlacesYouveBeen()
    }

    /// The sync engine has pulled every place in the account, so a suburb that adds
    /// itself now won't be one the account already had.
    func pulledAccount() {
        accountPulled = true
        addPlacesYouveBeen()
    }

    /// Adds the suburbs you've been in that aren't one of your places yet: where you
    /// were when the app opened, and wherever walks since the last check went on foot.
    /// Called when the app opens, when a walk ends and after each sync, never from
    /// moving the map about. One run at a time, and one lookup at a time within it.
    func addPlacesYouveBeen() {
        guard !locked, !worldGridResetPending, accountPulled, servicesEnabled || lookUpSuburb != nil else { return }
        if autoAdding {
            autoAddAgain = true
            return
        }
        autoAdding = true
        autoAddAgain = false
        let generation = dataGeneration
        Task {
            await addPlacesYouveBeen(generation: generation)
            // Signing out resets all this itself.
            guard generation == dataGeneration else { return }
            autoAdding = false
            findingFirstPlace = false
            if autoAddAgain { addPlacesYouveBeen() }
        }
    }

    /// Waits for any run of `addPlacesYouveBeen`, for tests.
    func waitForPlacesYouveBeen() async {
        while autoAdding { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func addPlacesYouveBeen(generation: Int) async {
        let due = autoPlaces.due(walks, now: .now)
        let tracks = await Task.detached(priority: .utility) { due.map { CoverageTracer.samples(for: $0.points) } }.value
        var lookups = 0
        // Hexes asked about this time, so one whose answer was one of your own places
        // isn't asked about again straight away.
        var asked = Set<Hex>()
        // Every round adds a place, asks about a spot or stops, so this is only a backstop.
        for _ in 0..<100 {
            guard generation == dataGeneration, !worldGridResetPending else { return }
            let auto = autoPlaces, here = spotToCheck, known = nearby, skip = asked, now = Date.now
            let places = cities.map { shape(for: $0) }
            let isYours = Self.isYours(in: cities)
            let next = await Task.detached(priority: .utility) {
                auto.next(here: here, tracks: tracks, places: places, known: known, isYours: isYours, asked: skip, now: now)
            }.value
            guard generation == dataGeneration else { return }
            switch next {
            case .nothing:
                if spotToCheck == here { spotToCheck = nil }
                autoPlaces.checked(due)
                saveAutoPlaces()
                return
            case .later:
                return
            case .add(let place):
                findingFirstPlace = cities.isEmpty
                // Whether it's added or its streets wouldn't download (and it waits its
                // turn), round again for the rest.
                await autoAdd(place, generation: generation)
            case .lookUp(let spot):
                guard lookups < AutoPlaces.lookupsPerRun else { return }
                lookups += 1
                asked.insert(HexGrid.world.hex(containing: spot))
                findingFirstPlace = cities.isEmpty
                do {
                    let found: AutoPlaces.Lookup
                    if let lookUpSuburb { found = try await lookUpSuburb(spot) } else { found = try await OSMClient.suburb(at: spot) }
                    guard generation == dataGeneration else { return }
                    autoPlaces.looked(at: spot, found: found, isYours: Self.isYours(in: cities), now: .now)
                    saveAutoPlaces()
                } catch {
                    guard generation == dataGeneration else { return }
                    Self.log.info("Couldn't find the suburb at a spot, trying again later: \(error)")
                    autoPlaces.lookUpFailed(now: .now)
                    saveAutoPlaces()
                    return
                }
            }
        }
    }

    /// Builds and adds a suburb that's added itself. Your first place is selected and
    /// the map flies there. Otherwise it's only selected if you're standing in it, and
    /// a note on the map says it's been added. If its streets won't download, it waits
    /// longer each time before it's tried again.
    private func autoAdd(_ place: PlaceResult, generation: Int) async {
        let builtFrom = walksToBuildWith
        do {
            let city: City
            if let buildPlace {
                city = try await buildPlace(place, builtFrom)
            } else {
                city = try await CityBuilder.build(from: place, walks: builtFrom, client: await makePlaceClient?(), status: { _ in })
            }
            guard generation == dataGeneration, !worldGridResetPending else { return }
            // Deleted while this one was downloading: it stays in `found`, so its spots
            // aren't asked about again, and isn't added.
            if autoPlaces.isDeclined(place) { return }
            autoPlaces.added(place)
            saveAutoPlaces()
            // Added by hand, or pulled from the account, while this one was downloading.
            guard !isYours(place) else { return }
            let first = cities.isEmpty
            add(city, selecting: first, builtFrom: builtFrom)
            if !first {
                if let spot = spotToCheck?.point, shape(for: city).contains(city.grid.projection.project(spot)) { selectedCityID = city.id }
                addedPlaceNotice = AddedPlace(id: city.id, name: city.name)
            }
        } catch {
            guard generation == dataGeneration else { return }
            Self.log.info("Couldn't add \(place.name) by itself, trying again later: \(error)")
            autoPlaces.failedToBuild(place, now: .now)
            saveAutoPlaces()
        }
    }

    /// One of your places already: the same OSM boundary, or for places saved before
    /// those were kept, the same name.
    private func isYours(_ place: PlaceResult) -> Bool {
        Self.isYours(in: cities)(place)
    }

    /// `isYours` for these places, to take off the main thread.
    private static func isYours(in cities: [City]) -> @Sendable (PlaceResult) -> Bool {
        let mine = cities.map { (osmId: $0.osmId, name: $0.name) }
        return { place in
            mine.contains { city in
                if let osmId = place.osmId, let have = city.osmId { return osmId == have }
                return city.name.caseInsensitiveCompare(place.name) == .orderedSame
            }
        }
    }

    private func saveAutoPlaces() {
        guard !locked else { return }
        autoPlaces.tidy(now: .now)
        store.save(autoPlaces: autoPlaces)
    }

    // MARK: Progression

    private(set) var ledger = Ledger()
    @ObservationIgnored private var cachedProgression: (key: String, state: Progression.State)?
    #if DEBUG
    @ObservationIgnored private(set) var progressionHistoryBuilds = 0
    #endif
    @ObservationIgnored private var cachedHistoricalRewards: (key: String, rewards: Progression.HistoricalRewards)?

    var progression: Progression.State {
        let calendar = Progression.calendar
        let now = Date.now
        let day = calendar.startOfDay(for: now)
        let historyKey = "\(historyRevision)-\(placesRevision)-\(secretsRevision)-\(day)"
        let key = "\(tilesRevision)-\(historyKey)"
        if let cachedProgression, cachedProgression.key == key { return cachedProgression.state }
        var inputs = Progression.Inputs(cities: cities, walks: walks, foundSecrets: foundStickers, now: now, calendar: calendar,
                                       newTilesByWalk: questTileCounts, countingTilesByPlace: countingTilesByPlace,
                                       unrecordedTilesByPlace: activeWalk == nil ? [:] : freshTiles.mapValues(\.count))
        if cachedHistoricalRewards?.key != historyKey {
            #if DEBUG
            progressionHistoryBuilds += 1
            #endif
            cachedHistoricalRewards = (historyKey, Progression.historicalRewards(inputs))
        }
        inputs.historicalRewards = cachedHistoricalRewards?.rewards
        let state = Progression.state(inputs)
        cachedProgression = (key, state)
        return state
    }

    var earnedBreakdown: Progression.Earned { progression.earned }
    var balance: Int { ledger.balance(earned: progression.earned.total) }
    var xp: Int { progression.xp }
    var level: Int { progression.level }
    var nextLevelXP: Int { progression.nextLevelXP }
    var xpToNextLevel: Int { nextLevelXP - xp }
    var pendingPicks: [Int] { historyReady && !batchingProgress ? Progression.pendingLevels(xp: xp, ledger: ledger) : [] }
    var weeklyQuests: [Progression.Quest] { progression.quests }
    var owned: Set<String> { ledger.owned }
    var equipped: Ledger.Equipped { ledger.resolvedEquipment }
    var spyglasses: Int { ledger.spyglassesLeft }
    /// Re-read on a timer while showing the map so the ring disappears at expiry.
    var activeSpyglassRing: Progression.Ring? {
        guard let city = selectedCity else { return nil }
        return Progression.activeRing(in: city, ledger: ledger, found: foundStickers, now: .now)
    }

    func picks(for level: Int) -> [String] { ledger.picks(for: level) }

    /// False means unknown item, already owned, or too few shells. Concurrent
    /// offline spending is retained on merge; the resulting debt blocks purchases.
    @discardableResult func buy(_ itemID: String) -> Bool {
        guard historyReady, let item = Progression.item(itemID), !item.isFree,
              item.group == nil || !owned.contains(itemID), balance >= item.price else { return false }
        // Include levels reached since the last refresh before ownership changes.
        ledger.preparePicks(xp: xp)
        ledger.purchases.append(Ledger.Purchase(item: itemID, cost: item.price, at: Date.now.timeIntervalSince1970))
        if let group = item.group { setEquipped(itemID, group: group) }
        saveProgress()
        return true
    }

    @discardableResult func equip(_ itemID: String) -> Bool {
        guard let group = Progression.item(itemID)?.group, owned.contains(itemID) else { return false }
        setEquipped(itemID, group: group)
        saveProgress()
        return true
    }

    @discardableResult func claim(level: Int, choice: String) -> Bool {
        guard pendingPicks.contains(level), picks(for: level).contains(choice) else { return false }
        // A frozen offer may have been bought in the meantime. Give the bag
        // instead of taking a level pick for something the player already owns.
        let reward = owned.contains(choice) ? Progression.shellBag : choice
        ledger.claims.append(Ledger.Claim(level: level, choice: reward))
        if let group = Progression.item(reward)?.group { setEquipped(reward, group: group) }
        saveProgress()
        return true
    }

    @discardableResult func useSpyglass() -> Bool {
        guard spyglasses > 0, let city = selectedCity, activeSpyglassRing == nil,
              let use = Progression.spyglass(in: city, from: lastLocation.map { Coordinate($0.coordinate) }, found: foundStickers, now: .now)
        else { return false }
        ledger.spyglasses.append(use)
        saveProgress()
        return true
    }

    private func setEquipped(_ itemID: String, group: Progression.Group) {
        ledger.equipped[group] = itemID
        ledger.equipped.updatedAt = max(Date.now.timeIntervalSince1970, ledger.equipped.updatedAt.nextUp)
    }

    private func refreshProgressPicks() {
        guard historyReady, !batchingProgress else { return }
        let old = ledger
        ledger.preparePicks(xp: xp)
        if ledger != old { saveProgress() }
    }

    private func saveProgress() {
        if historyReady, !batchingProgress { ledger.preparePicks(xp: xp) }
        store.save(progress: ledger)
        requestSync?()
    }

    /// The server accepted its first claim for a level. Give that copy precedence
    /// so two offline choices converge when both phones next pull a snapshot.
    func addRemoteProgress(_ remote: Ledger) {
        let merged = remote.merged(with: ledger)
        guard merged != ledger else { return }
        ledger = merged
        if historyReady, !batchingProgress { ledger.preparePicks(xp: xp) }
        store.save(progress: ledger)
        requestSync?()
    }

    // MARK: Sync

    /// Asks the sync engine to push and pull shortly. Set by the app delegate.
    @ObservationIgnored var requestSync: (() -> Void)?
    /// Tells the sync engine which places were deleted on purpose. Set by the sync engine.
    @ObservationIgnored var placesDeleted: (([UUID]) -> Void)?
    /// Tells sync which walks changed after they were saved, so they go up again.
    @ObservationIgnored var walksChanged: (([UUID]) -> Void)?

    /// Apply a pull as one batch. Merge ownership before preparing any level menu,
    /// and do coverage recovery on a worker rather than once per downloaded walk.
    func addRemote(cities remoteCities: [City], walks remoteWalks: [Walk], progress: Ledger?, secrets: [String: Date]) async {
        let generation = dataGeneration
        await historyTask?.value
        guard generation == dataGeneration else { return }
        batchingProgress = true
        defer {
            batchingProgress = false
            if generation == dataGeneration { refreshProgressPicks() }
        }
        if let progress { addRemoteProgress(progress) }
        addRemoteSecrets(secrets)
        var changedCities: Set<UUID> = []
        for remote in remoteCities {
            changedCities.insert(remote.id)
            if let i = cities.firstIndex(where: { $0.id == remote.id }) {
                var city = cities[i]
                let hadMore = city.merge(remote)
                city.updatedAt = hadMore ? .now : max(city.lastChanged, remote.lastChanged)
                cities[i] = city
            } else {
                cities.append(remote)
                if remote.lastWalked == nil { lastWalkedPending.insert(remote.id) }
                if selectedCityID == nil { select(remote.id) }
            }
            shapes[remote.id] = nil
        }
        let have = Set(walks.map(\.id))
        let missing = remoteWalks.filter { $0.endedAt != nil && $0.id != activeWalk?.id && !have.contains($0.id) }
        walks.append(contentsOf: missing)
        walks.sort { $0.startedAt < $1.startedAt }
        for walk in missing { store.save(walk) }
        guard !changedCities.isEmpty || !missing.isEmpty else { return }
        placesRevision += 1
        tilesRevision += 1
        rebuildCountingTiles()
        let snapshotCities = cities
        let snapshotWalks = walks
        let newIDs = Set(missing.map(\.id))
        let restored = await Task.detached(priority: .utility) {
            var restoredCities = snapshotCities
            let shapes = restoredCities.map { $0.shape() }
            var walkedBy: [UUID: [Walk]] = [:]
            for walk in snapshotWalks {
                let targets = restoredCities.indices.filter { changedCities.contains(restoredCities[$0].id) || newIDs.contains(walk.id) }
                guard !targets.isEmpty else { continue }
                let samples = CoverageTracer.samples(for: walk.points)
                for i in targets {
                    _ = restoredCities[i].visit(samples, within: shapes[i])
                    walkedBy[restoredCities[i].id, default: []].append(walk)
                }
            }
            // When the walks just pulled (from a phone that doesn't keep dates yet, say)
            // last crossed each tile, for the mist.
            var lastWalked: [UUID: LastWalked] = [:]
            for city in restoredCities {
                guard let walks = walkedBy[city.id] else { continue }
                lastWalked[city.id] = City.lastWalked(for: [city], from: walks)[city.id]
            }
            return (restoredCities, Progression.backfill(walks: snapshotWalks, cities: restoredCities), lastWalked)
        }.value
        guard generation == dataGeneration else { return }
        // Location fixes can arrive while the worker runs. Union its result so no
        // live coverage is overwritten by the snapshot it started with.
        for restoredCity in restored.0 {
            guard let i = cities.firstIndex(where: { $0.id == restoredCity.id }) else { continue }
            // Only the visited ones: the rest of its tiles are the snapshot's, which a
            // street update since then may have changed.
            cities[i].visited.formUnion(restoredCity.visited)
            cities[i].tiles.formUnion(restoredCity.visited)
            if let walked = restored.2[restoredCity.id], !walked.isEmpty { cities[i].mergeLastWalked(walked) }
        }
        installBackfill(restored.1)
        historyRevision += 1
        placesRevision += 1
        tilesRevision += 1
        rebuildCountingTiles()
        placeStickers()
        for city in cities { unlockStickers(in: city, on: city.visited, notify: false, popUp: false) }
        saveCities()
        refreshNeighbours()
        fillInLastWalked()
    }

    /// A genuine discovery beats the explored-coverage sentinel; otherwise the
    /// earliest discovery wins, matching the server's existing secret merge.
    func addRemoteSecrets(_ remote: [String: Date]) {
        var changed = false
        for (id, date) in remote where foundStickers[id].map({ date < $0 }) ?? true {
            foundStickers[id] = date
            changed = true
        }
        if changed {
            store.save(stickers: foundStickers)
            refreshProgressPicks()
        }
    }

    /// Forgets everything on this phone, for signing out. It's all in the account.
    func wipeLocalData() {
        stepCounter.clear()
        dataGeneration += 1
        teamMembershipRevision += 1
        historyTask?.cancel()
        historyTask = nil
        historyReady = true
        worldGridResetPending = false
        alwaysOn = false
        setupDone = false
        tracker.stop()
        tracker.stopAlwaysOn()
        activeWalk = nil
        activePath = []
        freshTiles = [:]
        recap = nil
        cities = []
        teams = []
        pendingTeamInvite = nil
        walks = []
        shapes = [:]
        foundStickers = [:]
        ledger = Ledger()
        cachedProgression = nil
        cachedHistoricalRewards = nil
        questTileCounts = [:]
        countingTilesByPlace = [:]
        addedTiles = [:]
        lastWalkedPending = []
        historyRevision += 1
        placesRevision += 1
        stickerQueue = []
        secretsAlreadyWalked = 0
        nearby = []
        selectedCityID = nil
        autoPlaces = AutoPlaces(walksSince: .now)
        spotToCheck = nil
        // Ready for whoever signs in next, if you're looking. Not when a sync in the
        // background has found someone else signed in: that fix could be from anywhere.
        checkSpotOnNextFix = inForeground
        accountPulled = false
        autoAdding = false
        autoAddAgain = false
        findingFirstPlace = false
        addedPlaceNotice = nil
        serverLore = ServerLore()
        loreNotice = nil
        loreAgain = []
        LoreLibrary.useServer(serverLore, stickers: store.serverStickers)
        tilesRevision += 1
        clouds = nil
        store.wipe()
    }

    private func shape(for city: City) -> BoundaryShape {
        if let shape = shapes[city.id] { return shape }
        let shape = city.shape()
        shapes[city.id] = shape
        return shape
    }
}

private extension Dictionary where Key == UUID, Value == Set<Hex> {
    var countsByPlaceID: [String: Int] {
        Dictionary<String, Int>(uniqueKeysWithValues: map { ($0.key.uuidString, $0.value.count) })
    }
}

extension AppModel {
    func editTeam(_ id: String, _ edit: (inout Team) -> Void) {
        guard let index = teams.firstIndex(where: { $0.id == id }) else { return }
        // Invalidate any list request started before this local membership edit.
        teamMembershipRevision += 1
        edit(&teams[index])
        saveTeams()
    }

    func saveTeams() { store.save(teams: teams) }

    func joinedTeam(_ id: String) {
        teamMembershipRevision += 1
        if !teams.contains(where: { $0.id == id }) {
            teams.append(Team(id: id, name: "Team", createdBy: "", inviteCode: ""))
        }
        saveTeams()
    }

    @discardableResult
    func acceptTeamList(_ listings: [Team], revision: Int) -> Bool {
        guard revision == teamMembershipRevision else { return false }
        let removed = teams.filter { team in !listings.contains(where: { $0.id == team.id }) }
        if !removed.isEmpty { teamNotice = "You’re no longer a member of \(removed.map(\.name).joined(separator: ", "))." }
        teamMembershipRevision += 1
        teams = listings
        saveTeams()
        return true
    }

    func retainTeams(_ ids: Set<String>) {
        teamMembershipRevision += 1
        teams.removeAll { !ids.contains($0.id) }
        saveTeams()
    }

    func teamAPI() async throws -> TeamsAPI {
        guard let client = await makePlaceClient?() else { throw ConvexError.server("Connect and sign in to manage a team.") }
        return TeamsAPI(client: client)
    }

    func refreshTeam(_ id: String, api: TeamsAPI) async throws {
        let generation = dataGeneration
        let revision = teamMembershipRevision
        guard teams.contains(where: { $0.id == id }) else { throw CancellationError() }
        let listings = try await api.list()
        guard generation == dataGeneration, acceptTeamList(listings, revision: revision) else { throw CancellationError() }
    }

    /// Both the neighbour buttons and place search add to your own places.
    func addPlace(_ place: PlaceResult, status: @escaping @MainActor @Sendable (String) -> Void) async throws {
        guard !worldGridResetPending else { throw ConvexError.server("Connect to finish rebuilding your places first.") }
        // Already one of yours, say it added itself: no need to fetch it again.
        if let osmId = place.osmId, let have = cities.first(where: { $0.osmId == osmId }) {
            select(have.id)
            return
        }
        let generation = dataGeneration
        let builtFrom = walksToBuildWith
        let city: City
        if let buildPlace {
            city = try await buildPlace(place, builtFrom)
        } else {
            city = try await CityBuilder.build(from: place, walks: builtFrom, client: await makePlaceClient?(), status: status)
        }
        guard generation == dataGeneration else { throw CancellationError() }
        add(city, builtFrom: builtFrom)
        autoPlaces.added(place)
        saveAutoPlaces()
    }

    func openTeamURL(_ url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.scheme?.lowercased() == "walkies", url.host?.lowercased() == "join",
              parts.count == 1, let raw = parts.first, TeamInviteCode.isValid(TeamInviteCode.normalise(raw)) else { return }
        pendingTeamInvite = TeamInviteCode.normalise(raw)
    }
}
