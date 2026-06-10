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
  if (!_cachedKey) _cachedKey = await importP8Key(env.APNS_PRIVATE_KEY);
  _cachedJWT = await signJWT(_cachedKey, env.APNS_KEY_ID, env.APNS_TEAM_ID);
  _jwtCreatedAt = now;
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

// ─── Python bridge script generator ──────────────────────────────────────────
function generatePythonBridge(printerId: string, workerUrl: string, secret: string): string {
  return [
    "#!/usr/bin/env python3",
    "# PaxxMaker Push Bridge",
    "import urllib.request, urllib.error, json, time, signal, sys",
    "",
    `MOONRAKER_HOST = "http://localhost:7125"`,
    `WORKER_URL     = "${workerUrl}"`,
    `PRINTER_ID     = "${printerId}"`,
    `SECRET         = "${secret}"`,
    "",
    "POLL_PRINTING  = 10",
    "POLL_IDLE      = 60",
    "TIMEOUT        = 5",
    "PROG_THRESHOLD = 0.01",
    "",
    "running = True",
    "last_state = None",
    "last_progress = -1",
    "",
    "def stop(sig, frame):",
    "    global running",
    "    running = False",
    "",
    "signal.signal(signal.SIGTERM, stop)",
    "signal.signal(signal.SIGINT,  stop)",
    "",
    "def get(url):",
    "    try:",
    "        with urllib.request.urlopen(url, timeout=TIMEOUT) as r:",
    "            return json.loads(r.read())",
    "    except:",
    "        return None",
    "",
    "def post(data):",
    "    try:",
    "        b = json.dumps(data).encode()",
    `        req = urllib.request.Request(WORKER_URL + "/update", data=b, method="POST")`,
    `        req.add_header("Content-Type", "application/json")`,
    "        with urllib.request.urlopen(req, timeout=TIMEOUT):",
    "            pass",
    "    except:",
    "        pass",
    "",
    "def get_status():",
    `    r = get(f"{MOONRAKER_HOST}/printer/objects/query?print_stats&virtual_sdcard&extruder&heater_bed")`,
    "    if not r:",
    "        return None",
    `    s  = r.get("result", {}).get("status", {})`,
    `    ps = s.get("print_stats", {})`,
    `    vs = s.get("virtual_sdcard", {})`,
    `    ex = s.get("extruder", {})`,
    `    hb = s.get("heater_bed", {})`,
    "    return {",
    `        "state":          ps.get("state", "standby"),`,
    `        "filename":       ps.get("filename", ""),`,
    `        "progress":       vs.get("progress", 0.0),`,
    `        "print_duration": ps.get("print_duration", 0),`,
    `        "hotend_temp":    round(ex.get("temperature", 0), 1),`,
    `        "bed_temp":       round(hb.get("temperature", 0), 1),`,
    "    }",
    "",
    "def send(status, event):",
    "    post({",
    `        "printer_id": PRINTER_ID,`,
    `        "secret":     SECRET,`,
    `        "event":      event,`,
    "        **status",
    "    })",
    "",
    "while running:",
    "    s = get_status()",
    "    if s is None:",
    "        time.sleep(POLL_IDLE)",
    "        continue",
    '    state = s["state"]',
    '    prog  = s["progress"]',
    "    if state != last_state:",
    '        if state == "printing":',
    '            send(s, "started"); last_progress = prog',
    '        elif state == "paused" and last_state == "printing":',
    '            send(s, "paused")',
    '        elif state == "printing" and last_state == "paused":',
    '            send(s, "resumed")',
    '        elif state in ("complete", "error", "cancelled"):',
    '            send(s, state); last_progress = -1',
    '        elif state == "standby" and last_state in ("printing", "paused"):',
    '            send(s, "cancelled"); last_progress = -1',
    "        last_state = state",
    '    elif state == "printing" and abs(prog - last_progress) >= PROG_THRESHOLD:',
    '        send(s, "progress"); last_progress = prog',
    '    time.sleep(POLL_PRINTING if state == "printing" else POLL_IDLE)',
  ].join("\n");
}

// ─── Router ───────────────────────────────────────────────────────────────────
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);
    const method = request.method;

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

      if (actTokens.length > 0) {
        const results = await Promise.all(
          actTokens.map((t) => sendLiveActivityPush(env, t, contentState, event, sandbox))
        );
        activitySent = results.filter((r) => r.ok).length;

        const liveTokens = actTokens.filter(
          (_, i) => results[i].ok || !DEAD_REASONS.has(results[i].reason ?? "")
        );
        if (liveTokens.length !== actTokens.length) {
          await env.TOKENS_KV.put(actKey, JSON.stringify(liveTokens));
        }
        // Clear activity tokens when print ends
        if (isEnd && liveTokens.length === 0) {
          await env.TOKENS_KV.delete(actKey);
        }
      }

      // ── For completion/error: send alert push to device tokens ─────────────
      let alertSent = 0;
      if (isEnd) {
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

      return json({ ok: true, activitySent, alertSent });
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
      ]);
      return json({ ok: true });
    }

    // GET /install — one-shot bash installer (curl | sh)
    if (pathname === "/install" && method === "GET") {
      const params = new URL(request.url).searchParams;
      const printerId = params.get("id");
      const secret    = params.get("secret");
      if (!printerId || !secret) return new Response("Missing fields", { status: 400 });

      const origin = new URL(request.url).origin;
      const py = generatePythonBridge(printerId, origin, secret);
      const installer = [
        "#!/bin/sh",
        "SCRIPT=/home/lava/printer_data/paxxmaker_bridge.py",
        "",
        "cat > $SCRIPT << 'PYEOF'",
        py,
        "PYEOF",
        "",
        "nohup /usr/bin/python3 $SCRIPT > /dev/null 2>&1 &",
        "echo '[PaxxMaker] Bridge gestartet'",
        "",
        "# --- cleanup old approach (previous installs) ---",
        "sed -i '/paxxmaker\\.cfg/d' /home/lava/printer_data/config/printer.cfg 2>/dev/null || true",
        "rm -f /home/lava/printer_data/config/paxxmaker.cfg 2>/dev/null || true",
        "rm -f /home/lava/klipper/klippy/extras/paxxmaker_autostart.py 2>/dev/null || true",
        "rm -f /oem/.debug 2>/dev/null || true",
        "",
        "# --- persistent autostart via Moonraker notifier (stored in printer_data) ---",
        "PAXX_START=/home/lava/printer_data/paxxmaker_start.sh",
        "MR_EXT=/home/lava/printer_data/config/extended/moonraker",
        "",
        "printf '#!/bin/sh\\n' > \"$PAXX_START\"",
        "printf 'pgrep -f paxxmaker_bridge.py > /dev/null 2>&1 || nohup python3 /home/lava/printer_data/paxxmaker_bridge.py > /tmp/paxxmaker.log 2>&1 &\\n' >> \"$PAXX_START\"",
        "printf 'exit 0\\n' >> \"$PAXX_START\"",
        "chmod +x \"$PAXX_START\"",
        "",
        "mkdir -p \"$MR_EXT\"",
        "printf '[notifier paxxmaker_autostart]\\n' > \"$MR_EXT/paxxmaker.cfg\"",
        "printf 'url: exec:///home/lava/printer_data/paxxmaker_start.sh\\n' >> \"$MR_EXT/paxxmaker.cfg\"",
        "printf 'events: started,paused,resumed,complete,error,cancelled\\n' >> \"$MR_EXT/paxxmaker.cfg\"",
        "printf 'body: bridge\\n' >> \"$MR_EXT/paxxmaker.cfg\"",
        "",
        "echo '[PaxxMaker] Autostart via Moonraker-Notifier eingerichtet'",
        "echo '[PaxxMaker] Bridge laeuft — nach naechstem Neustart automatisch aktiv'",
      ].join("\n");
      return new Response(installer, { headers: { "content-type": "text/plain; charset=utf-8" } });
    }

    return new Response("Not found", { status: 404 });
  },
};

function json(data: unknown): Response {
  return new Response(JSON.stringify(data), { headers: { "content-type": "application/json" } });
}
