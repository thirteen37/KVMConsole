import Foundation

struct RFBBigUInt: Equatable, Sendable {
    private var words: [UInt32]

    init(_ value: UInt32) {
        self.words = value == 0 ? [] : [value]
    }

    init(bigEndian data: Data) {
        var words: [UInt32] = []
        var index = data.count
        while index > 0 {
            var word: UInt32 = 0
            let start = max(0, index - 4)
            for byte in data[start..<index] {
                word = (word << 8) | UInt32(byte)
            }
            words.append(word)
            index = start
        }
        self.words = words
        normalize()
    }

    var isZero: Bool {
        words.isEmpty
    }

    func bigEndianData(paddedTo byteCount: Int) -> Data {
        var bytes = [UInt8]()
        for word in words.reversed() {
            bytes.append(UInt8((word >> 24) & 0xff))
            bytes.append(UInt8((word >> 16) & 0xff))
            bytes.append(UInt8((word >> 8) & 0xff))
            bytes.append(UInt8(word & 0xff))
        }
        while bytes.first == 0, bytes.count > 1 {
            bytes.removeFirst()
        }
        if bytes.count < byteCount {
            bytes.insert(contentsOf: repeatElement(UInt8(0), count: byteCount - bytes.count), at: 0)
        } else if bytes.count > byteCount {
            bytes = Array(bytes.suffix(byteCount))
        }
        return Data(bytes)
    }

    func bit(at index: Int) -> Bool {
        let wordIndex = index / 32
        guard wordIndex < words.count else { return false }
        return (words[wordIndex] & (UInt32(1) << UInt32(index % 32))) != 0
    }

    var bitWidth: Int {
        guard let last = words.last else { return 0 }
        return (words.count - 1) * 32 + (32 - last.leadingZeroBitCount)
    }

    static func modExp(base: RFBBigUInt, exponent: RFBBigUInt, modulus: RFBBigUInt) -> RFBBigUInt {
        if let result = montgomeryModExp(base: base, exponent: exponent, modulus: modulus) {
            return result
        }

        var result = RFBBigUInt(1)
        var base = base.modulo(modulus)
        for bitIndex in 0..<exponent.bitWidth {
            if exponent.bit(at: bitIndex) {
                result = result.multipliedModulo(by: base, modulus: modulus)
            }
            base = base.multipliedModulo(by: base, modulus: modulus)
        }
        return result
    }

    private static func montgomeryModExp(base: RFBBigUInt, exponent: RFBBigUInt, modulus: RFBBigUInt) -> RFBBigUInt? {
        guard !modulus.words.isEmpty, modulus.words[0].isMultiple(of: 2) == false else {
            return nil
        }

        let wordCount = modulus.words.count
        let modulusWords = modulus.paddedWords(count: wordCount)
        let inverse = inverseMod2To32(modulusWords[0])
        let nPrime = 0 &- inverse

        let one = RFBBigUInt(1)
        var result = one.shiftedLeftWords(wordCount).modulo(modulus).paddedWords(count: wordCount)
        var power = base.modulo(modulus).shiftedLeftWords(wordCount).modulo(modulus).paddedWords(count: wordCount)

        for bitIndex in 0..<exponent.bitWidth {
            if exponent.bit(at: bitIndex) {
                result = montgomeryMultiply(result, power, modulus: modulusWords, nPrime: nPrime)
            }
            power = montgomeryMultiply(power, power, modulus: modulusWords, nPrime: nPrime)
        }

        let normal = montgomeryMultiply(result, one.paddedWords(count: wordCount), modulus: modulusWords, nPrime: nPrime)
        return RFBBigUInt(words: normal)
    }

    private init(words: [UInt32]) {
        self.words = words
        normalize()
    }

    private func shiftedLeftWords(_ count: Int) -> RFBBigUInt {
        guard !words.isEmpty, count > 0 else { return self }
        return RFBBigUInt(words: Array(repeating: 0, count: count) + words)
    }

    private func paddedWords(count: Int) -> [UInt32] {
        if words.count >= count {
            return Array(words.prefix(count))
        }
        return words + Array(repeating: 0, count: count - words.count)
    }

    private static func inverseMod2To32(_ value: UInt32) -> UInt32 {
        var inverse = value
        for _ in 0..<5 {
            inverse = inverse &* (2 &- value &* inverse)
        }
        return inverse
    }

    private static func montgomeryMultiply(
        _ left: [UInt32],
        _ right: [UInt32],
        modulus: [UInt32],
        nPrime: UInt32
    ) -> [UInt32] {
        let wordCount = modulus.count
        var t = Array(repeating: UInt32(0), count: wordCount * 2 + 2)

        for i in 0..<wordCount {
            var carry: UInt64 = 0
            for j in 0..<wordCount {
                let index = i + j
                let product = UInt64(left[i]) * UInt64(right[j]) + UInt64(t[index]) + carry
                t[index] = UInt32(product & 0xffff_ffff)
                carry = product >> 32
            }
            addCarry(carry, to: &t, at: i + wordCount)
        }

        for i in 0..<wordCount {
            let m = t[i] &* nPrime
            var carry: UInt64 = 0
            for j in 0..<wordCount {
                let index = i + j
                let product = UInt64(m) * UInt64(modulus[j]) + UInt64(t[index]) + carry
                t[index] = UInt32(product & 0xffff_ffff)
                carry = product >> 32
            }
            addCarry(carry, to: &t, at: i + wordCount)
        }

        var result = Array(t[wordCount...(wordCount * 2)])
        if compare(result, modulus) >= 0 {
            subtract(modulus, from: &result)
        }
        return Array(result.prefix(wordCount))
    }

    private static func addCarry(_ carry: UInt64, to words: inout [UInt32], at index: Int) {
        var carry = carry
        var index = index
        while carry != 0 {
            if index == words.count {
                words.append(0)
            }
            let sum = UInt64(words[index]) + carry
            words[index] = UInt32(sum & 0xffff_ffff)
            carry = sum >> 32
            index += 1
        }
    }

    private static func compare(_ left: [UInt32], _ right: [UInt32]) -> Int {
        let count = max(left.count, right.count)
        for offset in stride(from: count - 1, through: 0, by: -1) {
            let lhs = offset < left.count ? left[offset] : 0
            let rhs = offset < right.count ? right[offset] : 0
            if lhs != rhs {
                return lhs < rhs ? -1 : 1
            }
        }
        return 0
    }

    private static func subtract(_ subtrahend: [UInt32], from words: inout [UInt32]) {
        var borrow: Int64 = 0
        for index in words.indices {
            let value = Int64(words[index]) - Int64(index < subtrahend.count ? subtrahend[index] : 0) - borrow
            if value < 0 {
                words[index] = UInt32(value + (1 << 32))
                borrow = 1
            } else {
                words[index] = UInt32(value)
                borrow = 0
            }
        }
    }

    private mutating func normalize() {
        while words.last == 0 {
            words.removeLast()
        }
    }

    private func modulo(_ modulus: RFBBigUInt) -> RFBBigUInt {
        guard self >= modulus else { return self }
        var result = RFBBigUInt(0)
        for bitIndex in stride(from: bitWidth - 1, through: 0, by: -1) {
            result.shiftLeftOne()
            if bit(at: bitIndex) {
                result.addSmall(1)
            }
            if result >= modulus {
                result.subtract(modulus)
            }
        }
        return result
    }

    private func multipliedModulo(by other: RFBBigUInt, modulus: RFBBigUInt) -> RFBBigUInt {
        var result = RFBBigUInt(0)
        var addend = self.modulo(modulus)
        for bitIndex in 0..<other.bitWidth {
            if other.bit(at: bitIndex) {
                result.add(addend)
                if result >= modulus {
                    result = result.modulo(modulus)
                }
            }
            addend.shiftLeftOne()
            if addend >= modulus {
                addend = addend.modulo(modulus)
            }
        }
        return result
    }

    private mutating func shiftLeftOne() {
        var carry: UInt32 = 0
        for index in words.indices {
            let nextCarry = words[index] >> 31
            words[index] = (words[index] << 1) | carry
            carry = nextCarry
        }
        if carry != 0 {
            words.append(carry)
        }
    }

    private mutating func addSmall(_ value: UInt32) {
        guard value != 0 else { return }
        if words.isEmpty {
            words = [value]
            return
        }
        var carry = UInt64(value)
        var index = 0
        while carry != 0 {
            if index == words.count {
                words.append(0)
            }
            let sum = UInt64(words[index]) + carry
            words[index] = UInt32(sum & 0xffff_ffff)
            carry = sum >> 32
            index += 1
        }
    }

    private mutating func add(_ other: RFBBigUInt) {
        let count = max(words.count, other.words.count)
        if words.count < count {
            words.append(contentsOf: repeatElement(0, count: count - words.count))
        }
        var carry: UInt64 = 0
        for index in 0..<count {
            let sum = UInt64(words[index]) + UInt64(index < other.words.count ? other.words[index] : 0) + carry
            words[index] = UInt32(sum & 0xffff_ffff)
            carry = sum >> 32
        }
        if carry != 0 {
            words.append(UInt32(carry))
        }
    }

    private mutating func subtract(_ other: RFBBigUInt) {
        var borrow: Int64 = 0
        for index in words.indices {
            let value = Int64(words[index]) - Int64(index < other.words.count ? other.words[index] : 0) - borrow
            if value < 0 {
                words[index] = UInt32(value + (1 << 32))
                borrow = 1
            } else {
                words[index] = UInt32(value)
                borrow = 0
            }
        }
        normalize()
    }
}

extension RFBBigUInt: Comparable {
    static func < (lhs: RFBBigUInt, rhs: RFBBigUInt) -> Bool {
        if lhs.words.count != rhs.words.count {
            return lhs.words.count < rhs.words.count
        }
        for (left, right) in zip(lhs.words.reversed(), rhs.words.reversed()) where left != right {
            return left < right
        }
        return false
    }
}
