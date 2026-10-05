//
//  ARMaxDecrypt.swift
//  ManicEmu
//
//  Port of Dolphin's Action Replay Max decryptor (GCNcrypt / ARDecrypt.cpp).
//  Converts `XXXX-YYYY-ZZZZZ` lines into Dolphin Action Replay `XXXXXXXX YYYYYYYY`.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum ARMaxDecrypt {
    /// Decrypt an ARMax cheat into libretro Action Replay form (`XXXXXXXX YYYYYYYY` joined by `+`).
    static func toActionReplay(_ code: String) -> String? {
        let lines = normalizedEncryptedLines(code)
        guard !lines.isEmpty else { return nil }
        guard let ops = decrypt(lines), !ops.isEmpty else { return nil }
        return ops.map { String(format: "%08X %08X", $0.0, $0.1) }.joined(separator: "+")
    }

    private static func normalizedEncryptedLines(_ code: String) -> [String] {
        let chunks = code
            .replacingOccurrences(of: "+", with: "\n")
            .components(separatedBy: .newlines)
        var lines: [String] = []
        for chunk in chunks {
            let compact = chunk
                .uppercased()
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
                .filter { !$0.isWhitespace }
            guard !compact.isEmpty else { continue }
            guard compact.count == 13 else { return [] }
            lines.append(compact)
        }
        return lines
    }

    private static func decrypt(_ encryptedLines: [String]) -> [(UInt32, UInt32)]? {
        guard var codes = convertAlphaToBinary(encryptedLines) else { return nil }
        guard codes.count >= 2, codes.count.isMultiple(of: 2) else { return nil }

        let seeds = Self.seeds
        for i in stride(from: 0, to: codes.count, by: 2) {
            decryptCode(seeds: seeds, code: &codes, index: i)
        }

        let nibble = codes[0] >> 28
        codes[0] &= 0x0FFF_FFFF
        let crcOk = nibble == verifyCode(codes)

        var ops: [(UInt32, UInt32)] = []
        let start = crcOk ? 2 : 0
        guard start < codes.count else { return ops }
        for i in stride(from: start, to: codes.count, by: 2) {
            ops.append((codes[i], codes[i + 1]))
        }
        return ops
    }

    private static func convertAlphaToBinary(_ alpha: [String]) -> [UInt32]? {
        var result: [UInt32] = []
        result.reserveCapacity(alpha.count * 2)
        for line in alpha {
            guard line.count == 13, let valueA = packedValue(line, start: 0, extraShift: 2, extraChar: 6, extraRightShift: 3),
                  let valueB = packedValue(line, start: 6, extraShift: 4, extraChar: 12, extraRightShift: 1) else {
                return nil
            }
            let parity = (valueA ^ valueB).nonzeroBitCount
            guard (parity & 1) == (getVal(charAt(line, 12)) & 1) else { return nil }
            result.append(valueA)
            result.append(valueB)
        }
        return result
    }

    private static func packedValue(_ line: String, start: Int, extraShift: Int, extraChar: Int, extraRightShift: Int) -> UInt32? {
        var value = getVal(charAt(line, extraChar)) >> extraRightShift
        for i in 0..<6 {
            let shift = ((5 - i) * 5) + extraShift
            value |= getVal(charAt(line, start + i)) &<< shift
        }
        return value
    }

    private static func charAt(_ line: String, _ index: Int) -> Character {
        let i = line.index(line.startIndex, offsetBy: index)
        return line[i]
    }

    private static let filter = Array("0123456789ABCDEFGHJKMNPQRTUVWXYZILOS")

    private static func getVal(_ chr: Character) -> UInt32 {
        let upper: Character
        if let ascii = chr.asciiValue, (97...122).contains(ascii) {
            upper = Character(UnicodeScalar(ascii - 32))
        } else {
            upper = chr
        }
        guard let ret = filter.firstIndex(of: upper) else { return 0xFF }
        switch ret {
        case 32, 33: return 1
        case 34: return 0
        case 35: return 5
        default: return UInt32(ret)
        }
    }

    private static func swap32(_ x: UInt32) -> UInt32 { x.byteSwapped }

    private static func rotl(_ x: UInt32, _ n: Int) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }

    private static func rotr(_ x: UInt32, _ n: Int) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    private static func getCode(_ codes: [UInt32], _ index: Int) -> (UInt32, UInt32) {
        (swap32(codes[index]), swap32(codes[index + 1]))
    }

    private static func setCode(_ codes: inout [UInt32], _ index: Int, addr: UInt32, val: UInt32) {
        codes[index] = swap32(addr)
        codes[index + 1] = swap32(val)
    }

    private static func getCRC16(_ codes: [UInt32]) -> UInt16 {
        var ret: UInt16 = 0
        for code in codes {
            for i in 0..<4 {
                let tmp = UInt8(truncatingIfNeeded: (code >> (i << 3)) ^ UInt32(ret))
                ret = crctable0[Int((tmp >> 4) & 0x0F)] ^ crctable1[Int(tmp & 0x0F)] ^ (ret >> 8)
            }
        }
        return ret
    }

    private static func verifyCode(_ codes: [UInt32]) -> UInt32 {
        let tmp = getCRC16(codes)
        return UInt32(((tmp >> 12) ^ (tmp >> 8) ^ (tmp >> 4) ^ tmp) & 0x0F)
    }

    private static func unscramble1(addr: inout UInt32, val: inout UInt32) {
        var tmp: UInt32 = 0
        val = rotl(val, 4)
        tmp = (addr ^ val) & 0xF0F0_F0F0
        addr ^= tmp
        val = rotr(val ^ tmp, 0x14)
        tmp = (addr ^ val) & 0xFFFF_0000
        addr ^= tmp
        val = rotr(val ^ tmp, 0x12)
        tmp = (addr ^ val) & 0x3333_3333
        addr ^= tmp
        val = rotr(val ^ tmp, 6)
        tmp = (addr ^ val) & 0x00FF_00FF
        addr ^= tmp
        val = rotl(val ^ tmp, 9)
        tmp = (addr ^ val) & 0xAAAA_AAAA
        addr = rotl(addr ^ tmp, 1)
        val ^= tmp
    }

    private static func unscramble2(addr: inout UInt32, val: inout UInt32) {
        var tmp: UInt32 = 0
        val = rotr(val, 1)
        tmp = (addr ^ val) & 0xAAAA_AAAA
        val ^= tmp
        addr = rotr(addr ^ tmp, 9)
        tmp = (addr ^ val) & 0x00FF_00FF
        val ^= tmp
        addr = rotl(addr ^ tmp, 6)
        tmp = (addr ^ val) & 0x3333_3333
        val ^= tmp
        addr = rotl(addr ^ tmp, 0x12)
        tmp = (addr ^ val) & 0xFFFF_0000
        val ^= tmp
        addr = rotl(addr ^ tmp, 0x14)
        tmp = (addr ^ val) & 0xF0F0_F0F0
        val ^= tmp
        addr = rotr(addr ^ tmp, 4)
    }

    private static func decryptCode(seeds: [UInt32], code: inout [UInt32], index: Int) {
        var addr: UInt32
        var val: UInt32
        (addr, val) = getCode(code, index)
        unscramble1(addr: &addr, val: &val)

        var i = 0
        while i < 32 {
            var tmp = rotr(val, 4) ^ seeds[i]
            i += 1
            var tmp2 = val ^ seeds[i]
            i += 1
            addr ^= table6[Int(tmp & 0x3F)]
            addr ^= table4[Int((tmp >> 8) & 0x3F)]
            addr ^= table2[Int((tmp >> 16) & 0x3F)]
            addr ^= table0[Int((tmp >> 24) & 0x3F)]
            addr ^= table7[Int(tmp2 & 0x3F)]
            addr ^= table5[Int((tmp2 >> 8) & 0x3F)]
            addr ^= table3[Int((tmp2 >> 16) & 0x3F)]
            addr ^= table1[Int((tmp2 >> 24) & 0x3F)]

            tmp = rotr(addr, 4) ^ seeds[i]
            i += 1
            tmp2 = addr ^ seeds[i]
            i += 1
            val ^= table6[Int(tmp & 0x3F)]
            val ^= table4[Int((tmp >> 8) & 0x3F)]
            val ^= table2[Int((tmp >> 16) & 0x3F)]
            val ^= table0[Int((tmp >> 24) & 0x3F)]
            val ^= table7[Int(tmp2 & 0x3F)]
            val ^= table5[Int((tmp2 >> 8) & 0x3F)]
            val ^= table3[Int((tmp2 >> 16) & 0x3F)]
            val ^= table1[Int((tmp2 >> 24) & 0x3F)]
        }
        unscramble2(addr: &addr, val: &val)
        setCode(&code, index, addr: val, val: addr)
    }

    private static let gentable0: [UInt8] = [
        0x39, 0x31, 0x29, 0x21, 0x19, 0x11, 0x09, 0x01, 0x3A, 0x32, 0x2A, 0x22, 0x1A, 0x12,
        0x0A, 0x02, 0x3B, 0x33, 0x2B, 0x23, 0x1B, 0x13, 0x0B, 0x03, 0x3C, 0x34, 0x2C, 0x24,
        0x3F, 0x37, 0x2F, 0x27, 0x1F, 0x17, 0x0F, 0x07, 0x3E, 0x36, 0x2E, 0x26, 0x1E, 0x16,
        0x0E, 0x06, 0x3D, 0x35, 0x2D, 0x25, 0x1D, 0x15, 0x0D, 0x05, 0x1C, 0x14, 0x0C, 0x04
    ]
    private static let gentable1: [UInt8] = [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01]
    private static let gentable2: [UInt8] = [
        0x01, 0x02, 0x04, 0x06, 0x08, 0x0A, 0x0C, 0x0E, 0x0F, 0x11, 0x13, 0x15, 0x17, 0x19, 0x1B, 0x1C
    ]
    private static let gentable3: [UInt8] = [
        0x0E, 0x11, 0x0B, 0x18, 0x01, 0x05, 0x03, 0x1C, 0x0F, 0x06, 0x15, 0x0A, 0x17, 0x13, 0x0C, 0x04,
        0x1A, 0x08, 0x10, 0x07, 0x1B, 0x14, 0x0D, 0x02, 0x29, 0x34, 0x1F, 0x25, 0x2F, 0x37, 0x1E, 0x28,
        0x33, 0x2D, 0x21, 0x30, 0x2C, 0x31, 0x27, 0x38, 0x22, 0x35, 0x2E, 0x2A, 0x32, 0x24, 0x1D, 0x20
    ]
    private static let gensubtable: [UInt8] = [0x34, 0x1C, 0x84, 0x9E, 0xFD, 0xA4, 0xB6, 0x7B]
    private static let crctable0: [UInt16] = [
        0x0000, 0x1081, 0x2102, 0x3183, 0x4204, 0x5285, 0x6306, 0x7387,
        0x8408, 0x9489, 0xA50A, 0xB58B, 0xC60C, 0xD68D, 0xE70E, 0xF78F
    ]
    private static let crctable1: [UInt16] = [
        0x0000, 0x1189, 0x2312, 0x329B, 0x4624, 0x57AD, 0x6536, 0x74BF,
        0x8C48, 0x9DC1, 0xAF5A, 0xBED3, 0xCA6C, 0xDBE5, 0xE97E, 0xF8F7
    ]

    private static let seeds: [UInt32] = {
        var array0 = [UInt8](repeating: 0, count: 0x38)
        var array1 = [UInt8](repeating: 0, count: 0x38)
        var array2 = [UInt8](repeating: 0, count: 0x38)
        var seeds = [UInt32](repeating: 0, count: 0x30)

        for i in 0..<array0.count {
            let tmp = UInt8(gentable0[i] &- 1)
            let mask = gensubtable[Int(tmp >> 3)] & gentable1[Int(tmp & 7)]
            array0[i] = mask == 0 ? 0 : 1
        }

        for i in 0..<0x10 {
            for j in 0..<8 { array2[j] = 0 }
            let tmp2 = gentable2[i]
            for j in 0..<0x38 {
                var tmp = UInt8(truncatingIfNeeded: Int(tmp2) + j)
                if j > 0x1B {
                    if tmp > 0x37 { tmp &-= 0x1C }
                } else if tmp > 0x1B {
                    tmp &-= 0x1C
                }
                array1[j] = array0[Int(tmp)]
            }
            for j in 0..<0x30 {
                if array1[Int(gentable3[j]) - 1] == 0 { continue }
                let tmp = UInt8((((UInt32(j) &* 0x2AAB) >> 16) &- (UInt32(j) >> 0x1F)) & 0xFF)
                array2[Int(tmp)] |= gentable1[j - (Int(tmp) * 6)] >> 2
            }
            seeds[i << 1] = (UInt32(array2[0]) << 24) | (UInt32(array2[2]) << 16) | (UInt32(array2[4]) << 8) | UInt32(array2[6])
            seeds[(i << 1) + 1] = (UInt32(array2[1]) << 24) | (UInt32(array2[3]) << 16) | (UInt32(array2[5]) << 8) | UInt32(array2[7])
        }

        var j = 0x1F
        for i in stride(from: 0, to: 16, by: 2) {
            seeds.swapAt(i, j - 1)
            seeds.swapAt(i + 1, j)
            j -= 2
        }
        return seeds
    }()

    private static let table0: [UInt32] = [
        0x01010400, 0x00000000, 0x00010000, 0x01010404, 0x01010004, 0x00010404, 0x00000004, 0x00010000,
        0x00000400, 0x01010400, 0x01010404, 0x00000400, 0x01000404, 0x01010004, 0x01000000, 0x00000004,
        0x00000404, 0x01000400, 0x01000400, 0x00010400, 0x00010400, 0x01010000, 0x01010000, 0x01000404,
        0x00010004, 0x01000004, 0x01000004, 0x00010004, 0x00000000, 0x00000404, 0x00010404, 0x01000000,
        0x00010000, 0x01010404, 0x00000004, 0x01010000, 0x01010400, 0x01000000, 0x01000000, 0x00000400,
        0x01010004, 0x00010000, 0x00010400, 0x01000004, 0x00000400, 0x00000004, 0x01000404, 0x00010404,
        0x01010404, 0x00010004, 0x01010000, 0x01000404, 0x01000004, 0x00000404, 0x00010404, 0x01010400,
        0x00000404, 0x01000400, 0x01000400, 0x00000000, 0x00010004, 0x00010400, 0x00000000, 0x01010004
    ]
    private static let table1: [UInt32] = [
        0x80108020, 0x80008000, 0x00008000, 0x00108020, 0x00100000, 0x00000020, 0x80100020, 0x80008020,
        0x80000020, 0x80108020, 0x80108000, 0x80000000, 0x80008000, 0x00100000, 0x00000020, 0x80100020,
        0x00108000, 0x00100020, 0x80008020, 0x00000000, 0x80000000, 0x00008000, 0x00108020, 0x80100000,
        0x00100020, 0x80000020, 0x00000000, 0x00108000, 0x00008020, 0x80108000, 0x80100000, 0x00008020,
        0x00000000, 0x00108020, 0x80100020, 0x00100000, 0x80008020, 0x80100000, 0x80108000, 0x00008000,
        0x80100000, 0x80008000, 0x00000020, 0x80108020, 0x00108020, 0x00000020, 0x00008000, 0x80000000,
        0x00008020, 0x80108000, 0x00100000, 0x80000020, 0x00100020, 0x80008020, 0x80000020, 0x00100020,
        0x00108000, 0x00000000, 0x80008000, 0x00008020, 0x80000000, 0x80100020, 0x80108020, 0x00108000
    ]
    private static let table2: [UInt32] = [
        0x00000208, 0x08020200, 0x00000000, 0x08020008, 0x08000200, 0x00000000, 0x00020208, 0x08000200,
        0x00020008, 0x08000008, 0x08000008, 0x00020000, 0x08020208, 0x00020008, 0x08020000, 0x00000208,
        0x08000000, 0x00000008, 0x08020200, 0x00000200, 0x00020200, 0x08020000, 0x08020008, 0x00020208,
        0x08000208, 0x00020200, 0x00020000, 0x08000208, 0x00000008, 0x08020208, 0x00000200, 0x08000000,
        0x08020200, 0x08000000, 0x00020008, 0x00000208, 0x00020000, 0x08020200, 0x08000200, 0x00000000,
        0x00000200, 0x00020008, 0x08020208, 0x08000200, 0x08000008, 0x00000200, 0x00000000, 0x08020008,
        0x08000208, 0x00020000, 0x08000000, 0x08020208, 0x00000008, 0x00020208, 0x00020200, 0x08000008,
        0x08020000, 0x08000208, 0x00000208, 0x08020000, 0x00020208, 0x00000008, 0x08020008, 0x00020200
    ]
    private static let table3: [UInt32] = [
        0x00802001, 0x00002081, 0x00002081, 0x00000080, 0x00802080, 0x00800081, 0x00800001, 0x00002001,
        0x00000000, 0x00802000, 0x00802000, 0x00802081, 0x00000081, 0x00000000, 0x00800080, 0x00800001,
        0x00000001, 0x00002000, 0x00800000, 0x00802001, 0x00000080, 0x00800000, 0x00002001, 0x00002080,
        0x00800081, 0x00000001, 0x00002080, 0x00800080, 0x00002000, 0x00802080, 0x00802081, 0x00000081,
        0x00800080, 0x00800001, 0x00802000, 0x00802081, 0x00000081, 0x00000000, 0x00000000, 0x00802000,
        0x00002080, 0x00800080, 0x00800081, 0x00000001, 0x00802001, 0x00002081, 0x00002081, 0x00000080,
        0x00802081, 0x00000081, 0x00000001, 0x00002000, 0x00800001, 0x00002001, 0x00802080, 0x00800081,
        0x00002001, 0x00002080, 0x00800000, 0x00802001, 0x00000080, 0x00800000, 0x00002000, 0x00802080
    ]
    private static let table4: [UInt32] = [
        0x00000100, 0x02080100, 0x02080000, 0x42000100, 0x00080000, 0x00000100, 0x40000000, 0x02080000,
        0x40080100, 0x00080000, 0x02000100, 0x40080100, 0x42000100, 0x42080000, 0x00080100, 0x40000000,
        0x02000000, 0x40080000, 0x40080000, 0x00000000, 0x40000100, 0x42080100, 0x42080100, 0x02000100,
        0x42080000, 0x40000100, 0x00000000, 0x42000000, 0x02080100, 0x02000000, 0x42000000, 0x00080100,
        0x00080000, 0x42000100, 0x00000100, 0x02000000, 0x40000000, 0x02080000, 0x42000100, 0x40080100,
        0x02000100, 0x40000000, 0x42080000, 0x02080100, 0x40080100, 0x00000100, 0x02000000, 0x42080000,
        0x42080100, 0x00080100, 0x42000000, 0x42080100, 0x02080000, 0x00000000, 0x40080000, 0x42000000,
        0x00080100, 0x02000100, 0x40000100, 0x00080000, 0x00000000, 0x40080000, 0x02080100, 0x40000100
    ]
    private static let table5: [UInt32] = [
        0x20000010, 0x20400000, 0x00004000, 0x20404010, 0x20400000, 0x00000010, 0x20404010, 0x00400000,
        0x20004000, 0x00404010, 0x00400000, 0x20000010, 0x00400010, 0x20004000, 0x20000000, 0x00004010,
        0x00000000, 0x00400010, 0x20004010, 0x00004000, 0x00404000, 0x20004010, 0x00000010, 0x20400010,
        0x20400010, 0x00000000, 0x00404010, 0x20404000, 0x00004010, 0x00404000, 0x20404000, 0x20000000,
        0x20004000, 0x00000010, 0x20400010, 0x00404000, 0x20404010, 0x00400000, 0x00004010, 0x20000010,
        0x00400000, 0x20004000, 0x20000000, 0x00004010, 0x20000010, 0x20404010, 0x00404000, 0x20400000,
        0x00404010, 0x20404000, 0x00000000, 0x20400010, 0x00000010, 0x00004000, 0x20400000, 0x00404010,
        0x00004000, 0x00400010, 0x20004010, 0x00000000, 0x20404000, 0x20000000, 0x00400010, 0x20004010
    ]
    private static let table6: [UInt32] = [
        0x00200000, 0x04200002, 0x04000802, 0x00000000, 0x00000800, 0x04000802, 0x00200802, 0x04200800,
        0x04200802, 0x00200000, 0x00000000, 0x04000002, 0x00000002, 0x04000000, 0x04200002, 0x00000802,
        0x04000800, 0x00200802, 0x00200002, 0x04000800, 0x04000002, 0x04200000, 0x04200800, 0x00200002,
        0x04200000, 0x00000800, 0x00000802, 0x04200802, 0x00200800, 0x00000002, 0x04000000, 0x00200800,
        0x04000000, 0x00200800, 0x00200000, 0x04000802, 0x04000802, 0x04200002, 0x04200002, 0x00000002,
        0x00200002, 0x04000000, 0x04000800, 0x00200000, 0x04200800, 0x00000802, 0x00200802, 0x04200800,
        0x00000802, 0x04000002, 0x04200802, 0x04200000, 0x00200800, 0x00000000, 0x00000002, 0x04200802,
        0x00000000, 0x00200802, 0x04200000, 0x00000800, 0x04000002, 0x04000800, 0x00000800, 0x00200002
    ]
    private static let table7: [UInt32] = [
        0x10001040, 0x00001000, 0x00040000, 0x10041040, 0x10000000, 0x10001040, 0x00000040, 0x10000000,
        0x00040040, 0x10040000, 0x10041040, 0x00041000, 0x10041000, 0x00041040, 0x00001000, 0x00000040,
        0x10040000, 0x10000040, 0x10001000, 0x00001040, 0x00041000, 0x00040040, 0x10040040, 0x10041000,
        0x00001040, 0x00000000, 0x00000000, 0x10040040, 0x10000040, 0x10001000, 0x00041040, 0x00040000,
        0x00041040, 0x00040000, 0x10041000, 0x00001000, 0x00000040, 0x10040040, 0x00001000, 0x00041040,
        0x10001000, 0x00000040, 0x10000040, 0x10040000, 0x10040040, 0x10000000, 0x00040000, 0x10001040,
        0x00000000, 0x10041040, 0x00040040, 0x10000040, 0x10040000, 0x10001000, 0x10001040, 0x00000000,
        0x10041040, 0x00041000, 0x00041000, 0x00001040, 0x00001040, 0x00040040, 0x10000000, 0x10041000
    ]
}
