import Foundation
import Testing
@testable import Walkies

/// Secrets the server writes for places without bundled ones (ServerLore.swift and
/// AppModel's refreshLore): reading `lore:forPlace`, caching it, and hiding them next
/// to the bundled ones. The server's stood in for; nothing here goes to the network.
/// What LoreLibrary was last handed isn't checked, since other suites' models running
/// alongside hand it theirs.
@MainActor
@Suite(.serialized)
struct ServerLoreTests {
    static let porlock = 2_676_434
    static let somewhere = 4_242

    func store() -> Store {
        let base = ProcessInfo.processInfo.environment["WALKIES_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL.temporaryDirectory.appending(path: "WalkiesServerLoreTests")
        return Store(root: base.appending(path: UUID().uuidString))
    }

    /// A place 2 km across with a row of 100 street tiles through the middle.
    func city(osmId: Int?, visited: Int = 0, origin: Coordinate = Coordinate(lat: 12.345, lon: 45.678)) -> City {
        let grid = HexGrid.world
        let base = grid.hex(containing: origin)
        let ring = [SIMD2(-1000.0, -1000), SIMD2(1000.0, -1000), SIMD2(1000.0, 1000), SIMD2(-1000.0, 1000)]
            .map { grid.projection.unproject(grid.centre(of: base) + $0) }
        var city = City(name: "Somewhere", detail: "Tests",
                        boundary: Boundary(polygons: [GeoPolygon(outer: ring, holes: [])]),
                        tiles: Set((0..<100).map { Hex(q: base.q + Int32($0), r: base.r) }),
                        visited: Set((0..<visited).map { Hex(q: base.q + Int32($0), r: base.r) }), roads: [])
        city.osmId = osmId
        return city
    }

    /// A server secret pinned `tile` tiles along the city's street.
    func secret(_ slug: String, in city: City, tile: Int? = nil, art: Bool = true) -> ServerLore.Entry {
        let base = city.grid.hex(containing: city.boundary.centre)
        let place = tile.map { i in
            let point = city.grid.projection.unproject(city.grid.centre(of: Hex(q: base.q + Int32(i), r: base.r)))
            return LoreEntry.Place(name: slug, lat: point.lat, lon: point.lon)
        }
        let entry = LoreEntry(id: "osm\(city.osmId ?? 0)-\(slug)", title: slug, body: "A story.", category: "history",
                              place: place, sticker: "", sources: ["https://example.org/\(slug)"], suburb: city.name)
        return ServerLore.Entry(entry: entry, stickerURL: art ? URL(string: "https://example.org/storage/\(slug)") : nil)
    }

    /// The smallest PNG there is: just its signature, which is all the app checks.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// A model whose server answers from `answers` and counts what it's asked.
    final class FakeServer {
        var answers: [Int: ServerLore.Answer] = [:]
        var asked: [Int] = []
        var downloads: [URL] = []
    }

    func model(_ store: Store, server: FakeServer) async -> AppModel {
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.askForLore = { osmId in
            server.asked.append(osmId)
            return server.answers[osmId] ?? ServerLore.Answer(status: .notStarted, version: 0, entries: [])
        }
        let png = png
        model.downloadSticker = { url in
            server.downloads.append(url)
            return png
        }
        return model
    }

    @Test func readsWhatForPlaceSaysAboutPorlock() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "shared/fixtures/lore/forPlace-porlock.json")
        let answer = try JSONDecoder().decode(ServerLore.Answer.self, from: Data(contentsOf: url))
        #expect(answer.status == .ready)
        #expect(answer.version == 1)
        #expect(answer.entries.count == 7)
        #expect(answer.entries.allSatisfy { $0.entry.id.hasPrefix("osm\(Self.porlock)-") && $0.entry.suburb == "Porlock" })
        #expect(answer.entries.allSatisfy { $0.entry.place != nil && !$0.entry.sources.isEmpty && $0.entry.photos == nil })
        let categories: Set = ["history", "first-nations", "nature", "the-sea", "odd-records", "modern-life"]
        #expect(answer.entries.allSatisfy { categories.contains($0.entry.category) })
        // The fixture's first sticker is a made-up URL; the rest failed to draw.
        #expect(answer.entries[0].stickerURL?.absoluteString.hasPrefix("https://resolute-pig-177.") == true)
        #expect(answer.entries.dropFirst().allSatisfy { $0.stickerURL == nil })
        #expect(answer.entries[0].entry.title == "A Clock Without a Face")
    }

    @Test func aStatusFromANewerServerIsTakenAsNone() throws {
        let answer = try JSONDecoder().decode(ServerLore.Answer.self, from: Data(#"{"status":"pondering","version":0,"entries":[]}"#.utf8))
        #expect(answer.status == .notStarted)
    }

    @Test func bundledPlacesNeverAsk() async throws {
        let store = store()
        defer { store.wipe() }
        let server = FakeServer()
        // Geographe ships its own secrets, and a place without a relation can't have any.
        #expect(LoreLibrary.bundledOsmIds.contains(11_688_696))
        #expect(LoreLibrary.bundledOsmIds.count == 29)
        let model = await model(store, server: server)
        model.add(city(osmId: 11_688_696))
        model.add(city(osmId: nil, origin: Coordinate(lat: 13.345, lon: 45.678)))
        await model.updateLore()
        await model.updateLore(now: 11_688_696)
        #expect(server.asked.isEmpty)
        #expect(server.downloads.isEmpty)
    }

    @Test func aNewPlaceIsAskedOnceThenWaits() async throws {
        let store = store()
        defer { store.wipe() }
        let server = FakeServer()
        let model = await model(store, server: server)
        model.add(city(osmId: Self.somewhere))
        server.answers[Self.somewhere] = ServerLore.Answer(status: .researching, version: 0, entries: [])
        await model.updateLore()
        await model.updateLore()
        #expect(server.asked == [Self.somewhere])
        #expect(model.lookingForSecrets?.osmId == Self.somewhere)
        // Asking straight away, as after Mike approves one.
        await model.updateLore(now: Self.somewhere)
        #expect(server.asked == [Self.somewhere, Self.somewhere])
    }

    @Test func serverSecretsGoNextToBundledOnesWithoutMovingAnyPins() async throws {
        let store = store()
        defer { store.wipe() }
        let server = FakeServer()
        let model = await model(store, server: server)
        // A place that isn't bundled but has a bundled story's spot inside it, so it gets both.
        let bundled = try #require(LoreLibrary.bundled.first { $0.place != nil })
        var place = city(osmId: Self.somewhere, origin: try #require(bundled.place?.coordinate))
        place.name = "Somewhere"
        model.add(place)
        let before = try #require(model.cities.first?.stickers)
        let bundledHex = try #require(before[bundled.id])

        server.answers[Self.somewhere] = ServerLore.Answer(status: .ready, version: 1, entries: [
            secret("the-jetty", in: place, tile: 40), secret("the-mill", in: place, tile: 70), secret("the-town", in: place, art: false),
        ])
        await model.updateLore()
        let first = try #require(model.cities.first?.stickers)
        #expect(first[bundled.id] == bundledHex)
        for slug in ["the-jetty", "the-mill", "the-town"] { #expect(first["osm\(Self.somewhere)-\(slug)"] != nil) }
        #expect(Set(first.values).count == first.count)
        #expect(model.loreNotice == AppModel.LoreNotice(id: place.id, name: "Somewhere", count: 3))
        #expect(model.lookingForSecrets == nil)
        // In the book and on the map's count, and their art's saved for offline.
        #expect(model.stickersHere.contains { $0.entry.id == "osm\(Self.somewhere)-the-mill" })
        #expect(FileManager.default.fileExists(atPath: ServerLore.stickerFile(for: "osm\(Self.somewhere)-the-jetty", in: store.serverStickers).path))
        #expect(server.downloads.count == 2)

        // Mike approves another: the earlier ones stay where they were.
        server.answers[Self.somewhere]?.version = 2
        server.answers[Self.somewhere]?.entries.append(secret("the-wreck", in: place, tile: 20))
        await model.updateLore(now: Self.somewhere)
        let second = try #require(model.cities.first?.stickers)
        for (id, hex) in first { #expect(second[id] == hex) }
        #expect(second["osm\(Self.somewhere)-the-wreck"] != nil)
        #expect(model.loreNotice?.count == 1)
        #expect(server.downloads.count == 3)

        // And they're still there next launch, from the cache, without asking.
        let reopened = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await reopened.waitForHistory()
        #expect(reopened.cities.first?.stickers == second)
        #expect(reopened.stickersHere.count == second.count)
    }

    @Test func anotherPhonesPinWaitsForTheServer() async throws {
        let store = store()
        defer { store.wipe() }
        // Synced from a phone that's already had Porlock's secrets.
        var place = city(osmId: Self.somewhere)
        let base = place.grid.hex(containing: place.boundary.centre)
        let theirs = Hex(q: base.q + 77, r: base.r)
        place.stickers = ["osm\(Self.somewhere)-the-jetty": theirs]
        store.save([place])
        let server = FakeServer()
        let model = await model(store, server: server)
        #expect(model.cities.first?.stickers?["osm\(Self.somewhere)-the-jetty"] == theirs)
        server.answers[Self.somewhere] = ServerLore.Answer(status: .ready, version: 1, entries: [secret("the-jetty", in: place, tile: 10)])
        await model.updateLore()
        // The tile the other phone gave it, not the one nearest its pin.
        #expect(model.cities.first?.stickers?["osm\(Self.somewhere)-the-jetty"] == theirs)
    }

    @Test func theSameVersionReusesTheCache() async throws {
        let store = store()
        defer { store.wipe() }
        let server = FakeServer()
        let model = await model(store, server: server)
        let place = city(osmId: Self.somewhere)
        model.add(place)
        server.answers[Self.somewhere] = ServerLore.Answer(status: .ready, version: 3, entries: [secret("the-jetty", in: place, tile: 10)])
        await model.updateLore()
        #expect(server.downloads.count == 1)
        model.loreNotice = nil

        // Same version: nothing new is taken, and no art is downloaded again.
        server.answers[Self.somewhere]?.entries = [secret("the-jetty", in: place, tile: 10), secret("the-mill", in: place, tile: 50)]
        await model.updateLore(now: Self.somewhere)
        #expect(server.asked.count == 2)
        #expect(server.downloads.count == 1)
        #expect(model.serverLore.place(Self.somewhere)?.entries.map(\.id) == ["osm\(Self.somewhere)-the-jetty"])
        #expect(model.loreNotice == nil)
    }

    @Test func artThatFailsToDownloadIsTriedAgain() {
        var lore = ServerLore()
        let place = city(osmId: Self.somewhere)
        let answer = ServerLore.Answer(status: .ready, version: 1, entries: [secret("the-jetty", in: place, tile: 10)])
        let first = lore.take(answer, for: Self.somewhere, at: .now, found: [:])
        #expect(first.stickers.count == 1)
        // Nothing saved, so the same version still wants it.
        #expect(lore.take(answer, for: Self.somewhere, at: .now, found: [:]).stickers == first.stickers)
        lore.savedStickers = first.stickers
        #expect(lore.take(answer, for: Self.somewhere, at: .now, found: [:]).stickers.isEmpty)
    }

    @Test func aSecretTakenDownGoesUnlessYouveFoundIt() async throws {
        let store = store()
        defer { store.wipe() }
        let server = FakeServer()
        let model = await model(store, server: server)
        let place = city(osmId: Self.somewhere)
        model.add(place)
        let found = secret("found-it", in: place, tile: 30), unfound = secret("not-yet", in: place, tile: 60)
        server.answers[Self.somewhere] = ServerLore.Answer(status: .ready, version: 1, entries: [found, unfound, secret("staying", in: place, tile: 90)])
        await model.updateLore()
        let pins = try #require(model.cities.first?.stickers)
        let foundAt = Date(timeIntervalSince1970: 1_790_000_000)
        model.addRemoteSecrets([found.entry.id: foundAt])

        // Mike hides both.
        server.answers[Self.somewhere] = ServerLore.Answer(status: .ready, version: 2, entries: [secret("staying", in: place, tile: 90)])
        await model.updateLore(now: Self.somewhere)
        let after = try #require(model.cities.first?.stickers)
        #expect(after[unfound.entry.id] == nil)
        #expect(after[found.entry.id] == pins[found.entry.id])
        #expect(after["osm\(Self.somewhere)-staying"] == pins["osm\(Self.somewhere)-staying"])
        #expect(model.foundStickers[found.entry.id] == foundAt)
        // Still yours to read in the book.
        #expect(model.serverLore.kept.map(\.id) == [found.entry.id])
        #expect(model.stickersHere.contains { $0.entry.id == found.entry.id })
        #expect(!model.stickersHere.contains { $0.entry.id == unfound.entry.id })
        #expect(model.serverLore.entry(id: found.entry.id)?.title == "found-it")
    }

    @Test func aQuietPlaceSaysSoOnce() async throws {
        let store = store()
        defer { store.wipe() }
        let server = FakeServer()
        let model = await model(store, server: server)
        let place = city(osmId: Self.somewhere)
        model.add(place)
        server.answers[Self.somewhere] = ServerLore.Answer(status: .quiet, version: 0, entries: [])
        await model.updateLore()
        #expect(model.loreNotice == AppModel.LoreNotice(id: place.id, name: "Somewhere", count: 0))
        model.loreNotice = nil
        await model.updateLore(now: Self.somewhere)
        #expect(model.loreNotice == nil)
    }

    @Test func aDeletedPlaceIsForgottenButItsFoundSecretsStay() async throws {
        let store = store()
        defer { store.wipe() }
        let server = FakeServer()
        let model = await model(store, server: server)
        let place = city(osmId: Self.somewhere)
        model.add(place)
        let found = secret("found-it", in: place, tile: 30)
        server.answers[Self.somewhere] = ServerLore.Answer(status: .ready, version: 1, entries: [found, secret("not-yet", in: place, tile: 60)])
        await model.updateLore()
        model.addRemoteSecrets([found.entry.id: .now])
        model.deleteCity(place.id)
        await model.updateLore()
        #expect(model.serverLore.places.isEmpty)
        #expect(model.serverLore.kept.map(\.id) == [found.entry.id])
        #expect(model.serverLore.savedStickers.keys.sorted() == [found.entry.id])
        #expect(server.asked == [Self.somewhere])
    }
}
