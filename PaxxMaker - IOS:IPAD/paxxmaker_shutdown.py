#!/usr/bin/env python3
# PaxxMaker Auto-Shutdown — switches the printer's smart plug off after a print.
# Runs entirely on the printer; nothing leaves the local network.
import fcntl, hashlib, hmac, json, logging, logging.handlers, os, signal, socket, struct, sys, time
import urllib.request

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

def printer_status():
    """State plus filename — the energy log needs to know which print it was."""
    try:
        url = MOONRAKER.rstrip("/") + "/printer/objects/query?print_stats"
        with urllib.request.urlopen(url, timeout=6) as r:
            d = json.loads(r.read())
        ps = (d.get("result", {}).get("status", {}).get("print_stats", {}) or {})
        return {"state": ps.get("state"),
                "filename": ps.get("filename") or "",
                "duration": ps.get("print_duration") or 0}
    except Exception:
        return None
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
    for url, key in (("http://%s/meter/0" % host, "power"),
                     ("http://%s/rpc/Switch.GetStatus?id=0" % host, "apower")):
        try:
            with urllib.request.urlopen(url, timeout=6) as r:
                d = json.loads(r.read())
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
ENERGY_KEEP = 100                      # newest entries kept in the file

def energy_path():
    return os.path.join(os.path.dirname(config_path()), ENERGY_NAME)

def append_energy_record(rec):
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
    del entries[ENERGY_KEEP:]
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump({"prints": entries}, f, indent=1, sort_keys=True)
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
                wh, last_sample = 0.0, None
                job = {"file": filename, "started": int(time.time())}
                if track:
                    log.info("Verbrauchszaehlung gestartet fuer %s", filename)

            if finished and track and job and wh > 0:
                append_energy_record({
                    "file": job.get("file") or filename,
                    "started": job["started"],
                    "ended": int(time.time()),
                    "seconds": int(time.time()) - job["started"],
                    "wh": round(wh, 2),
                    "price_per_kwh": float(cfg.get("price_per_kwh", 0) or 0),
                    "currency": cfg.get("currency", "EUR"),
                    "result": state,
                })
            if finished:
                job, wh, last_sample = None, 0.0, None

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
            w = plug_watts(cfg)
            now = time.time()
            if w is not None:
                if last_sample is not None:
                    wh += w * (now - last_sample) / 3600.0
                last_sample = now
            else:
                # A failed read (the app may hold the plug's single connection)
                # must not turn into a gap counted at the old wattage.
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
