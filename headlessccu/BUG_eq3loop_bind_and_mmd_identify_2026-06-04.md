# headlessCCU — Container kommt nach Funkmodul-Power-Cycle nicht mehr hoch (2026-06-04)

**Reporter:** Diagnose extern (busware-rule-engine BidCoS-Capture-Session), während die
headlessCCU als BidCoS/HmIP-Oracle benutzt wurde. Read-only Root-Cause + Host-seitige
Recovery durchgeführt; **Image/Recipe selbst NICHT geändert** (das ist eure Entscheidung).

## TL;DR

Der `headlessccu-smoke`-Container (Image `headlessccu:2026.6.1`) lief ~18 h sauber
(rfd `:2001` = 65 BidCoS-Einträge, HmServer `:2010` = 62 HmIP-Geräte). Nach einem
USB-I/O-Sturm des RFUSB (`SET_FLOW failed`, `transport read returned 0 (EOF)`,
Duty-Cycle-Timeouts) + einem **USB-Power-Cycle** des Funkmoduls kommt der Container
bei **jedem** `docker start/restart` **deterministisch** nicht mehr hoch. Zwei
unabhängige Bugs:

1. **PRIMARY (host-side, gefixt durch Recovery):** der `/dev/eq3loop`-**Bind-Mount**
   führt nach Verschwinden des Host-Char-Nodes zu einem von Docker auto-angelegten
   **leeren Verzeichnis**, das den init-`mknod`-Fallback aushebelt → `exit 1` → Shutdown.
2. **SECONDARY (Rig-Bug, blockiert weiterhin):** multimacds `COMMON_IDENTIFY` bekommt
   über den bmcond-Shim die **SGTIN** statt des App-Namens `DualCoPro_App` zurück →
   `readSerialNumber` scheitert → `No Coprocessor detected` → rfd exit → Shutdown.

Nach der Recovery ist Bug 1 weg (`/dev/mmd_bidcos ready`), Bug 2 blockiert weiterhin —
**die CCU ist noch nicht voll oben.** Bug 2 braucht einen Fix im bmcond/multimacd-Shim.

---

## Bug 1 (PRIMARY): `/dev/eq3loop`-Bind → Docker-Verzeichnis-Shadow

### Mechanismus
- Das `eq3_char_loop`-Modul hat **keinen persistenten /dev-Node auf dem Host** — es
  existiert nur in sysfs (`/proc/devices`: `509 eq3loop`,
  `/sys/devices/virtual/eq3loop/eq3loop/dev` = `509:0`). Kein udev-Regel/devtmpfs-Node.
- Der **laufende** Container wurde mit einem `-v /dev/eq3loop:/dev/eq3loop` **Bind**
  gestartet (so steht es in `docker inspect … HostConfig.Binds`). **`docker-compose.yml:78`
  listet `/dev/eq3loop` zwar korrekt unter `devices:`** — aber der real laufende Container
  benutzte einen `-v`-Bind. **Das ist der Bug:** bei einem Bind, dessen Quelle **fehlt**,
  legt Docker die Quelle **stillschweigend als leeres Verzeichnis** an.
- Nach dem USB-Power-Cycle war der Host-Char-Node `/dev/eq3loop` weg → der nächste
  `docker start` ließ Docker dort ein **Verzeichnis** anlegen (verifiziert:
  `stat /dev/eq3loop` → `directory`, Birth == StartedAt des Fehl-Starts). Das Verzeichnis
  **shadowed** den Namen ab da permanent über alle weiteren Starts.

### Warum der init-Fallback versagt — `run.sh:279` / `:284`
```sh
# run.sh:279
if [[ ! -e /dev/eq3loop && -e /sys/devices/virtual/eq3loop/eq3loop/dev ]]; then
  mknod /dev/eq3loop c $(cat …/dev | tr ':' ' ') || { echo "WARN…"; }
fi
# run.sh:284
if [[ ! -c /dev/eq3loop ]]; then
  echo "ERROR: /dev/eq3loop fehlt und konnte nicht erzeugt werden — multimacd kann nicht starten"
  exit 1
fi
```
Das Shadow-Verzeichnis lässt `/dev/eq3loop` **existieren** → `! -e` ist FALSE → der
`mknod` wird **übersprungen** → der `! -c`-Check trifft (ein Verzeichnis ist kein
char-dev) → `exit 1` **bevor multimacd startet** → der PID-1-Supervisor (`wait -n`)
sieht den Child-Exit → ganzer Container Shutdown. Exaktes Log:
```
ERROR: /dev/eq3loop fehlt und konnte nicht erzeugt werden — multimacd kann nicht starten
── A child exited unexpectedly (rc=0) ── Shutdown ──
```

### Warum der erste Start lief, Restarts nicht
18 h zuvor war `/dev/eq3loop` der echte 509:0-char-Node; der Bind reichte ihn sauber
durch. Nach USB-Churn/Power-Cycle war er weg → Docker-Bind-Autocreate machte ein
Verzeichnis daraus, das jeden weiteren Start abschießt. (Die ursprünglich naheliegende
„stale /tmp-Shim / tote /dev/pts-PTY"-Theorie ist **widerlegt** — bmcond baut PTY +
`/tmp/raw-uart-shim` jeden Start frisch und erreicht jedes Mal `DualCoPro_App`.)

### Empfohlener Fix (Image/Recipe — eure Entscheidung)
1. **`/dev/eq3loop` NICHT in den Container reichen** — weder als `-v`-Bind noch als
   `devices:`. Das init (`run.sh:279-287`) **mknod't es ohnehin selbst** aus sysfs
   (hat `CAP_MKNOD` + `device_cgroup_rules: c 509:* rwm`, beide vorhanden). Ohne die
   Quelle ist `! -e /dev/eq3loop` in einem frischen Container TRUE → echtes char-dev
   jeden Start, **kein host-seitiger Faul-State**. Der `devices: - /dev/eq3loop` in
   `docker-compose.yml:78` ist ebenfalls fragil (`--device` schlägt fehl, wenn der
   Host-Node nach einem Modul-Event fehlt) → **streichen**, auf das in-container-mknod
   verlassen. (Der `device_cgroup_rules: c 509:* rwm` MUSS bleiben — er erlaubt das
   open() der selbst-mknod'eten Nodes.)
2. **Guard härten (`run.sh:279` + `:284`):** auf `! -c` statt `! -e` testen und einen
   Fremd-Placeholder (Verzeichnis/Datei) vorher wegräumen, damit der Start auch dann
   self-healt, wenn doch mal ein Bind ein Verzeichnis hinterlässt:
   ```sh
   # Fremd-Placeholder (z.B. Docker-Bind-Autocreate) wegräumen — NIE ein echtes char-dev:
   if [[ -e /dev/eq3loop && ! -c /dev/eq3loop ]]; then
     rmdir /dev/eq3loop 2>/dev/null || rm -f /dev/eq3loop
   fi
   if [[ ! -c /dev/eq3loop && -e /sys/devices/virtual/eq3loop/eq3loop/dev ]]; then
     mknod /dev/eq3loop c $(cat /sys/devices/virtual/eq3loop/eq3loop/dev | tr ':' ' ') \
       || echo "WARN: mknod /dev/eq3loop failed — CAP_MKNOD?" >&2
   fi
   ```
   Dieselbe `! -c`-statt-`! -e`-Disziplin auch auf die `mmd_*`-Slave-mknod-Schleife
   (`run.sh:317-319`) anwenden.

---

## Bug 2 (SECONDARY): mmd `COMMON_IDENTIFY` bekommt SGTIN statt `DualCoPro_App`

### Belegt (am sauber re-enumerierten Funkmodul, nicht am verwundeten)
Nachdem Bug 1 behoben war (`/dev/mmd_bidcos ready after 1s`), scheiterte rfd weiterhin.
bmconds **eigene** Identify-Probe ist OK, aber multimacds Identify über den Shim bekommt
die falsche Antwort:
```
[bmcond] RADIO[dualcopro]: Modul ist in 'DualCoPro_App'        ← bmcond-Probe OK
[bmcond] shim: tx 8:  fd 00 03 fe 00 01 14 1e                  ← mmd COMMON_IDENTIFY (dst=FE op=01)
[bmcond] shim: rx 21: fd 00 10 fe 00 05 01 <SGTIN-12B> 45 5e   ← Antwort = SGTIN, NICHT ASCII "DualCoPro_App" (44 75 61 6c…)
        /dev/mmd_bidcos ready after 1s
[bmcond] shim: tx 8:  fd 00 03 00 01 00 9e 03  →  rx fd 00 02 ff 01 82 05   ← NACK (src=FF)
[rfd] CCU2CommController::readSerialNumber(): Could not read serial number from coprocessor.
[mmd] No Coprocessor detected!!!
```
Zum Vergleich der **funktionierende** Run (2026-06-03): auf dasselbe `fd 00 03 fe 00 01 …`
kam `fd 00 11 fe 00 05 01 44 75 61 6c 43 6f 50 72 6f 5f 41 70 70 …` = ASCII
`DualCoPro_App`, dann lief die Kette weiter (getVersion, SGTIN, HMID, **Serial**) und rfd
kam hoch.

### Einschätzung
Das ist **kein** verwundetes Radio (bmcond-Probe holt im selben Start `DualCoPro_App`) und
**kein** eq3loop-Problem. Es ist die **Identify-Behandlung im bmcond-Shim / multimacd-Pfad**:
vermutlich konsumiert bmconds eigene Identify-Probe das App-Namen-Frame, und mmds
nachfolgendes `COMMON_IDENTIFY` bekommt das **nächste** Frame der Identify-Sequenz (die
SGTIN) — oder der Shim proxied mmds Identify nicht sauber zum Copro. Der Kommentar in
`docker-compose.yml:84` flaggt bereits ein verwandtes Symptom:
`"Identify response string not handled: " (leer) → rfd crash → container-loop`.
Genau diese Identify-Fragilität ist hier die Wurzel.

### Was zu prüfen ist (CUL32-HM/bmcond-Domäne)
- Soll bmconds eigene Boot-Probe das Copro-`COMMON_IDENTIFY`-Response-Frame **verbrauchen**,
  oder muss es für mmds anschließendes Identify **erhalten/replay-bar** bleiben?
- Liefert der Copro auf `COMMON_IDENTIFY` eine **Mehr-Frame-Sequenz** (App-Name, SGTIN, …),
  bei der ein Frame-Pointer pro Sender weiterläuft? Dann braucht der Shim eine
  Per-Client-Identify-Antwort statt eines geteilten Streams.
- **Möglicher Workaround**, bis der Shim-Bug gefixt ist: rfds Coprocessor-**Serial im
  rfd-Config überschreiben** (die rfd-Fehlermeldung sagt explizit „… is not set/'overridden'
  in rfd config file") — dann braucht rfd den Identify-Serial-Read nicht. `BUSMATIC_SERIAL`
  (compose:99) scheint nicht auf den rfd-BidCoS-Serial-Override gemappt zu sein.

---

## Was ich host-seitig zur Recovery getan habe (reversibel, kein /data-Touch)
1. `rmdir /dev/eq3loop` — das leere Docker-Shadow-Verzeichnis entfernt (self-guarding;
   `rmdir` löscht nie non-empty/char-dev; **kein** `rm -rf` auf diesem Pfad).
2. `modprobe eq3_char_loop` (war nach meinem versehentlichen `rmmod` kurz entladen — wieder
   geladen). Das Modul legt host-seitig **keinen** /dev-Node an.
3. `mknod /dev/eq3loop c 509 0` — den echten Char-Node host-seitig wiederhergestellt
   (Major 509 aus `/proc/devices` + sysfs verifiziert).
4. `docker start headlessccu-smoke` → **Bug 1 weg** (`/dev/mmd_bidcos ready`, kein
   `eq3loop fehlt`), **Bug 2 blockiert** weiterhin (siehe oben).

`/data` (Host-Bind `./data` → 62 HmIP + 65 BidCoS State, `etc-config/ids` etc.) wurde
**nicht** angefasst und ist intakt. `BUSMATIC_HMID=auto` liest die HMID weiter aus `/data`.

## Status / offene Punkte
- **Bug 1:** durch Host-Recovery behoben; durabler Fix = Recipe (Bind/devices streichen) +
  Guard-Härtung wie oben. Bis dahin überlebt der Char-Node nur, bis das nächste Modul-/
  USB-Event ihn wieder entfernt → **fragil**.
- **Bug 2:** **offen**, blockiert das Hochkommen. Braucht einen bmcond/multimacd-Shim-Fix
  (Identify-Routing) oder den rfd-Serial-Override-Workaround. Ggf. einen **vollen
  Unplug/Replug** des RFUSB testen — aber da bmconds Probe sauber `DualCoPro_App` holt,
  ist ein Hardware-Reset wahrscheinlich nicht die Wurzel.

---

## ✅ RESOLUTION (2026-06-04, headlessCCU-Maintainer-Seite)

Beide Bugs gefixt + e2e verifiziert am echten HmIP-RFUSB (`1b1f:c020`, frisch
replugt auf Bus-001-Direktport).

### Bug 2 — Root-Cause korrigiert: KEIN Shim-Routing-Bug, sondern Copro-State

Der `COMMON_IDENTIFY`-Response ist **zustandsabhängig** (Copro-Firmware, kein
Shim-Defekt):
- Bootloader → `05 01 'HMIP_TRX_Bl'`
- direkt nach CHANGE_APP → COMMON-Push `00 'DualCoPro_App'`
- **eingeschwungener App-Mode → `05 01 <SGTIN>`** (die 12 SGTIN-Bytes statt ASCII)

multimacd treibt seinen **eigenen** Boot-Handshake und erwartet das Modul im
**Bootloader** (siehe `captures/multimacd_hmip_rfusb_*/ANALYSIS.md`: echtes
eq-3-multimacd via `hb_rf_usb_2`-Kernel-Treiber sieht `HMIP_TRX_Bl`, macht dann
selbst CHANGE_APP). Steht das Modul beim multimacd-Connect schon eingeschwungen
im App-Mode (was es über bmcond-Restarts/Power-Cycles bleibt — der USB-Open
resettet es nicht zuverlässig auf BL), bekommt multimacds Identify die SGTIN →
kein App-Tag → „No Coprocessor / Signal 10" → rfd-readSerial-Fail → Shutdown.
Die „bmcond-Probe konsumiert das App-Namen-Frame"-Hypothese wurde **widerlegt**:
ohne `-C` (also ohne bmcond-Probe; `hw_identify` sendet keine UART-Frames)
scheitert es identisch. Auch USB-Resets (`bConfigurationValue`, `usbreset`)
heilen es nicht.

**Fix:** `-B` (force-BL vor multimacd-Handoff) in `run.sh` CONC_ARGS. bmcond
zwingt den EFM nach confgen via `copro_start_bootloader` in den Bootloader +
drained Residual-Frames → multimacd sieht `HMIP_TRX_Bl` und treibt CHANGE_APP
selbst (genau wie der Kernel-Treiber via IOCRESET). `-C` läuft VOR `force_bl`
(`concentrator.c` main: confgen @747, force_bl @848) → rfd.conf/InterfacesList-
Output bleibt erhalten. Der rfd-Serial-Override-Workaround ist damit **nicht**
nötig (multimacd bringt den BidCoS-Coprozessor sauber hoch).

**Verifiziert e2e:** `forced BL → HMIP_TRX_Bl` → multimacd CHANGE_APP →
`DualCoPro_App`-Push → SGTIN/HMID `FFD6B4`/Serial `XEQ0194564` gelesen → rfd
**ohne** readSerial-Fehler hoch, BidCoS-Interface `CONNECTED` (`:2001
listBidcosInterfaces`), HMIPServer `:32010` hoch. **livetest HmIP 3/3 PASS.**
**Restart-resilient:** Start + 2× `docker restart` → jedes Mal sauber hoch
(vorher deterministischer Crash bei jedem Restart). (BidCoS-livetest = „Unknown
instance" weil in dieser `/data` aktuell **kein** BidCoS-Aktor gepaired ist —
nur `BidCoS-RF.dev`/Gateway. Pairing-State-Thema, kein Stack-/Coprozessor-Defekt.)

### Bug 1 — gefixt (Guard-Härtung + Recipe)

- `run.sh`: eq3loop-Guard testet jetzt `! -c` statt `! -e` und räumt einen
  Fremd-Placeholder (Docker-Bind-Autocreate-Verzeichnis/Datei) per `rmdir`/`rm -f`
  weg, bevor `mknod` läuft (fasst nie ein echtes char-dev an). Gleiche Disziplin
  auf die `mmd_*`-Slave-Schleife.
- `docker-compose.yml`: `/dev/eq3loop` aus `devices:` **gestrichen** — wird
  in-container per mknod aus sysfs erzeugt (CAP_MKNOD + `device_cgroup_rules
  'c 509:* rwm'` bleiben). Kein fragiles Host-Node-Durchreichen mehr.

### Geänderte Dateien
- `headlessCCU/headlessccu/run.sh` (CONC_ARGS `-B`; eq3loop+mmd_* Guards)
- `headlessCCU/headlessccu/docker-compose.yml` (`/dev/eq3loop` aus `devices:`)

### Offen / nächste Schritte (Maintainer-Entscheidung)
- Kanonischer Image-Rebuild (`build.sh`, bmcond 2026.6.1 unverändert, neue
  run.sh) + Versions-Bump + Git-Commit/Tag nach Release-Policy.
- Optional: BidCoS-Aktor (re-)pairen, dann BidCoS-livetest 3/3.
