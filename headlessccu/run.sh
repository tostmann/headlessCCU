#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# BusMatic-HASS init — startet busmatic-concentrator + rfd + HMServer +
# rega_session_mock + lighttpd. PID-1; routet alle Logs auf stdout.
#
# Lizenz: GPL-2.0-or-later

set -uo pipefail
INIT_ARGS=("$@")   # für restart_init (re-exec mit denselben Argumenten)

# ── Konfig: HA Add-On (/data/options.json) ODER env-vars (plain docker) ──
if [[ -f /data/options.json ]]; then
  read_opt() { jq -r --arg k "$1" --arg d "$2" '.[$k] // $d' /data/options.json; }
  HMID_LEGACY=$(read_opt hmid auto)
  SERIAL=$(read_opt serial BMC0000001)
  FW=$(read_opt firmware 2.8.6)
  # Transport — DualCoPro-Sticks bedienen BidCoS + HmIP gemeinsam.  Wir lesen
  # bidcos_radio (Legacy-Name) und ignorieren hmip_radio; multimacd demuxt
  # selbst.  Leere/"none"-Werte = HmIP deaktivieren (BidCoS-only-Setup).
  BIDCOS_TRANSPORT=$(read_opt bidcos_radio "usb=1b1f:c020")
  HMIP_TRANSPORT=$(read_opt hmip_radio "usb=1b1f:c020")
  RFD_LOGLEVEL=$(read_opt loglevel 3)
  REGA_MOCK_LOG=$(read_opt log_level_mock INFO)
  SGTIN=$(read_opt sgtin "")
else
  HMID_LEGACY=${BUSMATIC_HMID:-auto}
  SERIAL=${BUSMATIC_SERIAL:-BMC0000001}
  FW=${BUSMATIC_FW:-2.8.6}
  BIDCOS_TRANSPORT=${BUSMATIC_BIDCOS_TRANSPORT:-usb=1b1f:c020}
  # `-` (kein Doppelpunkt) statt `:-`: leerer String triggert KEINEN Default;
  # der User kann HmIP via `BUSMATIC_HMIP_TRANSPORT=""` explizit deaktivieren.
  HMIP_TRANSPORT=${BUSMATIC_HMIP_TRANSPORT-usb=1b1f:c020}
  RFD_LOGLEVEL=${BUSMATIC_LOGLEVEL:-3}
  REGA_MOCK_LOG=${REGA_MOCK_LOG_LEVEL:-INFO}
  SGTIN=${BUSMATIC_SGTIN:-}
fi

# HMID-Resolution:
#   "auto" (Default) → wenn /data/etc-config/ids existiert: HMID daraus
#                      lesen (= persistierter Stand früherer Runs).
#                      Sonst: random 3-byte hex aus /dev/urandom +
#                      später nach ids schreiben.
#   alles andere     → explizit gesetzt, ehren (z.B. user setzt "32f1df"
#                      um eine bestehende Pairing-Datenbank weiter zu nutzen).
# Persistenz-Anker: /data/etc-config/ids (wird im Bootstrap-Block unten
# geschrieben).  Vorteil: HMID ist stabil ab dem ersten Start, kollidiert
# nicht zwischen zwei Instanzen im selben LAN, und der User muss nichts
# konfigurieren.
if [[ "$HMID_LEGACY" == "auto" ]]; then
  if [[ -f /data/etc-config/ids ]] && grep -q '^BidCoS-Address=' /data/etc-config/ids; then
    HMID_LEGACY=$(sed -n 's/^BidCoS-Address=0x\([0-9a-fA-F]\{6\}\).*/\1/p' /data/etc-config/ids | head -1)
    [[ -z "$HMID_LEGACY" ]] && HMID_LEGACY=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
  else
    HMID_LEGACY=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
  fi
fi
# HMID muss zwischen bmcond (CLI -H) und rfd (/etc/config/ids) konsistent
# sein — sonst routet bmcond unter X aber rfd antwortet auf Frames mit Y,
# und Aktoren sehen einen widersprüchlichen Sender.  Wenn ids existiert
# aber eine andere HMID enthält als die jetzt aufgelöste, ist das immer
# ein User-Forcing-Pfad (explicit "32f1df" gesetzt, aber Container hat
# schon mal mit auto-gen'd HMID gepairt).  Warnen + ids korrigieren —
# der User trägt Verantwortung für Pairing-Invalidierung.
if [[ -f /data/etc-config/ids ]] && grep -q '^BidCoS-Address=' /data/etc-config/ids; then
  OLD_HMID=$(sed -n 's/^BidCoS-Address=0x\([0-9a-fA-F]\{6\}\).*/\1/p' /data/etc-config/ids | head -1)
  if [[ -n "$OLD_HMID" && "$OLD_HMID" != "$HMID_LEGACY" ]]; then
    echo "── WARN: HMID-Mismatch: option=$HMID_LEGACY  ids.OLD=$OLD_HMID ──" >&2
    echo "──       überschreibe ids → bestehende BidCoS-Pairings ungültig.   ──" >&2
    echo "──       (zum Erhalten: option auf 'auto' setzen oder $OLD_HMID    ──" >&2
    echo "──        explizit eintragen)                                       ──" >&2
  fi
fi

# Overlay aus /data/etc-config/bmcond.sources.json (Schema v1, vom WebUI/API
# geschrieben).  Wenn vorhanden: slots.bidcos / slots.hmip übersteuern die
# env/options-Defaults.  slots.hmip=null deaktiviert den HmIP-Pfad
# (BidCoS-only-Setup).  Fehlt sources.json oder ist sources[]-leer →
# Defaults bleiben aktiv (rückwärtskompatibel zu v0.2.5).
SOURCES_JSON=${BMCOND_SOURCES_JSON:-/data/etc-config/bmcond.sources.json}
if [[ -f "$SOURCES_JSON" ]]; then
  BIDCOS_SLOT=$(jq -r '.slots.bidcos // ""' "$SOURCES_JSON" 2>/dev/null || echo "")
  HMIP_SLOT_RAW=$(jq -r '.slots.hmip' "$SOURCES_JSON" 2>/dev/null || echo "null")
  if [[ -n "$BIDCOS_SLOT" && "$BIDCOS_SLOT" != "null" ]]; then
    T=$(jq -r --arg id "$BIDCOS_SLOT" '.sources[]? | select(.id==$id) | .transport' "$SOURCES_JSON" 2>/dev/null)
    if [[ -n "$T" && "$T" != "null" ]]; then
      BIDCOS_TRANSPORT="$T"
      echo "── sources.json overlay: bidcos slot=$BIDCOS_SLOT → $T ──"
    fi
  fi
  if [[ "$HMIP_SLOT_RAW" == "null" || -z "$HMIP_SLOT_RAW" ]]; then
    HMIP_TRANSPORT=""
    echo "── sources.json overlay: hmip slot=null → HmIP disabled ──"
  else
    T=$(jq -r --arg id "$HMIP_SLOT_RAW" '.sources[]? | select(.id==$id) | .transport' "$SOURCES_JSON" 2>/dev/null)
    if [[ -n "$T" && "$T" != "null" ]]; then
      HMIP_TRANSPORT="$T"
      echo "── sources.json overlay: hmip slot=$HMIP_SLOT_RAW → $T ──"
    fi
  fi
fi

# busmatic-concentrator -G erwartet 24-hex SGTIN, optional.  Wenn leer, nicht setzen.
SGTIN_ARG=()
[[ -n "$SGTIN" ]] && SGTIN_ARG=(-G "$SGTIN")

# HmIP-Disabled-Pfad: wenn HMIP_TRANSPORT empty oder "none", läuft der
# Stack BidCoS-only.  Folgen: kein /tmp/mmd_hmip, kein HMIPServer.jar.
# (BIDCOS_TRANSPORT bedient beide Layers — DualCoPro-Stick.)
HAS_HMIP=true
if [[ -z "$HMIP_TRANSPORT" || "$HMIP_TRANSPORT" == "none" ]]; then
  HAS_HMIP=false
fi
if [[ "$BIDCOS_TRANSPORT" != "$HMIP_TRANSPORT" ]] && $HAS_HMIP; then
  echo "WARN: bidcos_radio ≠ hmip_radio — multimacd-shim braucht ein gemeinsames"
  echo "      DualCoPro-Backend.  Nutze bidcos_radio=$BIDCOS_TRANSPORT für beide." >&2
fi

# Transport-Form auf bmcond-CLI-Flag mappen.  Lean bmcond 2026.5.7 nimmt
# (ohne Backend-Name-Prefix; alter `name=`-Style wird intern auch noch
# akzeptiert):
#   usb=VID:PID            → -U VID:PID    (libusb-direct, Default ohne Flag)
#   udp=host:port          → -E host:port  (UDP/hb-rf-eth — HB-RF-ETH / RFNETHM)
#   tcp=host:port          → -N host:port  (TCP — CULFW32, ser2net)
#   rfusb=PATH | /dev/...  → -t PATH       (UART — cp210x, ftdi_sio)
#   host:port              → -N host:port  (TCP fallback)
case "$BIDCOS_TRANSPORT" in
  usb=*)   TRANSPORT_FLAG="-U"; TRANSPORT_VAL="${BIDCOS_TRANSPORT#usb=}" ;;
  udp=*)   TRANSPORT_FLAG="-E"; TRANSPORT_VAL="${BIDCOS_TRANSPORT#udp=}" ;;
  tcp=*)   TRANSPORT_FLAG="-N"; TRANSPORT_VAL="${BIDCOS_TRANSPORT#tcp=}" ;;
  rfusb=*) TRANSPORT_FLAG="-t"; TRANSPORT_VAL="${BIDCOS_TRANSPORT#rfusb=}" ;;
  /dev/*)  TRANSPORT_FLAG="-t"; TRANSPORT_VAL="$BIDCOS_TRANSPORT" ;;
  *:*)     TRANSPORT_FLAG="-N"; TRANSPORT_VAL="$BIDCOS_TRANSPORT" ;;
  *)       TRANSPORT_FLAG="-t"; TRANSPORT_VAL="$BIDCOS_TRANSPORT" ;;
esac
TRANSPORT="$BIDCOS_TRANSPORT"   # für Banner-Print weiter unten

# Bundle-Version aus dpkg (was im Image installiert ist) + /boot/VERSION
# (was debmatic intern als CCU-Firmware-Stamp setzt, kommt im UI als
# "Firmware"-Versionsstring an).  Beide sollten sich entsprechen
# (debmatic=3.85.7-123 ↔ /boot/VERSION=3.85.7.123) — sind sie's nicht,
# ist im Build was schief gelaufen oder ein Hot-Patch im Container.
DEBMATIC_PKG=$(dpkg-query -W -f '${Version}' debmatic 2>/dev/null || echo "?")
CCU_VERSION=$(cat /boot/VERSION 2>/dev/null | sed 's/^VERSION=//' || echo "?")
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)

echo "═════════════════════════════════════════════════════════════"
echo " BusMatic-HASS — RF-Stack für Home Assistant"
echo "─────────────────────────────────────────────────────────────"
echo "  HMID:       $HMID_LEGACY"
echo "  Serial:     $SERIAL"
echo "  Firmware:   $FW       (Add-On-konfiguriert, in rfd-Banner)"
echo "  CCU-Bundle: $CCU_VERSION  (debmatic=$DEBMATIC_PKG, $ARCH)"
if $HAS_HMIP; then
  echo "  Transport:  $TRANSPORT (BidCoS + HmIP)"
else
  echo "  Transport:  $TRANSPORT (BidCoS only — HmIP disabled)"
fi
[[ -n "$SGTIN" ]] && echo "  SGTIN:      $SGTIN"
echo "═════════════════════════════════════════════════════════════"

ldconfig 2>/dev/null || true

# ── /var-State (detect_hardware-Marker) ──
mkdir -p /var/status /var/run /var/log /var/tmp /var/lib/lighttpd \
         /var/cache/lighttpd/uploads /var/log/lighttpd
chown -R www-data:www-data /var/cache/lighttpd /var/log/lighttpd 2>/dev/null || true

# ── /etc/config-State frühzeitig (rfd erwartet firmware/ schon beim Start,
#    sonst Warning "opendir(/etc/config/firmware//) failed" beim BidCoS-Boot;
#    /etc/config ist gleich darunter Symlink → /data/etc-config, also legen
#    wir die Subdirs implizit dort an).
mkdir -p /data/etc-config/firmware /data/etc-config/rfd /data/etc-config/crRFD/data

# ── Persistente Config aus /data (HA Add-On) bzw. Volume (plain docker) ──
mkdir -p /data/etc-config
if [[ -L /etc/config ]]; then
  :
elif [[ -d /etc/config ]]; then
  # Erst-Start: Templates schon eingespielt, jetzt nach /data umziehen.
  cp -an /etc/config/. /data/etc-config/ 2>/dev/null || true
  rm -rf /etc/config
  ln -s /data/etc-config /etc/config
else
  ln -s /data/etc-config /etc/config
fi
for tpl in /etc/config_templates/*; do
  fname=$(basename "$tpl")
  [[ -e /etc/config/$fname ]] || cp "$tpl" /etc/config/
done
# ids: HMID + Serial für rfd — wird nicht von confgen geschrieben.
# Immer (re)schreiben damit ids und bmcond-CLI-Args konsistent sind.
# Bei HMID=auto wurde HMID_LEGACY oben aus ids zurückgelesen — kein Drift.
# Bei explizit gesetzter HMID gewinnt die Option, alte ids wird überschrieben
# (Warning kam oben).
printf 'BidCoS-Address=0x%s\nSerialNumber=%s\n' "${HMID_LEGACY}" "${SERIAL}" > /etc/config/ids

# ── Trap / Cleanup ──
PIDS=()
declare -A SVC_NAME          # echte Service-PID → menschenlesbarer Name
# Service-Start-Helper: NACH `cmd > >(stdbuf sed …) 2>&1 &` aufrufen.
# Dank process-substitution ist $! die ECHTE Service-PID (nicht die des
# sed-Log-Wrappers wie beim alten `cmd | sed &`-Pattern, das immer rc=0
# meldete).  So kann `wait -n -p` beim Exit Service-Name + echten Code nennen.
track() { local p=$!; PIDS+=("$p"); SVC_NAME[$p]="$1"; }

# Läuft der Prozess noch?  `kill -0` allein reicht nicht: ein beendetes, noch
# nicht per wait eingesammeltes Kind (Zombie) antwortet weiter auf kill -0.
svc_alive() {
  local st
  st=$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null) || return 1
  [[ -n "$st" && "${st%% *}" != "Z" ]]
}
# SIGTERM an eine Gruppe, bis zu $1 ms auf ihr Ende warten, Rest mit SIGKILL.
term_and_wait() {
  local timeout_ms=$1 p alive deadline; shift
  (( $# )) || return 0
  for p in "$@"; do kill -TERM "$p" 2>/dev/null || true; done
  deadline=$(( $(date +%s%3N) + timeout_ms ))
  while :; do
    alive=0
    for p in "$@"; do svc_alive "$p" && alive=1; done
    (( alive )) || return 0
    (( $(date +%s%3N) >= deadline )) && break
    sleep 0.1
  done
  for p in "$@"; do
    if svc_alive "$p"; then
      echo "  WARN: ${SVC_NAME[$p]:-pid $p} reagiert nicht auf SIGTERM — SIGKILL" >&2
      kill -KILL "$p" 2>/dev/null || true
    fi
  done
}
# Dienste in umgekehrter Abhängigkeit stoppen (wie OpenCCU: S62HMIPServer /
# S61rfd vor S60multimacd).  rfd liest /dev/mmd_bidcos; beendet sich multimacd
# zuerst, liefert read() -ENODEV, rfd's ReadData() rechnet das als unsigned
# Länge und bricht mit std::length_error → abort → Coredump ab.  Darum:
#   1. rfd (Supervisor-Subshell leitet SIGTERM an rfd weiter) + HMIPServer
#   2. multimacd
#   3. bmcond und alle übrigen (Mock, Shims, lighttpd)
# Summe der Timeouts 8 s — Docker und der HA-Supervisor schicken nach 10 s
# SIGKILL; der Rest ist Reserve für die Trap-Latenz (siehe `sleep … & wait`).
stop_stack_ordered() {
  local p first=() second=() rest=()
  for p in "${PIDS[@]}"; do
    case "${SVC_NAME[$p]:-}" in
      rfd|HMIPServer) first+=("$p") ;;
      multimacd)      second+=("$p") ;;
      *)              rest+=("$p") ;;
    esac
  done
  term_and_wait 3500 "${first[@]}"
  term_and_wait 2000 "${second[@]}"
  term_and_wait 2500 "${rest[@]}"   # bmcond: USB-RX-Thread 200 ms + API-select bis 1 s
}
shutdown_handler() {
  trap '' TERM INT          # ein zweites SIGTERM startet keinen zweiten Durchlauf
  echo "── Shutdown ──"
  stop_stack_ordered
  exit 0
}
trap shutdown_handler TERM INT
# Wie shutdown_handler, aber mit rc≠0 und Ursache — für Init-Zustände, aus
# denen der Stack nicht von selbst herausfindet (Supervisor/Docker startet neu).
fatal_shutdown() {
  echo "ERROR: $1" >&2
  echo "── Fatal init error — stopping all services (rc=1) ──" >&2
  trap '' TERM INT
  stop_stack_ordered
  exit 1
}
# Ein Dienst ist unerwartet beendet: Rest geordnet stoppen und mit rc≠0 enden.
# rc 0 würde den Absturz verdecken — Docker `restart: on-failure` griffe nicht,
# das Supervisor-Log meldete keinen Exit-Code.  Ein Dienst-rc von 0 zählt hier
# ebenfalls als Fehler (alle Dienste sind Dauerläufer) → rc 1.
failure_exit() {
  local rc=$1
  trap '' TERM INT
  echo "── Stopping remaining services after unexpected exit (container rc=$(( rc == 0 ? 1 : rc ))) ──" >&2
  stop_stack_ordered
  exit $(( rc == 0 ? 1 : rc ))
}
# HTTP-Helfer: das Runtime-Image hat kein curl/wget (curl nur in der Build-
# Stage), python3 ist da.  http_get URL → Body auf stdout (leer bei Fehler).
http_get() {
  python3 -c 'import sys, urllib.request
try:
    sys.stdout.write(urllib.request.urlopen(sys.argv[1], timeout=3).read().decode())
except Exception:
    pass' "$1" 2>/dev/null
}
# Init komplett neu starten (Grund in $1).  Genutzt von bmcond's /api/reload
# (Marker bmcd-reload-requested) und vom Wartungsmodus nach erfolgreichem
# Firmware-Flash (Marker bmcd-flash-ok).
# Unter HA-Supervisor (SUPERVISOR_TOKEN gesetzt) → sauberer Container-Restart
# über die Supervisor-API (frisches Network-Namespace, alle Listen-Sockets
# sauber released).  Sonst (Standalone-Docker oder kein API-Token):
# geordneter Stop + in-container re-exec (pkill auf die eigenen Kinder als
# Nachlese — nicht `-P 1`: unter HA ist tini PID 1 und run.sh dessen Kind).
export SUPERVISOR_API=${SUPERVISOR_API:-http://supervisor}
# supervisor_get PATH → Body auf stdout (leer bei Fehler / ohne Token).
supervisor_get() {
  [[ -n "${SUPERVISOR_TOKEN:-}" ]] || return 0
  python3 -c 'import os, sys, urllib.request
req = urllib.request.Request(os.environ["SUPERVISOR_API"] + sys.argv[1],
      headers={"Authorization": "Bearer " + os.environ["SUPERVISOR_TOKEN"]})
try:
    sys.stdout.write(urllib.request.urlopen(req, timeout=3).read().decode())
except Exception:
    pass' "$1" 2>/dev/null
}
restart_init() {
  echo "── $1 — restarting init ──"
  if [[ -n "${SUPERVISOR_TOKEN:-}" ]]; then
    echo "── Asking Supervisor to restart this add-on ──"
    python3 -c 'import os, urllib.request
req = urllib.request.Request(os.environ["SUPERVISOR_API"] + "/addons/self/restart", method="POST",
      headers={"Authorization": "Bearer " + os.environ["SUPERVISOR_TOKEN"]})
try:
    urllib.request.urlopen(req, timeout=5)
except Exception as e:
    print("   supervisor restart request failed:", e)' || true
    # Supervisor schickt SIGTERM an Container — wir warten passiv
    # (max 60s; danach würde Supervisor SIGKILL nachschießen)
    # Hintergrund-sleep + wait: bash führt den TERM-Trap erst nach einem
    # Vordergrund-Kommando aus — ein `sleep 60` hielte das SIGTERM des
    # Supervisors bis zu dessen SIGKILL (10 s) zurück, ohne geordneten Stop.
    sleep 60 & wait $!
    # falls Supervisor's stop nicht durchkam, fallback: aufgeben
    echo "── Supervisor restart did not arrive within 60s — falling through ──"
  fi
  # Fallback / Standalone-Pfad
  echo "── Fallback: in-container re-exec ──"
  stop_stack_ordered
  pkill -TERM -P $$ 2>/dev/null || true
  sleep 2
  pkill -KILL -P $$ 2>/dev/null || true
  sleep 1
  exec "$0" "${INIT_ARGS[@]}"
}

# ── 0. HA-Watchdog-Hinweis ──
# Stirbt ein Dienst, endet der Container mit rc≠0 (failure_exit).  Unter Docker
# Compose startet `restart: unless-stopped` neu; unter Home Assistant nur, wenn
# der Watchdog-Schalter des Add-ons an ist (Supervisor-Default: aus).
if [[ -n "${SUPERVISOR_TOKEN:-}" ]]; then
  if [[ "$(supervisor_get /addons/self/info | jq -r '.data.watchdog' 2>/dev/null)" == "false" ]]; then
    echo "WARN: the Home Assistant watchdog for this add-on is disabled — if a service" >&2
    echo "      crashes, the add-on stops and is NOT restarted automatically." >&2
    echo "      Enable \"Watchdog\" on the add-on page." >&2
  fi
fi

# ── 1. busmatic-concentrator (= bmcond) ──
# bmcond 2026.5.7+ ist pure userspace radio-transport: byte-pump zwischen
# einem Transport-fd (USB-libusb / UART / TCP / UDP) und einem PTY-master.
# Multimacd öffnet den PTY-symlink (/tmp/raw-uart-shim) als seine
# "Coprocessor Device" und macht den vollen Mac-Layer (DUTY/CSMA/AES/
# LLMAC-Translation/3burst-Retry/Demux nach /dev/mmd_{bidcos,hmip}).
echo "── Starting busmatic-concentrator (transport-shim für multimacd) ──"
# -B (force-BL vor multimacd-Handoff) ist PFLICHT, nicht optional:
# multimacd treibt seinen eigenen Boot-Handshake und ERWARTET das Modul im
# Bootloader (COMMON_IDENTIFY → 'HMIP_TRX_Bl' → multimacd macht selbst
# CHANGE_APP → 'DualCoPro_App'-Push).  Steht das Modul beim multimacd-Connect
# schon eingeschwungen im App-Mode (was es über bmcond-Restarts/Power-Cycles
# bleibt), liefert COMMON_IDENTIFY die *SGTIN* statt des App-Namens →
# multimacd findet keinen App-Tag → "No Coprocessor detected / Signal 10" →
# rfd "readSerialNumber failed / No BidCoS-Interface" → Container-Shutdown.
# confgen (-C) läuft VOR force-BL (concentrator.c main: confgen @747, force_bl
# @848), also bleibt der rfd.conf/InterfacesList-Output erhalten UND multimacd
# bekommt einen sauberen Bootloader-Zustand.  Verifiziert 2026-06-04 e2e
# (HMIP_TRX_Bl → DualCoPro_App, rfd readSerial OK, livetest HmIP 3/3, BidCoS-
# Interface CONNECTED).  Repliziert exakt das, was der hb_rf_usb_2-Kernel-
# Treiber via IOCRESET macht (siehe captures/multimacd_hmip_rfusb_*/ANALYSIS.md).
# Kompat-Guard: -B gibt's erst ab bmcond 2026.6.1.  Ein älteres Binary
# (stale BMCOND_VERSION-Pin in Dockerfile/build.sh) stirbt sonst an
# getopt-Usage-Noise, der Stack hängt 15s am Shim-Wait und fällt dann
# scheinbar am eq3loop-Check — die echte Ursache ist im Log kaum zu
# erkennen (Vorfall 2026-06-07, Supervisor-Build mit Pin 2026.5.7).
if ! /usr/local/bin/busmatic-concentrator -h 2>&1 | grep -qE '^[[:space:]]*-B[[:space:]]'; then
  echo "ERROR: gebündelter busmatic-concentrator kennt -B nicht — bmcond >= 2026.6.1 erforderlich." >&2
  echo "       BMCOND_VERSION-Pin prüfen (Dockerfile ARG / build.sh / docker-compose.yml)." >&2
  exit 1
fi

CONC_ARGS=(
  "$TRANSPORT_FLAG" "$TRANSPORT_VAL"
  --raw-uart "/tmp/raw-uart-shim"
  -C
  -B
  -V
)
echo "  args: ${CONC_ARGS[*]}"
rm -f /var/run/bmcd-flash-ok   # nur im Wartungsmodus dieses Laufs relevant
/usr/local/bin/busmatic-concentrator "${CONC_ARGS[@]}" \
  > >(stdbuf -oL sed 's/^/[bmcond ] /') 2>&1 &
track "bmcond"
BMCOND_PID=$!

# Stale flash-busy-marker (älter als 5min) aufräumen — passiert wenn bmcond
# bei einem vorherigen flash gekillt wurde.
if [[ -f /var/run/bmcd-flash-busy ]]; then
  AGE=$(( $(date +%s) - $(stat -c %Y /var/run/bmcd-flash-busy 2>/dev/null || date +%s) ))
  if [[ $AGE -gt 300 ]]; then
    echo "── stale bmcd-flash-busy marker (age ${AGE}s) — clearing ──"
    rm -f /var/run/bmcd-flash-busy
  fi
fi

# Wenn flash pending oder läuft: bis zu 180s warten BEVOR rfd startet.
# bmcond's flash-job-Pfad löscht bmcd-flash-busy bei Ende (Erfolg/Fehler).
WAIT=0
while [[ -f /var/run/bmcd-flash-job.json || -f /var/run/bmcd-flash-busy ]]; do
  if [[ $WAIT -ge 180 ]]; then
    echo "WARN: flash-busy nach 180s noch da — fahre trotzdem fort" >&2
    break
  fi
  if [[ $((WAIT % 10)) -eq 0 ]]; then
    echo "── flash in progress (${WAIT}s elapsed) — rfd-start verzögert ──"
  fi
  sleep 2; WAIT=$((WAIT+2))
done

# Auf bmcond's PTY-Symlink warten (max 15s) — multimacd öffnet ihn als
# "Coprocessor Device Path".
for i in $(seq 1 30); do
  [[ -e /tmp/raw-uart-shim ]] && break
  sleep 0.5
done
if ! [[ -e /tmp/raw-uart-shim ]]; then
  echo "WARN: /tmp/raw-uart-shim did not appear within 15s" >&2
fi

# ── 1a. Wartungsmodus bei inkompatibler Coprocessor-Firmware ──
# bmcond meldet über /api/effective, ob der Coprocessor DualCoPro_App fährt.
# Bei HMIP_TRX_App (reine HmIP-FW) oder Co_CPU_App (reine BidCoS-FW) beendet
# sich multimacd mit "Please install DualCoPro Firmware" — der Stack käme nie
# hoch, der Container liefe in eine Neustart-Schleife und die WebUI wäre für
# einen Firmware-Flash kaum erreichbar.  Darum: nur bmcond weiterlaufen lassen
# (WebUI/API :9126 inkl. Flash), keine weiteren Dienste starten.  Nach einem
# erfolgreichen Flash legt bmcond /var/run/bmcd-flash-ok an → Init startet neu
# und fährt mit der neuen Firmware den vollen Stack.  Ist die API nicht
# erreichbar oder liefert keinen Wert, läuft der normale Start weiter.
MAINT_API=${MAINT_API:-http://127.0.0.1:9126/api/effective}
maint_json=$(http_get "$MAINT_API")
# Kein `// empty`: jq's Alternative-Operator behandelt auch `false` als leer.
if [[ "$(jq -r '.backends[0].firmware_compatible' <<<"$maint_json" 2>/dev/null)" == "false" ]]; then
  maint_tag=$(jq -r '.backends[0].app_tag // "?"' <<<"$maint_json" 2>/dev/null)
  maint_hint=$(jq -r '.backends[0].firmware_hint // ""' <<<"$maint_json" 2>/dev/null)
  echo "═════════════════════════════════════════════════════════════" >&2
  echo "  MAINTENANCE MODE — coprocessor firmware '$maint_tag' is not supported" >&2
  [[ -n "$maint_hint" ]] && echo "  $maint_hint" >&2
  echo "  Only bmcond is running (WebUI/API :9126).  multimacd, rfd and" >&2
  echo "  HMIPServer are NOT started.  After a successful firmware flash the" >&2
  echo "  add-on restarts automatically." >&2
  echo "═════════════════════════════════════════════════════════════" >&2
  while :; do
    if [[ -f /var/run/bmcd-flash-ok ]]; then
      rm -f /var/run/bmcd-flash-ok
      restart_init "maintenance mode: firmware flash succeeded"
    fi
    if [[ -f /var/run/bmcd-reload-requested ]]; then
      rm -f /var/run/bmcd-reload-requested
      restart_init "maintenance mode: /api/reload requested"
    fi
    if ! kill -0 "$BMCOND_PID" 2>/dev/null; then
      wait "$BMCOND_PID" 2>/dev/null; maint_rc=$?
      echo "── maintenance mode: bmcond exited rc=$maint_rc ──" >&2
      failure_exit "$maint_rc"
    fi
    sleep 2 & wait $!
  done
fi

# ── 1b. multimacd ──
# Spec aus /usr/share/debmatic/bin/start_multimacd.sh nachgebaut weil das
# Original-Wrapper multimacd daemonized und unsere wait-n-Loop dadurch
# ein falsches child-exit-Signal sieht.  Hier: multimacd FOREGROUND.
#
# Container-Permissions die wir brauchen:
#   - CAP_MKNOD (default im docker-cap-set; im HAOS-Add-On über die
#     devices:-Liste + udev:true cgroup-grant, NICHT über full_access)
#   - CAP_SYS_MODULE (modprobe — config.yaml kernel_modules:true; ODER
#     Host hat eq3_char_loop vor-geladen)
#   - CAP_SYS_ADMIN (mount -o rw,remount /dev — oben; HAOS-/dev ist ro)
#   - sysfs lesbar (default /sys ist read-only-mount aber lesbar)
echo "── Starting multimacd ──"

# eq3_char_loop laden falls Host das nicht schon gemacht hat.  Modul ist
# GPLv2 und Teil des piVCCU-modules-dkms-Pakets.
modprobe -q eq3_char_loop 2>/dev/null || {
  echo "WARN: modprobe eq3_char_loop fehlgeschlagen — "
  echo "      braucht CAP_SYS_MODULE im Container ODER vor-geladenes Host-Modul" >&2
}

# /dev rw machen falls read-only gemountet (HAOS-Supervisor bindet /dev
# read_only=True ein — MOUNT_DEV).  Die mknod's der eq3loop/mmd-Nodes weiter
# unten scheitern sonst mit EROFS.  Im docker-compose-Pfad ist /dev bereits
# rw → der Test schlägt nicht an, kein Remount.  Braucht CAP_SYS_ADMIN
# (config.yaml: privileged SYS_ADMIN); fehlt die Cap, ist der Remount ein
# No-op und der mknod-Fallback meldet seinen eigenen Fehler.
if ! { : > /dev/.bmcd-rwtest; } 2>/dev/null; then
  echo "── /dev ist read-only — remount rw (für mknod der eq3loop/mmd-Nodes) ──"
  mount -o rw,remount /dev 2>/dev/null || \
    echo "  WARN: remount /dev rw fehlgeschlagen — braucht CAP_SYS_ADMIN; mknod kann scheitern" >&2
else
  rm -f /dev/.bmcd-rwtest 2>/dev/null || true
fi

# /dev/eq3loop mknod-Fallback (siehe start_multimacd.sh).
# WICHTIG: auf `! -c` (kein char-dev) testen, NICHT `! -e` (existiert).
# Wenn der Host-Char-Node nach einem USB-/Modul-Event verschwindet und der
# Container mit `-v /dev/eq3loop:/dev/eq3loop` läuft, legt Docker die fehlende
# Bind-Quelle still als *leeres Verzeichnis* an → `! -e` ist FALSE → mknod
# übersprungen → `! -c` trifft → exit 1 → Container-Shutdown bei JEDEM Restart.
# Darum: Fremd-Placeholder (Verzeichnis/Datei, NIE ein echtes char-dev) erst
# wegräumen, dann mknod. rmdir/rm -f fassen ein char-dev nicht an.
# (Besser noch: /dev/eq3loop gar nicht in den Container reichen — siehe
# docker-compose.yml; dann ist es in einem frischen Container nie vorhanden
# und wird hier sauber selbst erzeugt.)
if [[ -e /dev/eq3loop && ! -c /dev/eq3loop ]]; then
  echo "── /dev/eq3loop ist kein char-dev (Docker-Bind-Autocreate?) — räume Placeholder weg ──" >&2
  rmdir /dev/eq3loop 2>/dev/null || rm -f /dev/eq3loop 2>/dev/null || true
fi
if [[ ! -c /dev/eq3loop && -e /sys/devices/virtual/eq3loop/eq3loop/dev ]]; then
  mknod /dev/eq3loop c $(cat /sys/devices/virtual/eq3loop/eq3loop/dev | tr ':' ' ') || {
    echo "WARN: mknod /dev/eq3loop failed — braucht CAP_MKNOD" >&2
  }
fi
if [[ ! -c /dev/eq3loop ]]; then
  echo "ERROR: /dev/eq3loop fehlt und konnte nicht erzeugt werden — multimacd kann nicht starten" >&2
  exit 1
fi

# /dev/eq3loop EXISTIERT jetzt — aber im HAOS-Add-On ist es u.U. noch nicht
# *öffenbar*: HA-Add-Ons können keine cgroup-Wildcard (wie docker-composes
# `device_cgroup_rules: c 509:* rwm`) setzen.  Die `devices:`-Liste in
# config.yaml gewährt den cgroup-Zugriff nur, wenn der Node beim Container-
# Create schon existierte.  Wenn der Container das Modul gerade selbst via
# modprobe geladen hat, erscheint /dev/eq3loop erst danach; der Supervisor
# grantet die Device-cgroup dann per `udev: true`-Hotplug NACH dem
# Modul-load-udev-Event — was ein paar hundert ms dauern kann.  Öffnet
# multimacd /dev/eq3loop zu früh, scheitert es mit
# "could not open master port /dev/eq3loop: Operation not permitted".
# Darum hier warten bis der Node WIRKLICH lesbar ist (head -c0 = open+close
# ohne Daten, gleiches Idiom wie eq-3's start_multimacd.sh).
EQ3_OK=false
for i in $(seq 1 40); do
  if head -c0 /dev/eq3loop >/dev/null 2>&1; then EQ3_OK=true; echo "  /dev/eq3loop openable after $((i/2))s"; break; fi
  sleep 0.5
done
if ! $EQ3_OK; then
  echo "WARN: /dev/eq3loop nach 20s nicht öffenbar (cgroup-Grant fehlt?) —" >&2
  echo "      multimacd kann mit EROFS/EPERM scheitern.  Auf HAOS: eq3_char_loop" >&2
  echo "      ggf. host-seitig vorladen, oder devices:-Auflösung prüfen." >&2
fi

# multimacd-config mit Shim-Pfad.  /etc/multimacd.conf (von debmatic
# geliefert) hat /dev/raw-uart als Default — wir generieren eine eigene
# Config mit /tmp/raw-uart-shim und starten multimacd selbst (statt das
# start_multimacd.sh-Wrapper) damit es im FOREGROUND läuft.  Sonst
# daemonized es sich, der Wrapper exitet rc=0 und run.sh's wait -n
# interpretiert das als crash → Shutdown-Trigger.
sed -e "s|^Coprocessor Device Path = .*$|Coprocessor Device Path = /tmp/raw-uart-shim|" \
    -e "s|^Log Destination = .*$|Log Destination = Stderr|" \
    /etc/multimacd.conf > /var/run/multimacd.conf
echo "  multimacd config:"
grep -E "Coprocessor Device|Log Destination" /var/run/multimacd.conf

# multimacd kein -d → foreground.  rt-scheduling-Setup vorher.
sysctl -w kernel.sched_rt_runtime_us=-1 >/dev/null 2>&1 || \
  echo "  WARN: sched_rt_runtime_us setup failed — multimacd's rt-prio kann hängen"
# multimacd schreibt seine PID nach /var/status/multimacd.status, sobald der
# Coprocessor-Init komplett durch ist (Identify → Version → SGTIN → RF-Adresse
# → Seriennummer).  Eine Datei aus einem früheren Lauf darf das Gate unten
# nicht vorzeitig öffnen.
rm -f /var/status/multimacd.status
/bin/multimacd -f /var/run/multimacd.conf -l "$RFD_LOGLEVEL" -c \
  > >(stdbuf -oL sed 's/^/[mmd    ] /') 2>&1 &
track "multimacd"
MMD_PID=$!

# Warten bis /sys/devices/virtual/eq3loop/mmd_*/dev erscheint.  multimacd
# legt die Slave-Kanäle beim Start an, noch VOR jedem Coprocessor-Verkehr —
# ihre Existenz sagt nichts über den Copro-Zustand (dafür das Status-Gate
# weiter unten).  In Containern ohne udev werden die /dev/-Nodes NICHT
# automatisch erzeugt — wir mknod-fallback'n nach Spec von eq-3's
# start_multimacd.sh.
echo "── Waiting for eq3loop slave-devices ──"
for dev in mmd_bidcos mmd_hmip; do
  if [[ "$dev" = "mmd_hmip" ]] && ! $HAS_HMIP; then continue; fi
  for i in $(seq 1 30); do
    if [[ -e /sys/devices/virtual/eq3loop/$dev/dev ]]; then
      # Fremd-Placeholder (Docker-Bind-Autocreate o.ä.) wegräumen — NIE ein
      # echtes char-dev. Dann auf `! -c` (statt `! -e`) testen.
      if [[ -e /dev/$dev && ! -c /dev/$dev ]]; then
        rmdir /dev/$dev 2>/dev/null || rm -f /dev/$dev 2>/dev/null || true
      fi
      if [[ ! -c /dev/$dev ]]; then
        mknod /dev/$dev c $(cat /sys/devices/virtual/eq3loop/$dev/dev | tr ':' ' ') || \
          echo "  WARN: mknod /dev/$dev failed — CAP_MKNOD?" >&2
      fi
      echo "  /dev/$dev ready after $((i/2))s"
      break
    fi
    sleep 0.5
  done
  if [[ ! -c /dev/$dev ]]; then
    echo "ERROR: /dev/$dev not created within 15s — multimacd handshake stuck" >&2
  fi
done

# Symlinks /tmp/mmd_* → /dev/mmd_* damit rfd/HMServer auf gewohnten Pfaden
# zugreifen können (sie öffnen /tmp/mmd_*).
ln -sf /dev/mmd_bidcos /tmp/mmd_bidcos
$HAS_HMIP && ln -sf /dev/mmd_hmip /tmp/mmd_hmip

# rfd.conf — minimale Config (HMID kommt aus /etc/config/ids, weiter unten
# geschrieben).  Idempotent: existiert die Datei schon, wird sie respektiert.
if [[ ! -f /etc/config/rfd.conf ]]; then
  cat > /etc/config/rfd.conf <<EOF
ComPortFile = /tmp/mmd_bidcos
ListenPort = 32001
EOF
  echo "  wrote minimal /etc/config/rfd.conf"
fi

# bmcond's PTY-Symlink existiert; multimacd hat /dev/mmd_* erzeugt.  Ob der
# Coprocessor-Init durchgelaufen ist, prüft erst das Readiness-Gate vor rfd.

# ── 2. rfd (mit Identify-Race-Retry) ──
# debmatic-apt installiert nach /bin/rfd mit libs unter /usr/share/debmatic/lib.
#
# Boot-Race: rfd's improvedInit schickt einen Identify-Probe an multimacd, BEVOR
# multimacd seine Coprocessor-Session fertig aufgebaut hat → leere Antwort
# ("Identify response string not handled: ") → rfd "No BidCoS-Interface" → rfd
# exitet sauber (rc=0) → früher fuhr das den ganzen Container runter.  Auf
# schnellen Hosts (nativ-USB) gewinnt multimacd meist; auf langsamen Pfaden
# (USB-Passthrough in einer VM, langsame Hosts) verliert rfd zuverlässig.
# Darum: rfd in einen Retry-Loop, der multimacd AM LEBEN lässt — stirbt rfd
# früh, neu starten (Backoff), bis multimacds Coprocessor antwortet und rfd
# identifiziert.  Lief rfd lange (>=60s = echter Lauf), Retry-Budget zurück-
# setzen, damit ein späterer echter Crash nicht vom Startup-Budget aufgefressen
# wird.  Nach RFD_MAX_TRIES schnellen Fehlversuchen aufgeben → Container-Exit
# mit rfds echtem rc (der self-diagnostizierende Supervisor nennt 'rfd').
#
# rfd läuft im Hintergrund der Subshell, damit ein SIGTERM an die Subshell (vom
# geordneten Stop) per trap an rfd weitergereicht wird — ein Vordergrund-Kind
# würde den trap bis zu seinem Ende blockieren, die Subshell stürbe allein und
# rfd bliebe verwaist bis zum multimacd-Ende (→ abort/Core, siehe
# stop_stack_ordered).
rfd_supervised() {
  local tries=0 rc start dur rfd_pid="" stopping=0
  trap 'stopping=1; [[ -n "$rfd_pid" ]] && kill -TERM "$rfd_pid" 2>/dev/null' TERM
  while true; do
    (( stopping )) && return 0
    start=$(date +%s)
    LD_LIBRARY_PATH=/usr/share/debmatic/lib \
      /bin/rfd -c -l "$RFD_LOGLEVEL" -f /etc/config/rfd.conf &
    rfd_pid=$!
    # TERM kam zwischen Schleifenkopf und $! an → der trap sah noch kein rfd_pid
    (( stopping )) && kill -TERM "$rfd_pid" 2>/dev/null
    wait "$rfd_pid"; rc=$?
    # wait kehrt beim trap sofort zurück (rc 143), rfd läuft dann noch kurz.
    while kill -0 "$rfd_pid" 2>/dev/null; do wait "$rfd_pid"; rc=$?; done
    rfd_pid=""
    if (( stopping )); then
      echo "[rfd] beendet nach SIGTERM (rc=$rc)" >&2
      return 0
    fi
    dur=$(( $(date +%s) - start ))
    [[ $dur -ge 60 ]] && tries=0          # echter Lauf → Budget reset
    tries=$((tries+1))
    if [[ $tries -ge ${RFD_MAX_TRIES:-8} ]]; then
      echo "[rfd] gab nach $tries schnellen Fehlversuchen auf (letzter rc=$rc, lief ${dur}s)" >&2
      return "$rc"
    fi
    echo "[rfd] exited rc=$rc nach ${dur}s (Fehlversuch $tries/${RFD_MAX_TRIES:-8}) — multimacd evtl. noch nicht bereit (Identify leer?); retry in ${RFD_RETRY_DELAY:-1}s" >&2
    # sleep im Hintergrund + wait: bleibt für den TERM-trap unterbrechbar.
    sleep "${RFD_RETRY_DELAY:-1}" & wait $! 2>/dev/null
    (( stopping )) && return 0
  done
}
# Readiness-Gate vor rfd, drei Stufen:
#
# 1. Status-Datei (Ground-Truth OpenCCU S60multimacd waitStartupComplete):
#    /var/status/multimacd.status == PID von multimacd.  multimacd schreibt sie
#    erst nach komplettem Coprocessor-Init.  Kommt sie nicht, hängt multimacd
#    im Init — es hat danach weder Retry noch Exit, `wait -n` sähe also nie
#    etwas.  → Stack neu starten (bmcond -B setzt den Copro wieder in den BL).
#
# 2. BidCoS-Antwortprobe: die Status-Datei entsteht auch, wenn multimacd die
#    Copro-Version NICHT lesen konnte ("GetVersion finally failed").  Dann
#    beantwortet es rfds VersionRequest/GetSerialNumber nie, und rfd scheitert
#    mit "readSerialNumber failed".  Darum dieselbe Anfrage vorab stellen:
#    Legacy-System-Frame VersionRequest (dst 0x00, cnt 0, cmd 0x02); multimacd
#    antwortet lokal mit Status 0x02 (OkWithData) — nur mit bekannter Version.
#    Das Öffnen/Schließen des Slaves hat dieselben Nebenwirkungen wie
#    `head -c0` (Connect/Disconnect im multimacd-Subsystem) und passiert, bevor
#    rfd den Slave exklusiv öffnet.
#
# 3. HmIP-Slave öffenbar (head -c0, wie OpenCCU).  Fehler-Text wird geloggt,
#    damit ein EPERM/EBUSY/ENODEV nicht mehr unsichtbar bleibt.
MMD_INIT_MAX=${MMD_INIT_MAX:-30}
mmd_status_ok() { [[ "$(cat /var/status/multimacd.status 2>/dev/null)" == "$MMD_PID" ]]; }
mmd_bidcos_answers() (
  # `<>` öffnet mit O_CREAT — ohne diesen Check entstünde bei fehlendem Node
  # eine reguläre Datei /dev/mmd_bidcos, die den echten Node später blockiert.
  [[ -c /dev/mmd_bidcos ]] || { echo "/dev/mmd_bidcos ist kein char-device" >&2; exit 2; }
  exec 7<>/dev/mmd_bidcos || exit 2
  printf '\xfd\x00\x03\x00\x00\x02\x98\x0f' >&7
  # multimacd antwortet lokal (ms); die Schleife unten wiederholt bei Bedarf.
  hex=$(timeout 0.5 cat <&7 | od -An -tx1 -v | tr -d ' \n')
  [[ "$hex" =~ fd00[0-9a-f]{2}00000402 ]]
)

gate_start=$(date +%s)
while ! mmd_status_ok; do
  if ! kill -0 "$MMD_PID" 2>/dev/null; then
    # z.B. "No Coprocessor detected" oder Firmware ohne DualCoPro_App
    # (HMIP_TRX_App/Co_CPU_App → "Please install DualCoPro Firmware").
    wait "$MMD_PID" 2>/dev/null; mmd_rc=$?
    fatal_shutdown "multimacd (pid $MMD_PID) vor Init-Ende beendet, rc=$mmd_rc — Ursache in den [mmd    ]- und [bmcond ]-Zeilen oben"
  fi
  if (( $(date +%s) - gate_start >= MMD_INIT_MAX )); then
    fatal_shutdown "multimacd-Init nach ${MMD_INIT_MAX}s nicht abgeschlossen (/var/status/multimacd.status fehlt oder trägt nicht pid $MMD_PID) — Coprocessor-Handshake hängt"
  fi
  sleep 0.5
done
mmd_status_ok && echo "  rfd-gate 1/3: multimacd-Init komplett nach $(( $(date +%s) - gate_start ))s (status == pid $MMD_PID)"

gate_deadline=$(( $(date +%s) + ${RFD_GATE_MAX:-15} ))
probe_err=""
while :; do
  probe_err=$(mmd_bidcos_answers 2>&1) && break
  if (( $(date +%s) >= gate_deadline )); then
    fatal_shutdown "multimacd beantwortet keine BidCoS-Versionsanfrage auf /dev/mmd_bidcos (${RFD_GATE_MAX:-15}s)${probe_err:+ — $probe_err} — Copro-Version unbekannt, rfd würde an readSerialNumber scheitern"
  fi
  sleep 0.5
done
echo "  rfd-gate 2/3: /dev/mmd_bidcos beantwortet VersionRequest"

if $HAS_HMIP; then
  hmip_err=""
  while :; do
    hmip_err=$(timeout 1 head -c0 /dev/mmd_hmip 2>&1 >/dev/null) && break
    if (( $(date +%s) >= gate_deadline )); then
      echo "  WARN: /dev/mmd_hmip nicht öffenbar${hmip_err:+: $hmip_err} — HMIPServer wird scheitern" >&2
      break
    fi
    sleep 0.25
  done
  [[ -z "$hmip_err" ]] && echo "  rfd-gate 3/3: /dev/mmd_hmip öffenbar"
fi

# Ground-Truth (OpenCCU S61rfd): nur sinnvoll, wenn rfd.conf überhaupt einen
# [Interface N]-Block hat.  Fehlt er (bmconds confgen lieferte keine BidCoS-
# Interface, z.B. weil die Stick-Probe fehlschlug), findet rfd keine Hardware,
# exitet sauber, und verbrennt das volle RFD_MAX_TRIES-Budget mit irreführendem
# rc.  Advisory-WARN mit klarer Ursache (Start läuft trotzdem; der wait-n-Exit
# nennt am Ende den echten Grund) — wandelt einen langsamen, verwirrenden
# Fehlschlag in eine sofort diagnostizierbare Meldung.
if ! grep -qE '^\[Interface [0-9]+\]' /etc/config/rfd.conf 2>/dev/null; then
  echo "  WARN: /etc/config/rfd.conf hat keinen [Interface N]-Block — bmcond-confgen lieferte keine BidCoS-Interface (Stick-Probe fehlgeschlagen?); rfd findet keine Hardware" >&2
fi

echo "── Starting rfd (Identify-Race-Retry, max ${RFD_MAX_TRIES:-8}) ──"
rfd_supervised > >(stdbuf -oL sed 's/^/[rfd    ] /') 2>&1 &
track "rfd"
sleep 2 & wait $!   # trap-unterbrechbar (siehe restart_init)

# ── 3. HMIPServer ──
# HmIP-side eq-3-Java-Daemon.  Bei vorhandenem HM_HMIP_DEV nimmt debmatic
# `HMIPServer` (de.eq3.ccu.server.ip.HMIPServer) — listened auf :32010 für
# HmIP-XML-RPC.  Reines `HMServer` (BidCoS-only) listened auf :39292 und
# wäre falsch für unseren Pfad.
# Skip wenn HMIP_TRANSPORT leer/none — kein /tmp/mmd_hmip, kein Bedarf für
# HMIPServer.
if $HAS_HMIP; then
  echo "── Starting HMIPServer ──"
  JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(which java)")")")
  CLAZZPATH=$(find /opt/HMServer/ -type f -name "*.jar" \
    | grep -v "HM\(IP\)\?Server.jar" | xargs echo | tr ' ' ':')

  # RXTX (java-serial) blockiert auf stale /var/lock/LCK..mmd_hmip wenn der
  # vorherige HMIPServer nach SIGTERM den Lock nicht aufräumte (passiert
  # nach /api/reload-Cycle).  Lock vor Start sicher entfernen.
  rm -f /var/lock/LCK..mmd_hmip /var/lock/LCK..mmd_bidcos 2>/dev/null || true

  # crRFD.conf-Template bekommt den richtigen Adapter-Port substituiert
  # (immer /tmp/mmd_hmip — bmcond demuxt das Hardware-Backend hinter der PTY).
  mkdir -p /var/run /etc/config/crRFD/data /etc/config/firmware
  # Lan.Routing ist für eine reine lokale USB-TRX-Installation ohne
  # netzwerk-gekoppelte HmIP-HAPs sinnlos — und initialisiert hier nicht
  # ("Routing was enabled in configuration but cannot be initialized").
  # Bleibt es an, routet HMIPServer die Inclusion-RESPONSE über den (leeren)
  # LAN-Backbone statt über den lokalen TRX → "BackboneWorker: Access point
  # not found. Could not send frame" → Live-HmIP-Anlernen scheitert still.
  # Aus → Inclusion-Response geht über den lokalen Adapter (mmd_hmip).
  sed -e "s|^Adapter\.1\.Port=.*$|Adapter.1.Port=/tmp/mmd_hmip|" \
      -e "s|^Lan\.Routing\.Enabled=.*$|Lan.Routing.Enabled=false|" \
      /etc/crRFD.conf > /var/run/crRFD.conf

  # KEYSERVER_LOCAL (Offline-/Lab-Betrieb ohne eq-3-Cloud-Keyserver) braucht
  # einen Network.Key — sonst kann die lokale Inclusion-Key-Exchange-Antwort
  # nicht erzeugt werden (HMIPServer: "Missing or invalid key server
  # configuration parameter (Network.Key / Network.Key.Base) for mode:
  # KEYSERVER_LOCAL" → Gerät sendet KEY_EXCHANGE, bekommt aber keine Antwort).
  # 01020304...x4 ist der OCCU-/HmIP-Public-Beta-Konstant-Key für Offline-/
  # Test-Betrieb (siehe OCCU config_templates/hmip_networkkey.conf).
  HMIP_NETWORK_KEY="${BUSMATIC_HMIP_NETWORK_KEY:-01020304010203040102030401020304}"
  grep -q '^Network.Key=' /var/run/crRFD.conf || \
    echo "Network.Key=${HMIP_NETWORK_KEY}" >> /var/run/crRFD.conf
  # zusätzlich die OCCU-kanonische Datei (manche HMServer-Pfade lesen die):
  printf 'Network.Key=%s\n' "${HMIP_NETWORK_KEY}" > /etc/config/hmip_networkkey.conf

  # Ground-Truth (OpenCCU S62HMServer): erst prüfen, dass der HmIP-Serial-Node
  # ein Char-Device ist, BEVOR die 128-MB-JVM startet.  Fehlt /dev/mmd_hmip
  # (multimacd-HmIP-Slave nie erzeugt), würde java-rxtx auf einem nicht
  # existenten Serial-Port blockieren/spinnen — JVM hängt + frisst RAM für
  # nichts.  Dann HMIPServer sauber überspringen (BidCoS bleibt nutzbar;
  # Container NICHT runterfahren).
  if [[ -c /tmp/mmd_hmip || -c /dev/mmd_hmip ]]; then
    "$JAVA_HOME/bin/java" -Xmx128m \
      -Dlog4j.configurationFile=file:///etc/config/log4j2.xml \
      -Dfile.encoding=ISO-8859-1 \
      -Dgnu.io.rxtx.SerialPorts=/tmp/mmd_hmip \
      -cp "${CLAZZPATH}:/opt/HMServer/HMIPServer.jar" \
      de.eq3.ccu.server.ip.HMIPServer /var/run/crRFD.conf /etc/HMServer.conf \
        > >(stdbuf -oL sed 's/^/[hmsrv  ] /') 2>&1 &
    track "HMIPServer"
    sleep 3 & wait $!
  else
    echo "  ERROR: /dev/mmd_hmip ist kein Char-Device — HMIPServer übersprungen (multimacd-HmIP-Slave nicht erzeugt); BidCoS bleibt aktiv" >&2
  fi
else
  echo "── HMIPServer skipped (HMIP disabled) ──"
fi

# ── 4. rega_session_mock ──
# Bind 0.0.0.0 damit der Add-On-Port :8765 von außen erreichbar ist.
echo "── Starting rega_session_mock ──"
REGA_MOCK_BIND=0.0.0.0 \
REGA_MOCK_PORT=8765 \
REGA_MOCK_LOG_LEVEL="$REGA_MOCK_LOG" \
REGA_MOCK_UNKNOWN_STRATEGY=lenient \
REGA_MOCK_BMCD_URL=http://127.0.0.1:9126/api/status \
  /usr/bin/python3 -u /usr/local/bin/rega_session_mock.py \
    > >(stdbuf -oL sed 's/^/[regamck] /') 2>&1 &
track "rega_session_mock"
sleep 0.5

# ── 5. ping_shim — XML-RPC reverse-proxies mit ping-pong-Interception ──
# Hängt sich vor rfd:32001 (BidCoS) und HMIPServer:32010 (HmIP) und
# bedient die CCU-Style-ping-pong-Sequenz die aiohomematic für Keepalive
# braucht — rfd antwortet auf nacktes ping(caller_id) mit fault, was sonst
# alle ~30s die Entities auf "unavailable" flippt.
echo "── Starting ping_shim (BidCoS :2001 → rfd :32001) ──"
/usr/bin/python3 -u /usr/local/bin/ping_shim.py \
    --listen-port 2001 --upstream-port 32001 --name bidcos-shim \
  > >(stdbuf -oL sed 's/^/[pingshim] /') 2>&1 &
track "ping_shim-bidcos"
if $HAS_HMIP; then
  echo "── Starting ping_shim (HmIP :2010 → HMIPServer :32010) ──"
  /usr/bin/python3 -u /usr/local/bin/ping_shim.py \
      --listen-port 2010 --upstream-port 32010 --name hmip-shim \
    > >(stdbuf -oL sed 's/^/[pingshim] /') 2>&1 &
  track "ping_shim-hmip"
fi
sleep 0.5

# ── 6. lighttpd (foreground) ──
echo "── Starting lighttpd ──"
/usr/sbin/lighttpd -D -f /etc/lighttpd/lighttpd.conf \
  > >(stdbuf -oL sed 's/^/[lighttpd] /') 2>&1 &
track "lighttpd"

echo
echo "═════════════════════════════════════════════════════════════"
echo " BusMatic-HASS up"
echo "  :80    → lighttpd → rega_session_mock (/api/homematic.cgi)"
echo "  :8765  → rega_session_mock direct"
echo "  :2001  → ping_shim → rfd (BidCoS XML-RPC + ping-pong)"
if $HAS_HMIP; then
  echo "  :2010  → ping_shim → HMServer (HmIP XML-RPC + ping-pong)"
else
  echo "  :2010  → (disabled — HMIP not configured)"
fi
echo "  :9126  → bmcond JSON-API (status/health, internal)"
echo "═════════════════════════════════════════════════════════════"

DIED=""
wait -n -p DIED "${PIDS[@]}"
RC=$?

# Wenn bmcond's POST /api/reload das Container-Init-Re-Exec angefordert
# hat, hat es vor seinem SIGTERM den Marker /var/run/bmcd-reload-requested
# geschrieben.  In dem Fall: alle anderen Kinder kontrolliert beenden und
# uns selbst re-execen.  HA-Supervisor sieht keinen Container-Exit
# (Process bleibt am Leben), pollt weiter, alles smooth.  Bei jedem
# anderen Child-Exit: geordneter Stop + Container-Exit mit rc≠0
# (failure_exit) — Docker-Restart-Policy bzw. HA-Watchdog starten neu.
if [[ -f /var/run/bmcd-reload-requested ]]; then
  rm -f /var/run/bmcd-reload-requested
  restart_init "/api/reload self-restart requested"
fi

# DIED (von wait -n -p) = die echte Service-PID; leer nur im Edge-Case.
# Index NUR bei nicht-leerem DIED (leerer Array-Index = bash-Fehler).
DIED_NAME="pid ${DIED:-?}"
[[ -n "$DIED" ]] && DIED_NAME="${SVC_NAME[$DIED]:-pid $DIED}"
echo "── A child exited: '$DIED_NAME' (pid ${DIED:-?}) exited rc=$RC ──"
echo "──   rc = ECHTER Service-Exit-Code (vorher war's immer der sed-Wrapper = 0).   ──"
echo "──   Ursache: die Logzeilen dieses Services weiter oben.                       ──"
failure_exit "$RC"
