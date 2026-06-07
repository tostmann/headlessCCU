# headlessCCU

HomeMatic CCU without WebUI / ReGaHss.  Bundles
**bmcond + rfd + HMIPServer + rega_session_mock** in a single container,
designed to be driven by Home Assistant's `homematicip_local` integration.

Two distribution paths from the same image:
- **Home Assistant Add-On** (HA Supervisor / HAOS) — install via the
  Add-On Store from the repository URL; configure via the UI; the
  `homematicip_local` integration connects locally.
- **Plain Docker / docker-compose** — on any Linux host with Docker and
  an HmIP-RFUSB plugged in.  Speaks XML-RPC on `:2001` (BidCoS) and
  `:2010` (HmIP) plus JSON-RPC on `:8765` (with `:80` reverse-proxy to
  the same), so any consumer (Home Assistant `homematicip_local`,
  ioBroker, Homegear, NodeRED, custom scripts) just connects.

## What's inside

```
HA homematicip_local (or any XML-RPC client)
  → :80   lighttpd → rega_session_mock     (Auth/Session stub for aiohomematic, default JSON-RPC port)
  → :8765 rega_session_mock                (same, direct)
  → :2001 lighttpd → rfd                   (BidCoS XML-RPC)
  → :2010 lighttpd → HMServer.jar          (HmIP XML-RPC)
          ↕  /tmp/mmd_bidcos  /tmp/mmd_hmip (PTYs)
          bmcond — talks to USB stick via libusb-direct
                 /dev/bus/usb → HmIP-RFUSB (cp210x + EFM32G220F64)
```

## Host prerequisites

**Plug the stick in — done.**  The eQ-3 HmIP-RFUSB (USB-ID `1b1f:c020`)
is opened via libusb-1.0 directly; bmcond detaches whatever kernel
driver had bound it and claims the interface.  No udev rule, no
module blacklist, no `/dev/ttyUSB0` required.  Works on HAOS read-only
root just fine.

What the container needs: access to `/dev/bus/usb`.  HA Supervisor
mounts it automatically when `usb: true` is set in the add-on config
(already set here).  Plain Docker: `devices: [/dev/bus/usb:/dev/bus/usb]`
in `docker-compose.yml` (already set).

Supported sticks via libusb-direct:
- eQ-3 **HmIP-RFUSB** (`1b1f:c020`) — both BidCoS and HmIP planes
- HB-RF-USB v1 (FT232RL `0403:6f70`) + RPi-RF-MOD — BidCoS only
- HB-RF-USB-2 (CP2102N `10c4:8c07/8d81/8d91/8e4a`) — verified
  cross-quirk-table

### Kernel module `eq3_char_loop` (required since 2026.6.x)

Since the multimacd-shim architecture (2026.6.x) the stack runs eQ-3's
`multimacd` inside the container.  multimacd needs `/dev/eq3loop`, whose
kernel module **must be available on the host** — the container can only
`modprobe` it (needs `CAP_SYS_MODULE`, granted in `docker-compose.yml`)
or `mknod` the device node from sysfs if the host already loaded it.

- **Debian / Raspberry Pi OS host:** the module ships in debmatic's
  `pivccu-modules-dkms` package (DKMS-built for the running kernel).
  Either install debmatic on the host, or build/load the module from
  the piVCCU sources.  Verify with `modinfo eq3_char_loop`.
- **Home Assistant OS:** the HAOS kernel does **not** ship this module
  and add-ons cannot load external modules — the multimacd-shim path
  therefore does **not** run on HAOS at the moment.  This is a known
  limitation of the 2026.6.x line (the pre-2026.6 bmcond-native path
  did not need it).

Failure signature when the module is missing:
`modprobe eq3_char_loop fehlgeschlagen` followed by
`ERROR: /dev/eq3loop fehlt und konnte nicht erzeugt werden`.

### Legacy: cp210x-via-kernel path

If you need to keep using the kernel `cp210x` driver (e.g., co-existing
with another tool that owns `/dev/ttyUSB0`), set
`bidcos_radio: "rfusb=/dev/ttyUSB0"` (and the same for `hmip_radio`)
and apply the one-time host setup:

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

Re-plug the stick after `udevadm control --reload` — `ls -l /dev/ttyUSB0`
should now appear.

## Add-On options

| Option | Default | Description |
| --- | --- | --- |
| `hmid` | `auto` | `auto` = random 3-byte hex on first start, persisted in `/data/etc-config/ids`.  Or a fixed 6-hex string |
| `serial` | `BMC0000001` | 10-char gateway serial reported to XML-RPC clients |
| `firmware` | `2.8.6` | Firmware version string reported to clients |
| `bidcos_radio` | `usb=1b1f:c020` | Transport for the BidCoS plane |
| `hmip_radio` | `usb=1b1f:c020` | Transport for the HmIP plane.  Empty or `none` = HmIP disabled |
| `loglevel` | `3` | `rfd` loglevel (0–5) |
| `log_level_mock` | `INFO` | `rega_session_mock` Python logging level |

Transport-string formats:
- `usb=VID:PID` — libusb-direct (default for HmIP-RFUSB)
- `rfusb=/dev/ttyXXX` — kernel UART driver
- `host:port` — TCP backend (CULFW32, HM-LGW2)
- `udp=host:port` — UDP backend (HB-RF-ETH / RFNetHM)

For BidCoS and HmIP on the same physical stick (HmIP-RFUSB DualCoPro
firmware), keep both `*_radio` options identical.  BidCoS on one stick
+ HmIP on another is not yet supported in this build.

## bmcond Web-UI (HA Sidebar Ingress)

After the add-on starts, a **HomeMatic-RF** panel appears in the HA
sidebar (Ingress, port 9126).  It shows:
- detected sources (USB / mDNS) with capabilities (BidCoS, HmIP)
- which source is currently mapped to which slot (BidCoS-Slot, HmIP-Slot)
- container stats (uptime, RX/TX counters, decoder OK/error)

On a fresh install with exactly one discovered source per capability,
the radio buttons are **pre-selected** — just click **"Speichern + Reload"**
to persist and restart the stack.  The reload triggers a clean
container restart via the Supervisor API.

## Connecting Home Assistant

Install the [`homematicip_local`](https://github.com/SukramJ/homematicip_local)
custom integration (via HACS or manual `custom_components/` copy).

**Settings → Devices & Services → Add Integration → HomematicIP Local:**

| Field | Value |
| --- | --- |
| Instance name | `headlessccu` (or your choice) |
| Host | `172.30.32.1` (HA Supervisor's bridge gateway) — or `127.0.0.1` on a non-HAOS host |
| Username / Password | anything — the mock accepts any credentials |
| Custom port config | leave OFF — defaults (`:80` for JSON-RPC) work since the bundled lighttpd proxies it for you |

The integration auto-detects both `BidCos-RF` and `HmIP-RF`.  Confirm
and finish.

## What does NOT work compared to a full CCU

This is intentional — the mock path covers direct-HA use cases without
ReGaHss, but you lose:
- CCU programs (server-side Tcl logic)
- CCU system variables, CCU rooms, CCU subsections
- Battery-low / service-message aggregation (raw datapoints still flow)
- HM device OTA firmware-update triggered from the HA UI

If you need these, run normal debmatic with ReGaHss + WebUI, and point
HA against the CCU XML-RPC endpoints — don't use this add-on.

## Pairing a device

Use the `homematicip_local`-provided buttons in HA:
- `button.headlessccu_install_mode_bidcos_rf`  — BidCoS (60 s)
- `button.headlessccu_install_mode_hmip_rf`    — HmIP (60 s)

(The exact entity names depend on the `Instance name` you chose.)

Press one of those, then trigger the pair-button on the device (or
plug a fresh BidCoS switch into mains — most send their
`DEVICE_INFO` automatically while unpaired).

### Cache-refresh after pairing (workaround)

Known `aiohomematic` quirk: some BidCoS senders (e.g.
`HM-PB-2-WM`) don't get their channels written to the persistent
cache after a live pair.  HA log shows:

```
INIT_DEVICE: Skipping channel JEQ0064205:0 — description not retrieved from CCU
GET_CONFIGURABLE_DEVICES: skipping ... due to DescriptionNotFoundException
```

and no entities materialize for the device.

**Workaround:** after the pair, clear the cache and restart HA:

```yaml
# Developer Tools → Services:
service: homematicip_local.clear_cache
data:
  entry_id: <entry_id_of_your_headlessccu_integration>
```

Then **Settings → System → Restart Home Assistant**.  After restart,
`aiohomematic` re-fetches the full device list via `listDevices()`
and the channels appear correctly as entities.

The root cause sits in `aiohomematic`'s persistence layer, not in this
add-on — we forward the eq-3 `newDevices` payload unchanged.

### "Install test" mode

Sender devices (HM-PB-2-WM, HM-RC-*, …) enter a ~3-minute "install
test mode" right after pairing: button presses emit `INSTALL_TEST=True`
instead of `PRESS_SHORT/PRESS_LONG`.  Normal — wait it out or long-press
the pair button to exit early.

## Versioning

This add-on follows HAOS-style `YYYY.M.B` versioning.  The runtime
banner shows the actually-installed eq-3 bundle version
(`/boot/VERSION`) plus the `debmatic` package pin — both are
displayed at startup in the add-on log:

```
  Firmware:   2.8.6       (Add-On-configured, in rfd-Banner)
  CCU-Bundle: 3.85.7.123  (debmatic=3.85.7-123, arm64)
```

The bundled bmcond version is pinned in the Dockerfile via
`BMCOND_VERSION` (default points at the matching
[tostmann/bmcond](https://github.com/tostmann/bmcond) release tag).
Both pins have `=latest` overrides for upstream-rotation emergencies.

## License

GPL-2.0-or-later — see `LICENSE`.

The Docker image *built* by this repository bundles eq-3 closed-source
binaries fetched from `apt.debmatic.de` at Docker-build time.  **Do
not redistribute the built image publicly** — each user builds locally
from upstream
[alexreinert/debmatic](https://github.com/alexreinert/debmatic),
which is what Alexander Reinert's packaging is designed for.
