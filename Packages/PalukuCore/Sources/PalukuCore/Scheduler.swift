import Foundation

/// Pure scheduling math; the app polls `due` every ~15 s and persists `remaining`.
public enum Scheduler {
    /// Splits tasks into those due at `now` and the rest (repeating tasks are advanced and kept).
    public static func due(_ tasks: [ScheduledTask], now: Date, calendar: Calendar = .current) -> (fire: [ScheduledTask], remaining: [ScheduledTask]) {
        var fire: [ScheduledTask] = [], remaining: [ScheduledTask] = []
        for t in tasks {
            guard t.fireDate <= now else { remaining.append(t); continue }
            fire.append(t)
            if let next = advance(t, after: now, calendar: calendar) { remaining.append(next) }
        }
        return (fire, remaining.sorted { $0.fireDate < $1.fireDate })
    }

    /// Next occurrence strictly after `now`, skipping weekends for weekday tasks. nil for one-shot tasks.
    public static func advance(_ t: ScheduledTask, after now: Date, calendar: Calendar = .current) -> ScheduledTask? {
        guard let interval = t.repeatInterval, interval > 0 else { return nil }
        var next = t
        repeat {
            next.fireDate = next.fireDate.addingTimeInterval(interval)
        } while next.fireDate <= now || (t.weekdaysOnly && calendar.isDateInWeekend(next.fireDate))
        return next
    }
}
