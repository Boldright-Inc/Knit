import Foundation

/// Encodes a `Date` into MS-DOS time/date words used in ZIP local & central headers.
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
        let second = (comps.second ?? 0) / 2

        self.date = UInt16((year << 9) | (month << 5) | day)
        self.time = UInt16((hour << 11) | (minute << 5) | second)
    }
}
