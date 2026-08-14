import Foundation

// MARK: - Minimal CBOR decoder
// Just enough of RFC 8949 to read OpenPrintTag payloads: unsigned/negative
// ints, byte/text strings, arrays, maps, floats. Returns a value tree plus the
// number of bytes consumed (needed to locate OpenPrintTag's main region).
enum CBORValue {
    case uint(UInt64)
    case int(Int64)
    case bytes([UInt8])
    case text(String)
    case array([CBORValue])
    case map([CBORKey: CBORValue])
    case float(Double)
    case bool(Bool)
    case null

    var intValue: Int? {
        switch self {
        case .uint(let v): return Int(v)
        case .int(let v):  return Int(v)
        case .float(let v): return Int(v)
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .uint(let v): return Double(v)
        case .int(let v):  return Double(v)
        case .float(let v): return v
        default: return nil
        }
    }
    var stringValue: String? { if case .text(let s) = self { return s }; return nil }
    var bytesValue: [UInt8]? { if case .bytes(let b) = self { return b }; return nil }
}

// CBOR map keys can be ints or strings; OpenPrintTag uses int keys.
enum CBORKey: Hashable {
    case int(Int)
    case text(String)
}

struct CBORDecoder {
    let bytes: [UInt8]
    var pos = 0

    init(_ data: [UInt8]) { self.bytes = data }

    mutating func decode() -> CBORValue? {
        guard pos < bytes.count else { return nil }
        let initial = bytes[pos]; pos += 1
        let major = initial >> 5
        let info = initial & 0x1F
        switch major {
        case 0: // unsigned int
            guard let v = readUInt(info) else { return nil }
            return .uint(v)
        case 1: // negative int
            guard let v = readUInt(info) else { return nil }
            return .int(-1 - Int64(v))
        case 2: // byte string
            guard let len = readUInt(info), pos + Int(len) <= bytes.count else { return nil }
            let slice = Array(bytes[pos..<pos+Int(len)]); pos += Int(len)
            return .bytes(slice)
        case 3: // text string
            guard let len = readUInt(info), pos + Int(len) <= bytes.count else { return nil }
            let slice = Array(bytes[pos..<pos+Int(len)]); pos += Int(len)
            return .text(String(decoding: slice, as: UTF8.self))
        case 4: // array
            guard let len = readUInt(info) else { return nil }
            var arr: [CBORValue] = []
            for _ in 0..<len { guard let v = decode() else { return nil }; arr.append(v) }
            return .array(arr)
        case 5: // map
            guard let len = readUInt(info) else { return nil }
            var m: [CBORKey: CBORValue] = [:]
            for _ in 0..<len {
                guard let k = decode(), let v = decode() else { return nil }
                switch k {
                case .uint(let u): m[.int(Int(u))] = v
                case .int(let i):  m[.int(Int(i))] = v
                case .text(let t): m[.text(t)] = v
                default: break
                }
            }
            return .map(m)
        case 7: // float / simple
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22, 23: return .null
            case 25: return readFloat16()
            case 26: return readFloat32()
            case 27: return readFloat64()
            default: return .null
            }
        default:
            return nil
        }
    }

    private mutating func readUInt(_ info: UInt8) -> UInt64? {
        if info < 24 { return UInt64(info) }
        let n: Int
        switch info {
        case 24: n = 1
        case 25: n = 2
        case 26: n = 4
        case 27: n = 8
        default: return nil
        }
        guard pos + n <= bytes.count else { return nil }
        var v: UInt64 = 0
        for _ in 0..<n { v = (v << 8) | UInt64(bytes[pos]); pos += 1 }
        return v
    }

    private mutating func readFloat16() -> CBORValue {
        guard pos + 2 <= bytes.count else { return .null }
        let hi = UInt16(bytes[pos]); let lo = UInt16(bytes[pos+1]); pos += 2
        let h = (hi << 8) | lo
        let sign = (h & 0x8000) != 0 ? -1.0 : 1.0
        let exp = Int((h >> 10) & 0x1F)
        let mant = Double(h & 0x3FF)
        let val: Double
        if exp == 0 { val = mant * pow(2, -24) }
        else if exp == 31 { val = mant == 0 ? .infinity : .nan }
        else { val = (1 + mant / 1024) * pow(2, Double(exp - 15)) }
        return .float(sign * val)
    }
    private mutating func readFloat32() -> CBORValue {
        guard pos + 4 <= bytes.count else { return .null }
        var u: UInt32 = 0
        for _ in 0..<4 { u = (u << 8) | UInt32(bytes[pos]); pos += 1 }
        return .float(Double(Float(bitPattern: u)))
    }
    private mutating func readFloat64() -> CBORValue {
        guard pos + 8 <= bytes.count else { return .null }
        var u: UInt64 = 0
        for _ in 0..<8 { u = (u << 8) | UInt64(bytes[pos]); pos += 1 }
        return .float(Double(bitPattern: u))
    }
}

// MARK: - OpenPrintTag parser (Prusa CBOR format)
// Reference: https://github.com/prusa3d/OpenPrintTag  ·  paxx12/PrintTag-Web
enum OpenPrintTag {
    static let mimeType = "application/vnd.openprinttag"

    // material_type enum (field 9) → abbreviation.
    private static let materialTypes: [Int: String] = [
        0:"PLA",1:"PETG",2:"ABS",3:"ASA",4:"TPU",5:"PA",6:"PA12",7:"PC",8:"PEEK",
        9:"PVA",10:"HIPS",11:"ASA-CF",12:"PCTG",13:"TPU-AMS",14:"PA-CF",15:"PA-GF",
        16:"PA6-CF",17:"PLA-CF",18:"PET-CF",19:"PETG-CF",20:"PLA-AERO",21:"PPS",
        22:"PPS-CF",23:"PPA-CF",24:"PPA-GF",25:"ABS-GF",26:"ASA-AERO",27:"PE",
        28:"PP",29:"EVA",30:"PHA",31:"BVOH",32:"PE-CF",33:"PP-CF",34:"PP-GF"
    ]

    /// Parse an OpenPrintTag NDEF payload (the raw CBOR bytes) into OpenSpoolData.
    static func parse(_ payload: Data) -> OpenSpoolData? {
        let bytes = [UInt8](payload)
        // The payload begins with a "meta" CBOR map giving the main region's
        // byte offset (key 0) and size (key 1). Decode meta, then decode the
        // main map from that slice.
        var metaDec = CBORDecoder(bytes)
        guard case .map(let meta)? = metaDec.decode() else { return nil }
        let metaConsumed = metaDec.pos
        let mainOffset = meta[.int(0)]?.intValue ?? metaConsumed
        let auxOffset = meta[.int(2)]?.intValue ?? bytes.count
        let mainSize = meta[.int(1)]?.intValue ?? (auxOffset - mainOffset)
        guard mainOffset >= 0, mainSize > 0, mainOffset + mainSize <= bytes.count else { return nil }

        var mainDec = CBORDecoder(Array(bytes[mainOffset..<mainOffset+mainSize]))
        guard case .map(let m)? = mainDec.decode() else { return nil }

        // Require this to actually look like a filament tag: needs at least a
        // material type/name or a color, else treat as "not OpenPrintTag".
        guard m[.int(9)] != nil || m[.int(10)] != nil || m[.int(19)] != nil else { return nil }

        var d = OpenSpoolData()
        d.protocol_ = "openspool"   // normalize so the rest of the app treats it uniformly

        if let t = m[.int(9)]?.intValue, let abbr = materialTypes[t] { d.type = abbr }
        if let name = m[.int(10)]?.stringValue, !name.isEmpty { d.name = name }
        if let brand = m[.int(11)]?.stringValue, !brand.isEmpty { d.brand = brand }
        if let rgba = m[.int(19)]?.bytesValue, rgba.count >= 3 {
            d.colorHex = String(format: "%02X%02X%02X", rgba[0], rgba[1], rgba[2])
        }
        if let w = m[.int(16)]?.intValue { d.weight = w }
        if let sw = m[.int(18)]?.intValue { d.spoolWeight = sw }
        if let de = m[.int(29)]?.doubleValue { d.density = de }
        if let dia = m[.int(30)]?.doubleValue { d.diameter = dia }
        if let t = m[.int(34)]?.intValue { d.minTemp = t }
        if let t = m[.int(35)]?.intValue { d.maxTemp = t }
        if let t = m[.int(37)]?.intValue { d.bedMinTemp = t }
        if let t = m[.int(38)]?.intValue { d.bedMaxTemp = t }
        if let abbr = m[.int(52)]?.stringValue, d.type == "PLA", !abbr.isEmpty { d.type = abbr }
        return d
    }
}
