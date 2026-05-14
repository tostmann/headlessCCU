#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# BusMatic-HASS init — startet busmatic-concentrator + rfd + HMServer +
# rega_session_mock + lighttpd. PID-1; routet alle Logs auf stdout.
#
# Lizenz: GPL-2.0-or-later

set -uo pipefail

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
shutdown_handler() {
  echo "── Shutdown ──"
  for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
  sleep 1
  for p in "${PIDS[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
  exit 0
}
trap shutdown_handler TERM INT

# ── 1. busmatic-concentrator (= bmcond) ──
# bmcond 2026.5.7+ ist pure userspace radio-transport: byte-pump zwischen
# einem Transport-fd (USB-libusb / UART / TCP / UDP) und einem PTY-master.
# Multimacd öffnet den PTY-symlink (/tmp/raw-uart-shim) als seine
# "Coprocessor Device" und macht den vollen Mac-Layer (DUTY/CSMA/AES/
# LLMAC-Translation/3burst-Retry/Demux nach /dev/mmd_{bidcos,hmip}).
echo "── Starting busmatic-concentrator (transport-shim für multimacd) ──"
CONC_ARGS=(
  "$TRANSPORT_FLAG" "$TRANSPORT_VAL"
  --raw-uart "/tmp/raw-uart-shim"
  -v
)
echo "  args: ${CONC_ARGS[*]}"
/usr/local/bin/busmatic-concentrator "${CONC_ARGS[@]}" 2>&1 \
  | stdbuf -oL sed 's/^/[bmcond ] /' &
PIDS+=($!)

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

# Auf bmcond's PTY-Symlink warten (max 15s).  Multimacd erzeugt
# /dev/mmd_{bidcos,hmip} erst NACHDEM es seine Coprocessor-Verbindung
# über /tmp/raw-uart-shim aufgebaut hat.
for i in $(seq 1 30); do
  [[ -e /tmp/raw-uart-shim ]] && break
  sleep 0.5
done
if ! [[ -e /tmp/raw-uart-shim ]]; then
  echo "WARN: /tmp/raw-uart-shim did not appear within 15s" >&2
fi

# ── 1b. multimacd ──
# Spec aus /usr/share/debmatic/bin/start_multimacd.sh nachgebaut weil das
# Original-Wrapper multimacd daemonized und unsere wait-n-Loop dadurch
# ein falsches child-exit-Signal sieht.  Hier: multimacd FOREGROUND.
#
# Container-Permissions die wir brauchen:
#   - CAP_MKNOD (default in docker, in HAOS-Add-On via full_access)
#   - CAP_SYS_MODULE (modprobe — falls Host eq3_char_loop nicht vor-geladen hat)
#   - sysfs lesbar (default /sys ist read-only-mount aber lesbar)
echo "── Starting multimacd ──"

# eq3_char_loop laden falls Host das nicht schon gemacht hat.  Modul ist
# GPLv2 und Teil des piVCCU-modules-dkms-Pakets.
modprobe -q eq3_char_loop 2>/dev/null || {
  echo "WARN: modprobe eq3_char_loop fehlgeschlagen — "
  echo "      braucht CAP_SYS_MODULE im Container ODER vor-geladenes Host-Modul" >&2
}

# /dev/eq3loop mknod-Fallback (siehe start_multimacd.sh).
if [[ ! -e /dev/eq3loop && -e /sys/devices/virtual/eq3loop/eq3loop/dev ]]; then
  mknod /dev/eq3loop c $(cat /sys/devices/virtual/eq3loop/eq3loop/dev | tr ':' ' ') || {
    echo "WARN: mknod /dev/eq3loop failed — braucht CAP_MKNOD" >&2
  }
fi
if [[ ! -c /dev/eq3loop ]]; then
  echo "ERROR: /dev/eq3loop fehlt und konnte nicht erzeugt werden — multimacd kann nicht starten" >&2
  exit 1
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
/bin/multimacd -f /var/run/multimacd.conf -l "$RFD_LOGLEVEL" -c 2>&1 \
  | stdbuf -oL sed 's/^/[mmd    ] /' &
PIDS+=($!)

# Warten bis /sys/devices/virtual/eq3loop/mmd_*/dev erscheint (multimacd
# registriert die Slave-Devices nach erstem erfolgreichem Coprocessor-
# Identify, ca. 3-5s).  In Containern ohne udev werden die /dev/-Nodes
# NICHT automatisch erzeugt — wir mknod-fallback'n nach Spec von eq-3's
# start_multimacd.sh.
echo "── Waiting for eq3loop slave-devices ──"
for dev in mmd_bidcos mmd_hmip; do
  if [[ "$dev" = "mmd_hmip" ]] && ! $HAS_HMIP; then continue; fi
  for i in $(seq 1 30); do
    if [[ -e /sys/devices/virtual/eq3loop/$dev/dev ]]; then
      if [[ ! -e /dev/$dev ]]; then
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

# bmcond's PTY-Symlink existiert; multimacd hat /dev/mmd_* erzeugt — Stack
# ist bereit für rfd+HMIPServer.  Multimacd erledigt die HW-Identifikation
# selbst (Boot-Probe + CHANGE_APP); /dev/mmd_bidcos existiert nur wenn das
# durchgegangen ist.

# ── 2. rfd ──
# debmatic-apt installiert nach /bin/rfd mit libs unter /usr/share/debmatic/lib.
echo "── Starting rfd ──"
LD_LIBRARY_PATH=/usr/share/debmatic/lib \
  /bin/rfd -c -l "$RFD_LOGLEVEL" \
    -f /etc/config/rfd.conf 2>&1 \
    | stdbuf -oL sed 's/^/[rfd    ] /' &
PIDS+=($!)
sleep 2

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
  sed "s|^Adapter\.1\.Port=.*$|Adapter.1.Port=/tmp/mmd_hmip|" /etc/crRFD.conf \
    > /var/run/crRFD.conf

  "$JAVA_HOME/bin/java" -Xmx128m \
    -Dlog4j.configurationFile=file:///etc/config/log4j2.xml \
    -Dfile.encoding=ISO-8859-1 \
    -Dgnu.io.rxtx.SerialPorts=/tmp/mmd_hmip \
    -cp "${CLAZZPATH}:/opt/HMServer/HMIPServer.jar" \
    de.eq3.ccu.server.ip.HMIPServer /var/run/crRFD.conf /etc/HMServer.conf 2>&1 \
      | stdbuf -oL sed 's/^/[hmsrv  ] /' &
  PIDS+=($!)
  sleep 3
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
  /usr/bin/python3 -u /usr/local/bin/rega_session_mock.py 2>&1 \
    | stdbuf -oL sed 's/^/[regamck] /' &
PIDS+=($!)
sleep 0.5

# ── 5. ping_shim — XML-RPC reverse-proxies mit ping-pong-Interception ──
# Hängt sich vor rfd:32001 (BidCoS) und HMIPServer:32010 (HmIP) und
# bedient die CCU-Style-ping-pong-Sequenz die aiohomematic für Keepalive
# braucht — rfd antwortet auf nacktes ping(caller_id) mit fault, was sonst
# alle ~30s die Entities auf "unavailable" flippt.
echo "── Starting ping_shim (BidCoS :2001 → rfd :32001) ──"
/usr/bin/python3 -u /usr/local/bin/ping_shim.py \
    --listen-port 2001 --upstream-port 32001 --name bidcos-shim 2>&1 \
  | stdbuf -oL sed 's/^/[pingshim] /' &
PIDS+=($!)
if $HAS_HMIP; then
  echo "── Starting ping_shim (HmIP :2010 → HMIPServer :32010) ──"
  /usr/bin/python3 -u /usr/local/bin/ping_shim.py \
      --listen-port 2010 --upstream-port 32010 --name hmip-shim 2>&1 \
    | stdbuf -oL sed 's/^/[pingshim] /' &
  PIDS+=($!)
fi
sleep 0.5

# ── 6. lighttpd (foreground) ──
echo "── Starting lighttpd ──"
/usr/sbin/lighttpd -D -f /etc/lighttpd/lighttpd.conf 2>&1 \
  | stdbuf -oL sed 's/^/[lighttpd] /' &
PIDS+=($!)

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

wait -n "${PIDS[@]}"
RC=$?

# Wenn bmcond's POST /api/reload das Container-Init-Re-Exec angefordert
# hat, hat es vor seinem SIGTERM den Marker /var/run/bmcd-reload-requested
# geschrieben.  In dem Fall: alle anderen Kinder kontrolliert beenden und
# uns selbst re-execen.  HA-Supervisor sieht keinen Container-Exit
# (Process bleibt am Leben), pollt weiter, alles smooth.  Bei jedem
# anderen Child-Exit: klassischer Shutdown (RC ≠ 0 ist hier ok — HA
# kann's dann als Crash behandeln + watchdog kicken).
if [[ -f /var/run/bmcd-reload-requested ]]; then
  echo "── /api/reload self-restart requested ──"
  rm -f /var/run/bmcd-reload-requested
  # Wenn unter HA-Supervisor mit hassio_api: true → SUPERVISOR_TOKEN ist
  # gesetzt → sauberer Container-Restart über Supervisor-API (frisches
  # Network-Namespace, alle Listen-Sockets sauber released).
  # Sonst (Standalone-Docker oder kein API-Token): in-container re-exec
  # mit pkill-P-1-Pfad (best-effort).
  if [[ -n "${SUPERVISOR_TOKEN:-}" ]]; then
    echo "── Asking Supervisor to restart this add-on ──"
    curl -m 5 -s -X POST \
      -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
      http://supervisor/addons/self/restart > /dev/null || true
    # Supervisor schickt SIGTERM an Container — wir warten passiv
    # (max 60s; danach würde Supervisor SIGKILL nachschießen)
    sleep 60
    # falls Supervisor's stop nicht durchkam, fallback: aufgeben
    echo "── Supervisor restart did not arrive within 60s — falling through ──"
  fi
  # Fallback / Standalone-Pfad
  echo "── Fallback: in-container re-exec ──"
  pkill -TERM -P 1 2>/dev/null || true
  sleep 2
  pkill -KILL -P 1 2>/dev/null || true
  sleep 1
  exec "$0" "$@"
fi

echo "── A child exited unexpectedly (rc=$RC) ──"
shutdown_handler
