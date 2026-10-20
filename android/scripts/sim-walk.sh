#!/bin/bash
# Walks the running emulator along a route, so you can test walks without leaving the desk.
# Route files are one "lat,lon" per line, the same ones scripts/sim-walk.sh feeds the iOS simulator.
# Usage: android/scripts/sim-walk.sh scripts/routes/navigation-way.txt [metres per second, default 1.4]
# Faster than 3.3 m/s by the GPS's speed won't uncover tiles, same as on a real walk.
# With more than one device attached, pick the emulator with ANDROID_SERIAL=emulator-5554.
set -euo pipefail
route="$1"
speed="${2:-1.4}"
interval=1
adb=$(command -v adb || echo "${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb")
# The emulator console takes speed in knots.
knots=$(awk -v s="$speed" 'BEGIN { printf "%.3f", s * 1.943844 }')

# A point every `interval` seconds along each leg of the route, as "lon lat".
points=$(awk -F, -v speed="$speed" -v interval="$interval" '
  function rad(d) { return d * 3.141592653589793 / 180 }
  function dist(a1, o1, a2, o2,   dl, dn, h) {
    dl = rad(a2 - a1); dn = rad(o2 - o1)
    h = sin(dl / 2) ^ 2 + cos(rad(a1)) * cos(rad(a2)) * sin(dn / 2) ^ 2
    return 2 * 6371008.8 * atan2(sqrt(h), sqrt(1 - h))
  }
  BEGIN { n = 0 }
  NF >= 2 { lat[n] = $1; lon[n] = $2; n++ }
  END {
    step = speed * interval
    for (i = 0; i < n - 1; i++) {
      k = int(dist(lat[i], lon[i], lat[i + 1], lon[i + 1]) / step); if (k < 1) k = 1
      for (j = 0; j < k; j++) {
        t = j / k
        printf "%.7f %.7f\n", lon[i] + (lon[i + 1] - lon[i]) * t, lat[i] + (lat[i + 1] - lat[i]) * t
      }
    }
    printf "%.7f %.7f\n", lon[n - 1], lat[n - 1]
  }' "$route")

total=$(printf '%s\n' "$points" | wc -l | tr -d ' ')
echo "Walking $total fixes at $speed m/s, one a second. Ctrl-C to stop."
i=0
while read -r lon lat; do
  i=$((i + 1))
  # geo fix <longitude> <latitude> <altitude> <satellites> <knots>
  "$adb" emu geo fix "$lon" "$lat" 0 8 "$knots" < /dev/null > /dev/null
  printf '\r%d/%d  %s, %s' "$i" "$total" "$lat" "$lon"
  sleep "$interval"
done <<< "$points"
echo
