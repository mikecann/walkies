import MapKit
import SwiftUI

struct MapFocusRequest: Equatable {
    enum Target { case city, user }
    var id = 0
    var target = Target.city

    mutating func send(_ target: Target) {
        id += 1
        self.target = target
    }
}

/// The satellite map, with the suburb's outline, your route and orange outlines on
/// tiles uncovered this walk. The clouds are drawn over the top by `CloudLayer`.
struct FogMapView: UIViewRepresentable {
    var city: City?
    var fresh: Set<Hex>
    var revision: Int
    var path: [Coordinate]
    var focus: MapFocusRequest
    /// Tilted, with Apple's 3D buildings and trees.
    var tilted: Bool
    let handle: MapHandle

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
        context.coordinator.update(map, with: self)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var city: City?
        private var fresh: Set<Hex> = []
        private var revision = -1
        private var focusID = -1
        private var pathCount = -1
        private var hasShownUser = false
        private var following = false
        private var tilted: Bool?

        private var outline: MKMultiPolygon?
        private var uncovered: MKMultiPolygon?
        private var line: MKPolyline?

        func update(_ map: MKMapView, with view: FogMapView) {
            if view.tilted != tilted {
                let first = tilted == nil
                tilted = view.tilted
                map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: view.tilted ? .realistic : .flat)
                if !first { tilt(map, animated: true) }
            }

            let cityChanged = view.city?.id != city?.id
            city = view.city
            fresh = view.fresh

            if cityChanged {
                revision = view.revision
                redrawAll(on: map)
                zoomToCity(on: map)
            } else if view.revision != revision {
                revision = view.revision
                drawUncovered(on: map)
            }

            if view.path.count != pathCount {
                pathCount = view.path.count
                drawPath(view.path, on: map)
            }

            if view.focus.id != focusID {
                let first = focusID == -1
                focusID = view.focus.id
                if !first {
                    switch view.focus.target {
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

        private var pitch: CGFloat { tilted == true ? 55 : 0 }

        /// Keeps the same spot in the middle, just leans the camera in or out.
        private func tilt(_ map: MKMapView, animated: Bool) {
            let camera = map.camera.copy() as! MKMapCamera
            camera.pitch = pitch
            map.setCamera(camera, animated: animated)
        }

        private func redrawAll(on map: MKMapView) {
            map.removeOverlays([outline, uncovered].compactMap { $0 })
            outline = nil
            uncovered = nil
            guard let city else { return }

            // Keep each overlay before adding it: MapKit can ask for its renderer straight
            // away, and the renderer is picked by which overlay it is.
            let outline = MKMultiPolygon(city.boundary.polygons.map { poly in
                var outer = poly.outer.map(\.cl)
                let holes = poly.holes.map { hole -> MKPolygon in
                    var coords = hole.map(\.cl)
                    return MKPolygon(coordinates: &coords, count: coords.count)
                }
                return MKPolygon(coordinates: &outer, count: outer.count, interiorPolygons: holes)
            })
            self.outline = outline
            add(outline, to: map)

            drawUncovered(on: map)
        }

        private func drawUncovered(on map: MKMapView) {
            if let uncovered { map.removeOverlay(uncovered) }
            uncovered = nil
            guard let city else { return }
            let hexes = fresh.intersection(city.visited)
            guard !hexes.isEmpty else { return }
            let layer = MKMultiPolygon(hexes.map { hex in
                var corners = city.grid.corners(of: hex).map(\.cl)
                return MKPolygon(coordinates: &corners, count: corners.count)
            })
            uncovered = layer
            add(layer, to: map)
        }

        private func drawPath(_ path: [Coordinate], on map: MKMapView) {
            if let line { map.removeOverlay(line) }
            line = nil
            guard path.count > 1 else { return }
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

        private func zoomToCity(on map: MKMapView) {
            guard let outline else { return }
            let rect = outline.boundingMapRect
            // Wait a tick so the map has its real size the first time round.
            DispatchQueue.main.async {
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 150, left: 20, bottom: 150, right: 20), animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let location = userLocation.location else { return }
            if following {
                mapView.setCenter(location.coordinate, animated: true)
            } else if city == nil, !hasShownUser {
                // With no city to frame yet, start on wherever you are instead of the whole planet.
                hasShownUser = true
                mapView.setRegion(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000), animated: true)
            }
        }

        /// Stop following the moment you drag or pinch the map yourself. We follow by hand
        /// rather than with MapKit's tracking mode, because that insists on its own zoom.
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            let touched = mapView.subviews.first?.gestureRecognizers?.contains { $0.state == .began || $0.state == .changed } ?? false
            if touched { following = false }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let multi = overlay as? MKMultiPolygon {
                let r = MKMultiPolygonRenderer(multiPolygon: multi)
                if multi === uncovered {
                    r.fillColor = UIColor.walkiesOrange.withAlphaComponent(0.18)
                    r.strokeColor = .walkiesOrange
                    r.lineWidth = 2
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
                r.strokeColor = .walkiesOrange
                r.lineWidth = 4
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
