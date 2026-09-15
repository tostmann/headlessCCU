#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
XML-RPC ping-shim for headlessCCU.

Sits in front of rfd (BidCoS) / HMIPServer (HmIP) and implements the
CCU-style ping-pong keepalive protocol that aiohomematic expects:

    Client → ping(caller_id) → Backend
    Backend → event(interface_id, "", "PONG", caller_id) → Client

Real CCU does this natively; rfd does NOT (returns fault -1 "Failure"
on ping), which causes aiohomematic's PingPongTracker to mark entities
as unavailable every ~30s and oscillate state.

This shim:
- Forwards every XML-RPC call verbatim to the upstream backend, EXCEPT:
- `init(url, interface_id)`: cache (interface_id → url) AND forward
- `ping(caller_id)`: return True immediately; async fire the PONG
  event-callback to the cached URL for the interface_id parsed from
  caller_id (format: "{interface_id}#{token}").

Run two instances: one for BidCoS (upstream rfd:32001) on :2001, one for
HmIP (upstream HMIPServer:32010) on :2010.  Lighttpd's previous :2001
and :2010 proxy entries are removed; the shim takes those ports directly.

Optional TX serialization (--tx-lock PATH): when BidCoS and HmIP share one
DualCoPro radio, a command on one interface issued 50–100 ms after a command
on the other makes the copro lose the HmIP reply twice and report NO_REPLY,
which HMIPServer turns into 'Generic error (UNREACH)' although the actuator
switched (measured on headlessCCU and stock OpenCCU with HmIP-RFUSB 4.4.18).
With a shared lock file both shim instances run radio-bound calls one at a
time, holding the lock until the upstream call returns plus --tx-guard-ms.
This only covers API-triggered traffic, not frames the devices send on
their own.

Usage:
  ping_shim.py --listen-port 2001 --upstream-port 32001 --name bidcos
  ping_shim.py --listen-port 2010 --upstream-port 32010 --name hmip
  ping_shim.py ... --tx-lock /var/run/headlessccu-rf-tx.lock
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import logging
import os
import sys
import threading
import time
import urllib.request
import xmlrpc.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from xml.etree import ElementTree as ET

LOG = logging.getLogger("ping_shim")

# (interface_id → callback url) — populated by init() interceptor.
# Thread-safe writes via the GIL since we only do single dict assignments.
INIT_URLS: dict[str, str] = {}

# XML-RPC methods that put frames on air.  getValue is left out on purpose:
# it is radio-bound only for some BidCoS parameters, and serializing it would
# slow down aiohomematic's initial load.
DEFAULT_TX_METHODS = (
    "setValue", "putParamset", "addLink", "removeLink",
    "activateLinkParamset", "deleteDevice", "restoreConfigToDevice",
)


class TxLock:
    """Cross-process lock shared by the BidCoS and HmIP shim instances.

    flock() on separate open() calls conflicts between processes and between
    threads of one process, so every request opens its own descriptor.
    """

    def __init__(self, path: str, guard_ms: int, max_wait_s: float, methods):
        self.path = path
        self.guard_s = guard_ms / 1000.0
        self.max_wait_s = max_wait_s
        self.methods = frozenset(methods)

    def wants(self, method: str, args: list) -> bool:
        if method in self.methods:
            return True
        if method == "system.multicall" and args and isinstance(args[0], list):
            return any(isinstance(c, dict) and c.get("methodName") in self.methods
                       for c in args[0])
        return False

    @contextlib.contextmanager
    def hold(self, label: str):
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        t0 = time.monotonic()
        locked = False
        try:
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    locked = True
                    break
                except BlockingIOError:
                    if time.monotonic() - t0 >= self.max_wait_s:
                        LOG.warning("tx-lock: %s waited %.0f ms — proceeding unserialized",
                                    label, (time.monotonic() - t0) * 1000)
                        break
                    time.sleep(0.005)
            waited_ms = (time.monotonic() - t0) * 1000
            if locked and waited_ms >= 20:
                LOG.info("tx-lock: %s waited %.0f ms", label, waited_ms)
            yield
            if locked and self.guard_s:
                time.sleep(self.guard_s)
        finally:
            if locked:
                fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)


def _parse_method_call(body: bytes) -> tuple[str, list]:
    """Extract methodName + positional args from an XML-RPC request body.

    Uses xmlrpc.client.loads on a forged response-wrapper so the parser
    handles all types (struct, array, datetime, base64) without us
    re-implementing the marshalling.
    """
    try:
        root = ET.fromstring(body)
    except ET.ParseError as exc:
        raise ValueError(f"XML parse error: {exc}") from exc

    method_name = root.findtext("methodName") or ""
    args: list = []
    for p in root.findall("./params/param"):
        v = p.find("value")
        if v is None:
            args.append(None)
            continue
        wrapper = (
            b"<?xml version='1.0'?><methodResponse><params><param>"
            + ET.tostring(v)
            + b"</param></params></methodResponse>"
        )
        try:
            params, _ = xmlrpc.client.loads(wrapper)
            args.append(params[0])
        except Exception:
            args.append(v.text)
    return method_name, args


def _send_pong_callback(url: str, interface_id: str, caller_id: str) -> None:
    """POST event(interface_id, "", "PONG", caller_id) to the callback URL."""
    try:
        srv = xmlrpc.client.ServerProxy(url, allow_none=True)
        srv.event(interface_id, "", "PONG", caller_id)
        LOG.info("PONG → %s for %s", url, caller_id)
    except Exception as exc:
        LOG.warning("PONG fire failed (url=%s caller_id=%s): %s",
                    url, caller_id, exc)


def _notify_mock_post_pair(upstream: str, secs: int) -> None:
    """Tell rega_session_mock to start its post-pair-refresh thread for
    the given upstream (interface backend).  Used for BidCoS which goes
    via XML-RPC setInstallMode rather than JSON-RPC."""
    import json as _json
    body = _json.dumps({"target": upstream, "secs": secs}).encode("utf-8")
    req = urllib.request.Request(
        "http://127.0.0.1:8765/internal/post-pair",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=5).read()
        LOG.debug("notify mock post-pair OK")
    except Exception as exc:
        LOG.warning("notify mock failed: %s", exc)


class Handler(BaseHTTPRequestHandler):
    upstream_host: str = "127.0.0.1"
    upstream_port: int = 32001
    tx_lock: TxLock | None = None

    def log_message(self, fmt, *args):  # noqa: A003
        LOG.debug("%s %s", self.address_string(), fmt % args)

    def _forward(self, body: bytes) -> tuple[int, bytes]:
        req = urllib.request.Request(
            f"http://{self.upstream_host}:{self.upstream_port}/",
            data=body,
            headers={"Content-Type": "text/xml"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return resp.status, resp.read()
        except Exception as exc:
            LOG.warning("upstream %s:%d failed: %s",
                        self.upstream_host, self.upstream_port, exc)
            fault = (
                b"<?xml version='1.0'?><methodResponse><fault><value><struct>"
                b"<member><name>faultCode</name><value><i4>-1</i4></value></member>"
                b"<member><name>faultString</name><value>Upstream unreachable</value></member>"
                b"</struct></value></fault></methodResponse>"
            )
            return 200, fault

    def _send(self, status: int, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/xml")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        try:
            method, args = _parse_method_call(body)
        except ValueError as exc:
            LOG.debug("body parse failed: %s — blind-forward", exc)
            status, response = self._forward(body)
            self._send(status, response)
            return

        # init(url, interface_id) — cache mapping AND forward
        if method == "init" and len(args) >= 2:
            url, interface_id = str(args[0]), str(args[1])
            if url:
                INIT_URLS[interface_id] = url
                LOG.info("init: %r → %s", interface_id, url)
            else:
                # init with empty URL = deregister
                INIT_URLS.pop(interface_id, None)
                LOG.info("init: %r DEREGISTER", interface_id)
            status, response = self._forward(body)
            self._send(status, response)
            return

        # setInstallMode(on, time, mode_or_addr) — BidCos uses XML-RPC for
        # this (HmIP goes via JSON-RPC mock).  We forward as usual but ALSO
        # tell the mock to start its post-pair-refresh thread so paired
        # devices get auto-confirmed + force-availability applied.
        if method == "setInstallMode" and len(args) >= 2:
            try:
                on_flag = bool(args[0])
                secs = int(args[1])
            except (ValueError, TypeError):
                on_flag, secs = False, 60
            status, response = self._forward(body)
            self._send(status, response)
            if on_flag and secs > 0:
                upstream = f"{self.upstream_host}:{self.upstream_port}"
                threading.Thread(
                    target=_notify_mock_post_pair,
                    args=(upstream, secs),
                    name="notify-mock-post-pair",
                    daemon=True,
                ).start()
                LOG.info("setInstallMode on=True secs=%d → notify mock post-pair (%s)",
                         secs, upstream)
            return

        # ping(caller_id) — short-circuit + async PONG
        if method == "ping" and args:
            caller_id = str(args[0])
            interface_id = caller_id.split("#", 1)[0]
            url = INIT_URLS.get(interface_id)
            if url:
                threading.Thread(
                    target=_send_pong_callback,
                    args=(url, interface_id, caller_id),
                    name="pong-fire",
                    daemon=True,
                ).start()
            else:
                LOG.warning("ping: no cached URL for %r — silent ack",
                            interface_id)
            success = (
                b"<?xml version='1.0'?><methodResponse><params>"
                b"<param><value><boolean>1</boolean></value></param>"
                b"</params></methodResponse>"
            )
            self._send(200, success)
            return

        # Radio-bound calls: one at a time across both shim instances
        if self.tx_lock is not None and self.tx_lock.wants(method, args):
            label = f"{method}({args[0] if args and isinstance(args[0], str) else ''})"
            with self.tx_lock.hold(label):
                status, response = self._forward(body)
            self._send(status, response)
            return

        # Everything else: blind forward
        status, response = self._forward(body)
        self._send(status, response)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen-port", type=int, required=True)
    ap.add_argument("--upstream-port", type=int, required=True)
    ap.add_argument("--upstream-host", default="127.0.0.1")
    ap.add_argument("--name", default="ping-shim")
    ap.add_argument("--tx-lock", default="",
                    help="shared lock file for TX serialization across shim instances ('' = off)")
    ap.add_argument("--tx-guard-ms", type=int, default=20,
                    help="keep the lock this long after the upstream call returned")
    ap.add_argument("--tx-lock-max-wait", type=float, default=3.0,
                    help="seconds to wait for the lock before forwarding unserialized")
    ap.add_argument("--tx-methods", default=",".join(DEFAULT_TX_METHODS),
                    help="comma-separated XML-RPC methods that take the lock")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format=f"[{args.name}] %(asctime)s %(levelname)s %(message)s",
        stream=sys.stderr,
    )

    Handler.upstream_host = args.upstream_host
    Handler.upstream_port = args.upstream_port
    if args.tx_lock:
        Handler.tx_lock = TxLock(args.tx_lock, args.tx_guard_ms, args.tx_lock_max_wait,
                                 [m.strip() for m in args.tx_methods.split(",") if m.strip()])
        LOG.info("tx-lock: %s guard=%d ms max-wait=%.1f s methods=%s", args.tx_lock,
                 args.tx_guard_ms, args.tx_lock_max_wait, ",".join(sorted(Handler.tx_lock.methods)))

    server = ThreadingHTTPServer(("0.0.0.0", args.listen_port), Handler)
    server.allow_reuse_address = True
    LOG.info("listening on :%d → %s:%d",
             args.listen_port, args.upstream_host, args.upstream_port)
    server.serve_forever()


if __name__ == "__main__":
    main()
