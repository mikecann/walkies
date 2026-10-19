import MapKit
import SwiftUI

/// A found sticker, pinned where you found it.
struct StickerPin: Equatable {
    let id: String
    let coordinate: Coordinate
}

private final class StickerAnnotation: NSObject, MKAnnotation {
    let id: String
    let coordinate: CLLocationCoordinate2D

    init(_ pin: StickerPin) {
        id = pin.id
        coordinate = pin.coordinate.cl
    }
}

/// A suburb next to yours, labelled on the zoomed-out map with a button to add it.
private final class NeighbourAnnotation: NSObject, MKAnnotation {
    let place: PlaceResult
    let coordinate: CLLocationCoordinate2D

    init(_ place: PlaceResult) {
        self.place = place
        coordinate = place.boundary.labelPoint.cl
    }
}

/// The neighbour's label: a cream sticker pill with an orange plus.
private enum NeighbourPill {
    private static var cache: [String: UIImage] = [:]

    static func image(for name: String) -> UIImage? {
        if let cached = cache[name] { return cached }
        let pill = HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.burnt, in: Circle())
            Text(name)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.ink)
        }
        .padding(.leading, 5)
        .padding(.trailing, 13)
        .padding(.vertical, 5)
        .background(Color.cream, in: Capsule())
        .overlay(Capsule().strokeBorder(.white, lineWidth: 2.5))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .padding(8)
        let renderer = ImageRenderer(content: pill)
        renderer.scale = UITraitCollection.current.displayScale
        let image = renderer.uiImage
        cache[name] = image
        return image
    }
}

struct MapFocusRequest: Equatable {
    /// `arrive`: opening the app. Go to where you are, or the selected place if
    /// there's no fix yet.
    enum Target { case city, user, arrive }
    var id = 0
    var target = Target.city

    mutating func send(_ target: Target) {
        id += 1
        self.target = target
    }
}

/// The satellite map, with your places' outlines, your route and orange outlines on
/// tiles uncovered this walk. Zoomed out, the suburbs next door are outlined too, each
/// with a button to add it. The clouds are drawn over the top by `CloudLayer`.
struct FogMapView: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    var cities: [City]
    /// The place the map flies to when `flyID` changes.
    var selectedID: UUID?
    var flyID: Int
    /// Tiles uncovered this walk, per place.
    var fresh: [UUID: Set<Hex>]
    var revision: Int
    var path: [Coordinate]
    var focus: MapFocusRequest
    /// Tilted to a game-like isometric angle, with Apple's 3D buildings and trees.
    var tilted: Bool
    let handle: MapHandle
    var stickers: [StickerPin] = []
    var onSelectSticker: (String) -> Void = { _ in }
    var neighbours: [PlaceResult] = []
    var onPickNeighbour: (PlaceResult) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: tilted ? .realistic : .flat)
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = true
        handle.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.handle = handle
        context.coordinator.update(map, with: self)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        /// Camera distance in metres beyond which the neighbours show.
        static let neighbourDistance = 2500.0

        private var cities: [City] = []
        private var cityIDs: [UUID]?
        private var selectedID: UUID?
        private var flyID = -1
        private var fresh: [UUID: Set<Hex>] = [:]
        private var revision = -1
        private var focusID = -1
        private var route: [Coordinate] = []
        private var trail = "trail.teal"
        private var hasShownUser = false
        /// Waiting for a GPS fix to open the map on.
        private var arriving = false
        private var following = false
        private var tilted: Bool?
        private var pins: [StickerPin] = []
        private var onSelectSticker: (String) -> Void = { _ in }
        weak var handle: MapHandle?

        private var outline: MKMultiPolygon?
        private var uncovered: MKMultiPolygon?
        private var line: MKPolyline?

        private var neighbourIDs: [Int] = []
        private var neighbourOutline: MKMultiPolygon?
        private var neighbourPins: [NeighbourAnnotation] = []
        private var showingNeighbours = false
        private var onPickNeighbour: (PlaceResult) -> Void = { _ in }

        func update(_ map: MKMapView, with view: FogMapView) {
            if view.tilted != tilted {
                let first = tilted == nil
                tilted = view.tilted
                map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: view.tilted ? .realistic : .flat)
                if !first { tilt(map, animated: true) }
            }

            onSelectSticker = view.onSelectSticker
            if view.stickers != pins {
                pins = view.stickers
                map.removeAnnotations(map.annotations.filter { $0 is StickerAnnotation })
                map.addAnnotations(pins.map { StickerAnnotation($0) })
            }

            let ids = view.cities.map(\.id)
            cities = view.cities
            fresh = view.fresh
            if ids != cityIDs {
                cityIDs = ids
                revision = view.revision
                redrawAll(on: map)
            } else if view.revision != revision {
                revision = view.revision
                drawUncovered(on: map)
            }
            selectedID = view.selectedID
            if view.flyID != flyID, !cities.isEmpty {
                let first = flyID == -1
                flyID = view.flyID
                // Opening the app goes to where you are (an `arrive` focus request), so
                // the first time round there's no place to fly to.
                if !first { zoomToCity(on: map) }
            }

            onPickNeighbour = view.onPickNeighbour
            if view.neighbours.map(\.id) != neighbourIDs {
                neighbourIDs = view.neighbours.map(\.id)
                neighbourPins = view.neighbours.map(NeighbourAnnotation.init)
                showNeighbours(on: map, force: true)
            }

            let equippedTrail = view.model.equipped[.trail]
            if view.path != route || equippedTrail != trail {
                route = view.path
                trail = equippedTrail
                handle?.route = route.map { MKMapPoint($0.cl) }
                drawPath(route, on: map)
            }

            if view.focus.id != focusID {
                let first = focusID == -1
                focusID = view.focus.id
                if !first || view.focus.target == .arrive {
                    switch view.focus.target {
                    case .arrive:
                        following = false
                        arriving = true
                        arrive(on: map)
                        // No fix after a few seconds (no signal, or location's off): show
                        // the selected place instead.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                            guard arriving else { return }
                            arriving = false
                            zoomToCity(on: map)
                        }
                    case .city:
                        following = false
                        zoomToCity(on: map)
                    case .user:
                        following = true
                        if let location = map.userLocation.location {
                            // Street level, where you can see the dotted roads to head for.
                            let distance = map.region.span.latitudeDelta > 0.008 ? 900 : map.camera.centerCoordinateDistance
                            map.setCamera(
                                MKMapCamera(lookingAtCenter: location.coordinate, fromDistance: distance, pitch: pitch, heading: map.camera.heading),
                                animated: true
                            )
                        }
                    }
                }
            }
        }

        /// The isometric angle. MapKit flattens it a little by itself when zoomed far out.
        private var pitch: CGFloat { tilted == true ? 55 : 0 }

        /// Keeps the same spot in the middle, just leans the camera in or out. Built
        /// fresh rather than changing the pitch on a copy, which keeps the camera's
        /// height and so pulls it much further away.
        private func tilt(_ map: MKMapView, animated: Bool) {
            let now = map.camera
            map.setCamera(
                MKMapCamera(lookingAtCenter: now.centerCoordinate, fromDistance: now.centerCoordinateDistance, pitch: pitch, heading: now.heading),
                animated: animated
            )
        }

        private static func polygons(_ boundary: Boundary) -> [MKPolygon] {
            boundary.polygons.map { poly in
                var outer = poly.outer.map(\.cl)
                let holes = poly.holes.map { hole -> MKPolygon in
                    var coords = hole.map(\.cl)
                    return MKPolygon(coordinates: &coords, count: coords.count)
                }
                return MKPolygon(coordinates: &outer, count: outer.count, interiorPolygons: holes)
            }
        }

        private func redrawAll(on map: MKMapView) {
            map.removeOverlays([outline, uncovered].compactMap { $0 })
            outline = nil
            uncovered = nil
            guard !cities.isEmpty else { return }

            // Keep each overlay before adding it: MapKit can ask for its renderer straight
            // away, and the renderer is picked by which overlay it is.
            let outline = MKMultiPolygon(cities.flatMap { Self.polygons($0.boundary) })
            self.outline = outline
            add(outline, to: map)

            drawUncovered(on: map)
        }

        private func drawUncovered(on map: MKMapView) {
            if let uncovered { map.removeOverlay(uncovered) }
            uncovered = nil
            let tiles = cities.flatMap { city in
                (fresh[city.id] ?? []).intersection(city.visited).map { city.grid.corners(of: $0) }
            }
            guard !tiles.isEmpty else { return }
            let layer = MKMultiPolygon(tiles.map { tile in
                var corners = tile.map(\.cl)
                return MKPolygon(coordinates: &corners, count: corners.count)
            })
            uncovered = layer
            add(layer, to: map)
        }

        /// The suburbs next door, only once you've zoomed out far enough to see past your own.
        private func showNeighbours(on map: MKMapView, force: Bool = false) {
            let show = !neighbourPins.isEmpty && map.camera.centerCoordinateDistance > Self.neighbourDistance
            guard force || show != showingNeighbours else { return }
            showingNeighbours = show
            if let neighbourOutline { map.removeOverlay(neighbourOutline) }
            neighbourOutline = nil
            map.removeAnnotations(map.annotations.filter { $0 is NeighbourAnnotation })
            guard show else { return }
            let outline = MKMultiPolygon(neighbourPins.flatMap { Self.polygons($0.place.boundary) })
            neighbourOutline = outline
            map.addOverlay(outline, level: .aboveRoads)
            map.addAnnotations(neighbourPins)
        }

        private func drawPath(_ path: [Coordinate], on map: MKMapView) {
            if let line { map.removeOverlay(line) }
            line = nil
            // These styles are drawn by the cloud Canvas, at a fixed size in screen points.
            guard path.count > 1, trail != "trail.footprints", trail != "trail.rainbow" else { return }
            var coords = path.map(\.cl)
            let newLine = MKPolyline(coordinates: &coords, count: coords.count)
            line = newLine
            map.addOverlay(newLine, level: .aboveLabels)
        }

        /// Everything sits above the map's labels, and the walk's route line stays on top.
        private func add(_ overlay: MKOverlay, to map: MKMapView) {
            if let line {
                map.insertOverlay(overlay, below: line)
            } else {
                map.addOverlay(overlay, level: .aboveLabels)
            }
        }

        /// Opens the map on you, at about neighbourhood level, once there's a recent fix
        /// and the map has its real size.
        private func arrive(on map: MKMapView) {
            guard arriving else { return }
            guard map.bounds.width > 0, map.bounds.height > 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in arrive(on: map) }
                return
            }
            guard let location = map.userLocation.location, location.timestamp.timeIntervalSinceNow > -120 else { return }
            arriving = false
            map.setCamera(
                MKMapCamera(lookingAtCenter: location.coordinate, fromDistance: 1500, pitch: pitch, heading: 0),
                animated: map.window != nil && hasShownUser
            )
            hasShownUser = true
        }

        private func zoomToCity(on map: MKMapView) {
            guard let city = cities.first(where: { $0.id == selectedID }) else { return }
            let rect = MKMultiPolygon(Self.polygons(city.boundary)).boundingMapRect
            let padding = UIEdgeInsets(top: 150, left: 20, bottom: 150, right: 20)
            // Fitting a place to a map with no size yet sends the camera somewhere random
            // (which is what happens if iOS relaunches the app in the background), so
            // wait until it has one.
            guard map.bounds.width > 0, map.bounds.height > 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in zoomToCity(on: map) }
                return
            }
            DispatchQueue.main.async { [self] in
                guard pitch > 0 else {
                    map.setVisibleMapRect(rect, edgePadding: padding, animated: true)
                    return
                }
                // MapKit only fits a rect looking straight down. So fit it flat without
                // animating, note that camera, put the old one back before anything's
                // drawn, then fly to the fitted spot tilted.
                let before = map.camera.copy() as! MKMapCamera
                let flatStart = before.copy() as! MKMapCamera
                flatStart.pitch = 0
                map.setCamera(flatStart, animated: false)
                map.setVisibleMapRect(rect, edgePadding: padding, animated: false)
                let fitted = map.camera
                let target = MKMapCamera(
                    lookingAtCenter: fitted.centerCoordinate, fromDistance: fitted.centerCoordinateDistance,
                    pitch: pitch, heading: fitted.heading
                )
                map.setCamera(before, animated: false)
                map.setCamera(target, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let location = userLocation.location else { return }
            if arriving {
                arrive(on: mapView)
            } else if following {
                mapView.setCenter(location.coordinate, animated: true)
            } else if cities.isEmpty, !hasShownUser {
                // With no city to frame yet, start on wherever you are instead of the whole planet.
                hasShownUser = true
                mapView.setCamera(MKMapCamera(lookingAtCenter: location.coordinate, fromDistance: 2000, pitch: pitch, heading: 0), animated: true)
            }
        }

        /// Stop following the moment you drag or pinch the map yourself. We follow by hand
        /// rather than with MapKit's tracking mode, because that insists on its own zoom.
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            let touched = mapView.subviews.first?.gestureRecognizers?.contains { $0.state == .began || $0.state == .changed } ?? false
            if touched { following = false }
            handle?.moving = true
            if touched { handle?.dragging = true }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            handle?.moving = false
            handle?.dragging = false
            showNeighbours(on: mapView)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // The clouds draw your position on top of themselves instead.
            if annotation is MKUserLocation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "me")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "me")
                view.annotation = annotation
                view.isHidden = true
                return view
            }
            if let neighbour = annotation as? NeighbourAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "neighbour")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "neighbour")
                view.annotation = annotation
                view.image = NeighbourPill.image(for: neighbour.place.name)
                view.canShowCallout = false
                // Let MapKit hide labels that would overlap, rather than pile them up.
                view.collisionMode = .rectangle
                view.displayPriority = .defaultHigh
                return view
            }
            guard let sticker = annotation as? StickerAnnotation, let entry = LoreLibrary.entry(id: sticker.id) else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "sticker")
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "sticker")
            view.annotation = annotation
            view.image = StickerArt.image(for: entry, size: 40)
            view.canShowCallout = false
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            if let neighbour = annotation as? NeighbourAnnotation {
                mapView.deselectAnnotation(annotation, animated: false)
                onPickNeighbour(neighbour.place)
                return
            }
            guard let sticker = annotation as? StickerAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            onSelectSticker(sticker.id)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let multi = overlay as? MKMultiPolygon {
                let r = MKMultiPolygonRenderer(multiPolygon: multi)
                if multi === uncovered {
                    r.fillColor = UIColor.walkiesOrange.withAlphaComponent(0.18)
                    r.strokeColor = .walkiesOrange
                    r.lineWidth = 2
                } else if multi === neighbourOutline {
                    r.fillColor = UIColor.white.withAlphaComponent(0.07)
                    r.strokeColor = UIColor.white.withAlphaComponent(0.6)
                    r.lineWidth = 1.5
                    r.lineDashPattern = [3, 5]
                } else {
                    r.fillColor = nil
                    r.strokeColor = UIColor.white.withAlphaComponent(0.85)
                    r.lineWidth = 2
                    r.lineDashPattern = [6, 5]
                }
                return r
            }
            if let polyline = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: polyline)
                // Teal, so the route stands apart from this walk's orange tiles.
                r.strokeColor = UIColor(red: 0.16, green: 0.72, blue: 0.78, alpha: 1)
                r.lineWidth = 4
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
