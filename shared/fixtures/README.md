# Shared fixtures

Test data used by both the iPhone and Android apps.

- `places/geographe.json`: the server street cache blob (`PlaceData`: boundary and walkable ways) for Geographe, OSM relation 11688696, as served by `places:get`. Map data © OpenStreetMap contributors, ODbL. Refresh with `npx convex run places:cachedUrl '{"osmId": 11688696}'` and download the URL.
