/**
 * PaxxMaker Cloudflare Worker — APNs Push Relay
 *
 * Endpoints:
 *   POST /register-device    — iOS app registers APNs device token (alert notifications)
 *   POST /register-activity  — iOS app registers Live Activity push token (progress updates)
 *   POST /update             — Python script on printer sends status → Live Activity push
 *   POST /unregister-device  — iOS app removes device token on printer removal
 *   POST /cleanup            — iOS app removes all KV entries for a secret (printer deletion)
 *   GET  /install            — curl | sh installer (bash + Python bridge embedded)
 *
 * Required Cloudflare secrets (wrangler secret put):
 *   APNS_PRIVATE_KEY  — full .p8 file content including header/footer lines
 *
 * Required environment variables (wrangler.toml [vars]):
 *   APNS_KEY_ID       — 10-char key ID from Apple Developer portal
 *   APNS_TEAM_ID      — 10-char Team ID
 *   APNS_BUNDLE_ID    — e.g. com.paxxmaker.u1
 *
 * Required KV binding (wrangler.toml [[kv_namespaces]]):
 *   TOKENS_KV         — stores tokens per secret
 *
 * KV key format (secret is a 32-char random string, unique per user per printer):
 *   device:{secret}    → JSON array of APNs device tokens (alert push)
 *   activity:{secret}  → JSON array of Live Activity push tokens
 *   locale:{secret}    → preferred locale string (e.g. "de-DE")
 *
 * No secret validation stored in KV — wrong secret simply returns empty arrays,
 * so no pushes are sent. This prevents the "first-secret-wins" lock-out that
 * would occur when many users share the same printer name (e.g. "Snapmaker U1").
 */

export interface Env {
  TOKENS_KV: KVNamespace;
  APNS_PRIVATE_KEY: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
}

// ─── JWT cache (per isolate) ──────────────────────────────────────────────────
let _cachedJWT: string | null = null;
let _jwtCreatedAt = 0;
let _cachedKey: CryptoKey | null = null;

async function getJWT(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (_cachedJWT && now - _jwtCreatedAt < 45 * 60) return _cachedJWT;
  // Das JWT ueber KV zwischen allen Isolates/Colos teilen: Cloudflare verteilt
  // Requests auf viele Instanzen, und wenn jede ihr eigenes JWT signiert,
  // drosselt APNs mit "429 TooManyProviderTokenUpdates" (Apple erwartet
  // Wiederverwendung fuer 20-60 min).
  try {
    const stored = await env.TOKENS_KV.get("jwt:apns");
    if (stored) {
      const { t, iat } = JSON.parse(stored) as { t: string; iat: number };
      if (t && now - iat < 45 * 60) {
        _cachedJWT = t;
        _jwtCreatedAt = iat;
        return t;
      }
    }
  } catch { /* KV-Lesefehler -> unten frisch signieren */ }
  if (!_cachedKey) _cachedKey = await importP8Key(env.APNS_PRIVATE_KEY);
  _cachedJWT = await signJWT(_cachedKey, env.APNS_KEY_ID, env.APNS_TEAM_ID);
  _jwtCreatedAt = now;
  try {
    await env.TOKENS_KV.put("jwt:apns", JSON.stringify({ t: _cachedJWT, iat: now }),
                            { expirationTtl: 45 * 60 });
  } catch { /* best effort */ }
  return _cachedJWT;
}

async function importP8Key(pem: string): Promise<CryptoKey> {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const raw = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    raw.buffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
}

function b64u(buf: ArrayBuffer | Uint8Array): string {
  const b = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  return btoa(Array.from(b, (x) => String.fromCharCode(x)).join(""))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");
}

async function signJWT(key: CryptoKey, kid: string, iss: string): Promise<string> {
  const enc = new TextEncoder();
  const hdr = b64u(enc.encode(JSON.stringify({ alg: "ES256", kid })));
  const pay = b64u(enc.encode(JSON.stringify({ iss, iat: Math.floor(Date.now() / 1000) })));
  const msg = `${hdr}.${pay}`;
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(msg));
  return `${msg}.${b64u(sig)}`;
}

async function getReason(resp: Response): Promise<string | undefined> {
  try { return ((await resp.json()) as { reason?: string }).reason; } catch { return undefined; }
}

// ─── Live Activity push ───────────────────────────────────────────────────────
// contentState must match PaxxMakerWidgetAttributes.ContentState in the iOS app:
//   { printState, progress, extruderTemp, bedTemp, timeElapsed }
async function sendLiveActivityPush(
  env: Env,
  token: string,
  contentState: Record<string, unknown>,
  event: string,
  sandbox: boolean
): Promise<{ ok: boolean; status: number; reason?: string }> {
  const jwt = await getJWT(env);
  const isEnd = event === "complete" || event === "error" || event === "cancelled";
  const now = Math.floor(Date.now() / 1000);

  const payload: Record<string, unknown> = {
    aps: {
      timestamp: now,
      event: isEnd ? "end" : "update",
      "content-state": contentState,
      "stale-date": now + 300,
      ...(isEnd ? { "dismissal-date": now + 30 } : {}),
    },
  };

  const apnsHost = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const resp = await fetch(`https://${apnsHost}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": `${env.APNS_BUNDLE_ID}.push-type.liveactivity`,
      "apns-push-type": "liveactivity",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  if (resp.status === 200) return { ok: true, status: 200 };
  return { ok: false, status: resp.status, reason: await getReason(resp) };
}

// ─── Alert push (for complete/error when app is in background/killed) ─────────
async function sendAlertPush(
  env: Env,
  token: string,
  title: string,
  body: string,
  sandbox: boolean,
  printerId: string,
  event: string
): Promise<{ ok: boolean; status: number }> {
  const jwt = await getJWT(env);
  const payload = {
    aps: {
      alert: { title, body },
      sound: "default",
      "interruption-level": "active",
      "content-available": 1,   // wakes app in background to end matching Live Activity
    },
    printer_id: printerId,
    event,
  };

  const apnsHost = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const resp = await fetch(`https://${apnsHost}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": env.APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600),
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  return { ok: resp.status === 200, status: resp.status };
}

// ─── Dead token filter ────────────────────────────────────────────────────────
const DEAD_REASONS = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "ExpiredToken"]);

// ─── Python bridge script generator (v2 — stable) ────────────────────────────
// Design fixes vs v1:
//   - flock single-instance lock: duplicate starts exit immediately, so no
//     process pile-up can ever crash the printer again
//   - every error is logged (rotating, hard-capped 64 KB on tmpfs)
//   - startup connectivity check makes "nothing arrives" visible instantly
//   - exponential backoff; end events (complete/error/cancelled) are retried
//     for up to 1 h instead of being lost
// NOTE: keep in sync with the reference copy paxxmaker_bridge.py in the repo.
function generatePythonBridge(printerId: string, workerUrl: string, secret: string): string {
  return `#!/usr/bin/env python3
# PaxxMaker Push Bridge v2 (generiert vom Worker-Installer)
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

MOONRAKER_URL = os.getenv("PAXX_MOONRAKER", "http://localhost:7125")
WORKER_URL    = os.getenv("PAXX_WORKER",    "${workerUrl}")
PRINTER_ID    = os.getenv("PAXX_PRINTER",   "${printerId}")
SECRET        = os.getenv("PAXX_SECRET",    "${secret}")
TLS_INSECURE  = os.getenv("PAXX_TLS_INSECURE", "0") == "1"

POLL_PRINTING_S   = 10
POLL_IDLE_S       = 30
HTTP_TIMEOUT_S    = 6
PROG_THRESHOLD    = 0.01
MAX_SILENT_S      = 240
LOCK_FILE         = "/tmp/paxxmaker_bridge.lock"
LOG_FILE          = "/tmp/paxxmaker_bridge.log"

END_EVENTS = ("complete", "error", "cancelled")

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

def acquire_lock():
    fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("PaxxMaker Bridge laeuft bereits — beende mich.")
        sys.exit(0)
    fd.write(str(os.getpid()))
    fd.flush()
    return fd

if TLS_INSECURE:
    _SSL_CTX = ssl._create_unverified_context()
else:
    _SSL_CTX = ssl.create_default_context()
_tls_hint_shown = False

def http_get_json(url):
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT_S) as r:
            return json.loads(r.read())
    except Exception:
        return None

def post_update(payload):
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
            log.error("TLS-Fehler zum Worker: %s — fehlen CA-Zertifikate? "
                      "Notloesung: PAXX_TLS_INSECURE=1", exc)
        else:
            log.warning("TLS-Fehler: %s", exc)
    except urllib.error.HTTPError as exc:
        log.warning("Worker antwortete HTTP %d (%s)", exc.code, exc.reason)
    except Exception as exc:
        log.warning("Worker nicht erreichbar: %s", exc)
    return False

def check_worker():
    # 'ping' an /update (loest KEINE Pushes aus): liefert auch im Standby direkt
    # beim Start das stop-Signal, wenn kein Geraet mehr Push will.
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

running = True
_should_uninstall = False

def _stop(sig, frame):
    global running
    running = False

def interruptible_sleep(seconds):
    end = time.monotonic() + seconds
    while running and time.monotonic() < end:
        time.sleep(1)

def self_uninstall():
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
    os.system("sed -i '/paxxmaker-moonraker/d' \\"%s/config/moonraker.conf\\" 2>/dev/null" % base)
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
        # HUP an deren Prozessgruppe — ohne das stirbt die Bridge nach Autostart.
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
    except (ValueError, AttributeError):
        pass

    log.info("PaxxMaker Bridge v2 startet  printer=%s  worker=%s  secret=%s...",
             PRINTER_ID, WORKER_URL, SECRET[:4])
    check_worker()

    last_state    = None
    last_progress = -1.0
    last_sent_at  = 0.0
    fail_streak   = 0
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
                interruptible_sleep(POLL_IDLE_S)
                continue

            state = s["state"]
            prog  = s["progress"]
            now   = time.monotonic()

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
            log.exception("Unerwarteter Fehler — mache weiter.")
            interruptible_sleep(POLL_IDLE_S)

    log.info("Beendet (Signal).")

if __name__ == "__main__":
    _lock_fd = acquire_lock()
    main()
`;
}

// Progress delta (fraction) at which the bridge sends a new /update. It is
// returned to the bridge in every /update response, so changing it here + a
// Worker deploy retunes push/KV load for ALL printers on their next tick —
// NO bridge reinstall needed. Lower = smoother Live Activity but more load.
const BRIDGE_PROG_THRESHOLD = 0.01;

// ─── Router ───────────────────────────────────────────────────────────────────
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);
    const method = request.method;

    // Ein kompakter Log pro Aufruf (Pfad + Absender): der User-Agent verraet,
    // ob Widget-Extension, Watch-App, iOS-App oder die Drucker-Bridge anfragt —
    // unverzichtbar, um unerklaerliche Request-Bursts zuzuordnen.
    console.log(`req ${method} ${pathname} ua=${(request.headers.get("user-agent") ?? "?").slice(0, 60)}`);

    // POST /register-device — iOS app stores APNs device token
    if (pathname === "/register-device" && method === "POST") {
      const body = await request.json() as Record<string, string>;
      const { device_token, secret } = body;
      if (!device_token || !secret) return new Response("Missing fields", { status: 400 });
      if (!/^[0-9a-f]{64}$/i.test(device_token)) return new Response("Invalid token", { status: 400 });

      const key = `device:${secret}`;
      const tokens: string[] = JSON.parse((await env.TOKENS_KV.get(key)) ?? "[]");
      const norm = device_token.toLowerCase();
      if (!tokens.includes(norm)) tokens.push(norm);
      await env.TOKENS_KV.put(key, JSON.stringify(tokens));
      if (body.locale) {
        await env.TOKENS_KV.put(`locale:${secret}`, (body.locale as string).substring(0, 10));
      }
      if (body.sandbox !== undefined) {
        await env.TOKENS_KV.put(`sandbox:${secret}`, String(body.sandbox === "true" || body.sandbox === true));
      }
      return json({ ok: true, registered: tokens.length });
    }

    // POST /register-activity — iOS app stores Live Activity push token
    if (pathname === "/register-activity" && method === "POST") {
      const body = await request.json() as Record<string, string>;
      const { activity_token, secret } = body;
      if (!activity_token || !secret) return new Response("Missing fields", { status: 400 });

      const key = `activity:${secret}`;
      const tokens: string[] = JSON.parse((await env.TOKENS_KV.get(key)) ?? "[]");
      if (!tokens.includes(activity_token)) tokens.push(activity_token);
      await env.TOKENS_KV.put(key, JSON.stringify(tokens));
      return json({ ok: true, registered: tokens.length });
    }

    // POST /update — Python script on printer sends status updates
    if (pathname === "/update" && method === "POST") {
      const body = await request.json() as Record<string, unknown>;
      const secret    = body.secret as string;
      const printerId = (body.printer_id as string) ?? "";
      const event     = (body.event as string) ?? "progress";
      const state     = (body.state as string) ?? "standby";
      const progress  = (body.progress as number) ?? 0;
      const hotend    = (body.hotend_temp as number) ?? 0;
      const bed       = (body.bed_temp as number) ?? 0;
      const duration  = (body.print_duration as number) ?? 0;
      const filename  = (body.filename as string) ?? "";

      if (!secret) return new Response("Missing fields", { status: 400 });

      const sandbox = (await env.TOKENS_KV.get(`sandbox:${secret}`)) === "true";

      const contentState = {
        printState:   state,
        progress,
        extruderTemp: hotend,
        bedTemp:      bed,
        timeElapsed:  Math.floor(duration),
      };

      const isEnd = event === "complete" || event === "error" || event === "cancelled";

      // ── Send Live Activity push to all registered activity tokens ──────────
      const actKey = `activity:${secret}`;
      const actTokens: string[] = JSON.parse((await env.TOKENS_KV.get(actKey)) ?? "[]");
      let activitySent = 0;

      // "ping" ist nur ein Erreichbarkeits-/stop-Check der Bridge (z. B. beim
      // Start) — nie Pushes ausloesen, sonst wuerde ein Bridge-Neustart mitten
      // im Druck die Live Activity mit standby/0% ueberschreiben.
      if (actTokens.length > 0 && event !== "ping") {
        const results = await Promise.all(
          actTokens.map((t) => sendLiveActivityPush(env, t, contentState, event, sandbox))
        );
        activitySent = results.filter((r) => r.ok).length;
        // Diagnose via `wrangler tail`: jede APNs-Antwort pro Token sichtbar.
        console.log(`LA-push event=${event} state=${state} prog=${progress} sandbox=${sandbox} ` +
          results.map((r, i) => `[${i}] ${r.ok ? "OK" : `FAIL ${r.status} ${r.reason ?? ""}`}`).join(" "));

        const liveTokens = actTokens.filter(
          (_, i) => results[i].ok || !DEAD_REASONS.has(results[i].reason ?? "")
        );
        if (liveTokens.length !== actTokens.length) {
          await env.TOKENS_KV.put(actKey, JSON.stringify(liveTokens));
        }
        // Nach dem Ende-Event sind ALLE Activity-Tokens nutzlos (die Live
        // Activity ist beendet) — immer loeschen. Sonst bleiben sie liegen und
        // kassieren beim naechsten Druck 410 ExpiredToken.
        if (isEnd) {
          await env.TOKENS_KV.delete(actKey);
        }
      }

      // ── For completion/error: send alert push to device tokens ─────────────
      // Dedup against the Moonraker-notifier path (/apprise) — whichever
      // arrives first sends the alert, the other is skipped.
      let alertSent = 0;
      let alertDuplicate = false;
      if (isEnd) {
        const dedupKey = `dedup:${secret}:${event}`;
        if (await env.TOKENS_KV.get(dedupKey)) {
          alertDuplicate = true;
        } else {
          await env.TOKENS_KV.put(dedupKey, "1", { expirationTtl: 120 });
        }
      }
      if (isEnd && !alertDuplicate) {
        const devKey = `device:${secret}`;
        const devTokens: string[] = JSON.parse((await env.TOKENS_KV.get(devKey)) ?? "[]");

        if (devTokens.length > 0) {
          const cleanName = filename.replace(/\.(gcode|gco|g)$/i, "").split("/").pop() ?? filename;
          const locale = (await env.TOKENS_KV.get(`locale:${secret}`)) ?? "de";
          const lang = locale.substring(0, 2).toLowerCase();
          const title =
            event === "complete" ? (lang === "de" ? "Druck fertig ✓" : lang === "fr" ? "Impression terminée ✓" : lang === "es" ? "Impresión lista ✓" : "Print done ✓") :
            event === "error"    ? (lang === "de" ? "Druckfehler"    : lang === "fr" ? "Erreur d'impression" : lang === "es" ? "Error de impresión" : "Print error") :
                                   (lang === "de" ? "Druck abgebrochen" : lang === "fr" ? "Impression annulée" : lang === "es" ? "Impresión cancelada" : "Print cancelled");
          const alertResults = await Promise.all(
            devTokens.map((t) => sendAlertPush(env, t, title, cleanName, sandbox, printerId, event))
          );
          alertSent = alertResults.filter((r) => r.ok).length;
        }
      }

      // Self-shutdown signal: if NO device and NO activity tokens remain for
      // this secret, nobody wants push anymore (user switched to Local) — tell
      // the bridge to uninstall itself. Only computed on ping / end events, NOT
      // on every 1% progress tick: doing the device:/activity: KV reads each
      // tick was the main consumer of the free 100k-reads/day quota. On progress
      // ticks stop stays false (we never want to uninstall mid-print anyway);
      // the bridge learns to stop on its next ping (restart) or end event.
      // Reuses actTokens already read above instead of re-reading activity:.
      let devCount = -1;
      let stop = false;
      if (event === "ping" || event === "started" || isEnd) {
        devCount = JSON.parse((await env.TOKENS_KV.get(`device:${secret}`)) ?? "[]").length;
        const actCount = isEnd ? 0 : actTokens.length;
        stop = devCount === 0 && actCount === 0;
      }

      // NOTE: We no longer persist a per-print `laststatus` snapshot here.
      // Nothing reads it anymore — the Apple Watch and the iOS widget are both
      // Cloudflare-free (they use the app's cache + the mirrored Live Activity).
      // That removes the hot-path KV write (was ~1 per progress tick, i.e. the
      // main consumer of the free 1000-writes/day KV quota) so the Worker scales
      // to a published app on the free tier.

      console.log(`update event=${event} act=${actTokens.length}/sent=${activitySent} alert=${alertSent} dev=${devCount} stop=${stop}`);
      return json({ ok: true, activitySent, alertSent, stop, prog_threshold: BRIDGE_PROG_THRESHOLD });
    }

    // GET /status?secret=X — last-known printer status, for clients that
    // can't reach the printer's LAN directly (widget away from home WiFi,
    // Apple Watch on cellular). Cheap KV read, no APNs calls.
    if (pathname === "/status" && method === "GET") {
      const secret = new URL(request.url).searchParams.get("secret");
      if (!secret) return new Response("Missing secret", { status: 400 });
      const raw = await env.TOKENS_KV.get(`laststatus:${secret}`);
      if (!raw) return new Response("Not found", { status: 404 });
      return new Response(raw, { headers: { "content-type": "application/json" } });
    }

    // POST /unregister-device — iOS app removes device token
    if (pathname === "/unregister-device" && method === "POST") {
      const body = await request.json() as Record<string, string>;
      const { secret, device_token } = body;
      if (!secret || !device_token) return new Response("Missing fields", { status: 400 });
      const key = `device:${secret}`;
      const tokens: string[] = JSON.parse((await env.TOKENS_KV.get(key)) ?? "[]");
      await env.TOKENS_KV.put(key, JSON.stringify(tokens.filter((t) => t !== device_token.toLowerCase())));
      return json({ ok: true });
    }

    // POST /cleanup — iOS app removes all KV entries for a secret (on printer deletion)
    if (pathname === "/cleanup" && method === "POST") {
      const body = await request.json() as Record<string, string>;
      const { secret } = body;
      if (!secret) return new Response("Missing fields", { status: 400 });
      await Promise.all([
        env.TOKENS_KV.delete(`device:${secret}`),
        env.TOKENS_KV.delete(`activity:${secret}`),
        env.TOKENS_KV.delete(`locale:${secret}`),
        env.TOKENS_KV.delete(`sandbox:${secret}`),
        env.TOKENS_KV.delete(`laststatus:${secret}`),
      ]);
      return json({ ok: true });
    }

    // GET /health — connectivity check for the bridge (and for debugging)
    if (pathname === "/health" && method === "GET") {
      return json({ ok: true });
    }

    // POST /setup-complete — one-time confirmation alert after a successful
    // install. Fired by the installer script at the very end; proves the whole
    // chain works (printer → worker → APNs → phone). No-op if the app hasn't
    // registered a device token yet.
    if (pathname === "/setup-complete" && method === "POST") {
      let secret = "";
      try { secret = ((await request.json()) as Record<string, string>).secret ?? ""; } catch { /* empty body */ }
      if (!secret) return new Response("Missing fields", { status: 400 });
      const devTokens: string[] = JSON.parse((await env.TOKENS_KV.get(`device:${secret}`)) ?? "[]");
      if (devTokens.length === 0) return json({ ok: true, alertSent: 0, note: "no device tokens registered" });
      const sandbox = (await env.TOKENS_KV.get(`sandbox:${secret}`)) === "true";
      const results = await Promise.all(
        devTokens.map((t) => sendAlertPush(env, t, "Push setup complete ✓", "Notifications are ready.", sandbox, "", "setup"))
      );
      return json({ ok: true, alertSent: results.filter((r) => r.ok).length });
    }

    // POST /apprise/<secret>/<event> — Moonraker [notifier] endpoint.
    // Moonraker's built-in notifier (apprise jsons:// scheme) POSTs
    // {version,title,message,type} on print events. Config lives in the
    // printer's persistent extended/moonraker dir and is loaded by Moonraker
    // itself on every boot — end-event pushes survive reboots with NO process
    // running on the printer. The bridge (when alive) adds Live Activity
    // progress on top; duplicate end-event alerts are filtered via KV dedup.
    if (pathname.startsWith("/apprise/") && method === "POST") {
      const parts = pathname.split("/").filter(Boolean); // [apprise, secret, event]
      const secret = parts[1];
      const event  = parts[2];
      if (!secret || !event) return new Response("Missing fields", { status: 400 });
      if (!["complete", "error", "cancelled"].includes(event)) return json({ ok: true, skipped: "event" });

      // Dedup with the bridge's /update alert (whichever arrives first wins)
      const dedupKey = `dedup:${secret}:${event}`;
      if (await env.TOKENS_KV.get(dedupKey)) return json({ ok: true, skipped: "duplicate" });
      await env.TOKENS_KV.put(dedupKey, "1", { expirationTtl: 120 });

      let filename = "";
      try {
        const body = await request.json() as Record<string, string>;
        filename = (body.message ?? "").toString();
      } catch { /* empty body is fine */ }

      const devTokens: string[] = JSON.parse((await env.TOKENS_KV.get(`device:${secret}`)) ?? "[]");
      if (devTokens.length === 0) return json({ ok: true, alertSent: 0 });

      const sandbox = (await env.TOKENS_KV.get(`sandbox:${secret}`)) === "true";
      const cleanName = filename.replace(/\.(gcode|gco|g)$/i, "").split("/").pop() ?? filename;
      const locale = (await env.TOKENS_KV.get(`locale:${secret}`)) ?? "de";
      const lang = locale.substring(0, 2).toLowerCase();
      const title =
        event === "complete" ? (lang === "de" ? "Druck fertig ✓" : lang === "fr" ? "Impression terminée ✓" : lang === "es" ? "Impresión lista ✓" : "Print done ✓") :
        event === "error"    ? (lang === "de" ? "Druckfehler"    : lang === "fr" ? "Erreur d'impression" : lang === "es" ? "Error de impresión" : "Print error") :
                               (lang === "de" ? "Druck abgebrochen" : lang === "fr" ? "Impression annulée" : lang === "es" ? "Impresión cancelada" : "Print cancelled");
      const results = await Promise.all(
        devTokens.map((t) => sendAlertPush(env, t, title, cleanName, sandbox, "", event))
      );

      // (No laststatus snapshot write here anymore — nothing reads it; see the
      // note in /update. Keeps KV writes near zero for a published app.)

      return json({ ok: true, alertSent: results.filter((r) => r.ok).length });
    }

    // GET /install — one-shot POSIX-sh installer (curl | sh)
    // v2: persistent install dir, single-instance-safe start, autostart via
    // systemd → cron watchdog → rc.local (in that order), full cleanup of
    // every mechanism previous installer versions ever created.
    if (pathname === "/install" && method === "GET") {
      const params = new URL(request.url).searchParams;
      const printerId = params.get("id");
      const secret    = params.get("secret");
      if (!printerId || !secret) return new Response("Missing fields", { status: 400 });

      const origin = new URL(request.url).origin;
      const wHost = new URL(request.url).host;
      const py = generatePythonBridge(printerId, origin, secret);
      const installer = `#!/bin/sh
# PaxxMaker Bridge Installer v2
set -u

# --- Persistentes Zielverzeichnis finden (printer_data ueberlebt Neustarts) ---
# /home/*/printer_data deckt Standard-Klipper-Hosts (MainsailOS etc.) ab, auch
# wenn der Installer via sudo als root laeuft (dann ist $HOME=/root).
BASE=""
for d in /home/lava/printer_data "$HOME/printer_data" /home/*/printer_data "$HOME"; do
  if [ -d "$d" ]; then BASE="$d"; break; fi
done
if [ -z "$BASE" ]; then BASE="$HOME"; fi
SCRIPT="$BASE/paxxmaker_bridge.py"
PY="$(command -v python3 || echo /usr/bin/python3)"
# Besitzer des Zielverzeichnisses — die systemd-Unit laeuft als dieser User,
# damit die Bridge (chmod 600) sie auch lesen darf.
OWNER="$(stat -c '%U' "$BASE" 2>/dev/null || echo root)"
echo "[PaxxMaker] Installiere nach $SCRIPT (User: $OWNER)"

# --- Alte Instanzen stoppen, ALLE alten Mechanismen restlos entfernen ---
pkill -f paxxmaker_bridge.py 2>/dev/null || true
rm -f "$BASE/paxxmaker_start.sh" 2>/dev/null || true
rm -f "$BASE/config/extended/moonraker/paxxmaker.cfg" 2>/dev/null || true
sed -i '/paxxmaker\\.cfg/d' "$BASE/config/printer.cfg" 2>/dev/null || true
rm -f "$BASE/config/paxxmaker.cfg" 2>/dev/null || true
rm -f /home/lava/klipper/klippy/extras/paxxmaker_autostart.py 2>/dev/null || true
rm -f /home/lava/moonraker/moonraker/components/paxxmaker.py 2>/dev/null || true
rm -f /home/lava/moonraker/moonraker/components/__pycache__/paxxmaker*.pyc 2>/dev/null || true
rm -f /etc/init.d/S99paxxmaker 2>/dev/null || true
rm -f /oem/.debug 2>/dev/null || true
for SP_F in /oem/apps/*/venv/lib/python3*/site-packages/sitecustomize.py; do
  grep -q PaxxMaker "$SP_F" 2>/dev/null && rm -f "$SP_F"
done
rm -f /tmp/paxxmaker.log /tmp/paxxmaker_bridge.log 2>/dev/null || true
if command -v crontab >/dev/null 2>&1; then
  crontab -l 2>/dev/null | grep -v paxxmaker_bridge | crontab - 2>/dev/null || true
fi

# --- Bridge-Script schreiben (600: enthaelt das Secret) ---
cat > "$SCRIPT" << 'PYEOF'
${py}
PYEOF
chmod 600 "$SCRIPT"
# Dem Verzeichnis-Besitzer geben, damit die als $OWNER laufende systemd-Unit
# das (600er) Script lesen kann — wichtig wenn wir via sudo als root schreiben.
chown "$OWNER" "$SCRIPT" 2>/dev/null || true

# --- Autostart: systemd -> SysV-init.d -> cron-Watchdog -> rc.local ---
# Der flock im Script macht jeden Mechanismus doppelstart-sicher.
METHOD=none
if command -v systemctl >/dev/null 2>&1 && [ -w /etc/systemd/system ]; then
  cat > /etc/systemd/system/paxxmaker-bridge.service << UNITEOF
[Unit]
Description=PaxxMaker Push Bridge
After=network-online.target moonraker.service
Wants=network-online.target
# Wenn die Bridge sich selbst deinstalliert hat (ohne root kann sie diese Unit
# nicht entfernen), bleibt die Unit einfach stumm statt ins Leere zu starten.
ConditionPathExists=$SCRIPT

[Service]
User=$OWNER
ExecStart=$PY $SCRIPT
# on-failure statt always: die Bridge beendet sich absichtlich mit Exit 0,
# wenn kein Geraet mehr registriert ist (Selbst-Deinstallation) — dann darf
# systemd sie nicht wieder hochziehen.
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNITEOF
  if systemctl daemon-reload && systemctl enable --now paxxmaker-bridge; then
    METHOD=systemd
  fi
fi
if [ "$METHOD" = "none" ] && grep -q "/oem/.debug" /etc/init.d/S01aoverlayfs 2>/dev/null; then
  # Snapmaker U1 (paxx12-Firmware): das rootfs-Overlay wird bei jedem Boot
  # geleert — /etc ist NICHT persistent, ein init.d-Autostart ist hier zwecklos.
  # (Das /oem/.debug-Persistenz-Flag setzen wir bewusst NICHT: es friert auch
  # Systemdateien wie die WLAN-Konfiguration ein und stoert deren Neuaufbau.)
  # Persistent sind /oem und printer_data. Wenn OctoEverywhere aktiv ist,
  # startet dessen Daemon bei jedem Boot aus /oem — ein sitecustomize.py in
  # seinem venv (Python laedt das automatisch beim Interpreter-Start) zieht
  # die Bridge mit hoch.
  # Hook in JEDE Boot-gestartete App unter /oem/apps (aktuell nur
  # OctoEverywhere via S99cloud, aber zukunftssicher falls paxx12 weitere
  # Apps mit venv hinzufuegt). Fremde sitecustomize.py werden NIE angefasst.
  for SP in /oem/apps/*/venv/lib/python3*/site-packages; do
    [ -d "$SP" ] || continue
    if [ -f "$SP/sitecustomize.py" ] && ! grep -q PaxxMaker "$SP/sitecustomize.py" 2>/dev/null; then
      continue  # gehoert einer anderen App — nicht ueberschreiben
    fi
    cat > "$SP/sitecustomize.py" << 'SCEOF'
# PaxxMaker: startet die Push-Bridge mit, wenn die Host-App bootet.
# Die Bridge verhindert Doppelstarts selbst per flock.
try:
    import subprocess
    subprocess.Popen(
        ["/usr/bin/python3", "SCRIPT_PATH_PLACEHOLDER"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True)
except Exception:
    pass
SCEOF
    sed -i "s#SCRIPT_PATH_PLACEHOLDER#$SCRIPT#" "$SP/sitecustomize.py"
    METHOD="app-hook: $SP"
  done
fi
if [ "$METHOD" = "none" ] && [ -d /etc/init.d ] && [ -w /etc/init.d ] \\
   && ! grep -q "/oem/.debug" /etc/init.d/S01aoverlayfs 2>/dev/null; then
  # BusyBox/Buildroot SysV-Init mit persistentem /etc: rcS startet S??-Skripte
  cat > /etc/init.d/S99paxxmaker << INITEOF
#!/bin/sh
#
# Start/stop PaxxMaker push bridge
#
SCRIPT=$SCRIPT
PY=$PY

case "\\$1" in
  start)
    [ -f "\\$SCRIPT" ] || exit 0
    # In einer Subshell + abgekoppeltem stdin starten. (Kein start-stop-daemon:
    # dessen -x /usr/bin/python3 wuerde Klipper/Moonraker als "laeuft schon"
    # fehl-erkennen und den Start verweigern.) Doppelstarts verhindert der flock.
    ( "\\$PY" "\\$SCRIPT" </dev/null >/dev/null 2>&1 & )
    ;;
  stop)
    pkill -f paxxmaker_bridge.py 2>/dev/null
    ;;
  restart)
    "\\$0" stop
    sleep 1
    "\\$0" start
    ;;
  *)
    echo "Usage: \\$0 {start|stop|restart}"
    ;;
esac
exit 0
INITEOF
  chmod 755 /etc/init.d/S99paxxmaker && METHOD=init.d
fi
if [ "$METHOD" = "none" ] && command -v crontab >/dev/null 2>&1 && [ -d /var/spool/cron ]; then
  if ( crontab -l 2>/dev/null | grep -v paxxmaker_bridge ; \\
       echo "*/5 * * * * $PY $SCRIPT >/dev/null 2>&1" ) | crontab - ; then
    METHOD=cron
  fi
fi
if [ "$METHOD" = "none" ] && [ -w /etc/rc.local ]; then
  sed -i '/paxxmaker_bridge/d' /etc/rc.local 2>/dev/null || true
  if grep -q '^exit 0' /etc/rc.local; then
    sed -i "s#^exit 0#$PY $SCRIPT >/dev/null 2>\\&1 \\&\\nexit 0#" /etc/rc.local && METHOD=rc.local
  else
    echo "$PY $SCRIPT >/dev/null 2>&1 &" >> /etc/rc.local && METHOD=rc.local
  fi
fi

# --- Reboot-feste Fertig/Fehler/Abbruch-Pushes via Moonrakers [notifier] ---
# Moonraker laedt diese Config bei jedem Boot selbst aus dem persistenten
# extended-Ordner — die wichtigsten Pushes funktionieren damit auch dann,
# wenn die Bridge (Live-Activity-Fortschritt) gerade nicht laeuft.
NOTIF=""
if grep -q "extended/moonraker" "$BASE/config/moonraker.conf" 2>/dev/null; then
  # paxx12 (Snapmaker U1): laedt extended/moonraker/*.cfg automatisch
  mkdir -p "$BASE/config/extended/moonraker"
  NOTIF="$BASE/config/extended/moonraker/paxxmaker.cfg"
elif [ -f "$BASE/config/moonraker.conf" ]; then
  # Standard-Klipper (MainsailOS etc.): eigene Datei + [include] in moonraker.conf
  NOTIF="$BASE/config/paxxmaker-moonraker.conf"
fi
if [ -n "$NOTIF" ]; then
  cat > "$NOTIF" << NOTIFEOF
# PaxxMaker: Push bei Druckende — von Moonraker selbst gesendet.
[notifier paxxmaker_complete]
url: jsons://${wHost}/apprise/${secret}/complete
events: complete
body: {event_args[1].filename}

[notifier paxxmaker_error]
url: jsons://${wHost}/apprise/${secret}/error
events: error
body: {event_args[1].filename}

[notifier paxxmaker_cancelled]
url: jsons://${wHost}/apprise/${secret}/cancelled
events: cancelled
body: {event_args[1].filename}
NOTIFEOF
  chown "$OWNER" "$NOTIF" 2>/dev/null || true
  # Standard-Klipper: Include-Zeile in moonraker.conf ergaenzen (einmalig)
  if [ "$NOTIF" = "$BASE/config/paxxmaker-moonraker.conf" ] \\
     && ! grep -q "paxxmaker-moonraker" "$BASE/config/moonraker.conf"; then
    printf '\\n[include paxxmaker-moonraker.conf]\\n' >> "$BASE/config/moonraker.conf"
  fi
  MRC=""
  command -v curl >/dev/null 2>&1 && MRC=curl
  [ -z "$MRC" ] && [ -x /usr/local/bin/curl ] && MRC=/usr/local/bin/curl
  if [ -n "$MRC" ]; then
    if $MRC -s "http://localhost:7125/printer/objects/query?print_stats" 2>/dev/null | grep -q '"state": *"printing"'; then
      echo "[PaxxMaker] Druck laeuft — Moonraker-Neustart uebersprungen; Notifier ab dem naechsten Moonraker-Start aktiv."
    else
      $MRC -s -X POST http://localhost:7125/server/restart >/dev/null 2>&1 || true
      echo "[PaxxMaker] Fertig/Fehler-Pushes via Moonraker-Notifier eingerichtet (reboot-fest)."
    fi
  fi
fi

# --- Sofort starten (Subshell + abgekoppeltes stdin; Lock verhindert Doppelstart) ---
# Bei systemd laeuft die Bridge bereits via "enable --now" — und zwar als
# $OWNER, nicht als root. Kein zweiter (root-)Start noetig.
if [ "$METHOD" != "systemd" ]; then
  ( "$PY" "$SCRIPT" </dev/null >/dev/null 2>&1 & )
fi
sleep 3

if pgrep -f paxxmaker_bridge.py >/dev/null 2>&1; then
  echo "[PaxxMaker] Bridge laeuft."
else
  echo "[PaxxMaker] WARNUNG: Bridge laeuft nicht! Log pruefen: cat /tmp/paxxmaker_bridge.log"
fi
echo "[PaxxMaker] Bridge-Autostart: $METHOD"
if [ "$METHOD" = "none" ]; then
  echo "[PaxxMaker] Hinweis: Kein Bridge-Autostart verfuegbar. Fertig/Fehler-Pushes"
  echo "[PaxxMaker] funktionieren trotzdem dauerhaft (Moonraker-Notifier). Fuer"
  echo "[PaxxMaker] Live-Activity-Fortschritt nach einem Drucker-Neustart diesen"
  echo "[PaxxMaker] Installer einfach erneut ausfuehren."
fi
echo "[PaxxMaker] Log ansehen:  cat /tmp/paxxmaker_bridge.log"

# --- Einmalige Bestaetigungs-Push (testet die ganze Kette) ---
CURL=""
command -v curl >/dev/null 2>&1 && CURL=curl
[ -z "$CURL" ] && [ -x /usr/local/bin/curl ] && CURL=/usr/local/bin/curl
if [ -n "$CURL" ]; then
  $CURL -s -X POST "${origin}/setup-complete" -H "Content-Type: application/json" -d '{"secret":"${secret}"}' >/dev/null 2>&1 || true
  echo "[PaxxMaker] Bestaetigungs-Push gesendet (sofern ein Geraet registriert ist)."
fi
`;
      return new Response(installer, { headers: { "content-type": "text/plain; charset=utf-8" } });
    }

    // GET /uninstall — one-shot POSIX-sh uninstaller (curl | sh). Removes every
    // artifact any installer version ever created. Uses a Moonraker restart
    // instead of `reboot` so it works when triggered over SSH from the app.
    if (pathname === "/uninstall" && method === "GET") {
      const uninstaller = `#!/bin/sh
BASE=""
for d in /home/lava/printer_data "$HOME/printer_data" /home/*/printer_data "$HOME"; do
  [ -d "$d" ] && { BASE="$d"; break; }
done
[ -z "$BASE" ] && BASE="$HOME"

# Laufende Bridge stoppen
pkill -f paxxmaker_bridge.py 2>/dev/null || true

# Autostart entfernen (alle Mechanismen)
systemctl disable --now paxxmaker-bridge 2>/dev/null || true
rm -f /etc/systemd/system/paxxmaker-bridge.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
rm -f /etc/init.d/S99paxxmaker 2>/dev/null || true
rm -f /oem/.debug 2>/dev/null || true
for SP_F in /oem/apps/*/venv/lib/python3*/site-packages/sitecustomize.py; do
  grep -q PaxxMaker "$SP_F" 2>/dev/null && rm -f "$SP_F"
done
if command -v crontab >/dev/null 2>&1; then
  crontab -l 2>/dev/null | grep -v paxxmaker_bridge | crontab - 2>/dev/null || true
fi
sed -i '/paxxmaker_bridge/d' /etc/rc.local 2>/dev/null || true

# Bridge-Script + Moonraker-Notifier
rm -f "$BASE/paxxmaker_bridge.py" 2>/dev/null || true
rm -f "$BASE/config/extended/moonraker/paxxmaker.cfg" 2>/dev/null || true
rm -f "$BASE/config/paxxmaker-moonraker.conf" 2>/dev/null || true
sed -i '/paxxmaker-moonraker/d' "$BASE/config/moonraker.conf" 2>/dev/null || true

# Reste aelterer Versionen
rm -f "$BASE/paxxmaker_start.sh" 2>/dev/null || true
rm -f "$BASE/config/paxxmaker.cfg" 2>/dev/null || true
sed -i '/paxxmaker\\.cfg/d' "$BASE/config/printer.cfg" 2>/dev/null || true
rm -f /home/lava/klipper/klippy/extras/paxxmaker_autostart.py 2>/dev/null || true
rm -f /home/lava/moonraker/moonraker/components/paxxmaker.py 2>/dev/null || true

# Temporaere Dateien
rm -f /tmp/paxxmaker.log /tmp/paxxmaker_bridge.log /tmp/paxxmaker_bridge.lock 2>/dev/null || true

# Moonraker neu laden, damit der Notifier sofort verschwindet (kein reboot noetig)
# — aber nicht mitten in einem laufenden Druck (kurzer Verbindungsabriss der
# Web-UI moeglich); dann greift die Bereinigung erst beim naechsten
# Moonraker-Start von selbst.
CURL=""
command -v curl >/dev/null 2>&1 && CURL=curl
[ -z "$CURL" ] && [ -x /usr/local/bin/curl ] && CURL=/usr/local/bin/curl
if [ -n "$CURL" ]; then
  if $CURL -s "http://localhost:7125/printer/objects/query?print_stats" 2>/dev/null | grep -q '"state": *"printing"'; then
    echo "[PaxxMaker] Druck laeuft — Moonraker-Neustart uebersprungen; Notifier-Entfernung greift ab dem naechsten Moonraker-Start."
  else
    $CURL -s -X POST http://localhost:7125/server/restart >/dev/null 2>&1 || true
  fi
fi

echo "[PaxxMaker] Deinstallation abgeschlossen."
`;
      return new Response(uninstaller, { headers: { "content-type": "text/plain; charset=utf-8" } });
    }

    return new Response("Not found", { status: 404 });
  },
};

function json(data: unknown): Response {
  return new Response(JSON.stringify(data), { headers: { "content-type": "application/json" } });
}
