# SPDX-License-Identifier: GPL-2.0-or-later
# headlessCCU — HomeMatic-RF-Stack für Home Assistant.
#
# Architektur:
#  - L1 (RF): bmcond + rfd + HMIPServer.jar + multimacd (optional, shim-mode)
#  - L2-Fassade: rega_session_mock.py + ping_shim.py + lighttpd-Reverse-Proxy
#  - KEIN ReGa, KEIN piVCCU-Kerneltreiber im Container
#
# Build-Stages:
#  1. `bmcond-builder`  — clont tostmann/bmcond + builded busmatic-concentrator
#  2. `debmatic-extract` — fetcht debmatic.deb (apt.debmatic.de) und entpackt
#                          via `dpkg-deb -x` ohne je zu installieren
#  3. final (FROM debian:bookworm-slim) — installiert NUR die runtime-deps
#                          die debmatic transitive bringen würde + COPYs nur
#                          die eq-3-Binaries+Configs die wir wirklich nutzen
#
# Effekt: `dpkg -l` im final image enthält KEIN `debmatic`-Paket — strikt
# saubere Trennung.  debmatic.postinst läuft nie → keine udev-Triggers, kein
# systemctl-Aufruf, kein lighttpd-mod-enable.  Wir kontrollieren explizit.
#
# Lizenz-Stance (siehe memory/license_stance.md):
# eq-3-Binaries werden zur Build-Zeit aus apt.debmatic.de gefetcht
# (= eq-3 OCCU + CCU3-Firmware repackagiert).  Nur die Bestandteile die
# wir nutzen landen im resultierenden Image.  Image wird NICHT öffentlich
# distribuiert — jeder baut lokal aus offiziellen Quellen.
#
# Lizenz Dockerfile selbst: GPL-2.0-or-later

ARG BUILD_FROM=debian:bookworm-slim

# Pin der eq-3-Bundle-Version aus apt.debmatic.de.
# Single source of truth für rfd-/multimacd-/HMServer.jar-Stand.
# Format: <upstream>-<debmatic-build>, z.B. 3.85.7-123.
# Override:  DEBMATIC_VERSION=latest ./build.sh   (= unpinned-Fallback wenn
# upstream den Pin rotiert).
ARG DEBMATIC_VERSION=3.85.7-123

# Pin der gebündelten bmcond-Version (tostmann/bmcond git-tag).
# run.sh übergibt seit 2026.6.2 unconditional -B (force-BL vor multimacd-
# Handoff) — das kennt bmcond erst ab 2026.6.1.  Dieser ARG-Default MUSS
# synchron bleiben mit den Defaults in build.sh und docker-compose.yml:
# der HA-Supervisor baut NUR aus diesem Dockerfile (build.yaml reicht keine
# args durch).  Vorfall 2026-06-07: stale Pin 2026.5.7 hier → Supervisor-
# Build stirbt an "invalid option -- 'B'", Stack kommt nie hoch.
ARG BMCOND_VERSION=2026.6.1
ARG BMCOND_REPO=https://github.com/tostmann/bmcond.git

# ─── Stage 1: bmcond-builder ──────────────────────────────────────────────────
FROM ${BUILD_FROM} AS bmcond-builder
ARG BMCOND_VERSION
ARG BMCOND_REPO

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential libc6-dev libusb-1.0-0-dev libcjson-dev \
        ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --depth=1 --branch="${BMCOND_VERSION}" "${BMCOND_REPO}" src
RUN cd src && rm -rf bin build && make concentrator

# ─── Stage 2: debmatic-extract ────────────────────────────────────────────────
# Fetcht debmatic.deb via apt-get download (kein Install — postinst wird
# NIEMALS ausgeführt).  Entpackt mit dpkg-deb -x; die finale Stage cherry-
# pickt nur die Bestandteile die headlessCCU nutzt.
FROM ${BUILD_FROM} AS debmatic-extract
ARG DEBMATIC_VERSION

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg dpkg-dev \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://apt.debmatic.de/debmatic/public.key \
         > /etc/apt/keyrings/debmatic.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/debmatic.asc] https://apt.debmatic.de/debmatic stable main" \
         > /etc/apt/sources.list.d/debmatic.list \
    && apt-get update

WORKDIR /pkg-fetch
RUN if [ -z "${DEBMATIC_VERSION}" ] || [ "${DEBMATIC_VERSION}" = "latest" ]; then \
        SPEC="debmatic"; \
        echo "── debmatic: UNPINNED (upstream-latest) ──"; \
    else \
        SPEC="debmatic=${DEBMATIC_VERSION}"; \
        echo "── debmatic: pinned to ${DEBMATIC_VERSION} ──"; \
    fi \
    && apt-get download "$SPEC" \
    && mkdir -p /pkg \
    && dpkg-deb -x debmatic*.deb /pkg \
    && echo "── strip HomeMatic-Wired (RS485) + LGW-Firmware ──" \
    && rm -rf /pkg/firmware/hs485types \
              /pkg/firmware/hmw_*.hex \
              /pkg/firmware/hm-lgw-*.eq3 \
              /pkg/firmware/hmw-lgw-*.eq3 \
    && ls -la /pkg/bin/rfd /pkg/bin/multimacd /pkg/opt/HMServer/HMIPServer.jar /pkg/firmware/rftypes/ 2>&1 | tail -5

# ─── Stage 3: Runtime ─────────────────────────────────────────────────────────
FROM ${BUILD_FROM}
ARG DEBMATIC_VERSION

# Runtime-Pakete — exakt die transitiven Dependencies die debmatic
# Pre-Depends hätte, aber explizit & minimal.  Kein Pre-Depends-Bloat
# wie ipcalc/iptables/net-tools/rsync/ifupdown/lua-*.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openjdk-17-jre-headless \
        libusb-1.0-0 \
        libcjson1 \
        libstdc++6 \
        python3 python3-minimal \
        lighttpd \
        avahi-utils \
        jq nano procps \
        kmod \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# eq-3-Binaries selektiv extracted aus debmatic.deb — kein dpkg-Eintrag
# „debmatic" im Image.  Layer per Komponente damit Updates später nur
# einzelne layers neu schreiben (z.B. nur HMServer-jar-bump bei
# DEBMATIC_VERSION-Update).
COPY --from=debmatic-extract /pkg/bin/rfd          /bin/rfd
COPY --from=debmatic-extract /pkg/bin/multimacd    /bin/multimacd
COPY --from=debmatic-extract /pkg/bin/crypttool    /bin/crypttool
COPY --from=debmatic-extract /pkg/bin/tclsh        /bin/tclsh
COPY --from=debmatic-extract /pkg/opt/HMServer     /opt/HMServer
COPY --from=debmatic-extract /pkg/opt/HmIP         /opt/HmIP
COPY --from=debmatic-extract /pkg/firmware /firmware
COPY --from=debmatic-extract /pkg/etc/multimacd.conf  /etc/multimacd.conf
COPY --from=debmatic-extract /pkg/etc/HMServer.conf   /etc/HMServer.conf
COPY --from=debmatic-extract /pkg/etc/crRFD.conf      /etc/crRFD.conf
COPY --from=debmatic-extract /pkg/etc/config_templates /etc/config_templates
COPY --from=debmatic-extract /pkg/usr/share/debmatic/lib /usr/share/debmatic/lib
COPY --from=debmatic-extract /pkg/usr/share/debmatic/bin /usr/share/debmatic/bin
COPY --from=debmatic-extract /pkg/etc/ld.so.conf.d/zz_debmatic.conf /etc/ld.so.conf.d/zz_debmatic.conf

# /lib/ld-linux-armhf.so.3 für 32-bit ARM rfd (debmatic-shipped libs sind
# armhf; rfd hat den interpreter-Pfad im ELF-Header gebacken).
RUN ln -sf /usr/share/debmatic/lib/ld/ld-linux-armhf.so.3 /lib/ld-linux-armhf.so.3 \
    && ldconfig

# /boot/VERSION — run.sh liest's für Banner-Ausgabe.  debmatic.postinst
# hätte das aus /VERSION kopiert; wir machen's manuell.
COPY --from=debmatic-extract /pkg/VERSION /boot/VERSION

LABEL org.opencontainers.image.title="headlessCCU" \
      org.opencontainers.image.source="https://github.com/tostmann/headlessCCU" \
      org.opencontainers.image.description="HomeMatic L1-RF-stack ohne ReGa/piVCCU-Kerneltreiber" \
      de.debmatic.source-version="${DEBMATIC_VERSION}"

# bmcond aus Stage 1
COPY --from=bmcond-builder /build/src/bin/busmatic-concentrator /usr/local/bin/busmatic-concentrator
RUN chmod +x /usr/local/bin/busmatic-concentrator

# headlessCCU-eigene Python-Helpers + run.sh
COPY rega_session_mock.py /usr/local/bin/rega_session_mock.py
COPY ping_shim.py /usr/local/bin/ping_shim.py
COPY rootfs/ /
COPY run.sh /usr/local/bin/headlessccu-init
RUN chmod +x /usr/local/bin/rega_session_mock.py \
             /usr/local/bin/ping_shim.py \
             /usr/local/bin/headlessccu-init

EXPOSE 8765 2001 2010
VOLUME ["/data"]
ENV LANG=C.UTF-8
ENTRYPOINT ["/usr/local/bin/headlessccu-init"]
