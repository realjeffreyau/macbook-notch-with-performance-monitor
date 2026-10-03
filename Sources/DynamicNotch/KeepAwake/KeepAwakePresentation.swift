import Foundation

/// User-facing Keep Awake copy shared by the menu bar and the notch. Pure
/// functions of status and time so they are testable and cheap to call from
/// a view body or `menuWillOpen`.
struct KeepAwakePresentation {
    var calendar = Calendar.current
    var locale = Locale.current

    /// One-line state, e.g. "Keeping awake until 3:40 PM".
    func statusTitle(for status: KeepAwakeStatus, now: Date) -> String {
        guard let session = status.session else { return "Keep Awake is off" }
        guard let endsAt = session.endsAt else { return "Keeping awake indefinitely" }
        return "Keeping awake until \(endTime(endsAt, now: now))"
    }

    /// Extra lines worth showing, in display order.
    func detailLines(for status: KeepAwakeStatus) -> [String] {
        guard let session = status.session else {
            return stopReasonLine(status.lastStopReason).map { [$0] } ?? []
        }
        var lines: [String] = []
        if session.keepsDisplayAwake {
            lines.append("Display stays on")
        }
        if let lidLine = closedLidLine(session.closedLid) {
            lines.append(lidLine)
        }
        return lines
    }

    func closedLidLine(_ state: ClosedLidState) -> String? {
        switch state {
        case .off: nil
        case .on: "Lid closed: stays awake"
        case .waitingForPower: "Lid closed: needs power adapter"
        case .unavailable(let reason): "Lid closed: unavailable. \(reason)"
        }
    }

    func stopReasonLine(_ reason: KeepAwakeStopReason?) -> String? {
        switch reason {
        case nil, .user, .expired: nil
        case .lowBattery: "Stopped because the battery is low"
        case .failed(let message): message
        }
    }

    /// Short countdown, e.g. "42 min left". Shown only in visible UI.
    func remainingText(until endsAt: Date, now: Date) -> String {
        let seconds = endsAt.timeIntervalSince(now)
        guard seconds >= 60 else { return "Less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 {
            return "\(minutes) min left"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr left" : "\(hours) hr \(remainder) min left"
    }

    /// "3:40 PM", or "tomorrow 3:40 PM" / a short date when not today.
    func endTime(_ date: Date, now: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.calendar = calendar
        style.locale = locale
        style.timeZone = calendar.timeZone
        let time = date.formatted(style)
        if calendar.isDate(date, inSameDayAs: now) {
            return time
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        var dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)
        dateStyle.calendar = calendar
        dateStyle.locale = locale
        dateStyle.timeZone = calendar.timeZone
        return date.formatted(dateStyle)
    }

    /// The next occurrence of the picked clock time: today if it is still
    /// ahead, otherwise tomorrow.
    func nextOccurrence(ofTimeIn picked: Date, after now: Date) -> Date? {
        let parts = calendar.dateComponents([.hour, .minute], from: picked)
        return calendar.nextDate(
            after: now,
            matching: DateComponents(hour: parts.hour, minute: parts.minute, second: 0),
            matchingPolicy: .nextTime
        )
    }
}
