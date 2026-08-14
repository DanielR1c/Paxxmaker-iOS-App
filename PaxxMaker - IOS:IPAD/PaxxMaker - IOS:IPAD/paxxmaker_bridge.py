#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# PaxxMaker Push Bridge v2
# ---------------------------------------------------------------------------
# Laeuft auf dem Drucker, pollt Moonraker und meldet Statusaenderungen an den
# Cloudflare Worker (POST /update). Referenzkopie — die installierte Version
# wird vom Worker-Endpoint GET /install generiert (worker.ts ist die Quelle).
#
# Stabilitaets-Design (Lehren aus v1):
#   - Single-Instance-Lock (flock): mehrfaches Starten (cron, Neustart,
#     Doppel-Install) erzeugt NIE zwei Prozesse — Duplikate beenden sich sofort.
#   - Logging mit harter Groessenbegrenzung (64 KB) nach /tmp (RAM-Disk):
#     kann weder Flash noch RAM voll schreiben.
#   - Jeder Fehler wird geloggt — kein stilles `except: pass` mehr.
#   - Exponentielles Backoff bei Worker-Fehlern; wichtige End-Events
#     (fertig/Fehler/abgebrochen) werden bis zu 1 h lang nachgeliefert.
#   - Speicher flach: nichts akkumuliert, nur Standardbibliothek.
#   - Python 3.7+, keine pip-Installationen.
# ---------------------------------------------------------------------------

import fcntl
import json
import logging
import logging.handlers
import os
import signal
import ssl
import sys
import time
import urllib.error
import urllib.request

# ── Konfiguration (wird vom Installer ersetzt bzw. per Env ueberschrieben) ──
MOONRAKER_URL = os.getenv("PAXX_MOONRAKER", "http://localhost:7125")
WORKER_URL    = os.getenv("PAXX_WORKER",    "https://REPLACED-BY-INSTALLER")
PRINTER_ID    = os.getenv("PAXX_PRINTER",   "REPLACED-BY-INSTALLER")
SECRET        = os.getenv("PAXX_SECRET",    "REPLACED-BY-INSTALLER")
TLS_INSECURE  = os.getenv("PAXX_TLS_INSECURE", "0") == "1"

POLL_PRINTING_S   = 10     # Poll-Intervall waehrend Druck/Pause
POLL_IDLE_S       = 30     # Poll-Intervall im Leerlauf
HTTP_TIMEOUT_S    = 6
PROG_THRESHOLD    = 0.01   # Progress-Event ab 1 % Aenderung
MAX_SILENT_S      = 240    # spaetestens alle 4 min senden (Live Activity stale-date = 5 min)
LOCK_FILE         = "/tmp/paxxmaker_bridge.lock"
LOG_FILE          = "/tmp/paxxmaker_bridge.log"

END_EVENTS = ("complete", "error", "cancelled")

# ── Logging: stdout + rotierendes File, hart gedeckelt ─────────────────────
log = logging.getLogger("paxx")
log.setLevel(logging.INFO)
_fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%m-%d %H:%M:%S")
_sh = logging.StreamHandler(sys.stdout)
_sh.setFormatter(_fmt)
log.addHandler(_sh)
try:
    _fh = logging.handlers.RotatingFileHandler(LOG_FILE, maxBytes=64 * 1024, backupCount=1)
    _fh.setFormatter(_fmt)
    log.addHandler(_fh)
except OSError:
    pass

# ── Single-Instance-Lock: Duplikate beenden sich sofort ────────────────────
def acquire_lock():
    fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("PaxxMaker Bridge laeuft bereits — beende mich.")
        sys.exit(0)
    fd.write(str(os.getpid()))
    fd.flush()
    return fd  # offen halten, sonst faellt der Lock

# ── TLS-Kontext ─────────────────────────────────────────────────────────────
if TLS_INSECURE:
    _SSL_CTX = ssl._create_unverified_context()
else:
    _SSL_CTX = ssl.create_default_context()
_tls_hint_shown = False

# ── HTTP-Helfer ─────────────────────────────────────────────────────────────
def http_get_json(url):
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT_S) as r:
            return json.loads(r.read())
    except Exception as exc:
        log.debug("GET %s fehlgeschlagen: %s", url, exc)
        return None

def post_update(payload):
    """POST an den Worker. Rueckgabe True bei HTTP 2xx. Loggt jeden Fehler.
    Setzt _should_uninstall, wenn der Worker meldet, dass kein Geraet mehr Push will."""
    global _tls_hint_shown, _should_uninstall, PROG_THRESHOLD
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        WORKER_URL.rstrip("/") + "/update", data=body, method="POST",
        headers={"Content-Type": "application/json", "User-Agent": "paxxmaker-bridge/2.0"})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S, context=_SSL_CTX) as r:
            raw = r.read()
            if 200 <= r.status < 300:
                try:
                    resp = json.loads(raw)
                    if resp.get("stop"):
                        _should_uninstall = True
                    # Server-tunable progress threshold: the Worker can retune
                    # push/KV load for ALL printers via its response, no reinstall.
                    t = resp.get("prog_threshold")
                    if isinstance(t, (int, float)) and 0.005 <= t <= 0.5:
                        PROG_THRESHOLD = float(t)
                except Exception:
                    pass
                return True
            return False
    except ssl.SSLError as exc:
        if not _tls_hint_shown:
            _tls_hint_shown = True
            log.error("TLS-Fehler zum Worker: %s — fehlen CA-Zertifikate auf dem "
                      "Drucker? Notloesung: PAXX_TLS_INSECURE=1 setzen.", exc)
        else:
            log.warning("TLS-Fehler: %s", exc)
    except urllib.error.HTTPError as exc:
        log.warning("Worker antwortete HTTP %d (%s)", exc.code, exc.reason)
    except Exception as exc:
        log.warning("Worker nicht erreichbar: %s", exc)
    return False

def check_worker():
    """Einmaliger Verbindungstest beim Start — macht Fehler sofort sichtbar.
    Geht als 'ping' an /update (loest KEINE Pushes aus): so erfaehrt die Bridge
    auch im Standby direkt beim Start, ob ueberhaupt noch ein Geraet Push will
    (stop:true -> Selbst-Deinstallation), nicht erst beim naechsten Druck."""
    global _should_uninstall
    if post_update({"printer_id": PRINTER_ID, "secret": SECRET, "event": "ping"}):
        log.info("Worker erreichbar.")
        if _should_uninstall:
            # Gnadenfrist: Direkt nach der App-Installation kann der Geraete-
            # Token noch unterwegs sein. Erst nach 60 s erneut pruefen.
            log.info("Kein Geraet registriert — pruefe in 60 s erneut.")
            _should_uninstall = False
            time.sleep(60)
            post_update({"printer_id": PRINTER_ID, "secret": SECRET, "event": "ping"})
    else:
        log.error("Worker-Verbindungstest FEHLGESCHLAGEN — siehe Meldung oben.")

# ── Moonraker-Status ────────────────────────────────────────────────────────
def get_status():
    r = http_get_json(MOONRAKER_URL.rstrip("/") +
                      "/printer/objects/query?print_stats&display_status&virtual_sdcard&toolhead&extruder&extruder1&extruder2&extruder3&heater_bed")
    if not r:
        return None
    s  = r.get("result", {}).get("status", {})
    ps = s.get("print_stats", {}) or {}
    ds = s.get("display_status", {}) or {}
    vs = s.get("virtual_sdcard", {}) or {}
    hb = s.get("heater_bed", {}) or {}
    # Match the app: prefer display_status.progress (honors M73 slicer
    # commands, what Mainsail/Klipper show), fall back to virtual_sdcard.
    dispProg = ds.get("progress")
    progress = float(dispProg) if dispProg is not None else float(vs.get("progress") or 0.0)
    # Report the ACTIVE nozzle's temperature (toolhead.extruder) instead of
    # always extruder0 — matches the nozzle the app/widget highlight as in use.
    # If the active nozzle can't be determined, use the hottest one (same
    # fallback the app uses). Single-nozzle printers just report "extruder".
    active_name = (s.get("toolhead", {}) or {}).get("extruder")
    active = (s.get(active_name, {}) or {}) if active_name else {}
    if active.get("temperature") is not None:
        active_temp = float(active["temperature"])
    else:
        temps = [float((s.get(k) or {}).get("temperature"))
                 for k in ("extruder", "extruder1", "extruder2", "extruder3")
                 if (s.get(k) or {}).get("temperature") is not None]
        active_temp = max(temps) if temps else 0.0
    return {
        "state":          ps.get("state", "standby"),
        "filename":       ps.get("filename", "") or "",
        "progress":       round(progress, 4),
        "print_duration": ps.get("print_duration", 0) or 0,
        "hotend_temp":    round(float(active_temp), 1),
        "bed_temp":       round(float(hb.get("temperature") or 0.0), 1),
    }

# ── Hauptlogik ──────────────────────────────────────────────────────────────
running = True
_should_uninstall = False   # vom Worker gesetzt, wenn kein Geraet mehr Push will

def _stop(sig, frame):
    global running
    running = False

def interruptible_sleep(seconds):
    end = time.monotonic() + seconds
    while running and time.monotonic() < end:
        time.sleep(1)

def self_uninstall():
    """Entfernt Bridge, Autostart und Moonraker-Notifier — der Nutzer hat auf
    'Lokal' geschaltet, also will kein Geraet mehr Push. So verbrauchen wir
    keine Worker-Anfragen mehr, egal ob die App das Script per SSH loeschen
    konnte oder nicht."""
    import glob
    log.info("Kein Geraet mehr registriert — Bridge entfernt sich selbst.")
    script = os.path.abspath(__file__)
    base = os.path.dirname(script)
    targets = [script,
               os.path.join(base, "config/extended/moonraker/paxxmaker.cfg"),
               os.path.join(base, "config/paxxmaker-moonraker.conf"),
               "/etc/init.d/S99paxxmaker",
               "/tmp/paxxmaker_bridge.log", "/tmp/paxxmaker_bridge.lock"]
    # Autostart-Hooks in allen App-venvs — aber nur unsere eigenen (Marker)
    for f in glob.glob("/oem/apps/*/venv/lib/python3*/site-packages/sitecustomize.py"):
        try:
            with open(f) as fh:
                if "PaxxMaker" in fh.read():
                    targets.append(f)
        except OSError:
            pass
    for f in targets:
        try: os.remove(f)
        except OSError: pass
    # systemd-Autostart entfernen (nur mit root-Rechten erfolgreich; laeuft die
    # Bridge als normaler User, genuegt das Loeschen des Scripts oben — der
    # anschliessende Prozess-Exit stoppt jegliche weitere Cloudflare-Requests).
    os.system("systemctl disable --now paxxmaker-bridge 2>/dev/null; "
              "rm -f /etc/systemd/system/paxxmaker-bridge.service 2>/dev/null; "
              "systemctl daemon-reload 2>/dev/null; "
              "crontab -l 2>/dev/null | grep -v paxxmaker_bridge | crontab - 2>/dev/null; "
              "sed -i '/paxxmaker_bridge/d' /etc/rc.local 2>/dev/null")
    os.system("sed -i '/paxxmaker-moonraker/d' \"%s/config/moonraker.conf\" 2>/dev/null" % base)
    # Moonraker neu laden, damit der Notifier sofort verschwindet
    try:
        r = urllib.request.Request(MOONRAKER_URL.rstrip("/") + "/server/restart", method="POST")
        urllib.request.urlopen(r, timeout=HTTP_TIMEOUT_S)
    except Exception:
        pass

def main():
    try:
        signal.signal(signal.SIGTERM, _stop)
        signal.signal(signal.SIGINT, _stop)
        # SIGHUP ignorieren: beim Boot beendet init die rcS-Sitzung und schickt
        # HUP an deren Prozessgruppe — ohne das hier stirbt die Bridge sofort
        # nach dem Autostart.
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
    except (ValueError, AttributeError):
        pass  # nicht im Main-Thread (z.B. Testumgebung) — ohne Signale weiter

    log.info("PaxxMaker Bridge v2 startet  printer=%s  worker=%s  secret=%s...",
             PRINTER_ID, WORKER_URL, SECRET[:4])
    check_worker()

    last_state    = None
    last_progress = -1.0
    last_sent_at  = 0.0
    fail_streak   = 0
    # Wichtiges Event, das noch nicht durchkam: (event, status, deadline)
    pending       = None

    def send(event, status, important):
        nonlocal fail_streak, pending
        ok = post_update({"printer_id": PRINTER_ID, "secret": SECRET,
                          "event": event, **status})
        if ok:
            fail_streak = 0
            if pending and pending[0] == event:
                pending = None
            log.info("Event '%s' gesendet (state=%s, %.0f%%).",
                     event, status["state"], status["progress"] * 100)
        else:
            fail_streak += 1
            if important:
                pending = (event, status, time.monotonic() + 3600)
                log.warning("Event '%s' nicht zugestellt — versuche es weiter.", event)
        return ok

    while running:
        try:
            s = get_status()
            if s is None:
                # Moonraker (noch) nicht da — ruhig weiter probieren
                interruptible_sleep(POLL_IDLE_S)
                continue

            state = s["state"]
            prog  = s["progress"]
            now   = time.monotonic()

            # Haengendes wichtiges Event nachliefern (mit Backoff via fail_streak)
            if pending and now < pending[2]:
                backoff = min(600, 15 * (2 ** min(fail_streak, 6)))
                if now - last_sent_at >= backoff:
                    last_sent_at = now
                    send(pending[0], pending[1], True)
            elif pending:
                log.warning("Event '%s' nach 1 h aufgegeben.", pending[0])
                pending = None

            if state != last_state:
                event = None
                if state == "printing":
                    event = "resumed" if last_state == "paused" else "started"
                    last_progress = prog
                elif state == "paused" and last_state == "printing":
                    event = "paused"
                elif state in END_EVENTS:
                    event = state
                    last_progress = -1.0
                elif state == "standby" and last_state in ("printing", "paused"):
                    event = "cancelled"
                    last_progress = -1.0
                log.info("Statuswechsel: %s -> %s", last_state, state)
                if event:
                    last_sent_at = now
                    send(event, s, important=event in END_EVENTS or event == "started")
                last_state = state

            elif state == "printing":
                changed = abs(prog - last_progress) >= PROG_THRESHOLD
                stale   = (now - last_sent_at) >= MAX_SILENT_S
                if (changed or stale) and fail_streak < 8:
                    last_sent_at = now
                    if send("progress", s, important=False):
                        last_progress = prog

            if _should_uninstall:
                self_uninstall()
                return

            interruptible_sleep(POLL_PRINTING_S if state in ("printing", "paused")
                                else POLL_IDLE_S)

        except Exception:
            # Sicherheitsnetz: Schleife stirbt nie
            log.exception("Unerwarteter Fehler — mache weiter.")
            interruptible_sleep(POLL_IDLE_S)

    log.info("Beendet (Signal).")

if __name__ == "__main__":
    _lock_fd = acquire_lock()
    main()
