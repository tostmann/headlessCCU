#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Mini ReGa Session Mock.

Standalone HTTP-Server der `/api/homematic.cgi` (JSON-RPC 1.1) so weit
beantwortet, dass aiohomematic ohne laufenden ReGaHss connecten kann.

Strategie
---------
aiohomematic ruft im Init-Pfad eine kleine, fixe Menge an Methoden:
Session-Lifecycle, CCU-Settings, system.listMethods, ein bisschen
ReGa.runScript für System-Info.  Alles andere (Sysvars, Programs,
Subsections, Inbox, Backups, Firmware-Updates) ist on-demand und im
aiohomematic-Quellcode mit walrus-Default-Pattern abgesichert:

    if json_result := response['result']:
        ... use it ...
    # else: leere Defaults

Wir liefern für ReGa.runScript daher einfach `result: null` und
beantworten alle Pflicht-Methoden mit minimal-akzeptablen Defaults.
Die eigentliche Aktor-Steuerung läuft via XML-RPC zu rfd/HMServer
und wird vom Mock nicht berührt.

Was geht ohne ReGa verloren
---------------------------
* Battery-low / Service-Messages-Aggregat (raw Datapoints kommen weiter)
* HM-Geräte-OTA-Firmware-Updates aus HA-UI angestoßen
* CCU-Programme, CCU-Sysvars, CCU-Räume in HA — wollten wir nicht
* CCU-Seriennummer / Hostname in Device-Registry — kosmetisch

Was bleibt
----------
* Aktor-Steuerung, Pairing, Event-Push, vollständige Device-Coverage.

Konfiguration
-------------
* `REGA_MOCK_PORT` (default: 8765)
* `REGA_MOCK_BIND` (default: 127.0.0.1)
* `REGA_MOCK_LOG_LEVEL` (default: INFO)
"""
from __future__ import annotations

import json
import logging
import os
import re
import secrets
import socket
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from time import monotonic
from typing import Any, Callable, Mapping

LOG = logging.getLogger("rega_session_mock")

JsonRpcResult = tuple[Any, Mapping[str, Any] | None]
"""(result, error) — analog zur JSON-RPC-1.1-Response."""

Handler = Callable[[Mapping[str, Any]], JsonRpcResult]


class SessionStore:
    """Thread-sichere Session-ID-Verwaltung.

    Sessions sind nicht persistent.  Bei einem Mock-Restart sind alle
    SIDs weg — aiohomematic erkennt das über fehlgeschlagene Calls und
    re-logged automatisch.
    """

    def __init__(self) -> None:
        self._sessions: dict[str, str] = {}
        self._lock = threading.Lock()

    def login(self, username: str) -> str:
        sid = "rgmock_" + secrets.token_hex(16)
        with self._lock:
            self._sessions[sid] = username
        return sid

    def logout(self, sid: str) -> None:
        with self._lock:
            self._sessions.pop(sid, None)

    def is_valid(self, sid: str) -> bool:
        with self._lock:
            return sid in self._sessions

    def adopt(self, sid: str) -> None:
        """Sei tolerant: unbekannte SIDs einfach übernehmen.

        aiohomematic erwartet bei Session.renew dass die Session valid
        bleibt; ein Mock-Restart darf das Setup nicht zerschiessen.
        """
        if not sid:
            return
        with self._lock:
            self._sessions.setdefault(sid, "adopted")


class RegaScriptHandler:
    """Dispatcher für ReGa.runScript-Aufrufe — namensbasiert.

    Der ReGa-Tcl-Script-Header beginnt mit `!# name: <scriptname>.fn`;
    wir parsen den Namen aus dem Script-Body und dispatchen auf
    Handler die ein JSON-string-Result (oder None) liefern.

    Unbekannte Skripte → None → walrus-default in aiohomematic-Caller.
    """

    _NAME_RE = re.compile(r"^!#\s*name:\s*([a-zA-Z0-9_]+)\.fn", re.MULTILINE)

    def __init__(self) -> None:
        self._handlers: dict[str, Callable[[], Any]] = {}

    def register(self, script_name: str) -> Callable[[Callable[[], Any]], Callable[[], Any]]:
        def decorator(fn: Callable[[], Any]) -> Callable[[], Any]:
            if script_name in self._handlers:
                raise ValueError(f"duplicate handler for script {script_name}")
            self._handlers[script_name] = fn
            return fn

        return decorator

    def script_name(self, script_text: str) -> str | None:
        m = self._NAME_RE.search(script_text or "")
        return m.group(1) if m else None

    def dispatch(self, script_text: str) -> Any:
        name = self.script_name(script_text)
        if name and (handler := self._handlers.get(name)):
            try:
                return handler()
            except Exception:  # noqa: BLE001 - boundary
                LOG.exception("rega-script handler %s failed", name)
                return None
        return None


class JsonRpcDispatcher:
    """Method-Registry für JSON-RPC mit Decorator-Pattern.

    Strategie für unbekannte Methoden ist konfigurierbar:

    * ``lenient`` (Default) — return ``null`` + WARNING-Log.  aiohomematic's
      walrus-Default-Pattern fängt das in den meisten Aufrufern.  Bei
      aiohomematic-Updates die neue Pflicht-Methoden einführen, läuft der
      Stack ohne Stop weiter; der WARNING-Log macht sichtbar wenn was
      Neues benötigt wird.
    * ``strict`` — return JSON-RPC ``-32601 Method not found`` wie es ein
      konformer Server tut.  Aiohomematic fängt das als
      ``UnsupportedException`` und stoppt den Pfad.
    """

    def __init__(self, *, unknown_strategy: str = "lenient") -> None:
        if unknown_strategy not in ("lenient", "strict"):
            raise ValueError(f"unknown_strategy must be lenient|strict, got {unknown_strategy!r}")
        self._handlers: dict[str, Handler] = {}
        self._unknown_strategy = unknown_strategy

    def register(self, method_name: str) -> Callable[[Handler], Handler]:
        def decorator(fn: Handler) -> Handler:
            if method_name in self._handlers:
                raise ValueError(f"duplicate handler for {method_name}")
            self._handlers[method_name] = fn
            return fn

        return decorator

    def dispatch(self, method: str, params: Mapping[str, Any]) -> JsonRpcResult:
        handler = self._handlers.get(method)
        if handler is None:
            if self._unknown_strategy == "lenient":
                LOG.warning(
                    "LENIENT FALLBACK: unknown method %s — returning null. "
                    "Add a handler if aiohomematic refuses to proceed.",
                    method,
                )
                return None, None
            LOG.info("rejecting unsupported method %s (strict)", method)
            return None, {"code": -32601, "message": f"Method not found: {method}"}
        try:
            return handler(params)
        except Exception as exc:  # noqa: BLE001 - boundary
            LOG.exception("handler error for %s", method)
            return None, {"code": -32603, "message": f"Internal error: {exc}"}

    @property
    def supported_methods(self) -> tuple[str, ...]:
        return tuple(self._handlers.keys())


# ---------------------------------------------------------------------------
# Singletons
# ---------------------------------------------------------------------------

sessions = SessionStore()
dispatcher = JsonRpcDispatcher(
    unknown_strategy=os.environ.get("REGA_MOCK_UNKNOWN_STRATEGY", "lenient").lower(),
)
rega_scripts = RegaScriptHandler()


# ---------------------------------------------------------------------------
# Real values for ReGa-script answers — read from system at request time
# (not at import time, so the mock picks up changes without restart).
# ---------------------------------------------------------------------------


def _read_version_field(field: str) -> str | None:
    """Parse `<FIELD>=<value>` aus /VERSION (debmatic-Format)."""
    try:
        for line in Path("/VERSION").read_text().splitlines():
            if line.startswith(f"{field}="):
                return line.split("=", 1)[1].strip()
    except OSError:
        return None
    return None


def _read_first_existing(*paths: str) -> str | None:
    for p in paths:
        try:
            text = Path(p).read_text().strip()
            if text:
                return text
        except OSError:
            continue
    return None


# Cache für die bmcd-Version: API-Call refresh alle 60s, sonst memoized.
_bmcd_version_cache: dict[str, Any] = {"value": None, "fetched_at": 0.0}
_BMCD_STATUS_URL = os.environ.get("REGA_MOCK_BMCD_URL", "http://127.0.0.1:9126/api/status")
_BMCD_VERSION_TTL = 60.0


def _read_busmatic_version() -> str | None:
    """Holt die bmcd-Version aus der bmcond-JSON-API (cached 60s).

    Fällt auf /VERSION zurück, falls bmcond nicht antwortet — aber das
    /VERSION-File spiegelt den unterliegenden debmatic-Stack, nicht
    busmatic.  Daher als Fallback expliziter Hinweis.
    """
    now = monotonic()
    if (
        _bmcd_version_cache["value"] is not None
        and (now - _bmcd_version_cache["fetched_at"]) < _BMCD_VERSION_TTL
    ):
        return _bmcd_version_cache["value"]

    try:
        with urllib.request.urlopen(_BMCD_STATUS_URL, timeout=2) as resp:
            data = json.loads(resp.read().decode())
            version = data.get("version")
            if version:
                _bmcd_version_cache["value"] = str(version)
                _bmcd_version_cache["fetched_at"] = now
                return _bmcd_version_cache["value"]
    except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError) as exc:
        LOG.debug("could not query bmcond at %s: %s", _BMCD_STATUS_URL, exc)

    return None


@rega_scripts.register("get_backend_info")
def _script_get_backend_info() -> str:
    """JSON-encoded backend info — busmatic-Identität, nicht debmatic.

    `version` kommt primär aus bmcond's API, fallback auf /VERSION.
    `product` ist immer "busmatic" — wir sind weder das original-CCU
    noch debmatic, auch wenn wir debmatic-Komponenten (rfd, HMServer.jar)
    re-use'n.
    """
    info = {
        "version": _read_busmatic_version() or _read_version_field("VERSION") or "",
        "product": "busmatic",
        "hostname": socket.gethostname(),
        # Wir laufen als nativer Pi5-Service, nicht als HA-Add-on.
        "is_ha_app": "false",
    }
    return json.dumps(info)


@rega_scripts.register("get_serial")
def _script_get_serial() -> str | None:
    """JSON-encoded serial — Quelle entspricht aiohomematic-original-Priorisierung."""
    serial = _read_first_existing(
        "/var/board_sgtin",
        "/var/board_serial",
        "/sys/module/plat_eq3ccu2/parameters/board_serial",
    )
    if not serial:
        return None
    # aiohomematic._get_serial akzeptiert sowohl string als auch dict-mit-key.
    # Wir liefern als plain JSON-string (ReGa-Pattern: string).
    return json.dumps(serial)


# ---------------------------------------------------------------------------
# Method handlers
# ---------------------------------------------------------------------------


@dispatcher.register("Session.login")
def _session_login(params: Mapping[str, Any]) -> JsonRpcResult:
    username = params.get("username", "anon") if isinstance(params, Mapping) else "anon"
    return sessions.login(username), None


@dispatcher.register("Session.logout")
def _session_logout(params: Mapping[str, Any]) -> JsonRpcResult:
    sid = params.get("_session_id_", "") if isinstance(params, Mapping) else ""
    sessions.logout(sid)
    return True, None


@dispatcher.register("Session.renew")
def _session_renew(params: Mapping[str, Any]) -> JsonRpcResult:
    sid = params.get("_session_id_", "") if isinstance(params, Mapping) else ""
    if not sessions.is_valid(sid):
        sessions.adopt(sid)
    return True, None


@dispatcher.register("system.listMethods")
def _system_list_methods(params: Mapping[str, Any]) -> JsonRpcResult:
    # aiohomematic erwartet pro Eintrag {"name": "<method>"}
    return [{"name": m} for m in dispatcher.supported_methods], None


@dispatcher.register("CCU.getAuthEnabled")
def _ccu_get_auth_enabled(params: Mapping[str, Any]) -> JsonRpcResult:
    # Kein Auth-Backend hinter dem Mock — aiohomematic akzeptiert dann
    # die Credentials wie übergeben (sind hier irrelevant).
    return False, None


@dispatcher.register("CCU.getHttpsRedirectEnabled")
def _ccu_get_https_redirect_enabled(params: Mapping[str, Any]) -> JsonRpcResult:
    return False, None


@dispatcher.register("ReGa.runScript")
def _rega_run_script(params: Mapping[str, Any]) -> JsonRpcResult:
    # Wir dispatchen auf den Skript-Namen aus dem Header `!# name: <name>.fn`.
    # Bekannte Skripte (get_backend_info, get_serial) bekommen echte Werte
    # aus /VERSION / /var/board_sgtin etc.  Alle anderen → null, was das
    # walrus-Default-Pattern in aiohomematic auf leere Defaults bringt.
    script = params.get("script", "") if isinstance(params, Mapping) else ""
    return rega_scripts.dispatch(script), None


_KNOWN_INTERFACES = ("BidCos-RF", "HmIP-RF")


@dispatcher.register("Interface.listInterfaces")
def _interface_list_interfaces(params: Mapping[str, Any]) -> JsonRpcResult:
    # aiohomematic.client.json_rpc._list_interfaces() iteriert über
    # response.result und liest pro Eintrag das "name"-Feld.  Die so
    # gewonnenen available_interfaces werden später in INIT_CLIENTS gegen
    # die konfigurierten Interfaces validiert; fehlt dort BidCos-RF /
    # HmIP-RF, schlägt der Client-Aufbau fehl.  Daher melden wir alle
    # üblichen aktiven Interfaces; die echten XML-RPC-Endpoints prüft
    # aiohomematic separat selbst.
    interfaces = [
        {"name": "BidCos-RF", "info": "BidCos RF", "port": 2001},
        {"name": "HmIP-RF", "info": "HmIP RF", "port": 2010},
    ]
    return interfaces, None


@dispatcher.register("Interface.isPresent")
def _interface_is_present(params: Mapping[str, Any]) -> JsonRpcResult:
    # aiohomematic.backend_detection ruft das pro konfigurierbarem Interface
    # auf, bevor es die Auto-Detect-Liste finalisiert.  Ohne diese Methode
    # ist BidCos-RF zwar in listInterfaces present, wird aber aus der
    # _detection_result.available_interfaces gestrichen — die Folge ist
    # "interface_not_available" in der homematicip_local-Config-Flow.
    name = ""
    if isinstance(params, Mapping):
        name = str(params.get("interface", "") or "")
    return name in _KNOWN_INTERFACES, None


# ---------------------------------------------------------------------------
# Read-only Discovery — als supported gemeldet damit aiohomematic das
# Init nicht abbricht.  Leere Defaults treffen das walrus-Pattern in
# allen aufrufenden Funktionen.  Echte Daten holt sich aiohomematic
# parallel via XML-RPC zu rfd / HMServer.
# ---------------------------------------------------------------------------


def _empty_list(_params: Mapping[str, Any]) -> JsonRpcResult:
    return [], None


def _empty_dict(_params: Mapping[str, Any]) -> JsonRpcResult:
    return {}, None


def _success_true(_params: Mapping[str, Any]) -> JsonRpcResult:
    return True, None


def _success_false(_params: Mapping[str, Any]) -> JsonRpcResult:
    return False, None


def _return_null(_params: Mapping[str, Any]) -> JsonRpcResult:
    return None, None


# HmIP-Pairing-Trigger: aiohomematic ruft JSON-RPC
# Interface.setInstallModeHMIP — wir leiten das an den jeweiligen
# XML-RPC setInstallMode am rfd (:2001) bzw. HMIPServer (:2010)
# weiter, damit das physische Pair-Fenster tatsächlich aufgeht.
# Empirisch verifiziert 2026-05-12: HMIPServer.jar's setInstallMode
# funktioniert sauber (öffnet 60s-Fenster) — der frühere "silent fail"-
# Vermerk war falsch, das Pair-Window wurde einfach nie aktiviert.
import urllib.request as _urlreq
import xmlrpc.client as _xmlrpc


def _xmlrpc_setinstallmode(host_port: str, on: bool, secs: int) -> bool:
    body = (
        '<?xml version="1.0"?>'
        '<methodCall><methodName>setInstallMode</methodName><params>'
        f'<param><value><boolean>{1 if on else 0}</boolean></value></param>'
        f'<param><value><i4>{secs}</i4></value></param>'
        '</params></methodCall>'
    ).encode("utf-8")
    try:
        req = _urlreq.Request(
            f"http://{host_port}/",
            data=body,
            headers={"Content-Type": "text/xml"},
            method="POST",
        )
        _urlreq.urlopen(req, timeout=3).read()
        return True
    except Exception as exc:  # network/timeout/HTTP error
        LOG.warning("setInstallMode forward to %s failed: %s", host_port, exc)
        return False


# ── HA-Core-API via Supervisor-proxy (homeassistant_api: true erforderlich) ──
# aiohomematic hat einen Persistent-Cache-Bug: nach Live-Pair landen die
# Device-Channels nicht im Cache, Entities werden nicht angelegt
# (memory aiohomematic_pair_cache_bug.md).  Workaround: clear_cache +
# reload_config_entry.  Wir triggern das nach Ablauf des Install-Mode-
# Fensters automatisch, damit der User die Aktion nicht selbst ausführen
# muss.
def _ha_api_call(path: str, body: dict | None = None) -> dict | None:
    token = os.environ.get("SUPERVISOR_TOKEN")
    if not token:
        LOG.warning("no SUPERVISOR_TOKEN — HA-API call skipped")
        return None
    try:
        req = _urlreq.Request(
            f"http://supervisor/core/api{path}",
            data=json.dumps(body or {}).encode("utf-8") if body is not None else None,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            method="POST" if body is not None else "GET",
        )
        resp = _urlreq.urlopen(req, timeout=8).read().decode("utf-8")
        return json.loads(resp) if resp.strip().startswith(("{", "[")) else {"raw": resp}
    except Exception as exc:
        LOG.warning("HA-API %s failed: %s", path, exc)
        return None


def _ha_homematic_entry_ids() -> list[str]:
    data = _ha_api_call("/config/config_entries/entry") or []
    if not isinstance(data, list):
        return []
    return [e.get("entry_id") for e in data if e.get("domain") == "homematicip_local"]


def _xmlrpc_root_count(host_port: str) -> int:
    """Count root devices (no ':') in listDevices reply from a HM-XML-RPC
    endpoint (HMIPServer:32010 or rfd:32001).  -1 on error."""
    body = (
        b'<?xml version="1.0"?>'
        b'<methodCall><methodName>listDevices</methodName><params/></methodCall>'
    )
    try:
        req = _urlreq.Request(
            f"http://{host_port}/",
            data=body,
            headers={"Content-Type": "text/xml"},
            method="POST",
        )
        data = _urlreq.urlopen(req, timeout=3).read().decode("latin-1", errors="ignore")
        addrs = re.findall(
            r"<name>ADDRESS</name>\s*<value>(?:<string>)?([^<]+)(?:</string>)?</value>",
            data,
        )
        return sum(1 for a in addrs if ":" not in a)
    except Exception as exc:
        LOG.debug("listDevices poll %s failed: %s", host_port, exc)
        return -1


def _post_pair_refresh(secs_window: int, target_port: str) -> None:
    """Poll the active interface's listDevices throughout the pair-window;
    trigger clear_cache + reload_config_entry as soon as a new root
    appears (typical 10-30s after the user presses the pair-button).
    Falls back to a fixed wait if polling missed the event (e.g.
    listDevices transiently failed during the window)."""
    import time as _time

    baseline = _xmlrpc_root_count(target_port)
    LOG.info("post-pair[%s]: baseline=%d roots, polling for %ds...",
             target_port, baseline, secs_window)

    deadline = _time.time() + secs_window + 10  # window + 10s grace
    triggered_by = "timeout"
    while _time.time() < deadline:
        _time.sleep(5)
        cur = _xmlrpc_root_count(target_port)
        if baseline >= 0 and cur > baseline:
            LOG.info("post-pair[%s]: new root detected (%d→%d), settling 3s...",
                     target_port, baseline, cur)
            _time.sleep(3)
            triggered_by = f"new-device ({baseline}→{cur})"
            break

    entry_ids = _ha_homematic_entry_ids()
    if not entry_ids:
        LOG.info("post-pair refresh: no homematicip_local entry — skip (trigger=%s)",
                 triggered_by)
        return
    for eid in entry_ids:
        # confirm_all_delayed_devices: aiohomematic stellt frisch gepairte
        # Geräte in eine Quarantäne ("Verzögertes Gerät hinzufügen"-Warning).
        # Wir bestätigen sie automatisch, sonst muss der User pro Pair
        # klicken.
        _ha_api_call("/services/homematicip_local/confirm_all_delayed_devices",
                     {"entry_id": eid})
        _ha_api_call("/services/homematicip_local/clear_cache",
                     {"entry_id": eid})
        _ha_api_call("/services/homeassistant/reload_config_entry",
                     {"entry_id": eid})
        LOG.info("post-pair refresh: confirm + clear_cache + reload done for %s (trigger=%s)",
                 eid, triggered_by)

    # Final-Step: force-availability auf alle bekannten Geräte.  rfd's
    # UN_REACH-Heuristik flippt RX1-Aktoren zwischen Toggles auf "unreach",
    # was aiohomematic als entity-unavailable interpretiert.  Wir setzen
    # einmal pro post-pair-Zyklus ForcedDeviceAvailability.FORCE_TRUE für
    # alle Geräte beider Interfaces, damit der Flicker-Loop entfällt.
    _time.sleep(15)  # warte bis Integration nach reload wieder ready
    _force_all_devices_available()


def _xmlrpc_list_root_addresses(host_port: str) -> list[str]:
    """Return device-root addresses (ohne ':') aus listDevices, ohne den
    interface-Gateway selbst (TEQ.../HmIP-RCV-1 etc. filtern wir nicht aus —
    force-availability auf die Gateway-Adresse ist harmlos)."""
    body = (
        b'<?xml version="1.0"?>'
        b'<methodCall><methodName>listDevices</methodName><params/></methodCall>'
    )
    try:
        req = _urlreq.Request(
            f"http://{host_port}/",
            data=body,
            headers={"Content-Type": "text/xml"},
            method="POST",
        )
        data = _urlreq.urlopen(req, timeout=3).read().decode("latin-1", errors="ignore")
        addrs = re.findall(
            r"<name>ADDRESS</name>\s*<value>(?:<string>)?([^<]+)(?:</string>)?</value>",
            data,
        )
        return [a for a in addrs if ":" not in a]
    except Exception as exc:
        LOG.debug("listDevices %s failed: %s", host_port, exc)
        return []


def _force_all_devices_available() -> None:
    """Apply ForcedDeviceAvailability.FORCE_TRUE to every paired device on
    every interface.  Idempotent (call repeatedly = same result).  Without
    this, RX1 actuators flicker between "on" and "unavailable" every few
    seconds because rfd asserts UN_REACH=true between commands."""
    addresses: list[str] = []
    for port in ("127.0.0.1:32001", "127.0.0.1:32010"):
        addresses.extend(_xmlrpc_list_root_addresses(port))
    if not addresses:
        LOG.info("force_availability: no devices found — skip")
        return
    forced = 0
    for addr in addresses:
        # Ignoriere Interface-Gateways (TEQxxx und HmIP-RCV-1 etc.) — sind
        # nicht in HA-Geräteregistry; force ist no-op aber Service liefert
        # dann WARNING. Wir filtern Gateways nicht direkt, sondern verlassen
        # uns auf den Service-Fail-Silent für unbekannte Adressen.
        resp = _ha_api_call(
            "/services/homematicip_local/force_device_availability",
            {"device_address": addr},
        )
        if resp is not None:
            forced += 1
            LOG.debug("force_availability: %s OK", addr)
    LOG.info("force_availability: applied to %d/%d known devices",
             forced, len(addresses))


def _set_install_mode_hmip(params: Mapping[str, Any]) -> JsonRpcResult:
    iface = (params or {}).get("interface", "HmIP-RF") if isinstance(params, Mapping) else "HmIP-RF"
    on = str((params or {}).get("on", "true")).lower() in ("1", "true", "yes")
    try:
        secs = int((params or {}).get("time", 60))
    except (TypeError, ValueError):
        secs = 60
    # interface-Mapping → Backend
    target = "127.0.0.1:32010" if "ip" in iface.lower() else "127.0.0.1:32001"
    ok = _xmlrpc_setinstallmode(target, on, secs)
    LOG.info("setInstallModeHMIP → %s on=%s time=%ds → %s",
             target, on, secs, "OK" if ok else "FORWARD-FAIL")
    # Bei "on": Polling-Thread fired auto-refresh sobald listDevices ein
    # neues Root liefert (typisch 10-30s nach Pair-Knopf) statt fix nach
    # 75s zu warten — bringt die Pair-UX-Latenz von ~75s auf ~15-35s.
    if on and secs > 0:
        threading.Thread(
            target=_post_pair_refresh,
            args=(secs, target),
            name=f"post-pair-refresh-{target}",
            daemon=True,
        ).start()
    return True, None  # immer success an aiohomematic — sonst markt's UI als crash


# ── Generic JSON-RPC → XML-RPC bridge for Interface.* methods ──────────────
# aiohomematic CHECK_SUPPORTED_METHODS-warning listet diese als "Backend
# nicht unterstützt"; ohne ihre Implementierung schlägt der Delayed-Device-
# Confirm-Pfad und die Install-Mode-Sync-Loop fehl.  Wir bridgen sie generisch:
# JSON-Params → positional XML-RPC-Args auf dem richtigen Backend-Port.
_INTERFACE_PORT = {
    "BidCos-RF": "127.0.0.1:32001",
    "HmIP-RF":    "127.0.0.1:32010",
}


def _xmlrpc_to_jsonable(obj: Any) -> Any:
    """xmlrpc.client liefert Structs als dict, Arrays als list.  Datetime
    und Binary müssen wir noch zu String/hex wandeln damit json.dumps OK ist."""
    if isinstance(obj, dict):
        return {k: _xmlrpc_to_jsonable(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_xmlrpc_to_jsonable(v) for v in obj]
    if isinstance(obj, _xmlrpc.DateTime):
        return str(obj)
    if isinstance(obj, _xmlrpc.Binary):
        return obj.data.hex()
    if isinstance(obj, bytes):
        return obj.hex()
    return obj


def _xmlrpc_forward(host_port: str, method: str, *args: Any) -> Any:
    """Wirft Exception bei XML-RPC-Fault — Caller wandelt in JSON-RPC-Error."""
    srv = _xmlrpc.ServerProxy(f"http://{host_port}/", allow_none=True)
    return _xmlrpc_to_jsonable(getattr(srv, method)(*args))


def _make_interface_handler(method: str, json_arg_order: tuple[str, ...]) -> Handler:
    """Baue einen JSON-RPC-Handler der params[interface] → port mapped und
    die übrigen Felder in der vorgegebenen Reihenfolge als XML-RPC-Args
    weiterleitet."""

    def handler(params: Mapping[str, Any]) -> JsonRpcResult:
        if not isinstance(params, Mapping):
            return None, {"code": -32602, "message": "params must be a dict"}
        iface = params.get("interface")
        port = _INTERFACE_PORT.get(iface)
        if not port:
            LOG.warning("Interface.%s: unknown interface %r — return null",
                        method, iface)
            return None, None  # tolerant: null statt error
        xargs = [params.get(k) for k in json_arg_order]
        try:
            result = _xmlrpc_forward(port, method, *xargs)
            return result, None
        except _xmlrpc.Fault as fault:
            LOG.warning("Interface.%s @ %s fault %d: %s",
                        method, port, fault.faultCode, fault.faultString)
            return None, {"code": fault.faultCode, "message": fault.faultString}
        except Exception as exc:
            LOG.warning("Interface.%s @ %s failed: %s", method, port, exc)
            return None, None  # tolerant: null statt RPC-Error

    return handler


_interface_get_device_description = _make_interface_handler(
    "getDeviceDescription", ("address",),
)
_interface_get_install_mode = _make_interface_handler(
    "getInstallMode", (),
)
_interface_list_devices = _make_interface_handler(
    "listDevices", (),
)
_interface_get_paramset = _make_interface_handler(
    "getParamset", ("address", "paramsetKey"),
)
_interface_get_paramset_description = _make_interface_handler(
    "getParamsetDescription", ("address", "paramsetKey"),
)
_interface_get_value = _make_interface_handler(
    "getValue", ("address", "valueKey"),
)
_interface_get_master_value = _make_interface_handler(
    "getMasterValue", ("address", "valueKey"),
)
_interface_set_value = _make_interface_handler(
    "setValue", ("address", "valueKey", "value"),
)
_interface_put_paramset = _make_interface_handler(
    "putParamset", ("address", "paramsetKey", "set"),
)
_interface_get_link_info = _make_interface_handler(
    "getLinkInfo", ("senderAddress", "receiverAddress"),
)
_interface_set_link_info = _make_interface_handler(
    "setLinkInfo", ("senderAddress", "receiverAddress", "name", "description"),
)
_interface_get_suppressed = _make_interface_handler(
    "getSuppressedServiceMessages", (),
)
_interface_suppress = _make_interface_handler(
    "suppressServiceMessages", (),
)


for _method, _handler in (
    # Device-Discovery
    ("Device.listAllDetail", _empty_list),
    # CCU-Konzepte (gibt's hier nicht — leer)
    ("Program.getAll", _empty_list),
    ("Room.getAll", _empty_list),
    ("Subsection.getAll", _empty_list),
    ("SysVar.getAll", _empty_list),
    # Naming-Schreib-Operationen — no-op success
    ("Channel.setName", _success_true),
    ("Device.setName", _success_true),
    # Channel-Programmrelation: existiert hier nicht
    ("Channel.hasProgramIds", _empty_dict),
    # HmIP-Pairing-Trigger: leitet an HMIPServer's XML-RPC weiter
    ("Interface.setInstallModeHMIP", _set_install_mode_hmip),
    # Interface.* JSON-RPC → XML-RPC-Bridges (delayed-device, install-mode-sync etc.)
    ("Interface.getDeviceDescription",     _interface_get_device_description),
    ("Interface.getInstallMode",           _interface_get_install_mode),
    ("Interface.listDevices",              _interface_list_devices),
    ("Interface.getParamset",              _interface_get_paramset),
    ("Interface.getParamsetDescription",   _interface_get_paramset_description),
    ("Interface.getValue",                 _interface_get_value),
    ("Interface.getMasterValue",           _interface_get_master_value),
    ("Interface.setValue",                 _interface_set_value),
    ("Interface.putParamset",              _interface_put_paramset),
    ("Interface.getLinkInfo",              _interface_get_link_info),
    ("Interface.setLinkInfo",              _interface_set_link_info),
    ("Interface.getSuppressedServiceMessages", _interface_get_suppressed),
    ("Interface.suppressServiceMessages",  _interface_suppress),
    # Program.execute: CCU-Logikprogramm-Ausführung — gibt's hier nicht.
    # aiohomematic ruft das selten; success ist sichere Antwort.
    ("Program.execute",                    _success_true),
    # SysVar.* — System-Variablen-Tabelle der CCU.  Wir haben keine,
    # also no-op success für Schreibzugriffe und null für Lese-by-name.
    ("SysVar.createBool",                  _success_true),
    ("SysVar.createEnum",                  _success_true),
    ("SysVar.createFloat",                 _success_true),
    ("SysVar.deleteSysVarByName",          _success_true),
    ("SysVar.getValueByName",              _return_null),
    ("SysVar.setBool",                     _success_true),
    ("SysVar.setFloat",                    _success_true),
):
    dispatcher.register(_method)(_handler)
del _method, _handler


# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------


class JsonRpcRequestHandler(BaseHTTPRequestHandler):
    server_version = "rega-session-mock/0.2"

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003 - matches base
        LOG.debug("%s %s", self.address_string(), fmt % args)

    def _send_json(self, status: int, body: Mapping[str, Any]) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/", "/health"):
            self._send_json(
                200,
                {
                    "status": "ok",
                    "service": "rega-session-mock",
                    "supported_methods": list(dispatcher.supported_methods),
                    "active_sessions": len(sessions._sessions),  # noqa: SLF001
                },
            )
            return
        self._send_json(404, {"error": {"code": -32601, "message": "not found"}})

    def do_POST(self) -> None:  # noqa: N802
        # Internal trigger from ping_shim when it observes a BidCoS XML-RPC
        # setInstallMode (aiohomematic uses XML-RPC for BidCoS, JSON-RPC for
        # HmIP — only the HmIP path triggers _set_install_mode_hmip directly).
        if self.path == "/internal/post-pair":
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length > 0 else b"{}"
            try:
                body = json.loads(raw or b"{}")
            except json.JSONDecodeError:
                body = {}
            target = str(body.get("target", "127.0.0.1:32001"))
            try:
                secs = int(body.get("secs", 60))
            except (TypeError, ValueError):
                secs = 60
            LOG.info("internal: trigger post-pair-refresh target=%s secs=%d",
                     target, secs)
            threading.Thread(
                target=_post_pair_refresh,
                args=(secs, target),
                name=f"post-pair-refresh-{target}-internal",
                daemon=True,
            ).start()
            self._send_json(200, {"status": "ok"})
            return

        if self.path != "/api/homematic.cgi":
            self._send_json(404, {"error": {"code": -32601, "message": "unknown endpoint"}})
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            req = json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError as exc:
            self._send_json(
                200,
                {"version": "1.1", "id": 0, "result": None, "error": {"code": -32700, "message": f"parse error: {exc}"}},
            )
            return

        method = req.get("method", "")
        params = req.get("params") or {}
        req_id = req.get("id", 0)

        # Sensible Felder maskieren fürs Logging
        log_params = dict(params) if isinstance(params, dict) else params
        if isinstance(log_params, dict):
            for sensitive in ("password", "_session_id_"):
                if sensitive in log_params:
                    log_params[sensitive] = "***"
            # Skripte sind oft groß; nur Header + Größe loggen
            if "script" in log_params and isinstance(log_params["script"], str):
                src = log_params["script"]
                head = src.splitlines()[0] if src else ""
                log_params["script"] = f"<{len(src)}b: {head[:60]}…>"
        LOG.info("RPC %s params=%s", method, log_params)

        result, error = dispatcher.dispatch(method, params if isinstance(params, Mapping) else {})
        self._send_json(
            200,
            {"version": "1.1", "id": req_id, "result": result, "error": error},
        )


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("REGA_MOCK_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )
    bind = os.environ.get("REGA_MOCK_BIND", "127.0.0.1")
    port = int(os.environ.get("REGA_MOCK_PORT", "8765"))
    # Bei /api/reload-getriggertem Container-Re-Exec ist das vorige
    # rega-Socket evtl. noch in TIME_WAIT / Listen-Cleanup — SO_REUSEADDR
    # erlaubt sofortiges Re-Binding.
    ThreadingHTTPServer.allow_reuse_address = True
    server = ThreadingHTTPServer((bind, port), JsonRpcRequestHandler)
    LOG.info(
        "rega-session-mock listening on http://%s:%d/api/homematic.cgi (methods: %s)",
        bind,
        port,
        ", ".join(dispatcher.supported_methods),
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("shutdown requested")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
