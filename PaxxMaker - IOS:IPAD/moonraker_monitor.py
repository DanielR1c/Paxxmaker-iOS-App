#!/usr/bin/env python3
"""
moonraker_monitor.py
--------------------
Monitors Moonraker (Klipper) print state and POSTs events to a
Cloudflare Worker endpoint.

Requirements: Python 3.7+ standard library ONLY — no pip installs.

Usage:
    python3 moonraker_monitor.py

    Or with the Moonraker venv:
    /home/pi/moonraker-env/bin/python3 moonraker_monitor.py

Configuration: edit the CONSTANTS block below, or set environment variables
    MOONRAKER_URL, WORKER_URL, WORKER_SECRET, PRINTER_ID
"""

# ---------------------------------------------------------------------------
# CONFIGURATION — edit these or override with environment variables
# ---------------------------------------------------------------------------
import os

MOONRAKER_URL   = os.getenv("MOONRAKER_URL",   "http://localhost:7125")
WORKER_URL      = os.getenv("WORKER_URL",       "https://your-worker.your-subdomain.workers.dev/events")
WORKER_SECRET   = os.getenv("WORKER_SECRET",    "change-me-secret")   # sent as Bearer token
PRINTER_ID      = os.getenv("PRINTER_ID",       "snapmaker-u1")        # arbitrary label in payload

POLL_INTERVAL_S       = 5     # seconds between Moonraker status polls
PROGRESS_NOTIFY_S     = 30    # send a progress event at most every N seconds
HTTP_TIMEOUT_S        = 8     # connection + read timeout for all HTTP calls
LOG_FILE              = "/home/pi/moonraker_monitor.log"  # set "" to log to stdout only
LOG_MAX_BYTES         = 512 * 1024   # 512 KB per log file
LOG_BACKUP_COUNT      = 2            # keep 2 rotated files → max ~1.5 MB total on disk
# ---------------------------------------------------------------------------

import json
import logging
import logging.handlers
import sys
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Dict, Optional

# ---------------------------------------------------------------------------
# Logging setup — RotatingFileHandler caps disk usage automatically
# ---------------------------------------------------------------------------

def _build_logger() -> logging.Logger:
    logger = logging.getLogger("moonraker_monitor")
    logger.setLevel(logging.DEBUG)
    fmt = logging.Formatter(
        "%(asctime)s %(levelname)-8s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    # Always log to stdout (journald / systemd picks this up for free)
    sh = logging.StreamHandler(sys.stdout)
    sh.setLevel(logging.INFO)
    sh.setFormatter(fmt)
    logger.addHandler(sh)

    if LOG_FILE:
        try:
            rfh = logging.handlers.RotatingFileHandler(
                LOG_FILE,
                maxBytes=LOG_MAX_BYTES,
                backupCount=LOG_BACKUP_COUNT,
                encoding="utf-8",
            )
            rfh.setLevel(logging.DEBUG)
            rfh.setFormatter(fmt)
            logger.addHandler(rfh)
        except OSError as exc:
            logger.warning("Cannot open log file %s: %s — logging to stdout only", LOG_FILE, exc)

    return logger


log = _build_logger()

# ---------------------------------------------------------------------------
# Moonraker polling
# ---------------------------------------------------------------------------
# Endpoint documentation:
#   GET /printer/objects/query?print_stats&virtual_sdcard&display_status
#
# Response shape (abbreviated):
# {
#   "result": {
#     "status": {
#       "print_stats": {
#         "state":          "standby"|"printing"|"paused"|"complete"|"error"|"cancelled",
#         "filename":       "benchy.gcode",
#         "print_duration": 123.4,   # seconds of actual printing (excludes pauses)
#         "total_duration": 456.7,   # wall-clock seconds since print started
#         "filament_used":  1200.5,  # mm
#         "message":        ""       # error message when state == "error"
#       },
#       "virtual_sdcard": {
#         "progress":       0.42,    # 0.0 – 1.0
#         "file_position":  987654,
#         "file_size":      2345678
#       },
#       "display_status": {
#         "progress":  0.42,         # same value, from M73 or calculated
#         "message":   ""
#       }
#     }
#   }
# }

_MOONRAKER_QUERY = (
    "/printer/objects/query"
    "?print_stats&virtual_sdcard&display_status"
)

# State strings returned by Moonraker / Klipper
_STATE_STANDBY   = "standby"
_STATE_PRINTING  = "printing"
_STATE_PAUSED    = "paused"
_STATE_COMPLETE  = "complete"
_STATE_ERROR     = "error"
_STATE_CANCELLED = "cancelled"

# These are the states we treat as "terminal" — print is no longer running
_TERMINAL_STATES = {_STATE_STANDBY, _STATE_COMPLETE, _STATE_ERROR, _STATE_CANCELLED}


def _http_get_json(url: str, timeout: int = HTTP_TIMEOUT_S) -> Optional[Dict[str, Any]]:
    """
    GET *url* and return the parsed JSON body, or None on any error.
    Uses only urllib.request from the standard library.
    """
    try:
        req = urllib.request.Request(
            url,
            headers={"Accept": "application/json", "User-Agent": "moonraker-monitor/1.0"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return json.loads(raw)
    except urllib.error.HTTPError as exc:
        log.warning("GET %s → HTTP %d %s", url, exc.code, exc.reason)
    except urllib.error.URLError as exc:
        log.warning("GET %s → URLError: %s", url, exc.reason)
    except json.JSONDecodeError as exc:
        log.warning("GET %s → bad JSON: %s", url, exc)
    except OSError as exc:
        log.warning("GET %s → OSError: %s", url, exc)
    return None


def poll_printer_status() -> Optional[Dict[str, Any]]:
    """
    Query Moonraker and return a flat dict of useful fields, or None on failure.
    """
    url = MOONRAKER_URL.rstrip("/") + _MOONRAKER_QUERY
    data = _http_get_json(url)
    if data is None:
        return None

    try:
        status       = data["result"]["status"]
        ps           = status.get("print_stats", {})
        vsd          = status.get("virtual_sdcard", {})
        disp         = status.get("display_status", {})
    except (KeyError, TypeError) as exc:
        log.warning("Unexpected Moonraker response shape: %s", exc)
        return None

    # Prefer virtual_sdcard progress (0–1); fall back to display_status
    progress_raw = vsd.get("progress") or disp.get("progress") or 0.0

    return {
        "state":          ps.get("state", _STATE_STANDBY),
        "filename":       ps.get("filename", ""),
        "print_duration": ps.get("print_duration", 0.0),   # seconds
        "total_duration": ps.get("total_duration", 0.0),   # seconds
        "filament_used":  ps.get("filament_used", 0.0),    # mm
        "error_message":  ps.get("message", ""),
        "progress":       round(progress_raw * 100, 2),    # 0–100 %
        "file_position":  vsd.get("file_position", 0),
        "file_size":      vsd.get("file_size", 0),
    }


# ---------------------------------------------------------------------------
# Cloudflare Worker notification (stdlib HTTPS POST)
# ---------------------------------------------------------------------------
# How urllib.request does a JSON POST over HTTPS:
#
#   1. Encode the dict to bytes with json.dumps + .encode("utf-8").
#   2. Create a Request object with the byte body — urllib infers POST.
#   3. Set Content-Type and Authorization headers.
#   4. Call urlopen() with a timeout.
#   5. Read and discard the response body to release the connection.
#
# TLS is handled transparently by the standard ssl module that ships with
# CPython; no extra packages are needed.

def post_event(event_type: str, printer_status: Dict[str, Any]) -> bool:
    """
    POST a JSON event to the Cloudflare Worker.
    Returns True on HTTP 2xx, False otherwise.
    event_type: one of "started"|"paused"|"resumed"|"error"|"completed"|
                       "cancelled"|"progress"
    """
    payload = {
        "printer_id":     PRINTER_ID,
        "event":          event_type,
        "timestamp":      time.time(),
        "timestamp_iso":  time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        **printer_status,
    }
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")

    req = urllib.request.Request(
        WORKER_URL,
        data=body,
        method="POST",
        headers={
            "Content-Type":  "application/json",
            "Authorization": f"Bearer {WORKER_SECRET}",
            "User-Agent":    "moonraker-monitor/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            resp.read()  # drain body; releases socket
            ok = 200 <= resp.status < 300
            if ok:
                log.info("Event '%s' posted → HTTP %d", event_type, resp.status)
            else:
                log.warning("Event '%s' → unexpected HTTP %d", event_type, resp.status)
            return ok
    except urllib.error.HTTPError as exc:
        log.error("POST event '%s' → HTTP %d %s", event_type, exc.code, exc.reason)
    except urllib.error.URLError as exc:
        log.error("POST event '%s' → URLError: %s", event_type, exc.reason)
    except OSError as exc:
        log.error("POST event '%s' → OSError: %s", event_type, exc)
    return False


# ---------------------------------------------------------------------------
# State-change detection + progress throttle
# ---------------------------------------------------------------------------

class PrintMonitor:
    """
    Tracks print state across polls and fires events only when something
    interesting changes.  All mutable state lives here — no globals.
    """

    def __init__(self) -> None:
        self._last_state:          Optional[str]  = None
        self._last_progress_time:  float          = 0.0
        self._last_filename:       str            = ""
        self._consecutive_errors:  int            = 0
        self._max_poll_errors      = 10  # give up after N consecutive Moonraker failures

    def tick(self, status: Optional[Dict[str, Any]]) -> None:
        """Called every POLL_INTERVAL_S with the latest status (or None on failure)."""
        if status is None:
            self._consecutive_errors += 1
            if self._consecutive_errors == self._max_poll_errors:
                log.error(
                    "Moonraker unreachable after %d consecutive attempts — "
                    "will keep retrying silently.",
                    self._max_poll_errors,
                )
            return

        self._consecutive_errors = 0
        current_state = status["state"]
        now = time.monotonic()

        # --- state-change events ----------------------------------------
        if current_state != self._last_state:
            log.info(
                "State change: %s → %s  (file=%s)",
                self._last_state, current_state, status["filename"],
            )
            event = self._state_to_event(current_state, self._last_state)
            if event:
                post_event(event, status)

            self._last_state = current_state
            self._last_filename = status["filename"]
            # Reset progress timer on any state change so we get a fresh
            # progress notification early in the new state.
            self._last_progress_time = now
            return

        # --- periodic progress while printing or paused -----------------
        if current_state in (_STATE_PRINTING, _STATE_PAUSED):
            if (now - self._last_progress_time) >= PROGRESS_NOTIFY_S:
                post_event("progress", status)
                self._last_progress_time = now

    @staticmethod
    def _state_to_event(
        new_state: str, old_state: Optional[str]
    ) -> Optional[str]:
        """Map a Moonraker state transition to an event name, or None to suppress."""
        if new_state == _STATE_PRINTING:
            # "resumed" if we were paused, otherwise "started"
            return "resumed" if old_state == _STATE_PAUSED else "started"
        if new_state == _STATE_PAUSED:
            return "paused"
        if new_state == _STATE_ERROR:
            return "error"
        if new_state == _STATE_COMPLETE:
            return "completed"
        if new_state == _STATE_CANCELLED:
            return "cancelled"
        # standby → standby or any other transition: no event
        return None


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def run_monitor() -> None:
    """
    Polling loop.  Runs forever; designed to be restarted by systemd on crash.
    Memory footprint stays flat because:
      - No data is accumulated between polls
      - RotatingFileHandler caps disk/log usage
      - HTTP connections are closed after each request (context manager + read())
      - No third-party libraries with large import graphs
    """
    log.info(
        "Starting moonraker_monitor  moonraker=%s  worker=%s  printer=%s",
        MOONRAKER_URL, WORKER_URL, PRINTER_ID,
    )
    monitor = PrintMonitor()

    while True:
        try:
            status = poll_printer_status()
            monitor.tick(status)
        except Exception as exc:  # noqa: BLE001 — catch-all safety net
            # Never let an unhandled exception kill the loop.
            log.exception("Unexpected error in main loop (continuing): %s", exc)

        time.sleep(POLL_INTERVAL_S)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    try:
        run_monitor()
    except KeyboardInterrupt:
        log.info("Interrupted — exiting.")
        sys.exit(0)
