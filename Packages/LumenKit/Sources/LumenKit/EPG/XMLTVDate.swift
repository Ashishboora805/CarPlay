import Foundation

/// Fast parser for XMLTV timestamps: `YYYYMMDDhhmmss ±hhmm` (seconds, offset and the space
/// before the offset are optional; a missing offset means UTC).
///
/// Avoids `DateFormatter`, which is roughly two orders of magnitude slower and dominates
/// parse time for EPGs with hundreds of thousands of programmes.
public enum XMLTVDate {
    public static func parse(_ string: String) -> Date? {
        var digits: [Int] = []
        digits.reserveCapacity(14)
        var iterator = string.utf8.makeIterator()
        var pending: UInt8?

        while digits.count < 14, let byte = iterator.next() {
            if byte >= 48 && byte <= 57 {
                digits.append(Int(byte - 48))
            } else {
                pending = byte
                break
            }
        }
        guard digits.count == 12 || digits.count == 14 else { return nil }

        func number(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 * 10 + digits[$1] }
        }
        let year = number(0..<4), month = number(4..<6), day = number(6..<8)
        let hour = number(8..<10), minute = number(10..<12)
        let second = digits.count == 14 ? number(12..<14) : 0
        guard (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second < 61 else { return nil }

        // Offset: skip spaces, then ±hhmm.
        var offsetSeconds = 0
        var byte = pending ?? iterator.next()
        while byte == 32 { byte = iterator.next() }
        if let sign = byte, sign == 43 || sign == 45 { // '+' / '-'
            var offsetDigits: [Int] = []
            while offsetDigits.count < 4, let next = iterator.next(), next >= 48 && next <= 57 {
                offsetDigits.append(Int(next - 48))
            }
            if offsetDigits.count == 4 {
                let hours = offsetDigits[0] * 10 + offsetDigits[1]
                let minutes = offsetDigits[2] * 10 + offsetDigits[3]
                offsetSeconds = (hours * 3600 + minutes * 60) * (sign == 45 ? -1 : 1)
            }
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let epoch = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
