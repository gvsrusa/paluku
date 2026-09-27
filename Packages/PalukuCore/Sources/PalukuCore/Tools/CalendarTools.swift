import EventKit
import Foundation

/// Apple Calendar + Reminders via EventKit.
public enum CalendarTools {
    nonisolated(unsafe) static let store = EKEventStore()

    static func requireEvents() async throws {
        guard try await store.requestFullAccessToEvents() else {
            throw Shell.Failure(message: "Calendar access denied. Enable Paluku in System Settings › Privacy › Calendars.")
        }
    }

    static func requireReminders() async throws {
        guard try await store.requestFullAccessToReminders() else {
            throw Shell.Failure(message: "Reminders access denied. Enable Paluku in System Settings › Privacy › Reminders.")
        }
    }

    static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d, HH:mm"
        return f
    }()

    static func describe(_ e: EKEvent) -> String {
        let when = e.isAllDay ? "all day \(DateParsing.iso(e.startDate).prefix(10))" : "\(DateParsing.iso(e.startDate)) → \(DateParsing.iso(e.endDate))"
        var s = "[\(e.eventIdentifier ?? "")] \(e.title ?? "(no title)") — \(when) (\(e.calendar.title))"
        if let l = e.location, !l.isEmpty { s += " @ \(l)" }
        return s
    }

    static func card(_ events: [EKEvent], title: String) -> Card {
        Card(
            icon: "calendar", title: title,
            rows: events.map {
                Card.Row(
                    $0.title ?? "(no title)",
                    detail: $0.isAllDay ? "All day" : "\(timeFmt.string(from: $0.startDate)) – \(timeFmt.string(from: $0.endDate).suffix(5))",
                    url: URL(string: "ical://ekevent/\($0.eventIdentifier ?? "")"))
            })
    }

    static func day(_ args: JSONValue, _ key: String, default d: Date) -> Date { args.date(key) ?? d }

    public static var all: [Tool] {
        [
            Tool(
                name: "calendar_list_events", description: "List Apple Calendar events between two times.",
                parameters: Schema.object([
                    "start": Schema.string("ISO start, default now"), "end": Schema.string("ISO end, default end of start day"),
                    "query": Schema.string("optional text filter on title/location"),
                ]), integration: "calendar", untrusted: true  // invites carry other people's text
            ) { args in
                try await requireEvents()
                let start = day(args, "start", default: Date())
                let end = args.date("end") ?? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: start))!
                var events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                if let q = args.optString("query")?.lowercased() {
                    events = events.filter { ($0.title ?? "").lowercased().contains(q) || ($0.location ?? "").lowercased().contains(q) }
                }
                events.sort { $0.startDate < $1.startDate }
                if events.isEmpty { return ToolResult("No events between \(DateParsing.iso(start)) and \(DateParsing.iso(end)).") }
                return ToolResult(events.map(describe).joined(separator: "\n"), card: card(events, title: "Calendar"))
            },
            Tool(
                name: "calendar_find_free_time", description: "Find free slots of a given length on a day, within working hours.",
                parameters: Schema.object(
                    [
                        "date": Schema.string("ISO day (YYYY-MM-DD)"), "duration_minutes": Schema.integer("slot length"),
                        "from_hour": Schema.integer("earliest hour, default 9"), "to_hour": Schema.integer("latest hour, default 18"),
                    ], required: ["date", "duration_minutes"]), integration: "calendar"
            ) { args in
                try await requireEvents()
                let dayStart = Calendar.current.startOfDay(for: args.date("date") ?? Date())
                let from = Calendar.current.date(byAdding: .hour, value: args.int("from_hour", default: 9, in: 0...24), to: dayStart) ?? dayStart
                let to = Calendar.current.date(byAdding: .hour, value: args.int("to_hour", default: 18, in: 0...24), to: dayStart) ?? dayStart
                let busy = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
                    .filter { !$0.isAllDay && $0.availability != .free }.map { ($0.startDate!, $0.endDate!) }
                let slots = freeSlots(from: max(from, Date()), to: to, busy: busy, minutes: args.int("duration_minutes", default: 30, in: 1...1440))
                if slots.isEmpty { return ToolResult("No free slot found.") }
                return ToolResult("Free slots:\n" + slots.map { "\(DateParsing.iso($0.0)) → \(DateParsing.iso($0.1))" }.joined(separator: "\n"))
            },
            Tool(
                name: "calendar_create_event", description: "Create an Apple Calendar event.",
                parameters: Schema.object(
                    [
                        "title": Schema.string("event title"), "start": Schema.string("ISO start"),
                        "end": Schema.string("ISO end (default start + 30 min)"), "all_day": Schema.boolean("all-day event"),
                        "location": Schema.string("location or meeting link"), "notes": Schema.string("notes"),
                        "calendar": Schema.string("calendar name (default calendar if omitted)"),
                    ], required: ["title", "start"]), integration: "calendar", isWrite: true,
                preview: { a in
                    var lines = ["📅 \(a.optString("title") ?? "")", "\(a.optString("start") ?? "")\(a.optString("end").map { " → \($0)" } ?? "")"]
                    if let c = a.optString("calendar") { lines.append("Calendar: \(c)") }
                    if let l = a.optString("location") { lines.append("📍 \(l)") }
                    if let n = a.optString("notes") { lines.append("Notes: \(n.prefix(500))") }
                    return lines.joined(separator: "\n")
                }
            ) { args in
                try await requireEvents()
                guard let start = args.date("start") else { throw ToolArgumentError(message: "Invalid 'start' date") }
                let e = EKEvent(eventStore: store)
                e.title = try args.string("title")
                e.startDate = start
                e.endDate = args.date("end") ?? start.addingTimeInterval(1800)
                e.isAllDay = args.bool("all_day") ?? false
                e.location = args.optString("location")
                e.notes = args.optString("notes")
                e.calendar =
                    args.optString("calendar").flatMap { n in store.calendars(for: .event).first { $0.title.lowercased() == n.lowercased() } }
                    ?? store.defaultCalendarForNewEvents
                try store.save(e, span: .thisEvent, commit: true)
                return ToolResult("Created: \(describe(e))", card: card([e], title: "Event created"))
            },
            Tool(
                name: "calendar_update_event", description: "Move/rename an event by id (from calendar_list_events).",
                parameters: Schema.object(
                    [
                        "id": Schema.string("event id"), "title": Schema.string("new title"),
                        "start": Schema.string("new ISO start"), "end": Schema.string("new ISO end"),
                    ], required: ["id"]), integration: "calendar", isWrite: true,
                preview: { a in
                    let e = a.optString("id").flatMap { store.event(withIdentifier: $0) }
                    var lines = ["📅 Change “\(e?.title ?? "unknown event")”"]
                    if let t = a.optString("title") { lines.append("New title: \(t)") }
                    if let s = a.optString("start") { lines.append("New start: \(s)") }
                    if let en = a.optString("end") { lines.append("New end: \(en)") }
                    return lines.joined(separator: "\n")
                }
            ) { args in
                try await requireEvents()
                guard let e = store.event(withIdentifier: try args.string("id")) else { throw ToolArgumentError(message: "Event not found") }
                let length = e.endDate.timeIntervalSince(e.startDate)
                if let t = args.optString("title") { e.title = t }
                if let s = args.date("start") {
                    e.startDate = s; e.endDate = args.date("end") ?? s.addingTimeInterval(length)
                } else if let en = args.date("end") {
                    e.endDate = en
                }
                try store.save(e, span: .thisEvent, commit: true)
                return ToolResult("Updated: \(describe(e))", card: card([e], title: "Event updated"))
            },
            Tool(
                name: "calendar_delete_event", description: "Delete an event by id.",
                parameters: Schema.object(["id": Schema.string("event id")], required: ["id"]), integration: "calendar", isWrite: true,
                preview: { a in "Delete event \(a.optString("id").flatMap { store.event(withIdentifier: $0)?.title } ?? "?")" }
            ) { args in
                try await requireEvents()
                guard let e = store.event(withIdentifier: try args.string("id")) else { throw ToolArgumentError(message: "Event not found") }
                try store.remove(e, span: .thisEvent, commit: true)
                return ToolResult("Deleted \(e.title ?? "event").")
            },
        ] + reminderTools
    }

    static func freeSlots(from: Date, to: Date, busy: [(Date, Date)], minutes: Int) -> [(Date, Date)] {
        var slots: [(Date, Date)] = []
        var cursor = from
        for (s, e) in busy.sorted(by: { $0.0 < $1.0 }) {
            if s.timeIntervalSince(cursor) >= Double(minutes * 60) { slots.append((cursor, s)) }
            cursor = max(cursor, e)
        }
        if to.timeIntervalSince(cursor) >= Double(minutes * 60) { slots.append((cursor, to)) }
        return slots
    }

    static func fetchReminders(_ pred: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { c in store.fetchReminders(matching: pred) { c.resume(returning: $0 ?? []) } }
    }

    static func describe(_ r: EKReminder) -> String {
        var s = "[\(r.calendarItemIdentifier)] \(r.isCompleted ? "✓ " : "")\(r.title ?? "")"
        if let d = r.dueDateComponents?.date { s += " (due \(DateParsing.iso(d)))" }
        return s + " — \(r.calendar.title)"
    }

    static var reminderTools: [Tool] {
        [
            Tool(
                name: "reminders_list", description: "List incomplete Apple Reminders (optionally one list).",
                parameters: Schema.object(["list": Schema.string("list name"), "include_completed": Schema.boolean("include done")]),
                integration: "reminders", untrusted: true  // shared lists
            ) { args in
                try await requireReminders()
                let cals = args.optString("list").map { n in store.calendars(for: .reminder).filter { $0.title.lowercased() == n.lowercased() } }
                let pred =
                    (args.bool("include_completed") ?? false)
                    ? store.predicateForReminders(in: cals) : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
                let items = await fetchReminders(pred).prefix(50)
                if items.isEmpty { return ToolResult("No reminders.") }
                return ToolResult(
                    items.map(describe).joined(separator: "\n"),
                    card: Card(
                        icon: "checklist", title: "Reminders",
                        rows: items.map { Card.Row($0.title ?? "", detail: $0.dueDateComponents?.date.map { timeFmt.string(from: $0) }) }))
            },
            Tool(
                name: "reminders_create", description: "Create an Apple Reminder, optionally with a due date/time.",
                parameters: Schema.object(
                    [
                        "title": Schema.string("reminder text"), "due": Schema.string("ISO due date/time"),
                        "notes": Schema.string("notes"), "list": Schema.string("list name"),
                    ], required: ["title"]), integration: "reminders", isWrite: true,
                preview: { a in "☑︎ \(a.optString("title") ?? "")\(a.optString("due").map { "\nDue \($0)" } ?? "")" }
            ) { args in
                try await requireReminders()
                let r = EKReminder(eventStore: store)
                r.title = try args.string("title")
                r.notes = args.optString("notes")
                r.calendar =
                    args.optString("list").flatMap { n in store.calendars(for: .reminder).first { $0.title.lowercased() == n.lowercased() } }
                    ?? store.defaultCalendarForNewReminders()
                if let due = args.date("due") {
                    r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                    r.addAlarm(EKAlarm(absoluteDate: due))
                }
                try store.save(r, commit: true)
                return ToolResult(
                    "Created reminder: \(describe(r))",
                    card: Card(icon: "checklist", title: "Reminder added", rows: [Card.Row(r.title ?? "", detail: args.optString("due"))]))
            },
            Tool(
                name: "reminders_complete", description: "Mark a reminder done by id.",
                parameters: Schema.object(["id": Schema.string("reminder id")], required: ["id"]), integration: "reminders", isWrite: true
            ) { args in
                try await requireReminders()
                guard let r = store.calendarItem(withIdentifier: try args.string("id")) as? EKReminder else {
                    throw ToolArgumentError(message: "Reminder not found")
                }
                r.isCompleted = true
                try store.save(r, commit: true)
                return ToolResult("Completed \(r.title ?? "").")
            },
            Tool(
                name: "reminders_delete", description: "Delete a reminder by id.",
                parameters: Schema.object(["id": Schema.string("reminder id")], required: ["id"]), integration: "reminders", isWrite: true
            ) { args in
                try await requireReminders()
                guard let r = store.calendarItem(withIdentifier: try args.string("id")) as? EKReminder else {
                    throw ToolArgumentError(message: "Reminder not found")
                }
                try store.remove(r, commit: true)
                return ToolResult("Deleted \(r.title ?? "").")
            },
        ]
    }
}
