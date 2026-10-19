#!/bin/bash
# Walks the booted simulator along a route so you can test without leaving the desk.
# Route files are one "lat,lon" per line (simctl reads negative latitudes as flags otherwise).
# Usage: scripts/sim-walk.sh scripts/routes/navigation-way.txt [metres per second, default 4]
# Anything over 4.5 m/s won't uncover tiles, same as on a real walk.
set -euo pipefail
xcrun simctl location booted start --speed="${2:-4}" --interval=2 - < "$1"
