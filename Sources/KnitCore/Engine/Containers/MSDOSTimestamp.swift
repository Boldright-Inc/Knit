import Foundation

/// Encodes a `Date` into the MS-DOS time/date words used in ZIP local and
/// central directory headers (PKWARE APPNOTE.TXT §4.4.6).
///
/// Bit-packed layout:
///
///     date: |yyyyyyy|mmmm|ddddd|       year is 1980-relative (0..127 → 1980..2107)
///                                      month 1..12, day 1..31
///     time: |hhhhh|mmmmmm|sssss|       seconds field is /2 (resolution = 2 s)
///
/// Two consequences of the format that bite occasionally:
///   - Dates before 1980 round up to 1980 (the format has no representation).
///   - Sub-second precision is lost, and odd seconds round down.
struct MSDOSTimestamp {
    let date: UInt16
    let time: UInt16

    init(date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) {
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year  = max(1980, comps.year ?? 1980) - 1980
        let month = comps.month ?? 1
        let day   = comps.day ?? 1
        let hour  = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = (comps.second ?? 0) / 2  // 2-second resolution

        self.date = UInt16((year << 9) | (month << 5) | day)
        self.time = UInt16((hour << 11) | (minute << 5) | second)
    }
}
