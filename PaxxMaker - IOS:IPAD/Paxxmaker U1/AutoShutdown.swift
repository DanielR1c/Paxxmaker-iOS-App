import Foundation

// MARK: - Auto-Shutdown (smart plug off after a print)
// The work happens on the printer: a small Python daemon polls Moonraker and
// switches the plug off once a print ends. Everything stays on the local
// network — the script and its settings (including the Tuya local key) are
// uploaded straight to the printer via Moonraker, never through any server.
//
// Why the script installs ITSELF (--setup/--remove): Dropbear on the U1 rejects
// long SSH exec requests, so the commands we send have to stay short.
enum AutoShutdownInstaller {

    /// Settings live beside the push bridge's own paxxmaker.cfg, so both
    /// PaxxMaker files a user can see sit in one place.
    /// U1: next to the push bridge's paxxmaker.cfg in extended/moonraker/.
    /// Standard Klipper: straight in the config root, where
    /// paxxmaker-moonraker.conf already lives.
    static func dir(for type: PrinterConfig.PrinterType) -> String {
        type == .snapmakerU1 ? "extended/moonraker" : ""
    }
    /// "<root>/<dir>/<file>" without a double slash when dir is empty.
    static func path(_ dir: String, _ file: String) -> String {
        dir.isEmpty ? file : "\(dir)/\(file)"
    }
    private static let legacyDir = "extended"

    /// Where Moonraker really keeps its config. On the U1 that tree
    /// (/oem/printer_data/config) is a different mount from the one the scripts
    /// live in, so deriving it from the script directory pointed at a path that
    /// does not exist — which is why the move and the cleanup silently did
    /// nothing. Falls back to the guess only if Moonraker cannot be asked.
    private static func configRoot(baseURL: String, apiKey: String) async -> String? {
        guard let url = URL(string: "\(baseURL)/server/files/roots") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["result"] as? [[String: Any]] else { return nil }
        return roots.first { ($0["name"] as? String) == "config" }?["path"] as? String
    }
    /// Same search the push-bridge installer uses, so both scripts end up in the
    /// one directory that survives reboots and firmware updates — and outside
    /// the config folder, which Moonraker serves over plain HTTP.
    private static let findBase =
        "B=$(for d in /home/lava/printer_data \"$HOME/printer_data\" /home/*/printer_data \"$HOME\"; "
      + "do [ -d \"$d\" ] && { echo \"$d\"; break; }; done); "
    static let scriptName = "paxxmaker_shutdown.py"
    static let configName = "paxxmaker_shutdown.json"

    struct Settings {
        /// Auto-Shutdown and energy tracking share ONE daemon: a Tuya plug
        /// accepts a single connection at a time, so two pollers would lock
        /// each other out. Each feature has its own flag here.
        var shutdownEnabled: Bool
        var trackEnergy: Bool
        var pricePerKWh: Double
        var currency: String
        var keepCount: Int
        var delayMinutes: Int
        var onComplete: Bool
        var onCancelled: Bool
        var plugType: PrinterConfig.SmartPlugType
        var plugHost: String
        var deviceID: String
        var localKey: String
        /// "v33" / "v35" as detected by TuyaLocalService, or "auto". Saves the
        /// script from probing — and a wrong guess from looking like success.
        var proto: String

        var json: Data {
            let payload: [String: Any] = [
                "shutdown_enabled": shutdownEnabled,
                "track_energy": trackEnergy,
                "price_per_kwh": pricePerKWh,
                "currency": currency,
                "keep": max(0, keepCount),
                "delay_s": max(0, delayMinutes) * 60,
                "on_complete": onComplete,
                "on_cancelled": onCancelled,
                "plug": [
                    "type": plugType == .shelly ? "shelly" : "tuya",
                    "host": plugHost,
                    "device_id": deviceID,
                    "local_key": localKey,
                    "proto": proto
                ]
            ]
            // sortedKeys: a Swift Dictionary has no order, and its iteration is
            // seeded per process — without this the file came out shuffled on
            // every upload, which makes it impossible to see what changed.
            return (try? JSONSerialization.data(withJSONObject: payload,
                                                options: [.prettyPrinted, .sortedKeys])) ?? Data()
        }
    }

    enum Failure: LocalizedError {
        case upload(String)
        case ssh(String)
        var errorDescription: String? {
            switch self {
            case .upload(let m): return m
            case .ssh(let m):    return m
            }
        }
    }

    /// Upload script + settings, then let the printer install and start them.
    static func install(baseURL: String, apiKey: String, dir: String,
                        host: String, user: String, password: String,
                        settings: Settings) async throws -> String {
        guard await upload(baseURL: baseURL, apiKey: apiKey, dir: dir,
                           filename: scriptName, data: Data(script.utf8)) else {
            throw Failure.upload(lz(en: "Script could not be uploaded — is the printer reachable?", de: "Skript konnte nicht übertragen werden — ist der Drucker erreichbar?", fr: "Le script n'a pas pu être transféré — l'imprimante est-elle joignable ?", es: "No se pudo transferir el script: ¿la impresora está accesible?", pt: "Não foi possível enviar o script — a impressora está acessível?", it: "Impossibile trasferire lo script — la stampante è raggiungibile?", zh: "无法上传脚本——打印机可以连接吗？"))
        }
        guard await upload(baseURL: baseURL, apiKey: apiKey, dir: dir,
                           filename: configName, data: settings.json) else {
            throw Failure.upload(lz(en: "Settings could not be uploaded — is the printer reachable?", de: "Einstellungen konnten nicht übertragen werden — ist der Drucker erreichbar?", fr: "Les réglages n'ont pas pu être transférés — l'imprimante est-elle joignable ?", es: "No se pudieron transferir los ajustes: ¿la impresora está accesible?", pt: "Não foi possível enviar as configurações — a impressora está acessível?", it: "Impossibile trasferire le impostazioni — la stampante è raggiungibile?", zh: "无法上传设置——打印机可以连接吗？"))
        }
        // Moonraker can only write inside config/, so the upload above lands
        // there and this moves the SCRIPT up next to the bridge. The settings
        // stay behind on purpose: there they can be replaced by a plain upload,
        // which is quicker than opening an SSH session for a changed number.
        let cfg = await configRoot(baseURL: baseURL, apiKey: apiKey) ?? "$B/config"
        // Stop the running instance by PID from its lock file instead of
        // pkill -f: that pattern also matches the shell executing THIS command,
        // and on busybox it may take it down mid-way — which would leave the
        // move and everything after it silently undone.
        let cmd = findBase
                + "systemctl stop paxxmaker-shutdown >/dev/null 2>&1; "
                + "K=$(cat /tmp/paxxmaker_shutdown.lock 2>/dev/null); "
                + "[ -n \"$K\" ] && kill \"$K\" 2>/dev/null; "
                + "if mv \"\(cfg)/\(path(dir, scriptName))\" \"$B/\" 2>/dev/null; then M=moved; else M=NOMOVE; fi; "
                + "S=$(python3 \"$B/\(scriptName)\" --setup 2>&1 | head -1); sync; "
                + "nohup python3 \"$B/\(scriptName)\" >/dev/null 2>&1 & "
                + "echo \"base=$B $M $S\""
        return try await SSHInstaller.exec(host: host, user: user, password: password, command: cmd)
    }

    /// Distinguishes "no settings file" from "printer off" — only the former
    /// means the features are gone.
    static func printerReachable(baseURL: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/server/info") else { return false }
        let req = URLRequest(url: url, timeoutInterval: 5)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// What the printer says is set up, applied to a config — so a second
    /// device (installed from the iPhone, opened on the iPad) shows the same
    /// state instead of "not installed". Returns true when anything changed.
    @discardableResult
    static func adopt(_ p: OnPrinter, into config: inout PrinterConfig) -> Bool {
        var c = config
        c.autoShutdownEnabled = p.shutdownEnabled
        c.energyTrackingEnabled = p.trackEnergy
        if p.delaySeconds >= 0 { c.autoShutdownDelayMin = p.delaySeconds / 60 }
        c.autoShutdownOnComplete = p.onComplete
        c.autoShutdownOnCancelled = p.onCancelled
        if let v = p.pricePerKWh { c.energyPricePerKWh = v }
        if let v = p.currency, !v.isEmpty { c.energyCurrency = v }
        if let v = p.keep { c.energyKeepCount = v }
        let changed = c.autoShutdownEnabled != config.autoShutdownEnabled
            || c.energyTrackingEnabled != config.energyTrackingEnabled
            || c.autoShutdownDelayMin != config.autoShutdownDelayMin
            || c.autoShutdownOnComplete != config.autoShutdownOnComplete
            || c.autoShutdownOnCancelled != config.autoShutdownOnCancelled
            || c.energyPricePerKWh != config.energyPricePerKWh
            || c.energyCurrency != config.energyCurrency
            || c.energyKeepCount != config.energyKeepCount
        config = c
        return changed
    }

    /// Replace the settings file and read it back. Without the read-back an
    /// unreachable printer would still look like a successful change, and the
    /// app would then show a delay that only exists on the phone.
    static func updateSettings(baseURL: String, apiKey: String, dir: String,
                               settings: Settings) async throws {
        guard await upload(baseURL: baseURL, apiKey: apiKey, dir: dir,
                           filename: configName, data: settings.json) else {
            throw Failure.upload(lz(en: "Printer not reachable — nothing was changed.", de: "Drucker nicht erreichbar — es wurde nichts geändert.", fr: "Imprimante injoignable — rien n'a été modifié.", es: "Impresora no accesible: no se cambió nada.", pt: "Impressora inacessível — nada foi alterado.", it: "Stampante non raggiungibile — non è stato modificato nulla.", zh: "无法连接打印机——未做任何更改。"))
        }
        guard let onPrinter = await readSettings(baseURL: baseURL, apiKey: apiKey, dir: dir) else {
            throw Failure.upload(lz(en: "Written, but could not be read back from the printer.", de: "Geschrieben, aber vom Drucker nicht zurückgelesen.", fr: "Écrit, mais impossible de le relire depuis l'imprimante.", es: "Escrito, pero no se pudo volver a leer desde la impresora.", pt: "Gravado, mas não foi possível ler de volta da impressora.", it: "Scritto, ma non rileggibile dalla stampante.", zh: "已写入，但无法从打印机读回。"))
        }
        guard onPrinter.delaySeconds == max(0, settings.delayMinutes) * 60,
              onPrinter.onComplete == settings.onComplete,
              onPrinter.onCancelled == settings.onCancelled else {
            throw Failure.upload(lz(en: "The printer still reports different settings.", de: "Der Drucker meldet weiterhin andere Einstellungen.", fr: "L'imprimante indique toujours d'autres réglages.", es: "La impresora sigue informando otros ajustes.", pt: "A impressora ainda informa outras configurações.", it: "La stampante riporta ancora impostazioni diverse.", zh: "打印机仍报告不同的设置。"))
        }
    }

    struct OnPrinter {
        var delaySeconds: Int; var onComplete: Bool; var onCancelled: Bool
        var shutdownEnabled: Bool = true; var trackEnergy: Bool = false
        var pricePerKWh: Double? = nil; var currency: String? = nil; var keep: Int? = nil
    }

    /// Is a cloud app that boots from /oem actually ENABLED? The firmware's
    /// S99cloud starts OctoEverywhere only when extended2.cfg says
    /// "cloud: octoeverywhere" — merely having it installed is not enough, and
    /// our autostart hook rides along with that daemon. nil = could not tell.
    static func octoEverywhereEnabled(baseURL: String, apiKey: String) async -> Bool? {
        guard let url = URL(string: "\(baseURL)/server/files/config/extended/extended2.cfg")
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !line.hasPrefix("#") else { continue }      // the file explains
            if line.hasPrefix("cloud:") { return line.contains("octoeverywhere") }
        }
        return false
    }

    /// What the printer actually has. Source of truth for what this screen shows.
    static func readSettings(baseURL: String, apiKey: String, dir: String) async -> OnPrinter? {
        guard let url = URL(string: "\(baseURL)/server/files/config/\(path(dir, configName))")
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData   // never a stale copy
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return OnPrinter(delaySeconds: (obj["delay_s"] as? Int) ?? -1,
                         onComplete: (obj["on_complete"] as? Bool) ?? false,
                         onCancelled: (obj["on_cancelled"] as? Bool) ?? false,
                         shutdownEnabled: (obj["shutdown_enabled"] as? Bool) ?? true,
                         trackEnergy: (obj["track_energy"] as? Bool) ?? false,
                         pricePerKWh: obj["price_per_kwh"] as? Double,
                         currency: obj["currency"] as? String,
                         keep: obj["keep"] as? Int)
    }

    /// Remove every trace. Deliberately not delegating to the script's own
    /// --remove: if the file is already gone or unreadable, that would leave the
    /// autostart entry and the logs behind. Plain rm covers both locations,
    /// including anything left staged in the config folder.
    static func remove(baseURL: String, apiKey: String, dir: String,
                       host: String, user: String, password: String) async throws -> String {
        let cfg = await configRoot(baseURL: baseURL, apiKey: apiKey) ?? "$B/config"
        let cmd = findBase
                + "systemctl disable --now paxxmaker-shutdown >/dev/null 2>&1; "
                + "K=$(cat /tmp/paxxmaker_shutdown.lock 2>/dev/null); "
                + "[ -n \"$K\" ] && kill \"$K\" 2>/dev/null; "
                + "rm -f /etc/systemd/system/paxxmaker-shutdown.service /etc/init.d/S98paxxshutdown "
                + "/tmp/paxxmaker_shutdown.log /tmp/paxxmaker_shutdown.log.1 /tmp/paxxmaker_shutdown.lock "
                + "\"$B/\(scriptName)\" \"$B/\(configName)\" "
                + "\"\(cfg)/\(path(dir, scriptName))\" \"\(cfg)/\(path(dir, configName))\" "
                + "\"\(cfg)/\(path(dir, "paxxmaker_energy_status.json"))\" "
                + "\"\(cfg)/\(legacyDir)/\(scriptName)\" \"\(cfg)/\(legacyDir)/\(configName)\"; "
                + "systemctl daemon-reload >/dev/null 2>&1; "
                + "L=$(ls \"$B/\(scriptName)\" \"\(cfg)/\(path(dir, scriptName))\" \"\(cfg)/\(path(dir, configName))\" 2>/dev/null | wc -l); "
                + "echo \"base=$B cfg=\(cfg) left=$L\""
        return try await SSHInstaller.exec(host: host, user: user, password: password, command: cmd)
    }

    static func upload(baseURL: String, apiKey: String, dir: String,
                       filename: String, data: Data) async -> Bool {
        guard let url = URL(string: "\(baseURL)/server/files/upload") else { return false }
        let boundary = "----paxx\(UUID().uuidString)"
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(n)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(v)\r\n".data(using: .utf8)!)
        }
        field("root", "config")
        field("path", dir)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return code == 200 || code == 201
    }

    // The printer-side daemon, verified locally: AES against the FIPS-197 vector,
    // CRC32 against zlib, the Tuya v3.3 frame unpacked field by field, and the
    // trigger table against ten state transitions.
    static let script = #"""
#!/usr/bin/env python3
# PaxxMaker Auto-Shutdown — switches the printer's smart plug off after a print.
# Runs entirely on the printer; nothing leaves the local network.
import fcntl, hashlib, hmac, json, logging, logging.handlers, os, re, signal, socket, struct, sys, time
import urllib.request, urllib.parse

HERE        = os.path.dirname(os.path.abspath(__file__))
CONFIG_NAME = "paxxmaker_shutdown.json"
MOONRAKER   = os.getenv("PAXX_MOONRAKER", "http://localhost:7125")
LOCK_FILE   = "/tmp/paxxmaker_shutdown.lock"
LOG_FILE    = "/tmp/paxxmaker_shutdown.log"
POLL_S      = 10

log = logging.getLogger("paxxoff")
log.setLevel(logging.INFO)
_fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%m-%d %H:%M:%S")
_sh = logging.StreamHandler(sys.stdout); _sh.setFormatter(_fmt); log.addHandler(_sh)
try:
    _fh = logging.handlers.RotatingFileHandler(LOG_FILE, maxBytes=32 * 1024, backupCount=1)
    _fh.setFormatter(_fmt); log.addHandler(_fh)
except OSError:
    pass

def acquire_lock():
    fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("PaxxMaker Auto-Shutdown laeuft bereits — beende mich.")
        sys.exit(0)
    fd.write(str(os.getpid())); fd.flush()
    return fd

def load_config():
    with open(config_path()) as f:
        return json.load(f)

def _moonraker_config_root():
    """Ask Moonraker where its config folder actually is. On the U1 the config
    tree (/oem/printer_data/config) and the data tree the script lives in are
    different mounts, so deriving one from the other guesses wrong."""
    try:
        url = MOONRAKER.rstrip("/") + "/server/files/roots"
        with urllib.request.urlopen(url, timeout=6) as r:
            for root in json.loads(r.read()).get("result", []):
                if root.get("name") == "config" and root.get("path"):
                    return root["path"]
    except Exception:
        pass
    return None

def config_path():
    """Settings sit with the push bridge's own paxxmaker.cfg in
    config/extended/moonraker/. The local candidates keep older installs and a
    side-by-side layout working when Moonraker cannot be reached."""
    root = _moonraker_config_root()
    cands = []
    if root:
        cands.append(os.path.join(root, "extended", "moonraker", CONFIG_NAME))
        cands.append(os.path.join(root, CONFIG_NAME))                 # standard Klipper: config root
        cands.append(os.path.join(root, "extended", CONFIG_NAME))     # older installs
    cands += [os.path.join(HERE, "config", "extended", "moonraker", CONFIG_NAME),
              os.path.join(HERE, "config", "extended", CONFIG_NAME),
              os.path.join(HERE, CONFIG_NAME)]                        # side by side
    for c in cands:
        if os.path.exists(c):
            return c
    return cands[0]

def _config_mtime():
    try:
        return os.path.getmtime(config_path())
    except OSError:
        return 0

def _log_settings(cfg):
    log.info("Auto-Shutdown=%s (Verzoegerung %ds, fertig=%s, abgebrochen=%s), "
             "Verbrauchszaehlung=%s, Steckdose=%s",
             cfg.get("shutdown_enabled", True), int(cfg.get("delay_s", 0)),
             cfg.get("on_complete", True), cfg.get("on_cancelled", False),
             cfg.get("track_energy", False), (cfg.get("plug") or {}).get("type", "?"))

def _moonraker(path, headers=None, timeout=6, raw=False):
    try:
        req = urllib.request.Request(MOONRAKER.rstrip("/") + path, headers=headers or {})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read()
        return data if raw else json.loads(data).get("result")
    except Exception:
        return None

def printer_status():
    """State, filename, filament so far and the active tool — the energy log
    needs to know which print it was and what went through which nozzle."""
    res = _moonraker("/printer/objects/query?print_stats&toolhead=extruder")
    if res is None:
        return None
    st = res.get("status", {}) or {}
    ps = st.get("print_stats", {}) or {}
    tool = (st.get("toolhead", {}) or {}).get("extruder") or "extruder"
    return {"state": ps.get("state"),
            "filename": ps.get("filename") or "",
            "duration": ps.get("print_duration") or 0,
            "filament_mm": float(ps.get("filament_used") or 0),
            "tool": 0 if tool == "extruder" else int(tool[8:] or 0)}

def spoolman_spool(spool_id, tries=3):
    """Vendor, name, material and colour of a spool, asked from Spoolman via
    Moonraker's proxy. The Spoolman host is often a second machine on Wi-Fi,
    so one failed answer is retried before giving up on it."""
    body = json.dumps({"request_method": "GET", "path": "/v1/spool/%d" % spool_id,
                       "use_v2_response": True}).encode()
    for attempt in range(tries):
        try:
            req = urllib.request.Request(MOONRAKER.rstrip("/") + "/server/spoolman/proxy", data=body,
                                         headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(req, timeout=8) as r:
                res = json.loads(r.read()).get("result") or {}
            sp = res.get("response") if isinstance(res, dict) and "response" in res else res
            if isinstance(sp, dict) and sp.get("id"):
                f = sp.get("filament") or {}
                vendor = ((f.get("vendor") or {}).get("name") or "")
                color = str(f.get("color_hex") or "")[:6]
                return {"type": str(f.get("material") or ""), "vendor": vendor,
                        "name": str(f.get("name") or ""), "color": color,
                        "spool_id": int(sp["id"]), "source": "spoolman"}
        except Exception as exc:
            log.info("Spoolman-Abfrage Spule %s (%d/%d) fehlgeschlagen: %s", spool_id, attempt + 1, tries, exc)
        time.sleep(2)
    return None

def enrich_channels(channels, spools):
    """Where a channel has a Spoolman spool, its name and colour win over the
    printer's own (often 'Generic PETG') display entry, which stays as
    fallback only."""
    out = [dict(c) for c in channels] if channels else [{"type": "", "vendor": "", "color": ""} for _ in range(4)]
    for ch, sid in (spools or {}).items():
        info = spoolman_spool(sid)
        if info:
            while len(out) <= ch:
                out.append({"type": "", "vendor": "", "color": ""})
            out[ch].update(info)
    return out

def spoolman_channel_map():
    """U1 with the app's 4-colour hook: the channel -> spool table lives in
    the _SPOOLMAN_MAP macro. Reading it once is far more reliable than
    catching the active spool during each tool change."""
    res = _moonraker("/printer/objects/query?gcode_macro%20_SPOOLMAN_MAP") or {}
    m = ((res.get("status") or {}).get("gcode_macro _SPOOLMAN_MAP") or {})
    out = {}
    for i in range(4):
        try:
            sid = int(m.get("spool%d" % i) or 0)
        except (TypeError, ValueError):
            sid = 0
        if sid > 0:
            out[i] = sid
    return out

def active_spool_id():
    """Moonraker's active Spoolman spool (None when Spoolman isn't set up)."""
    res = _moonraker("/server/spoolman/spool_id")
    return (res or {}).get("spool_id") if isinstance(res, dict) else None

# Filament: material density fallback when the slicer wrote no weight (g/cm3).
DENSITY = {"PLA": 1.24, "PETG": 1.27, "ABS": 1.04, "ASA": 1.07, "TPU": 1.21,
           "PA": 1.14, "NYLON": 1.14, "PC": 1.20, "PVA": 1.23, "HIPS": 1.04}

def file_filament_info(filename):
    """The slicer's own numbers for this file: total mm and grams, material,
    and — Orca/Prusa write them into the footer — grams per tool."""
    info = {"total_mm": 0.0, "total_g": 0.0, "type": "", "name": "", "tools_g": None, "tools_mm": None, "price_kg": []}
    if not filename:
        return info
    q = urllib.parse.quote(filename)
    md = _moonraker("/server/files/metadata?filename=" + q) or {}
    info["total_mm"] = float(md.get("filament_total") or 0)
    info["total_g"] = float(md.get("filament_weight_total") or 0)
    info["type"] = str(md.get("filament_type") or "")
    info["name"] = str(md.get("filament_name") or "")      # slicer profile name(s), ";"-separated per tool
    # Moonraker's metadata only carries the sum; the per-tool split and the
    # profile's prices sit in the config block at the END of the file. Orca's
    # block can run to well over 100 KB, so fetch the last 256 KB.
    tail = _moonraker("/server/files/gcodes/" + q, headers={"Range": "bytes=-262144"},
                      timeout=15, raw=True)
    if tail:
        text = tail.decode("utf-8", "replace")
        # The slicer profile's price per kg — Orca/Prusa/Bambu write it into
        # the config block at the end, one value per filament/tool.
        m = re.search(r"^; filament_cost\s*=\s*(.+)$", text, re.M)
        if m:
            try:
                info["price_kg"] = [float(x) for x in m.group(1).split(",") if x.strip()]
            except ValueError:
                pass
        m = re.search(r"^; filament used \[mm\]\s*=\s*(.+)$", text, re.M)
        if m:
            try:
                vals = [float(x) for x in m.group(1).split(",") if x.strip()]
                if vals:
                    info["tools_mm"] = vals
            except ValueError:
                pass
        m = re.search(r"^; filament used \[g\]\s*=\s*(.+)$", text, re.M)
        if m:
            try:
                vals = [float(x) for x in m.group(1).split(",") if x.strip()]
            except ValueError:
                vals = []
            if vals:
                info["tools_g"] = vals
                if info["total_g"] <= 0:
                    info["total_g"] = sum(vals)
    return info

def extruder_map():
    """U1 only: sliced tool index -> channel actually used. The user can remap
    at print start (sliced with head 2, printed from head 4); the firmware
    keeps that choice in extruder_map_table."""
    res = _moonraker("/printer/objects/query?print_task_config") or {}
    ptc = ((res.get("status") or {}).get("print_task_config") or {})
    table = ptc.get("extruder_map_table")
    if not isinstance(table, list):
        return []
    try:
        return [int(x) for x in table[:4]]
    except (TypeError, ValueError):
        return []

def channel_info():
    """U1 only: what is loaded in each channel (material, vendor, colour).
    Standard Klipper has no print_task_config and gets an empty list."""
    res = _moonraker("/printer/objects/query?print_task_config") or {}
    ptc = ((res.get("status") or {}).get("print_task_config") or {})
    types = ptc.get("filament_type") or []
    if not isinstance(types, list) or not types:
        return []
    vendors = ptc.get("filament_vendor") or []
    colors = ptc.get("filament_color_rgba") or []
    out = []
    for i in range(len(types)):
        c = str(colors[i]) if i < len(colors) and colors[i] else ""
        out.append({"type": str(types[i] or ""),
                    "vendor": str(vendors[i] or "") if i < len(vendors) else "",
                    "color": c[:6]})
    return out

def filament_tools_mm(info, used_mm):
    """Millimetres per tool, scaled like the grams; None without a footer."""
    if info.get("tools_mm") and info["total_mm"] > 0:
        ratio = max(0.0, min(1.0, used_mm / info["total_mm"]))
        return [round(v * ratio, 1) for v in info["tools_mm"]]
    return None

def filament_grams(info, used_mm):
    """Actual grams: the slicer's weight scaled by how far the print got."""
    if info["total_mm"] > 0 and info["total_g"] > 0:
        ratio = max(0.0, min(1.0, used_mm / info["total_mm"]))
        tools = [round(g * ratio, 2) for g in info["tools_g"]] if info["tools_g"] else None
        return round(info["total_g"] * ratio, 2), tools
    # No usable header: length x cross-section x density (1.75 mm filament).
    dens = DENSITY.get((info["type"].split(";")[0] or "PLA").upper().strip(), 1.24)
    return round(used_mm / 10.0 * 0.02405 * dens, 2), None
# Minimal AES-128 ECB encryption — pure Python.
# The printer runs a Buildroot image: no pip, no compiler, and the Python
# standard library has no AES. Tuya's LAN protocol needs it, so it lives here.
_SBOX = None
def _init():
    global _SBOX
    p = q = 1
    sbox = [0] * 256
    while True:
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1; q ^= q << 2; q ^= q << 4; q &= 0xFF
        if q & 0x80: q ^= 0x09
        x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1: break
    sbox[0] = 0x63
    _SBOX = sbox
_init()

def _xtime(a): return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1

def _expand(key):
    w = [list(key[i*4:i*4+4]) for i in range(4)]
    rcon = 1
    for i in range(4, 44):
        t = list(w[i-1])
        if i % 4 == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[b] for b in t]
            t[0] ^= rcon
            rcon = _xtime(rcon)
        w.append([w[i-4][j] ^ t[j] for j in range(4)])
    return w

def encrypt_block(block, w):
    s = [list(block[i::4]) for i in range(4)]          # column-major -> rows
    def addkey(rnd):
        for c in range(4):
            for r in range(4):
                s[r][c] ^= w[rnd*4+c][r]
    addkey(0)
    for rnd in range(1, 11):
        for r in range(4):
            for c in range(4):
                s[r][c] = _SBOX[s[r][c]]
        for r in range(1, 4):
            s[r] = s[r][r:] + s[r][:r]
        if rnd != 10:
            for c in range(4):
                a = [s[r][c] for r in range(4)]
                x = a[0] ^ a[1] ^ a[2] ^ a[3]
                for r in range(4):
                    s[r][c] = a[r] ^ x ^ _xtime(a[r] ^ a[(r+1) % 4])
        addkey(rnd)
    out = bytearray(16)
    for c in range(4):
        for r in range(4):
            out[c*4+r] = s[r][c]
    return bytes(out)

def aes_ecb_encrypt(data, key):
    pad = 16 - (len(data) % 16)
    data = data + bytes([pad]) * pad                    # PKCS#7
    w = _expand(key)
    return b"".join(encrypt_block(data[i:i+16], w) for i in range(0, len(data), 16))

# -- AES-128 ECB decryption ---------------------------------------------------
# Needed to READ from a v3.3 plug: its replies are ECB-encrypted, and the
# standard library has no AES. (v3.4/v3.5 use GCM, which needs only the forward
# cipher above.)
_INV_SBOX = None
def _init_inv():
    global _INV_SBOX
    inv = [0] * 256
    for i, v in enumerate(_SBOX):
        inv[v] = i
    _INV_SBOX = inv
_init_inv()

def _gmul(a, b):
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p

def decrypt_block(block, w):
    s = [list(block[i::4]) for i in range(4)]          # column-major -> rows
    def addkey(rnd):
        for c in range(4):
            for r in range(4):
                s[r][c] ^= w[rnd * 4 + c][r]
    addkey(10)
    for rnd in range(9, -1, -1):
        for r in range(1, 4):                          # InvShiftRows
            s[r] = s[r][-r:] + s[r][:-r]
        for r in range(4):                             # InvSubBytes
            for c in range(4):
                s[r][c] = _INV_SBOX[s[r][c]]
        addkey(rnd)
        if rnd != 0:                                   # InvMixColumns
            for c in range(4):
                a = [s[r][c] for r in range(4)]
                s[0][c] = _gmul(a[0], 14) ^ _gmul(a[1], 11) ^ _gmul(a[2], 13) ^ _gmul(a[3], 9)
                s[1][c] = _gmul(a[0], 9) ^ _gmul(a[1], 14) ^ _gmul(a[2], 11) ^ _gmul(a[3], 13)
                s[2][c] = _gmul(a[0], 13) ^ _gmul(a[1], 9) ^ _gmul(a[2], 14) ^ _gmul(a[3], 11)
                s[3][c] = _gmul(a[0], 11) ^ _gmul(a[1], 13) ^ _gmul(a[2], 9) ^ _gmul(a[3], 14)
    out = bytearray(16)
    for c in range(4):
        for r in range(4):
            out[c * 4 + r] = s[r][c]
    return bytes(out)

def aes_ecb_decrypt(data, key):
    w = _expand(key)
    out = b"".join(decrypt_block(data[i:i + 16], w) for i in range(0, len(data), 16))
    pad = out[-1] if out else 0                        # strip PKCS#7 when sane
    if 1 <= pad <= 16 and out[-pad:] == bytes([pad]) * pad:
        out = out[:-pad]
    return out

# -- AES-GCM (Tuya v3.5) -----------------------------------------------------
# Same reason as the AES core above: no crypto library exists on the printer.
_GCM_R = 0xE1000000000000000000000000000000

def _gf_mult(x, y):
    z, v = 0, y
    for i in range(128):
        if (x >> (127 - i)) & 1:
            z ^= v
        if v & 1:
            v = (v >> 1) ^ _GCM_R
        else:
            v >>= 1
    return z

def _ghash(h, data):
    y = 0
    for i in range(0, len(data), 16):
        blk = data[i:i + 16]
        if len(blk) < 16:
            blk = blk + b"\x00" * (16 - len(blk))
        y = _gf_mult(y ^ int.from_bytes(blk, "big"), h)
    return y

def aes_gcm_encrypt(plain, key, nonce, aad=b""):
    """Returns (ciphertext, 16-byte tag). Nonce must be 12 bytes."""
    w = _expand(key)
    h = int.from_bytes(encrypt_block(b"\x00" * 16, w), "big")
    j0 = nonce + b"\x00\x00\x00\x01"
    ctr = int.from_bytes(j0, "big")
    out = bytearray()
    for i in range(0, len(plain), 16):
        ctr = (ctr & ~0xFFFFFFFF) | ((ctr + 1) & 0xFFFFFFFF)
        ks = encrypt_block(ctr.to_bytes(16, "big"), w)
        blk = plain[i:i + 16]
        out += bytes(a ^ b for a, b in zip(blk, ks[:len(blk)]))
    ct = bytes(out)
    pad = lambda d: d + b"\x00" * ((16 - len(d) % 16) % 16)
    s = _ghash(h, pad(aad) + pad(ct)
               + (len(aad) * 8).to_bytes(8, "big") + (len(ct) * 8).to_bytes(8, "big"))
    tag = bytes(a ^ b for a, b in zip(s.to_bytes(16, "big"), encrypt_block(j0, w)))
    return ct, tag

# -- Tuya LAN protocol v3.3 --------------------------------------------------
PREFIX_55AA = b"\x00\x00\x55\xaa"
SUFFIX_55AA = b"\x00\x00\xaa\x55"
VERSION_33  = b"3.3" + b"\x00" * 12
CMD_CONTROL = 7

def _crc32(data):
    v = 0xFFFFFFFF
    for b in data:
        x = b
        for _ in range(8):
            if (v ^ x) & 1:
                v = (v >> 1) ^ 0xEDB88320
            else:
                v >>= 1
            x >>= 1
    return v ^ 0xFFFFFFFF

def tuya_pack33(seqno, cmd, payload_json, key):
    enc = aes_ecb_encrypt(payload_json, key)
    # The "3.3" header goes on CONTROL commands only; other commands are
    # rejected with "parse data error" when it is present.
    payload = (VERSION_33 + enc) if cmd == CMD_CONTROL else enc
    msg_len = len(payload) + 8                      # CRC32(4) + suffix(4)
    d = PREFIX_55AA + struct.pack(">III", seqno, cmd, msg_len) + payload
    return d + struct.pack(">I", _crc32(d)) + SUFFIX_55AA

def _tuya33(host, device_id, key):
    body = json.dumps({"devId": device_id, "uid": device_id,
                       "t": str(int(time.time())), "dps": {"1": False}}).encode()
    pkt = tuya_pack33(1, CMD_CONTROL, body, key.encode())
    s = socket.create_connection((host, 6668), timeout=6)
    try:
        s.sendall(pkt)
        s.settimeout(3)
        # A reply is what tells 3.3 apart from a 3.5 plug, which ignores this
        # frame entirely. Without the check a 3.5 plug would look like success.
        if not s.recv(1024):
            raise RuntimeError("no reply — not a 3.3 plug?")
    finally:
        s.close()

# -- Tuya LAN protocols v3.4 / v3.5 ------------------------------------------
# Both negotiate a session key first; they differ only in how the command is
# framed afterwards (3.4 stays on the 55AA frame, 3.5 uses 6699).
PREFIX_6699 = b"\x00\x00\x66\x99"
SUFFIX_6699 = b"\x00\x00\x99\x66"
VERSION_34  = b"3.4" + b"\x00" * 12
VERSION_35  = b"3.5" + b"\x00" * 12
CMD_SESS_START  = 3
CMD_SESS_FINISH = 5
CMD_CONTROL_NEW = 13

def _hmac(key, msg):
    return hmac.new(key, msg, hashlib.sha256).digest()

def _pack55_hmac(seqno, cmd, payload, key):
    """55AA frame whose trailer is an HMAC instead of a CRC (3.4 / 3.5)."""
    msg_len = len(payload) + 36                       # HMAC(32) + suffix(4)
    d = PREFIX_55AA + struct.pack(">III", seqno, cmd, msg_len) + payload
    return d + _hmac(key, d) + SUFFIX_55AA

def _recv55(sock, timeout=3):
    sock.settimeout(timeout)
    buf = b""
    while len(buf) < 16:
        chunk = sock.recv(1024)
        if not chunk:
            return b""
        buf += chunk
    need = 16 + struct.unpack(">I", buf[12:16])[0]
    while len(buf) < need:
        chunk = sock.recv(1024)
        if not chunk:
            break
        buf += chunk
    return buf[:need]

def _unpack55_payload(data):
    if len(data) < 20:
        return b""
    msg_len = struct.unpack(">I", data[12:16])[0]
    end = min(16 + msg_len - 36, len(data))           # strip HMAC(32) + suffix(4)
    return data[16:end] if end > 16 else b""

def _negotiate(sock, kb):
    """Three-way handshake; returns the 16-byte session key."""
    local_nonce = os.urandom(16)
    sock.sendall(_pack55_hmac(1, CMD_SESS_START, local_nonce, kb))
    payload = _unpack55_payload(_recv55(sock))
    if len(payload) < 48:
        raise RuntimeError("session negotiation failed")
    remote_nonce, received = payload[:16], payload[16:48]
    if _hmac(kb, local_nonce) != received:
        raise RuntimeError("HMAC mismatch — wrong local key?")
    sock.sendall(_pack55_hmac(2, CMD_SESS_FINISH, _hmac(kb, remote_nonce), kb))
    xored = bytes(a ^ b for a, b in zip(local_nonce, remote_nonce))
    return aes_gcm_encrypt(xored, kb, local_nonce[:12])[0][:16]

def _control_body(device_id):
    return json.dumps({"devId": device_id, "uid": device_id,
                       "t": str(int(time.time())), "dps": {"1": False}}).encode()

def _pack34(seqno, cmd, body, session_key):
    plain = VERSION_34 + body
    msg_len = len(plain) + 28 + 36                    # nonce+tag, then HMAC+suffix
    header = PREFIX_55AA + struct.pack(">III", seqno, cmd, msg_len)
    nonce = os.urandom(12)
    ct, tag = aes_gcm_encrypt(plain, session_key, nonce, header)
    d = header + nonce + ct + tag
    return d + _hmac(session_key, d) + SUFFIX_55AA

def _encode6699(cmd, payload, session_key, seqno):
    full = VERSION_35 + payload
    msg_len = len(full) + 28                          # nonce(12) + tag(16)
    header = (PREFIX_6699 + struct.pack(">HH", seqno >> 16, seqno & 0xFFFF)
              + struct.pack(">III", cmd, 0, msg_len))
    aad = header[4:]                                  # 16 bytes
    nonce = os.urandom(12)
    ct, tag = aes_gcm_encrypt(full, session_key, nonce, aad)
    return header + nonce + ct + tag + SUFFIX_6699

def _tuya_session(host, device_id, key, version):
    kb = key.encode()
    s = socket.create_connection((host, 6668), timeout=6)
    try:
        session_key = _negotiate(s, kb)
        body = _control_body(device_id)
        pkt = (_pack34(3, CMD_CONTROL_NEW, body, session_key) if version == "v34"
               else _encode6699(CMD_CONTROL_NEW, body, session_key, 3))
        s.sendall(pkt)
        try: s.recv(1024)
        except Exception: pass
    finally:
        s.close()

def _tuya34(host, device_id, key): _tuya_session(host, device_id, key, "v34")
def _tuya35(host, device_id, key): _tuya_session(host, device_id, key, "v35")

# -- Reading the plug's current wattage ---------------------------------------
CMD_DP_QUERY     = 10      # v3.3
CMD_DP_QUERY_NEW = 16      # v3.4 / v3.5, inside a session

def _dps_from_ecb_frame(data, kb):
    """Pull the dps object out of a v3.3 reply. The body may carry a 4-byte
    return code and/or the 15-byte version header before the ciphertext, in
    any combination — try the plausible offsets and take what decrypts."""
    if len(data) < 20:
        return None
    msg_len = struct.unpack(">I", data[12:16])[0]
    end = min(16 + msg_len - 8, len(data))             # strip CRC(4) + suffix(4)
    body = data[16:end]
    for off in (0, 4, 15, 19):
        chunk = body[off:]
        if not chunk or len(chunk) % 16:
            continue
        try:
            plain = aes_ecb_decrypt(chunk, kb)
        except Exception:
            continue
        i = plain.find(b"{")
        if i < 0:
            continue
        try:
            return json.loads(plain[i:]).get("dps")
        except Exception:
            continue
    return None

def _tuya33_read(host, device_id, key):
    kb = key.encode()
    body = json.dumps({"gwId": device_id, "devId": device_id, "uid": device_id,
                       "t": str(int(time.time()))}).encode()
    s = socket.create_connection((host, 6668), timeout=6)
    try:
        s.sendall(tuya_pack33(1, CMD_DP_QUERY, body, kb))
        return _dps_from_ecb_frame(_recv55(s), kb)
    finally:
        s.close()

def _tuya_session_read(host, device_id, key, version):
    kb = key.encode()
    s = socket.create_connection((host, 6668), timeout=6)
    try:
        session_key = _negotiate(s, kb)
        body = json.dumps({"gwId": device_id, "devId": device_id, "uid": device_id,
                           "t": str(int(time.time()))}).encode()
        pkt = (_pack34(3, CMD_DP_QUERY_NEW, body, session_key) if version == "v34"
               else _encode6699(CMD_DP_QUERY_NEW, body, session_key, 3))
        s.sendall(pkt)
        data = s.recv(8192)
        plain = _decrypt_session_frame(data, session_key)
        if not plain:
            return None
        i = plain.find(b"{")
        return json.loads(plain[i:]).get("dps") if i >= 0 else None
    finally:
        s.close()

def _gcm_decrypt(ct, tag, key, nonce, aad=b""):
    """GCM decryption needs only the forward cipher: the keystream is the same
    as when encrypting. The tag is recomputed and compared."""
    w = _expand(key)
    h = int.from_bytes(encrypt_block(b"\x00" * 16, w), "big")
    j0 = nonce + b"\x00\x00\x00\x01"
    ctr = int.from_bytes(j0, "big")
    out = bytearray()
    for i in range(0, len(ct), 16):
        ctr = (ctr & ~0xFFFFFFFF) | ((ctr + 1) & 0xFFFFFFFF)
        ks = encrypt_block(ctr.to_bytes(16, "big"), w)
        blk = ct[i:i + 16]
        out += bytes(a ^ b for a, b in zip(blk, ks[:len(blk)]))
    pad = lambda d: d + b"\x00" * ((16 - len(d) % 16) % 16)
    s = _ghash(h, pad(aad) + pad(ct)
               + (len(aad) * 8).to_bytes(8, "big") + (len(ct) * 8).to_bytes(8, "big"))
    if bytes(a ^ b for a, b in zip(s.to_bytes(16, "big"), encrypt_block(j0, w))) != tag:
        raise ValueError("GCM tag mismatch")
    return bytes(out)

def _decrypt_session_frame(data, session_key):
    if len(data) < 24:
        return None
    if data[:4] == PREFIX_6699:                        # v3.5
        msg_len = struct.unpack(">I", data[16:20])[0]
        aad = data[4:20]
        body = data[20:20 + msg_len]
        nonce, rest = body[:12], body[12:]
        plain = _gcm_decrypt(rest[:-16], rest[-16:], session_key, nonce, aad)
    else:                                              # v3.4, 55AA frame
        msg_len = struct.unpack(">I", data[12:16])[0]
        aad = data[:16]
        body = data[16:16 + msg_len - 36]
        nonce, rest = body[:12], body[12:]
        plain = _gcm_decrypt(rest[:-16], rest[-16:], session_key, nonce, aad)
    return plain[15:] if plain[:3] in (b"3.4", b"3.5") else plain

def tuya_read_watts(host, device_id, key, proto="auto"):
    handlers = {"v33": lambda: _tuya33_read(host, device_id, key),
                "v34": lambda: _tuya_session_read(host, device_id, key, "v34"),
                "v35": lambda: _tuya_session_read(host, device_id, key, "v35")}
    order = ["v35", "v34", "v33"]
    if proto in handlers:
        order = [proto] + [p for p in order if p != proto]
    for p in order:
        try:
            dps = handlers[p]()
        except Exception:
            continue
        if dps:
            # DP 19 is power in units of 0.1 W on every Tuya plug seen so far.
            raw = dps.get("19", dps.get(19))
            if raw is not None:
                return float(raw) / 10.0
    return None

def shelly_read_watts(host):
    for url, key in (("http://%s/rpc/Switch.GetStatus?id=0" % host, "apower"),
                     ("http://%s/meter/0" % host, "power"),
                     ("http://%s/status" % host, "meters")):
        try:
            with urllib.request.urlopen(url, timeout=6) as r:
                d = json.loads(r.read())
            if key == "meters":                       # old Gen1 firmware
                d = (d.get("meters") or [{}])[0]
                key = "power"
            if key in d:
                return float(d[key])
        except Exception:
            continue
    return None

def plug_watts(cfg):
    plug = cfg.get("plug") or {}
    host = plug.get("host") or ""
    if not host:
        return None
    if plug.get("type") == "shelly":
        return shelly_read_watts(host)
    key = plug.get("local_key") or ""
    if len(key) != 16:
        return None
    return tuya_read_watts(host, plug.get("device_id") or "", key, plug.get("proto", "auto"))

def tuya_switch_off(host, device_id, local_key, proto="auto"):
    """Try the protocol the app detected first, the other one as a fallback."""
    handlers = {"v33": _tuya33, "v34": _tuya34, "v35": _tuya35}
    order = ["v35", "v34", "v33"]
    if proto in handlers:                       # what the app already detected
        order = [proto] + [p for p in order if p != proto]
    last = None
    for p in order:
        try:
            handlers[p](host, device_id, local_key)
            log.info("Tuya %s erfolgreich.", p)
            return p
        except Exception as exc:
            log.info("Tuya %s fehlgeschlagen: %s", p, exc)
            last = exc
    raise last

# -- Shelly ------------------------------------------------------------------
def shelly_switch_off(host):
    # Gen 1 first, Gen 2 as fallback — the two firmware families use different
    # endpoints and there is no cheap way to tell them apart up front.
    last = None
    for url in ("http://%s/relay/0?turn=off" % host,
                "http://%s/rpc/Switch.Set?id=0&on=false" % host):
        try:
            urllib.request.urlopen(url, timeout=6).read()
            return
        except Exception as exc:
            last = exc
    raise last

def switch_off(cfg):
    plug = cfg.get("plug") or {}
    kind = plug.get("type", "tuya")
    host = plug.get("host") or ""
    if not host:
        raise RuntimeError("no plug address configured")
    if kind == "shelly":
        shelly_switch_off(host)
    else:
        key = plug.get("local_key") or ""
        if len(key) != 16:
            raise RuntimeError("Tuya local key must be 16 characters")
        tuya_switch_off(host, plug.get("device_id") or "", key, plug.get("proto", "auto"))

# -- Energy log ---------------------------------------------------------------
ENERGY_NAME = "paxxmaker_energy.json"
ENERGY_KEEP = 100                      # default; the app sends "keep" (0 = unlimited)
STATUS_NAME = "paxxmaker_energy_status.json"

def energy_path():
    return os.path.join(os.path.dirname(config_path()), ENERGY_NAME)

def write_energy_status(st):
    """What the daemon sees right now — the app shows it while printing and it
    tells at a glance whether the plug is readable at all."""
    path = os.path.join(os.path.dirname(config_path()), STATUS_NAME)
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(st, f)
        # Started over SSH the daemon inherits umask 077 — Moonraker (another
        # user) could then not serve the file and the app saw a 404.
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError:
        pass

last_record = None                     # newest entry, mirrored into the status file

def append_energy_record(rec, keep=ENERGY_KEEP):
    global last_record
    last_record = rec
    """Newest first, capped. Written next to the settings so the app can read it
    over Moonraker without SSH."""
    path = energy_path()
    try:
        with open(path) as f:
            data = json.load(f)
        entries = data.get("prints") or []
    except Exception:
        entries = []
    entries.insert(0, rec)
    if keep > 0:
        del entries[keep:]
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            # Compact: the app never shows this file raw, and with "keep all
            # prints" it can grow to thousands of entries.
            json.dump({"prints": entries}, f, separators=(",", ":"), sort_keys=True)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)          # atomic: never a half-written file
        log.info("Verbrauch gespeichert: %.1f Wh fuer %s", rec.get("wh", 0), rec.get("file"))
    except OSError as exc:
        log.error("Verbrauch nicht speicherbar: %s", exc)

# -- Main loop ----------------------------------------------------------------
running = True
def _stop(sig, frame):
    global running
    running = False

def sleep_interruptible(seconds):
    end = time.time() + seconds
    while running and time.time() < end:
        time.sleep(1)

def main():
    for s in (signal.SIGTERM, signal.SIGINT):
        try: signal.signal(s, _stop)
        except (ValueError, AttributeError): pass
    # Init kills the boot session's process group with SIGHUP; ignoring it is
    # what keeps the service alive after an autostart.
    try: signal.signal(signal.SIGHUP, signal.SIG_IGN)
    except (ValueError, AttributeError): pass

    cfg = load_config()
    cfg_mtime = _config_mtime()
    _log_settings(cfg)

    last = None
    wh = 0.0                 # accumulated this print
    last_sample = None       # timestamp of the previous wattage sample
    job = None               # filename + start time of the running print
    ok_n = fail_n = 0        # wattage reads this print — for the log and the record
    last_status = 0          # when the status file was last refreshed
    finfo = None             # slicer filament numbers for the running file
    spools = {}              # channel -> FIRST Spoolman spool id seen while printing
    cur_spool = {}           # channel -> spool id loaded right now (may change mid-print)
    usage = {}               # channel -> {spool id -> mm extruded from it}
    spool_infos = {}         # spool id -> Spoolman description (all spools seen)
    last_mm = None           # filament_used at the previous sample

    while running:
        # Re-read the settings when the app has uploaded a new file. Without
        # this a changed delay would only take effect after a restart, and the
        # app has no reason to restart anything just to change a number.
        m = _config_mtime()
        if m != cfg_mtime:
            try:
                cfg = load_config()
                cfg_mtime = m
                log.info("Einstellungen neu geladen.")
                _log_settings(cfg)
            except Exception as exc:
                log.error("Neue Einstellungen unlesbar, behalte die alten: %s", exc)
                cfg_mtime = m
        delay = int(cfg.get("delay_s", 0))
        on_complete = bool(cfg.get("on_complete", True))
        on_cancelled = bool(cfg.get("on_cancelled", False))
        shutdown_on = bool(cfg.get("shutdown_enabled", True))
        track = bool(cfg.get("track_energy", False))

        st = printer_status()
        if st is None:
            sleep_interruptible(POLL_S); continue
        state, filename = st.get("state"), st.get("filename") or ""

        if state != last:
            log.info("Zustand: %s -> %s", last, state)
            started = state in ("printing",) and last not in ("printing", "paused")
            finished = last in ("printing", "paused") and state not in ("printing", "paused")

            if started:
                wh, last_sample, ok_n, fail_n = 0.0, None, 0, 0
                job = {"file": filename, "started": int(time.time())}
                finfo, spools, cur_spool, usage, spool_infos, last_mm = None, {}, {}, {}, {}, None
                if track:
                    log.info("Verbrauchszaehlung gestartet fuer %s", filename)
                    finfo = file_filament_info(filename)
                    log.info("Filament laut Slicer: %.0f mm, %.1f g, %s, je Tool %s, Preis/kg %s",
                             finfo["total_mm"], finfo["total_g"], finfo["type"] or "?", finfo["tools_g"], finfo["price_kg"])
                    job["channels"] = channel_info()
                    job["map"] = extruder_map()
                    spools = spoolman_channel_map()        # full table first …
                    cur_spool = dict(spools)
                    job["channels"] = enrich_channels(job["channels"], spools)
                    for c in job["channels"]:
                        if c.get("spool_id"):
                            spool_infos[c["spool_id"]] = c
                    log.info("Kanalbelegung: %s, Zuordnung Tool->Kanal: %s",
                             [c["type"] for c in job["channels"]], job["map"])

            # Written even at 0 Wh: a row with "no readings" tells the user the
            # plug could not be read, a missing row tells him nothing.
            if finished and track and job:
                if finfo is None:
                    finfo = file_filament_info(job.get("file") or filename)
                # Last look at the table, then describe every spool that only
                # turned up during the print.
                for ch, sid in spoolman_channel_map().items():
                    spools.setdefault(ch, sid)
                known = {c.get("spool_id") for c in (job.get("channels") or []) if c.get("source") == "spoolman"}
                late = {ch: sid for ch, sid in spools.items() if sid not in known}
                if late:
                    job["channels"] = enrich_channels(job.get("channels") or [], late)
                    for c in job["channels"]:
                        if c.get("spool_id"):
                            spool_infos[c["spool_id"]] = c
                # Spools that only came in mid-print need their description too.
                for per in usage.values():
                    for s_id in per:
                        if s_id and s_id not in spool_infos:
                            info = spoolman_spool(s_id)
                            if info:
                                spool_infos[s_id] = info
                used_mm = float(st.get("filament_mm") or 0)
                grams, tools_g = filament_grams(finfo, used_mm)
                log.info("Verbrauch %s: %.1f Wh (%d Messwerte, %d Lesefehler), Filament %.0f mm = %.1f g, Spulen %s",
                         state, wh, ok_n, fail_n, used_mm, grams, spools)
                append_energy_record({
                    "file": job.get("file") or filename,
                    "started": job["started"],
                    "ended": int(time.time()),
                    "seconds": int(time.time()) - job["started"],
                    "wh": round(wh, 2),
                    "price_per_kwh": float(cfg.get("price_per_kwh", 0) or 0),
                    "currency": cfg.get("currency", "EUR"),
                    "result": state,
                    "samples": ok_n,
                    "failed": fail_n,
                    "filament_mm": round(used_mm, 1),
                    "filament_g": grams,
                    "filament_type": finfo["type"],
                    "filament_name": finfo.get("name", ""),
                    "filament_tools_g": tools_g,
                    "filament_tools_mm": filament_tools_mm(finfo, used_mm),
                    "filament_channels": (job or {}).get("channels") or [],
                    "extruder_map": extruder_map() or (job or {}).get("map") or [],
                    "filament_slicer_price_kg": finfo.get("price_kg") or [],
                    "spools": {str(k): v for k, v in spools.items()},
                    "spool_usage_mm": {str(ch): {str(s_id): round(mm, 1) for s_id, mm in per.items()}
                                       for ch, per in usage.items()},
                    "spool_infos": {str(s_id): info for s_id, info in spool_infos.items()},
                }, keep=int(cfg.get("keep", ENERGY_KEEP) or 0))
                # The tile only needs the newest print: hand it over in the
                # small status file so it never has to fetch the whole log.
                write_energy_status({"printing": False, "at": int(time.time()), "last": last_record})
            if finished:
                job, wh, last_sample, ok_n, fail_n = None, 0.0, None, 0, 0

            trigger = shutdown_on and (last == "printing" or last == "paused") and (
                (state == "complete"  and on_complete) or
                (state in ("cancelled", "standby") and on_cancelled))
            if trigger:
                log.info("Ausloeser erkannt — warte %d s.", delay)
                sleep_interruptible(delay)
                if not running:
                    break
                # A new print during the delay cancels the shutdown: pulling the
                # power then would ruin it.
                now = (printer_status() or {}).get("state")
                if now in ("printing", "paused"):
                    log.info("Neuer Druck laeuft (%s) — Abschaltung verworfen.", now)
                else:
                    try:
                        switch_off(cfg)
                        log.info("Steckdose ausgeschaltet.")
                    except Exception as exc:
                        log.error("Abschalten fehlgeschlagen: %s", exc)
            last = state

        # Sample the wattage only while something is actually running — polling
        # an idle printer would query the plug around the clock for nothing.
        if track and state in ("printing", "paused"):
            # Remember which spool fed which nozzle — Moonraker's active spool
            # follows the tool changes, so sampling it maps tool -> spool.
            tool = int(st.get("tool") or 0)
            sid = active_spool_id()                    # … sampling only fills gaps
            table = spoolman_channel_map()
            if sid:
                table.setdefault(tool, sid)
            # Re-read every sample: the table is often complete only after the
            # first tool changes, and a spool swapped MID-PRINT (empty spool,
            # new one assigned) must be charged from that moment on.
            # Filament extruded since the last sample came from the spool that
            # was loaded UNTIL now — book it before taking over a swap.
            # (0 = no spool known for that head.)
            mm_now = float(st.get("filament_mm") or 0)
            if last_mm is not None and mm_now > last_mm:
                per = usage.setdefault(tool, {})
                key = cur_spool.get(tool, 0)
                per[key] = per.get(key, 0.0) + (mm_now - last_mm)
            last_mm = mm_now
            for ch, s_id in table.items():
                spools.setdefault(ch, s_id)
                if cur_spool.get(ch) != s_id:
                    if cur_spool.get(ch):
                        log.info("Kanal %d: Spule %s -> %s gewechselt", ch + 1, cur_spool.get(ch), s_id)
                    cur_spool[ch] = s_id
            w = plug_watts(cfg)
            if w is None:
                # A Tuya plug takes one connection at a time; the app polling
                # the same plug makes the first attempt fail now and then.
                time.sleep(1.5)
                w = plug_watts(cfg)
            now = time.time()
            if w is not None:
                ok_n += 1
                if last_sample is not None:
                    wh += w * (now - last_sample) / 3600.0
                last_sample = now
                if now - last_status >= 30:        # eMMC-friendly cadence
                    last_status = now
                    g_now, tools_now = filament_grams(finfo or file_filament_info(filename),
                                                      float(st.get("filament_mm") or 0))
                    write_energy_status({"printing": True, "at": int(now), "watts": w,
                                         "wh": round(wh, 2), "samples": ok_n, "failed": fail_n,
                                         "file": (job or {}).get("file", filename),
                                         "price_per_kwh": float(cfg.get("price_per_kwh", 0) or 0),
                                         "currency": cfg.get("currency", "EUR"),
                                         "filament_g": g_now, "filament_tools_g": tools_now,
                                         "filament_type": (finfo or {}).get("type", ""),
                                         "filament_channels": (job or {}).get("channels") or [],
                                         "extruder_map": (job or {}).get("map") or [],
                                         "filament_slicer_price_kg": (finfo or {}).get("price_kg") or [],
                                         "spools": {str(k): v for k, v in spools.items()}})
            else:
                fail_n += 1
                # A failed read must not turn into a gap counted at the old
                # wattage. Log sparingly — one line per failure would flood.
                if fail_n in (1, 10) or fail_n % 100 == 0:
                    log.warning("Steckdose nicht lesbar (%d. Fehler, %d gute Messwerte)", fail_n, ok_n)
                    write_energy_status({"printing": True, "at": int(now), "watts": None,
                                         "wh": round(wh, 2), "samples": ok_n, "failed": fail_n,
                                         "file": (job or {}).get("file", filename)})
                last_sample = None

        sleep_interruptible(POLL_S)
    log.info("Beendet.")

# -- Self setup / removal ----------------------------------------------------
# Doing this here keeps the SSH command short: Dropbear rejects long exec
# requests, so the app only ever sends "<script> --setup" or "--remove".
INIT_FILE = "/etc/init.d/S98paxxshutdown"
UNIT_FILE = "/etc/systemd/system/paxxmaker-shutdown.service"

UNIT_TEXT = (
    "[Unit]\n"
    "Description=PaxxMaker Auto-Shutdown\n"
    "After=network.target\n"
    "\n"
    "[Service]\n"
    "Type=simple\n"
    "ExecStart=/usr/bin/env python3 %s\n"
    "Restart=always\n"
    "RestartSec=10\n"
    "\n"
    "[Install]\n"
    "WantedBy=multi-user.target\n"
)

INIT_TEXT = (
    "#!/bin/sh\n"
    "case \"$1\" in\n"
    "  start) nohup python3 %s >/dev/null 2>&1 & ;;\n"
    "  stop)  pkill -f paxxmaker_shutdown.py ;;\n"
    "esac\n"
    "exit 0\n"
)

def _self_path():
    return os.path.abspath(__file__)

HOOK_BEGIN = "# PaxxMaker-AutoShutdown-BEGIN"
HOOK_END   = "# PaxxMaker-AutoShutdown-END"

def _overlay_is_wiped():
    """paxx12 clears the rootfs overlay on every boot, so /etc is not
    persistent and an init.d entry there is pointless — which is exactly why
    this daemon stopped coming back after a reboot."""
    try:
        with open("/etc/init.d/S01aoverlayfs") as f:
            return "/oem/.debug" in f.read()
    except OSError:
        return False

def _hook_dirs():
    import glob
    return glob.glob("/oem/apps/*/venv/lib/python3*/site-packages")

def _hook_text(me):
    return ("\n" + HOOK_BEGIN + "\n"
            "try:\n"
            "    import subprocess\n"
            "    subprocess.Popen([\"/usr/bin/python3\", \"%s\"],\n"
            "                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,\n"
            "                     start_new_session=True)\n"
            "except Exception:\n"
            "    pass\n" + HOOK_END + "\n") % me

def install_autostart():
    me = _self_path()
    # /oem survives a reboot; Python loads sitecustomize.py automatically when
    # the host app starts. The push bridge uses the same file, so APPEND to it
    # instead of overwriting — otherwise the two would keep evicting each other.
    if _overlay_is_wiped():
        hooked = already = 0
        for sp in _hook_dirs():
            f = os.path.join(sp, "sitecustomize.py")
            try:
                cur = open(f).read() if os.path.exists(f) else ""
            except OSError:
                continue
            if cur and "PaxxMaker" not in cur:
                continue                      # belongs to another app
            if HOOK_BEGIN in cur:
                already += 1
                continue                      # already hooked
            try:
                with open(f, "a" if cur else "w") as fh:
                    if not cur:
                        fh.write("# PaxxMaker\n")
                    fh.write(_hook_text(me))
                hooked += 1
            except OSError:
                pass
        if hooked or already:
            return "app-hook(%d new,%d kept)" % (hooked, already)
    if os.path.isdir("/etc/systemd/system"):
        with open(UNIT_FILE, "w") as f:
            f.write(UNIT_TEXT % me)
        os.system("systemctl daemon-reload >/dev/null 2>&1; "
                  "systemctl enable --now paxxmaker-shutdown >/dev/null 2>&1")
        return "systemd"
    if os.path.isdir("/etc/init.d"):
        with open(INIT_FILE, "w") as f:
            f.write(INIT_TEXT % me)
        os.chmod(INIT_FILE, 0o755)
        return "init.d"
    return "none"

def remove_autostart():
    os.system("systemctl disable --now paxxmaker-shutdown >/dev/null 2>&1")
    # Strip only OUR block: the bridge shares these files and must keep working.
    for sp in _hook_dirs():
        f = os.path.join(sp, "sitecustomize.py")
        try:
            cur = open(f).read()
        except OSError:
            continue
        if HOOK_BEGIN not in cur:
            continue
        a = cur.index(HOOK_BEGIN)
        b = cur.find(HOOK_END)
        cleaned = cur[:a] + (cur[b + len(HOOK_END):] if b != -1 else "")
        try:
            # Nothing but our own marker line left → the file was ours alone.
            if cleaned.strip() in ("", "# PaxxMaker"):
                os.remove(f)
            else:
                open(f, "w").write(cleaned)
        except OSError:
            pass
    for f in (UNIT_FILE, INIT_FILE, LOCK_FILE, LOG_FILE):
        try: os.remove(f)
        except OSError: pass
    os.system("systemctl daemon-reload >/dev/null 2>&1")

if __name__ == "__main__":
    if "--setup" in sys.argv:
        print("autostart:" + install_autostart())
        sys.exit(0)
    if "--remove" in sys.argv:
        os.system("pkill -f paxxmaker_shutdown.py")
        remove_autostart()
        for f in (_self_path(), config_path()):
            try: os.remove(f)
            except OSError: pass
        print("removed")
        sys.exit(0)
    _lock = acquire_lock()
    main()
"""#
}

import SwiftUI

// MARK: - Auto-Shutdown settings sheet
struct AutoShutdownSheet: View {
    @Binding var config: PrinterConfig
    let sshUser: String
    /// What the edit screen currently holds. May be empty even though a
    /// password IS stored — which is exactly what made this screen demand one
    /// that was already there. `effectivePassword` is the value to use.
    let sshPassword: String

    /// Resolves in the same order the SSH installer does: what the user typed,
    /// otherwise the keychain, otherwise the U1 factory default.
    private var effectivePassword: String {
        if !sshPassword.isEmpty { return sshPassword }
        if let saved = SSHCredentialStore.load(for: config.name), !saved.isEmpty { return saved }
        return config.type == .snapmakerU1 ? "snapmaker" : ""
    }
    /// Persists the printer without closing the edit screen — the activation
    /// state must survive even if the user never taps Save.
    var persist: (PrinterConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var busy = false          // install / remove
    /// Separate from `busy`: a spinner on the Activate/Deactivate button
    /// while merely sending a changed delay looked like that button was
    /// doing something.
    @State private var sending = false
    /// The values this screen opened with, so Cancel can put them back.
    /// Only the settings — whether the daemon is installed reflects the
    /// printer's actual state and must not be rolled back.
    @State private var original: PrinterConfig? = nil
    @State private var message: String? = nil
    @State private var failed = false

    private var host: String {
        config.ip
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .components(separatedBy: ":").first?
            .trimmingCharacters(in: .whitespaces) ?? config.ip
    }
    private var baseURL: String {
        config.ip.hasPrefix("http") ? config.ip : "http://\(config.ip)"
    }
    private var user: String {
        let u = sshUser.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty { return u }
        return config.type == .snapmakerU1 ? "root" : "pi"
    }
    private var noTrigger: Bool { !config.autoShutdownOnComplete && !config.autoShutdownOnCancelled }
    private var currentJSON: String { String(data: settings().json, encoding: .utf8) ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(lz(
                    en: "Time between the print ending and the plug switching off. The shutdown is skipped if a new print has started by then.",
                    de: "Zeit zwischen Druckende und Abschalten der Steckdose. Läuft dann bereits ein neuer Druck, wird nicht abgeschaltet.",
                    fr: "Délai entre la fin de l'impression et la coupure de la prise. Si une nouvelle impression a démarré entre-temps, rien n'est coupé.",
                    es: "Tiempo entre el fin de la impresión y el apagado del enchufe. Si para entonces hay una impresión en curso, no se apaga.",
                    pt: "Tempo entre o fim da impressão e o desligamento da tomada. Se já houver uma nova impressão, nada é desligado.",
                    it: "Tempo tra la fine della stampa e lo spegnimento della presa. Se nel frattempo è partita una nuova stampa, non si spegne nulla.",
                    zh: "打印结束到断电之间的等待时间。若届时已开始新的打印，则不会断电。"))) {
                    Stepper(value: $config.autoShutdownDelayMin, in: 0...120) {
                        HStack {
                            Image(systemName: "clock").foregroundColor(.orange).frame(width: 28)
                            Text(lz(en: "Delay", de: "Verzögerung", fr: "Délai", es: "Retardo", pt: "Atraso", it: "Ritardo", zh: "延迟"))
                            Spacer()
                            Text(config.autoShutdownDelayMin == 0
                                 ? lz(en: "immediately", de: "sofort", fr: "immédiat", es: "inmediato", pt: "imediato", it: "subito", zh: "立即")
                                 : "\(config.autoShutdownDelayMin) min")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(header: Text(lz(en: "Switch off when", de: "Abschalten bei", fr: "Couper lorsque", es: "Apagar cuando", pt: "Desligar quando", it: "Spegni quando", zh: "何时断电"))) {
                    Toggle(isOn: $config.autoShutdownOnComplete) {
                        Label(lz(en: "Print finished", de: "Druck fertig", fr: "Impression terminée", es: "Impresión terminada", pt: "Impressão concluída", it: "Stampa completata", zh: "打印完成"),
                              systemImage: "checkmark.circle")
                    }
                    Toggle(isOn: $config.autoShutdownOnCancelled) {
                        Label(lz(en: "Print cancelled", de: "Druck abgebrochen", fr: "Impression annulée", es: "Impresión cancelada", pt: "Impressão cancelada", it: "Stampa annullata", zh: "打印已取消"),
                              systemImage: "xmark.circle")
                    }
                }

                Section {
                    if effectivePassword.isEmpty {
                        Label(lz(en: "Enter the SSH password under \"SSH Access\" first.",
                                 de: "Bitte zuerst oben unter \"SSH-Zugriff\" das SSH-Passwort eintragen.",
                                 fr: "Saisis d'abord le mot de passe SSH sous « Accès SSH ».",
                                 es: "Introduce primero la contraseña SSH en «Acceso SSH».",
                                 pt: "Insira primeiro a senha SSH em \"Acesso SSH\".",
                                 it: "Inserisci prima la password SSH in «Accesso SSH».",
                                 zh: "请先在\"SSH 访问\"中输入 SSH 密码。"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundColor(.orange)
                    } else if noTrigger {
                        Label(lz(en: "Pick at least one event above.", de: "Bitte oben mindestens ein Ereignis wählen.", fr: "Choisis au moins un événement ci-dessus.", es: "Elige al menos un evento arriba.", pt: "Escolha ao menos um evento acima.", it: "Scegli almeno un evento qui sopra.", zh: "请在上方至少选择一个事件。"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundColor(.orange)
                    }

                    Button {
                        config.autoShutdownEnabled ? deactivate() : activate()
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(config.autoShutdownEnabled
                                 ? lz(en: "Deactivate", de: "Deaktivieren", fr: "Désactiver", es: "Desactivar", pt: "Desativar", it: "Disattiva", zh: "停用")
                                 : lz(en: "Activate", de: "Aktivieren", fr: "Activer", es: "Activar", pt: "Ativar", it: "Attiva", zh: "启用"))
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(busy || sending || effectivePassword.isEmpty || (noTrigger && !config.autoShutdownEnabled))
                    .foregroundColor(config.autoShutdownEnabled ? .red : .accentColor)

                    if sending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(lz(en: "Sending change to the printer…", de: "Änderung wird an den Drucker geschickt…", fr: "Envoi de la modification à l'imprimante…", es: "Enviando el cambio a la impresora…", pt: "Enviando a alteração para a impressora…", it: "Invio della modifica alla stampante…", zh: "正在将更改发送到打印机…"))
                                .font(.footnote)
                        }
                        .foregroundColor(.blue)
                    }

                    if let message {
                        Label(message, systemImage: failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundColor(failed ? .red : .green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    Text(lz(
                        en: "The script runs on the printer itself, so it also works with the app closed. Tuya and Shelly plugs are both supported; Tuya on local protocols 3.3, 3.4 and 3.5.",
                        de: "Das Skript läuft auf dem Drucker selbst und funktioniert daher auch bei geschlossener App. Tuya und Shelly werden beide unterstützt, Tuya mit den lokalen Protokollen 3.3, 3.4 und 3.5.",
                        fr: "Le script tourne sur l'imprimante, il fonctionne donc aussi app fermée. Les prises Tuya et Shelly sont prises en charge ; Tuya en protocoles locaux 3.3, 3.4 et 3.5.",
                        es: "El script corre en la propia impresora, así que funciona también con la app cerrada. Se admiten enchufes Tuya y Shelly; Tuya con los protocolos locales 3.3, 3.4 y 3.5.",
                        pt: "O script roda na própria impressora, portanto funciona também com o app fechado. Tomadas Tuya e Shelly têm suporte; Tuya nos protocolos locais 3.3, 3.4 e 3.5.",
                        it: "Lo script gira sulla stampante stessa, quindi funziona anche ad app chiusa. Sono supportate sia Tuya sia Shelly; Tuya con i protocolli locali 3.3, 3.4 e 3.5.",
                        zh: "脚本在打印机上运行，因此关闭应用也有效。支持 Tuya 与 Shelly 插座；Tuya 支持本地协议 3.3、3.4 和 3.5。"))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .onAppear { if original == nil { original = config } }   // set at once
            .task {
                // Show what the PRINTER has, not what the phone remembers — the
                // two can differ if a change never made it across.
                if config.autoShutdownEnabled,
                   let live = await AutoShutdownInstaller.readSettings(baseURL: baseURL, apiKey: "", dir: AutoShutdownInstaller.dir(for: config.type)) {
                    await MainActor.run {
                        config.autoShutdownDelayMin = max(0, live.delaySeconds / 60)
                        config.autoShutdownOnComplete = live.onComplete
                        config.autoShutdownOnCancelled = live.onCancelled
                        original = config
                    }
                }
            }
            .navigationTitle(lz(en: "Auto Shutdown", de: "Auto-Shutdown", fr: "Arrêt automatique", es: "Apagado automático", pt: "Desligamento automático", it: "Spegnimento automatico", zh: "自动关机"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) {
                        if let o = original {
                            config.autoShutdownDelayMin = o.autoShutdownDelayMin
                            config.autoShutdownOnComplete = o.autoShutdownOnComplete
                            config.autoShutdownOnCancelled = o.autoShutdownOnCancelled
                        }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: confirm) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(busy || sending ? .gray : .blue)
                    }
                    .disabled(busy || sending)
                    .accessibilityLabel(lz(en: "Save", de: "Speichern", fr: "Enregistrer", es: "Guardar", pt: "Salvar", it: "Salva", zh: "保存"))
                }
            }
        }
    }

    private func settings() -> AutoShutdownInstaller.Settings {
        AutoShutdownInstaller.Settings(
            shutdownEnabled: config.autoShutdownEnabled,
            trackEnergy: config.energyTrackingEnabled,
            pricePerKWh: config.energyPricePerKWh,
            currency: config.energyCurrency,
            keepCount: config.energyKeepCount,
            delayMinutes: config.autoShutdownDelayMin,
            onComplete: config.autoShutdownOnComplete,
            onCancelled: config.autoShutdownOnCancelled,
            plugType: config.smartPlugType,
            plugHost: config.smartPlugIP
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: ""),
            deviceID: config.smartPlugDeviceID,
            localKey: config.smartPlugLocalKey,
            proto: UserDefaults.standard.string(
                forKey: "tuyaProto." + config.smartPlugIP
                    .replacingOccurrences(of: "http://", with: "")
                    .replacingOccurrences(of: "https://", with: "")) ?? "auto")
    }

    private func activate() {
        busy = true; message = nil; failed = false
        let s = settings(), b = baseURL, h = host, u = user, pw = effectivePassword
        Task {
            do {
                // Same gate Server Push uses: on the U1 the rootfs is wiped on
                // every boot, and the autostart hook lives inside OctoEverywhere.
                // Without it the daemon would run until the next restart and
                // then quietly stop — worse than refusing to install.
                // Ask the config first — it decides whether the daemon starts at
                // all. Only if that file can't be read do we fall back to looking
                // for the directory over SSH.
                var octoOK = true
                if config.type == .snapmakerU1 {
                    if let enabled = await AutoShutdownInstaller.octoEverywhereEnabled(baseURL: b, apiKey: "") {
                        octoOK = enabled
                    } else {
                        octoOK = try await SSHInstaller.checkOctoEverywhereInstalled(host: h, user: u, password: pw)
                    }
                }
                if !octoOK {
                    await MainActor.run {
                        busy = false; failed = true
                        message = lz(
                            en: "OctoEverywhere required. Auto Shutdown attaches itself to its startup instead of changing the printer's system files — that keeps the firmware untouched and brings the service back by itself after a restart. Enable OctoEverywhere first under Konfiguration › Cloud Access.",
                            de: "OctoEverywhere erforderlich. Auto-Shutdown hängt sich an dessen Start an, statt Systemdateien des Druckers zu verändern — so bleibt die Firmware unangetastet und der Dienst kommt nach einem Neustart von selbst wieder hoch. Aktiviere OctoEverywhere zuerst im Reiter Konfiguration unter Cloud Access.",
                            fr: "OctoEverywhere requis. L'arrêt automatique se greffe sur son démarrage au lieu de modifier les fichiers système de l'imprimante — le firmware reste intact et le service repart tout seul après un redémarrage. Active d'abord OctoEverywhere dans l'onglet Konfiguration sous Cloud Access.",
                            es: "Se requiere OctoEverywhere. El apagado automático se engancha a su arranque en lugar de modificar archivos del sistema de la impresora: así el firmware queda intacto y el servicio vuelve solo tras un reinicio. Activa OctoEverywhere en la pestaña Konfiguration, en Cloud Access.",
                            pt: "OctoEverywhere é necessário. O desligamento automático se acopla à inicialização dele em vez de alterar arquivos de sistema da impressora — assim o firmware permanece intacto e o serviço volta sozinho após um reinício. Ative o OctoEverywhere na aba Konfiguration, em Cloud Access.",
                            it: "OctoEverywhere richiesto. Lo spegnimento automatico si aggancia al suo avvio invece di modificare i file di sistema della stampante — così il firmware resta intatto e il servizio riparte da solo dopo un riavvio. Attiva OctoEverywhere nella scheda Konfiguration, in Cloud Access.",
                            zh: "需要 OctoEverywhere。自动关机会挂接到它的启动过程，而不去改动打印机的系统文件——这样固件保持原样，重启后服务也会自行恢复。请先在“Konfiguration”标签页的 Cloud Access 中启用 OctoEverywhere。")
                    }
                    return
                }
                let out = try await AutoShutdownInstaller.install(baseURL: b, apiKey: "", dir: AutoShutdownInstaller.dir(for: config.type), host: h,
                                                                  user: u, password: pw, settings: s)
                // The remote command reports NOMOVE when the script could not be
                // put in place — a silent failure there would otherwise look
                // exactly like success.
                let placed = !out.contains("NOMOVE")
                await MainActor.run {
                    config.autoShutdownEnabled = placed
                    if placed { persist(config) }
                    busy = false
                    failed = !placed
                    message = placed
                        ? lz(en: "Installed and running on the printer.", de: "Auf dem Drucker eingerichtet und aktiv.", fr: "Installé et actif sur l'imprimante.", es: "Instalado y activo en la impresora.", pt: "Instalado e ativo na impressora.", it: "Installato e attivo sulla stampante.", zh: "已在打印机上安装并运行。")
                        : lz(en: "The script could not be placed on the printer.", de: "Das Skript konnte auf dem Drucker nicht abgelegt werden.", fr: "Le script n'a pas pu être placé sur l'imprimante.", es: "No se pudo colocar el script en la impresora.", pt: "Não foi possível colocar o script na impressora.", it: "Non è stato possibile collocare lo script sulla stampante.", zh: "无法在打印机上放置脚本。")
                }
            } catch {
                await MainActor.run {
                    busy = false; failed = true
                    message = error.localizedDescription
                }
            }
        }
    }

    /// The checkmark: hand the settings over, then close. Nothing is written
    /// while the user is still turning the dials.
    private func confirm() {
        // Nothing installed on the printer → nothing to verify, the values are
        // just remembered for the next activation.
        guard config.autoShutdownEnabled else { persist(config); dismiss(); return }
        // Otherwise ALWAYS write and read back, even when the values look
        // unchanged. Two earlier conditions could quietly skip the check: a
        // still-running initial read left `original` empty, and comparing
        // against it assumed we already knew what the printer has. With the
        // printer switched off both were true and the change was accepted in
        // silence.
        sending = true
        Task {
            await applyChanges()
            // persist() happens inside applyChanges only on success, so an
            // unreachable printer leaves the app showing the old value instead
            // of a setting that exists nowhere but on the phone.
            await MainActor.run { sending = false; if !failed { dismiss() } }
        }
    }

    private func applyChanges() async {
        let st = settings(), b = baseURL
        do {
            try await AutoShutdownInstaller.updateSettings(baseURL: b, apiKey: "", dir: AutoShutdownInstaller.dir(for: config.type), settings: st)
            await MainActor.run {
                persist(config)          // only now is it real on the printer
                failed = false
                message = lz(en: "Changes applied.", de: "Änderungen übernommen.", fr: "Modifications appliquées.", es: "Cambios aplicados.", pt: "Alterações aplicadas.", it: "Modifiche applicate.", zh: "更改已应用。")
            }
        } catch {
            await MainActor.run {
                failed = true
                // Put the sheet back to what the printer has, so nothing that
                // failed to arrive stays on screen as if it were set.
                if let o = original {
                    config.autoShutdownDelayMin = o.autoShutdownDelayMin
                    config.autoShutdownOnComplete = o.autoShutdownOnComplete
                    config.autoShutdownOnCancelled = o.autoShutdownOnCancelled
                }
                message = error.localizedDescription
            }
        }
    }

    /// Turning one feature off must not take the daemon down while the other
    /// still needs it — in that case only the settings are rewritten.
    private func stillNeeded() -> Bool { config.energyTrackingEnabled }

    private func deactivate() {
        busy = true; message = nil; failed = false
        let h = host, u = user, pw = effectivePassword, b = baseURL
        Task {
            do {
                var left = true
                if stillNeeded() {
                    var st = settings(); st.shutdownEnabled = false
                    try await AutoShutdownInstaller.updateSettings(baseURL: b, apiKey: "", dir: AutoShutdownInstaller.dir(for: config.type), settings: st)
                } else {
                    let out = try await AutoShutdownInstaller.remove(baseURL: b, apiKey: "", dir: AutoShutdownInstaller.dir(for: config.type), host: h,
                                                                    user: u, password: pw)
                    left = out.contains("left=0")
                }
                await MainActor.run {
                    config.autoShutdownEnabled = false
                    persist(config)
                    busy = false
                    failed = !left            // "left=" counts what survived
                    message = left
                        ? lz(en: "Removed from the printer.", de: "Vom Drucker entfernt.", fr: "Retiré de l'imprimante.", es: "Eliminado de la impresora.", pt: "Removido da impressora.", it: "Rimosso dalla stampante.", zh: "已从打印机移除。")
                        : lz(en: "Some files could not be removed.", de: "Einige Dateien konnten nicht entfernt werden.", fr: "Certains fichiers n'ont pas pu être supprimés.", es: "Algunos archivos no se pudieron eliminar.", pt: "Alguns arquivos não puderam ser removidos.", it: "Alcuni file non sono stati rimossi.", zh: "部分文件无法删除。")
                }
            } catch {
                await MainActor.run {
                    busy = false; failed = true
                    message = error.localizedDescription
                }
            }
        }
    }
}
