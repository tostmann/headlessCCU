#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Lokales Build des headlessccu Add-On Images.
#
# Layout: Dockerfile + run.sh + config.yaml + rootfs/ + rega_session_mock.py
# alle im selben Verzeichnis (HA-Supervisor-Konvention).  bmcond-Source wird
# vom Dockerfile via `git clone --depth=1 --branch=$BMCOND_VERSION` aus
# https://github.com/tostmann/bmcond zur Build-Zeit gezogen — kein lokales
# Vendoring nötig.
#
# Sources der eq-3-Binaries: apt.debmatic.de — kein lokaler Mirror nötig.
# Build dauert ~5 min beim ersten Mal (apt-fetch von debmatic + JRE + bmcond-clone).
#
# Lizenz: GPL-2.0-or-later

set -euo pipefail

cd "$(dirname "$0")"
ADDON_DIR="$PWD"

IMAGE_TAG="${IMAGE_TAG:-headlessccu:dev}"

# Default-Pin der eq-3-Bundle-Version (siehe Dockerfile-Kommentar).  Kann
# überschrieben werden:
#   DEBMATIC_VERSION=3.85.8-124 ./build.sh   # neuer Pin (Test-Upgrade)
#   DEBMATIC_VERSION=latest     ./build.sh   # unpinned — Notausgang wenn
#                                            # apt.debmatic.de den Pin gedroppt hat
DEBMATIC_VERSION="${DEBMATIC_VERSION:-3.85.7-123}"

# Pin der gebündelten bmcond-Version (Default = passender Tag im
# tostmann/bmcond Repo).  Override:
#   BMCOND_VERSION=main ./build.sh
BMCOND_VERSION="${BMCOND_VERSION:-2026.5.3}"

echo "── docker build ──"
# --network=host umgeht docker0-MTU-Falle: bei Hosts mit eth0-MTU<1500
# (z.B. via Tailscale/WireGuard) fragmentieren TLS-Pakete via docker-bridge
# ins Leere und apt.debmatic.de-Fetch hängt mit "SSL connection timeout".
# Im Host-Network sieht der Build-Container direkt das eth0-MTU.
# HA-Supervisor-Builds laufen auf normalen 1500-MTU-Hosts; dort egal.
docker build \
  --network=host \
  -t "$IMAGE_TAG" \
  --build-arg BUILD_FROM=debian:bookworm-slim \
  --build-arg "DEBMATIC_VERSION=$DEBMATIC_VERSION" \
  --build-arg "BMCOND_VERSION=$BMCOND_VERSION" \
  "$ADDON_DIR"

echo
echo "── Image bereit ──"
docker images "$IMAGE_TAG"

echo
echo "── Run mit ──"
echo "  docker compose up -d"
echo "── oder manuell ──"
echo "  docker run --rm -it --network host \\"
echo "    --device /dev/bus/usb:/dev/bus/usb \\"
echo "    -v \$PWD/data:/data \\"
echo "    $IMAGE_TAG"
