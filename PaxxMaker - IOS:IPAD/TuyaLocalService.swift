// TuyaLocalService.swift
// Tuya LAN protocol — v3.3 (AES-ECB, direct) and v3.5 (AES-GCM, session key).
// Auto-detects version per host; tries v3.3 first, falls back to v3.5.

import Foundation
import Network
import CryptoKit
import CommonCrypto

// MARK: - Plug status (power on/off + optional wattage)
struct PlugStatus {
    let power: Bool
    let watts: Double?   // nil if device doesn't report power consumption
}

// MARK: - Error
enum TuyaError: Error, LocalizedError {
    case connectionFailed
    case sessionNegotiationFailed
    case hmacMismatch
    case invalidResponse
    case encryptionError
    case noStatus
    case timeout
    case noKey

    var errorDescription: String? {
        switch self {
        case .connectionFailed:         return "Connection failed"
        case .sessionNegotiationFailed: return "Session negotiation failed"
        case .hmacMismatch:             return "Key mismatch — check local key"
        case .invalidResponse:          return "Invalid response from device"
        case .encryptionError:          return "Encryption error"
        case .noStatus:                 return "Could not read plug status"
        case .timeout:                  return "Timeout"
        case .noKey:                    return "No local key configured"
        }
    }
}

// One-shot gate: ensures a continuation is resumed at most once across concurrent closures.
private final class _OnceFlag: @unchecked Sendable {
    nonisolated(unsafe) private var fired = false
    nonisolated func fire() -> Bool { guard !fired else { return false }; fired = true; return true }
}

// MARK: - Protocol constants
private let TUYA_PORT: UInt16 = 6668
private let PREFIX_55AA = Data([0x00, 0x00, 0x55, 0xAA])
private let SUFFIX_55AA = Data([0x00, 0x00, 0xAA, 0x55])
private let PREFIX_6699 = Data([0x00, 0x00, 0x66, 0x99])
private let SUFFIX_6699 = Data([0x00, 0x00, 0x99, 0x66])
// 15-byte version headers prepended to payloads
private let VERSION_33_HEADER = Data("3.3".utf8) + Data(repeating: 0, count: 12)
private let VERSION_34_HEADER = Data("3.4".utf8) + Data(repeating: 0, count: 12)
private let VERSION_35_HEADER = Data("3.5".utf8) + Data(repeating: 0, count: 12)

// v3.3 command codes
private let CMD_CONTROL:  UInt32 = 7   // set DPS
private let CMD_DP_QUERY: UInt32 = 10  // query DPS (0x0A)

// v3.5 session negotiation command codes
private let CMD_SESS_NEG_START:  UInt32 = 3
private let CMD_SESS_NEG_FINISH: UInt32 = 5
// v3.5 post-session command codes
private let CMD_CONTROL_NEW:  UInt32 = 13  // 0x0d — set DPS
private let CMD_DP_QUERY_NEW: UInt32 = 16  // 0x10 — query DPS

// MARK: - Helpers
private extension UInt32 {
    var be: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}
private extension UInt16 {
    var be: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}

private func crc32(_ data: Data) -> UInt32 {
    var v: UInt32 = 0xFFFF_FFFF
    for b in data {
        var x = UInt32(b)
        for _ in 0..<8 { v = ((v ^ x) & 1) != 0 ? (v >> 1) ^ 0xEDB8_8320 : v >> 1; x >>= 1 }
    }
    return v ^ 0xFFFF_FFFF
}

// MARK: - AES-128-ECB (v3.3 only)
private func aesECBEncrypt(_ data: Data, key: Data) throws -> Data {
    let blockSize = kCCBlockSizeAES128
    let padLen = blockSize - (data.count % blockSize)
    var padded = data
    padded.append(contentsOf: repeatElement(UInt8(padLen), count: padLen))
    let outputLen = padded.count + blockSize
    var output = [UInt8](repeating: 0, count: outputLen)
    var numBytes = 0
    let status = padded.withUnsafeBytes { ip in key.withUnsafeBytes { kp in
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode), kp.baseAddress, key.count, nil,
                ip.baseAddress, padded.count, &output, outputLen, &numBytes)
    }}
    guard status == kCCSuccess else { throw TuyaError.encryptionError }
    return Data(output.prefix(numBytes))
}

private func aesECBDecrypt(_ data: Data, key: Data) throws -> Data {
    let outputLen = data.count + kCCBlockSizeAES128
    var output = [UInt8](repeating: 0, count: outputLen)
    var numBytes = 0
    let status = data.withUnsafeBytes { ip in key.withUnsafeBytes { kp in
        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode), kp.baseAddress, key.count, nil,
                ip.baseAddress, data.count, &output, outputLen, &numBytes)
    }}
    guard status == kCCSuccess else { throw TuyaError.encryptionError }
    var result = Data(output.prefix(numBytes))
    if let last = result.last, last > 0, last <= 16, result.count >= Int(last) {
        result = result.dropLast(Int(last))
    }
    return result
}

// MARK: - TCP Session
private final class TuyaSession {
    private let connection: NWConnection
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "tuya.session")

    init(host: String) {
        connection = NWConnection(
            to: .hostPort(host: .init(host), port: .init(rawValue: TUYA_PORT)!),
            using: .tcp
        )
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = _OnceFlag()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard once.fire() else { return }
                    self?.connection.stateUpdateHandler = nil; c.resume()
                case .failed(let e):
                    guard once.fire() else { return }; c.resume(throwing: e)
                case .cancelled:
                    guard once.fire() else { return }
                    c.resume(throwing: TuyaError.connectionFailed)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        scheduleReceive()
    }

    func disconnect() { connection.cancel() }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = _OnceFlag()
            connection.send(content: data, completion: .contentProcessed { err in
                guard once.fire() else { return }
                if let err { c.resume(throwing: err) } else { c.resume() }
            })
        }
    }

    private var waiters: [CheckedContinuation<Data, Error>] = []

    func receivePacket(timeout: TimeInterval = 5) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { c in
                    self.queue.async { self.waiters.append(c); self.drainWaiters() }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TuyaError.timeout
            }
            guard let result = try await group.next() else { throw TuyaError.timeout }
            group.cancelAll()
            return result
        }
    }

    private func scheduleReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { self.queue.async { self.receiveBuffer += data; self.drainWaiters() } }
            if !done, err == nil { self.scheduleReceive() }
            else if let err { self.queue.async { self.waiters.forEach { $0.resume(throwing: err) }; self.waiters = [] } }
        }
    }

    private func drainWaiters() {
        while !waiters.isEmpty, let pkt = extractPacket() {
            waiters.removeFirst().resume(returning: pkt)
        }
    }

    private func extractPacket() -> Data? {
        guard receiveBuffer.count >= 16 else { return nil }
        let p4 = receiveBuffer.prefix(4)
        let is55 = p4 == PREFIX_55AA
        let is66 = p4 == PREFIX_6699
        guard is55 || is66 else { receiveBuffer.removeFirst(); return extractPacket() }
        // 55AA: msgLen at byte 12 (header=16)
        // 6699: msgLen at byte 16 (header=20: prefix4+seqHi2+seqLo2+cmd4+retcode4+msgLen4)
        let lenOff = is55 ? 12 : 16
        guard receiveBuffer.count >= lenOff + 4 else { return nil }
        let msgLen = receiveBuffer[lenOff..<(lenOff+4)].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let headerLen = is55 ? 16 : 20
        // 6699: suffix (4 bytes) is NOT included in msgLen, so add separately
        let totalLen = headerLen + Int(msgLen) + (is66 ? 4 : 0)
        guard receiveBuffer.count >= totalLen else { return nil }
        let pkt = Data(receiveBuffer.prefix(totalLen))
        receiveBuffer.removeFirst(totalLen)
        return pkt
    }
}

// MARK: - TuyaLocalService
enum TuyaLocalService {

    struct Config {
        let host: String
        let deviceID: String
        let localKeyData: Data
    }

    // Per-host protocol version cache (in-memory, resets on app restart)
    private enum Proto { case v33, v34, v35 }
    private static var protoCache = [String: Proto]()

    // MARK: - Public API
    // Detection order: v3.3 (no handshake) → v3.5 (6699) → v3.4 (55AA+session)
    static func getStatus(config: Config) async throws -> PlugStatus {
        switch protoCache[config.host] {
        case .v33: return try await getStatus_v33(config: config)
        case .v34: return try await getStatus_v34(config: config)
        case .v35: return try await getStatus_v35(config: config)
        case nil:
            if let r = try? await getStatus_v33(config: config) { protoCache[config.host] = .v33; return r }
            if let r = try? await getStatus_v35(config: config) { protoCache[config.host] = .v35; return r }
            let r = try await getStatus_v34(config: config)
            protoCache[config.host] = .v34; return r
        }
    }

    static func setPower(_ on: Bool, config: Config) async throws {
        switch protoCache[config.host] {
        case .v33: try await setPower_v33(on, config: config)
        case .v34: try await setPower_v34(on, config: config)
        case .v35: try await setPower_v35(on, config: config)
        case nil:
            if (try? await setPower_v33(on, config: config)) != nil { protoCache[config.host] = .v33; return }
            if (try? await setPower_v35(on, config: config)) != nil { protoCache[config.host] = .v35; return }
            try await setPower_v34(on, config: config)
            protoCache[config.host] = .v34
        }
    }

    // MARK: - v3.3 implementation
    private static func getStatus_v33(config: Config) async throws -> PlugStatus {
        let session = TuyaSession(host: config.host)
        try await session.connect()
        defer { session.disconnect() }
        let ts = Int(Date().timeIntervalSince1970)
        let json = try JSONSerialization.data(withJSONObject: [
            "gwId": config.deviceID, "devId": config.deviceID,
            "uid": config.deviceID, "t": "\(ts)"
        ])
        try await session.send(try pack33(seqno: 1, cmd: CMD_DP_QUERY, json: json, key: config.localKeyData))
        let resp = try await session.receivePacket(timeout: 4)
        return try parseDPS(try unpack33(resp, key: config.localKeyData))
    }

    private static func setPower_v33(_ on: Bool, config: Config) async throws {
        let session = TuyaSession(host: config.host)
        try await session.connect()
        defer { session.disconnect() }
        let ts = Int(Date().timeIntervalSince1970)
        let json = try JSONSerialization.data(withJSONObject: [
            "devId": config.deviceID, "uid": config.deviceID,
            "t": "\(ts)", "dps": ["1": on]
        ])
        try await session.send(try pack33(seqno: 1, cmd: CMD_CONTROL, json: json, key: config.localKeyData))
        _ = try? await session.receivePacket(timeout: 3)
    }

    private static func pack33(seqno: UInt32, cmd: UInt32, json: Data, key: Data) throws -> Data {
        let payload = VERSION_33_HEADER + (try aesECBEncrypt(json, key: key))
        let msgLen = UInt32(payload.count + 8)  // CRC32(4) + suffix(4)
        var d = PREFIX_55AA + seqno.be + cmd.be + msgLen.be + payload
        d += crc32(d).be + SUFFIX_55AA
        return d
    }

    private static func unpack33(_ data: Data, key: Data) throws -> Data {
        guard data.count >= 20 else { throw TuyaError.invalidResponse }
        let msgLen = data[12..<16].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let end = min(16 + Int(msgLen) - 8, data.count)   // strip CRC(4) + suffix(4)
        guard end > 16 else { throw TuyaError.invalidResponse }
        var payload = Data(data[16..<end])
        // Strip 15-byte version header if present
        if payload.count >= 15 && payload.prefix(3) == Data("3.3".utf8) {
            payload = Data(payload.dropFirst(15))
        }
        guard !payload.isEmpty else { throw TuyaError.invalidResponse }
        return try aesECBDecrypt(payload, key: key)
    }

    // MARK: - v3.4 implementation
    // Same session negotiation as v3.5, but commands use 55AA (not 6699):
    //   payload = VERSION_34_HEADER + AES-GCM(session_key, nonce+ct+tag)
    //   AAD     = 55AA header (16 bytes)
    //   end     = HMAC-SHA256(session_key, header+payload) + suffix  (36 bytes)
    private static func getStatus_v34(config: Config) async throws -> PlugStatus {
        try await withSessionKey(config: config) { session, sessionKey, nextSeq in
            let ts = Int(Date().timeIntervalSince1970)
            let json = try JSONSerialization.data(withJSONObject: [
                "devId": config.deviceID, "uid": config.deviceID, "t": "\(ts)"
            ])
            let pkt = try pack34(seqno: nextSeq(), cmd: CMD_DP_QUERY_NEW,
                                 json: json, sessionKey: sessionKey)
            try await session.send(pkt)
            let resp = try await session.receivePacket()
            return try parseDPS(try unpack34(resp, sessionKey: sessionKey))
        }
    }

    private static func setPower_v34(_ on: Bool, config: Config) async throws {
        try await withSessionKey(config: config) { session, sessionKey, nextSeq in
            let ts = Int(Date().timeIntervalSince1970)
            let json = try JSONSerialization.data(withJSONObject: [
                "devId": config.deviceID, "uid": config.deviceID,
                "t": "\(ts)", "dps": ["1": on]
            ])
            let pkt = try pack34(seqno: nextSeq(), cmd: CMD_CONTROL_NEW,
                                 json: json, sessionKey: sessionKey)
            try await session.send(pkt)
            _ = try? await session.receivePacket()
        }
    }

    // Build v3.4 55AA command packet
    private static func pack34(seqno: UInt32, cmd: UInt32, json: Data, sessionKey: Data) throws -> Data {
        let plaintext = VERSION_34_HEADER + json           // 15 + json bytes
        // payload = nonce(12) + ciphertext + tag(16); len = plaintext.count + 28
        let payloadLen = plaintext.count + 28
        let msgLen = UInt32(payloadLen + 36)               // HMAC(32) + suffix(4)
        let header = PREFIX_55AA + seqno.be + cmd.be + msgLen.be   // 16 bytes
        let nonce  = AES.GCM.Nonce()
        let sk     = SymmetricKey(data: sessionKey)
        let box    = try AES.GCM.seal(plaintext, using: sk, nonce: nonce, authenticating: header)
        var d = header + Data(nonce) + box.ciphertext + box.tag
        d += Data(HMAC<SHA256>.authenticationCode(for: d, using: sk)) + SUFFIX_55AA
        return d
    }

    // Decode v3.4 55AA response packet
    private static func unpack34(_ data: Data, sessionKey: Data) throws -> Data {
        guard data.count >= 20 else { throw TuyaError.invalidResponse }
        let header = data.prefix(16)                       // 55AA header as AAD
        let msgLen = data[12..<16].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let payEnd = min(16 + Int(msgLen) - 36, data.count)   // strip HMAC(32)+suffix(4)
        guard payEnd >= 16 + 28 else { throw TuyaError.invalidResponse }
        let body = data[16..<payEnd]                       // nonce(12) + ct + tag(16)
        let iv   = body.prefix(12)
        let tag  = body.suffix(16)
        let ct   = body.dropFirst(12).dropLast(16)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sk    = SymmetricKey(data: sessionKey)
        let box   = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let plain = try AES.GCM.open(box, using: sk, authenticating: header)
        return stripToJSON(plain)                          // strip VERSION_34_HEADER + find JSON
    }

    // MARK: - v3.5 implementation
    private static func getStatus_v35(config: Config) async throws -> PlugStatus {
        try await withSessionKey(config: config) { session, sessionKey, nextSeq in
            let ts = Int(Date().timeIntervalSince1970)
            let json = try JSONSerialization.data(withJSONObject: [
                "devId": config.deviceID, "uid": config.deviceID, "t": "\(ts)"
            ])
            let pkt = try encode6699(cmd: CMD_DP_QUERY_NEW, payload: json,
                                     sessionKey: sessionKey, seqno: nextSeq())
            try await session.send(pkt)
            let resp = try await session.receivePacket()
            let plain = try decode6699(resp, sessionKey: sessionKey)
            return try parseDPS(stripToJSON(plain))
        }
    }

    private static func setPower_v35(_ on: Bool, config: Config) async throws {
        try await withSessionKey(config: config) { session, sessionKey, nextSeq in
            let ts = Int(Date().timeIntervalSince1970)
            let json = try JSONSerialization.data(withJSONObject: [
                "devId": config.deviceID, "uid": config.deviceID,
                "t": "\(ts)", "dps": ["1": on]
            ])
            let pkt = try encode6699(cmd: CMD_CONTROL_NEW, payload: json,
                                     sessionKey: sessionKey, seqno: nextSeq())
            try await session.send(pkt)
            _ = try? await session.receivePacket()
        }
    }

    // MARK: - v3.5 session key negotiation
    @discardableResult
    private static func withSessionKey<T>(
        config: Config,
        work: (TuyaSession, Data, () -> UInt32) async throws -> T
    ) async throws -> T {
        let session = TuyaSession(host: config.host)
        try await session.connect()
        defer { session.disconnect() }

        var seqno: UInt32 = 1
        func nextSeq() -> UInt32 { let s = seqno; seqno += 1; return s }

        let localNonce = Data("0123456789abcdef".utf8)   // 16 bytes
        let step1 = pack55_v35(seqno: nextSeq(), cmd: CMD_SESS_NEG_START,
                               payload: localNonce, key: config.localKeyData)
        try await session.send(step1)

        let resp = try await session.receivePacket()
        let rPayload = unpack55_payload_v35(resp)
        guard rPayload.count >= 48 else { throw TuyaError.sessionNegotiationFailed }
        let remoteNonce  = rPayload.prefix(16)
        let receivedHMAC = rPayload[16..<48]

        let symKey = SymmetricKey(data: config.localKeyData)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: localNonce, using: symKey))
        guard expected == Data(receivedHMAC) else { throw TuyaError.hmacMismatch }

        let finishMAC = Data(HMAC<SHA256>.authenticationCode(for: Data(remoteNonce), using: symKey))
        let step3 = pack55_v35(seqno: nextSeq(), cmd: CMD_SESS_NEG_FINISH,
                               payload: finishMAC, key: config.localKeyData)
        try await session.send(step3)

        // Derive session key: AES-GCM(key=localKey, iv=localNonce[:12], plain=localNonce⊕remoteNonce).ciphertext[:16]
        let xored = Data(zip(localNonce, remoteNonce).map { $0 ^ $1 })
        let iv     = try AES.GCM.Nonce(data: localNonce.prefix(12))
        let sealed = try AES.GCM.seal(xored, using: symKey, nonce: iv)
        let sessionKey = Data(sealed.ciphertext.prefix(16))

        return try await work(session, sessionKey, nextSeq)
    }

    // 55AA v3.5 builder: end-field = HMAC-SHA256(localKey, header+payload) + suffix (36 bytes total)
    private static func pack55_v35(seqno: UInt32, cmd: UInt32, payload: Data, key: Data) -> Data {
        let msgLen = UInt32(payload.count + 36)   // HMAC(32) + suffix(4)
        var d = PREFIX_55AA + seqno.be + cmd.be + msgLen.be + payload
        d += Data(HMAC<SHA256>.authenticationCode(for: d, using: SymmetricKey(data: key))) + SUFFIX_55AA
        return d
    }

    private static func unpack55_payload_v35(_ data: Data) -> Data {
        guard data.count >= 20 else { return Data() }
        let msgLen = data[12..<16].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let end = min(16 + Int(msgLen) - 36, data.count)   // -36: HMAC(32)+suffix(4)
        return end > 16 ? Data(data[16..<end]) : Data()
    }

    // MARK: - 6699 encode/decode (v3.5 commands)
    // Header layout (20 bytes):
    //   prefix(4) + seqHi(2) + seqLo(2) + cmd(4) + retcode(4) + msgLen(4)
    // msgLen = nonce(12) + ciphertext + tag(16)
    // Packet = header(20) + nonce(12) + ciphertext + tag(16) + suffix(4)
    private static func encode6699(cmd: UInt32, payload: Data,
                                   sessionKey: Data, seqno: UInt32) throws -> Data {
        let full    = VERSION_35_HEADER + payload
        let msgLen  = UInt32(full.count + 28)          // nonce(12) + tag(16)
        let header  = PREFIX_6699
                    + UInt16(seqno >> 16).be
                    + UInt16(seqno & 0xFFFF).be
                    + cmd.be
                    + UInt32(0).be                     // retcode
                    + msgLen.be
        let aad     = Data(header.dropFirst(4))        // bytes 4‥19 (16 bytes)
        let nonce   = AES.GCM.Nonce()
        let sk      = SymmetricKey(data: sessionKey)
        let box     = try AES.GCM.seal(full, using: sk, nonce: nonce, authenticating: aad)
        return header + Data(nonce) + box.ciphertext + box.tag + SUFFIX_6699
    }

    private static func decode6699(_ data: Data, sessionKey: Data) throws -> Data {
        guard data.count >= 52 else { throw TuyaError.invalidResponse }
        let header = data.prefix(20)
        let aad    = Data(header.dropFirst(4))          // 16 bytes
        let body   = data.dropFirst(20).dropLast(4)     // strip header(20) + suffix(4)
        guard body.count >= 28 else { throw TuyaError.invalidResponse }
        let iv  = body.prefix(12)
        let tag = body.suffix(16)
        let ct  = body.dropFirst(12).dropLast(16)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sk    = SymmetricKey(data: sessionKey)
        let box   = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: sk, authenticating: aad)
    }

    // MARK: - Shared helpers
    private static func parseDPS(_ data: Data) throws -> PlugStatus {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dps  = dict["dps"] as? [String: Any] else { throw TuyaError.noStatus }
        let power: Bool
        if let b = dps["1"] as? Bool      { power = b }
        else if let i = dps["1"] as? Int  { power = i != 0 }
        else { throw TuyaError.noStatus }
        // DPS "19" = power in 0.1 W units on most Tuya power-monitoring plugs
        let watts: Double?
        if let raw = dps["19"] as? Int    { watts = Double(raw) / 10.0 }
        else if let raw = dps["19"] as? Double { watts = raw / 10.0 }
        else { watts = nil }
        return PlugStatus(power: power, watts: watts)
    }

    private static func stripToJSON(_ data: Data) -> Data {
        guard let idx = data.firstIndex(of: UInt8(ascii: "{")) else { return data }
        return Data(data[idx...])
    }
}

// MARK: - Config convenience init
extension TuyaLocalService.Config {
    // localKey: 16-char ASCII (from tinytuya) OR 32-char hex string
    init?(host: String, deviceID: String, localKey: String) {
        guard !host.isEmpty, !deviceID.isEmpty, !localKey.isEmpty else { return nil }
        let keyData: Data
        if localKey.count == 32, let hex = Data(hexString: localKey) {
            keyData = hex
        } else {
            keyData = Data(localKey.utf8)
        }
        guard keyData.count == 16 else { return nil }
        self.host = host
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .components(separatedBy: ":").first ?? host
        self.deviceID = deviceID
        self.localKeyData = keyData
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var d = Data(); var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2)
            guard let b = UInt8(hexString[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        self = d
    }
}
