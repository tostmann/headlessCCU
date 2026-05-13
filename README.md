# headlessCCU

HomeMatic CCU **without the WebUI / ReGaHss**.  Bundles
[bmcond](https://github.com/tostmann/bmcond) + eQ-3's `rfd` +
`HMIPServer.jar` + a JSON-RPC stub for `aiohomematic` in a single
container.

This repository follows the Home Assistant **Add-On Repository**
layout: `repository.yaml` at the root, and the actual add-on under
`headlessccu/`.  Both the HA-Supervisor "Add Repository" UI and a
plain `docker compose` from the subdirectory work out of the box.

Two distribution paths from the same image:

- **Home Assistant Add-On** (HA Supervisor / HAOS) — install via the
  Add-On store, configure via UI, [`homematicip_local`](https://github.com/SukramJ/homematicip_local)
  connects to it locally.
- **Plain Docker / docker-compose** — on any host with Docker and an
  HmIP-RFUSB stick plugged in.  Speaks XML-RPC on `:2001` (BidCoS) and
  `:2010` (HmIP) plus JSON-RPC on `:8765`, so any consumer (Home
  Assistant `homematicip_local`, ioBroker, Homegear, NodeRED, custom
  scripts) just connects.

## Why not the regular CCU?

The eQ-3 CCU stack pulls in ReGaHss (Tcl logic engine), HMServer.jar,
WebUI, eshlight, and a few hundred MB of Tcl/web assets — none of which
are needed when Home Assistant is your automation engine.  headlessCCU
strips the stack down to just the parts that actually move RF frames:

```
┌─────────────────────────────────────────────────────────────┐
│ Home Assistant (or any XML-RPC consumer)                    │
└──┬──────────────────────────────────────────────────────────┘
   │ XML-RPC :2001 (BidCoS), :2010 (HmIP), JSON-RPC :80 / :8765
┌──▼──────────────────────────────────────────────────────────┐
│ headlessCCU container                                       │
│  ┌────────────┐  ┌────────────┐  ┌─────────────────────┐    │
│  │ rfd        │  │ HMIPServer │  │ rega_session_mock   │    │
│  │ (BidCoS)   │  │ (HmIP)     │  │ (aiohomematic stub) │    │
│  └─────┬──────┘  └──────┬─────┘  └─────────────────────┘    │
│  /dev/mmd_bidcos    /dev/mmd_hmip    ↑ JSON-RPC :8765       │
│        ▲                  ▲           (Session.login etc.)  │
│        └─────────┬────────┘                                 │
│             multimacd                                       │
│        (eq-3 Mac-Layer: DUTY, CSMA, AES, demux)             │
│                  │                                          │
│             /dev/raw-uart (PTY)                             │
│                  │                                          │
│               bmcond                                        │
│        (userspace transport — libusb / UDP / TCP / UART)    │
└────────────┬───────────────────────────────────────────────┘
             │ libusb-direct  /dev/bus/usb
       ┌─────▼─────┐
       │ HmIP-RFUSB │
       └────────────┘
```

`bmcond` claims `/dev/bus/usb`, detaches whatever kernel driver had
bound the stick, and exposes the radio's wire bytes as a PTY symlink.
`multimacd` opens that PTY as its `Coprocessor Device Path` and
handles all Mac-Layer concerns (DUTY-cycle, CSMA, AES, retransmits,
LLMAC ↔ APP translation, BidCoS / HmIP demuxing).  No
`/dev/ttyUSB0`, no udev rule, no `cp210x` module blacklist needed for
the default path.  An HA-side `rega_session_mock` answers the
JSON-RPC calls `aiohomematic` issues during setup — no ReGaHss
running on the container side.

## Quick install — Home Assistant Add-On (HAOS)

This is the recommended path on HAOS / Home Assistant Supervisor.

**Step 1 — Add this repository to the Add-On store.**

1. Settings → Add-ons → Add-on Store
2. Click the three-dots menu (top right) → **Repositories**
3. Paste `https://github.com/tostmann/headlessCCU` → **Add**, then close

**Step 2 — Install the add-on.**

1. The repository panel now appears at the bottom of the Add-on Store.
   Click **headlessCCU**.
2. Click **Install**.  HA Supervisor builds the image locally; this
   takes ~5 minutes on a Raspberry Pi 5 because eQ-3 binaries are
   fetched at build time from `apt.debmatic.de` (no eQ-3 closed-source
   blobs are vendored into this repository).
3. Once installed, plug in your **eQ-3 HmIP-RFUSB** stick if it isn't
   already (USB-ID `1b1f:c020`).

**Step 3 — Defaults work out of the box.**

The default `hmid: "auto"` makes the add-on roll a random 3-byte
gateway address on first start and persist it.  Default transport
`usb=1b1f:c020` opens the HmIP-RFUSB via libusb directly.  No
configuration is required for a single-stick setup.

If you have more than one CCU-like instance in the same LAN, or you
want to migrate pairings from an existing eQ-3 / debmatic install, set
the `hmid` option to a fixed 6-hex value.

**Step 4 — Start the add-on.**

1. Toggle **Start on boot** and **Watchdog** on.
2. Press **Start**.
3. Open **Log**.  You should see a banner with the firmware bundle
   version, an `eQ-3 HmIP-RFUSB` backend coming up via libusb, and
   `── BusMatic-HASS up ──` after ~30 s.
4. Open **headlessCCU** in the HA sidebar (Ingress panel) — the bmcond
   web UI shows the source inventory and slot mapping.

**Step 5 — Connect Home Assistant.**

Install the `homematicip_local` custom integration (e.g. via HACS).
Then **Settings → Devices & Services → Add Integration → HomematicIP
Local**:

| Field | Value |
| --- | --- |
| Instance name | `headlessccu` (or whatever) |
| Host | `172.30.32.1` (the HA Supervisor bridge gateway) |
| Username / Password | anything — the mock accepts any credentials |
| `custom_port_config` | leave off — defaults work |

The integration auto-detects both `BidCos-RF` and `HmIP-RF` interfaces.
Confirm the device list (initially empty) and finish setup.

**Step 6 — Pair your first device.**

In Home Assistant, **Settings → Devices & Services → HomematicIP Local
→ … (kebab) → Reload** to make the integration register interfaces.

To put the gateway into pair mode:

```bash
# in any host with access to the HA host:
curl -X POST http://172.30.32.1:2001/ \
  -d '<?xml version="1.0"?><methodCall><methodName>setInstallMode</methodName><params><param><value><boolean>1</boolean></value></param><param><value><i4>60</i4></value></param></params></methodCall>'

curl -X POST http://172.30.32.1:2010/ \
  -d '<?xml version="1.0"?><methodCall><methodName>setInstallMode</methodName><params><param><value><boolean>1</boolean></value></param><param><value><i4>60</i4></value></param></params></methodCall>'
```

Press the pair button on your HM-Classic or HmIP device.  Once the
device announces itself, it appears as a new entity in HA within a few
seconds.

## Quick install — Plain Docker / docker-compose

```bash
git clone https://github.com/tostmann/headlessCCU
cd headlessCCU/headlessccu      # add-on lives in a subdir (HA-repo layout)
./build.sh                      # builds headlessccu:dev image (~5 min)
docker compose up -d
```

`docker-compose.yml` sets `network_mode: host` (required so XML-RPC
callbacks from `rfd` reach Home Assistant) and passes
`/dev/bus/usb` through to the container.  See the file for the full
port and environment-variable layout.

`build.sh` pulls the matching [bmcond](https://github.com/tostmann/bmcond)
version (default `2026.5.1`, override via `BMCOND_VERSION=main ./build.sh`)
and the pinned eq-3 bundle (`DEBMATIC_VERSION=3.85.7-123` by default;
override via `DEBMATIC_VERSION=latest ./build.sh`) at Docker-build time —
no local source-staging required.

Verify with the included smoke test (in this repo's parent project):

```bash
curl http://localhost:9126/api/effective | jq .running
```

should print a `version` and a non-zero `uptime_s`.

## Configuration options

| Option | Default | Description |
| --- | --- | --- |
| `hmid` | `auto` | `auto` = random 3-byte hex on first start, persisted to `/data/etc-config/ids`.  Or a fixed 6-hex string |
| `serial` | `BMC0000001` | 10-char gateway serial reported to clients |
| `firmware` | `2.8.6` | Firmware version reported to clients |
| `bidcos_radio` | `usb=1b1f:c020` | Transport for the BidCoS plane |
| `hmip_radio` | `usb=1b1f:c020` | Transport for the HmIP plane.  Empty or `none` = HmIP disabled |
| `loglevel` | `3` | `rfd` loglevel (0–5) |
| `log_level_mock` | `INFO` | `rega_session_mock` Python logging level |

Transport-string formats: `usb=VID:PID` (libusb-direct),
`rfusb=/dev/ttyXXX` (kernel-driver UART), `host:port` (TCP, e.g.
CULFW32 or HM-LGW2), `udp=host:port` (HB-RF-ETH / RFNetHM).

For HA Supervisor: configurable via the Add-On UI.  Plain Docker:
environment variables in `docker-compose.yml`.

## BidCoS-only setup (HmIP disabled)

Set `hmip_radio` to empty or `none`.  Effects:

- `bmcond` runs without an HmIP PTY (no `/tmp/mmd_hmip`).
- `HMIPServer.jar` is not started; port 2010 returns no service.
- `confgen` writes `InterfacesList.xml` without the `HmIP-RF` slot, so
  `aiohomematic` only registers the BidCoS interface.

Useful for HM-Classic-only deployments — e.g. when the only RF source
is a CULFW32 acting as a BidCoS gateway over `_hmuartlgw._tcp:2327`.

## Legacy: cp210x-via-kernel path

If you want to keep the old kernel-driver path (e.g. coexisting with
another tool that owns `/dev/ttyUSB0`), set
`bidcos_radio: "rfusb=/dev/ttyUSB0"` in the options and apply this
one-time host setup:

```bash
# /etc/modprobe.d/blacklist-eq3.conf
blacklist hb_rf_usb_2
blacklist hb_rf_usb
blacklist generic_raw_uart

# /etc/modules-load.d/cp210x.conf
cp210x

# /etc/udev/rules.d/70-hmip-rfusb-cp210x.rules
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="1b1f", ATTRS{idProduct}=="c020", \
  RUN+="/sbin/modprobe cp210x", \
  RUN+="/bin/sh -c 'echo 1b1f c020 > /sys/bus/usb-serial/drivers/cp210x/new_id'"
```

Re-plug the stick after udev reload — `ls -l /dev/ttyUSB0` should now
appear.  The container then receives it via
`--device /dev/ttyUSB0:/dev/ttyUSB0`.

## License

GPL-2.0-or-later — see [LICENSE](LICENSE).

> The Docker image *built* by this repo bundles eQ-3 closed-source
> binaries fetched from `apt.debmatic.de`.  Do **not redistribute the
> built image publicly** — each user builds locally from upstream
> debmatic, which is what Alexander Reinert's packaging
> ([alexreinert/debmatic](https://github.com/alexreinert/debmatic)) is
> designed for.

## Project context

Part of the BusMatic effort by Dirk Tostmann
([@tostmann](https://github.com/tostmann)).  `bmcond`
([github.com/tostmann/bmcond](https://github.com/tostmann/bmcond))
provides the userspace radio transport layer; this repo wraps it
together with eQ-3's `multimacd`, `rfd` and `HMIPServer.jar` into a
single container for HA / Docker consumption.
