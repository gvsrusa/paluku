import Foundation
import Testing

@testable import PalukuCore

@Suite struct SchedulerTests {
    @Test func oneShotFiresOnceAndIsRemoved() {
        let now = Date()
        let t = ScheduledTask(kind: .reminder, instruction: "x", fireDate: now.addingTimeInterval(-1))
        let later = ScheduledTask(kind: .reminder, instruction: "y", fireDate: now.addingTimeInterval(60))
        let (fire, rest) = Scheduler.due([t, later], now: now)
        #expect(fire.map(\.instruction) == ["x"])
        #expect(rest.map(\.instruction) == ["y"])
    }

    @Test func dailyRepeatAdvancesPastNow() {
        let now = Date()
        let t = ScheduledTask(kind: .agent, instruction: "x", fireDate: now.addingTimeInterval(-3 * 86400 - 5), repeatInterval: 86400)
        let (fire, rest) = Scheduler.due([t], now: now)
        #expect(fire.count == 1)
        #expect(rest.count == 1 && rest[0].fireDate > now && rest[0].fireDate < now.addingTimeInterval(86400))
    }

    @Test func weekdaysSkipWeekend() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let friday = cal.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 9))!
        var t = ScheduledTask(kind: .agent, instruction: "x", fireDate: friday, repeatInterval: 86400)
        t.weekdaysOnly = true
        let next = Scheduler.advance(t, after: friday, calendar: cal)!
        #expect(cal.component(.weekday, from: next.fireDate) == 2)  // Monday
    }
}

@Suite struct ToolParsingTests {
    @Test func freeSlotsBetweenMeetings() {
        let base = Date(timeIntervalSince1970: 0)
        let h = { (x: Double) in base.addingTimeInterval(x * 3600) }
        let slots = CalendarTools.freeSlots(from: h(9), to: h(17), busy: [(h(10), h(11)), (h(10.5), h(12)), (h(16.75), h(17))], minutes: 60)
        #expect(slots.map { $0.0 } == [h(9), h(12)])
        #expect(slots.map { $0.1 } == [h(10), h(16.75)])
    }

    @Test func duckDuckGoParsing() {
        let html = """
            <div class="result results_links"><div class="links_main result__body">
            <h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=x">Example <b>A</b></a></h2>
            <a class="result__snippet" href="x">Snippet &amp; more</a></div></div>
            """
        let r = WebTools.parseDuckDuckGo(html)
        #expect(r == [WebTools.SearchResult(title: "Example A", url: "https://example.com/a", snippet: "Snippet & more")])
    }

    @Test func spotlightQueryAndRanking() {
        let q = FinderTools.spotlightQuery("tax return", kind: "pdf", after: nil, before: nil)
        #expect(q.contains("kMDItemFSName == \"*tax*\"cd && kMDItemFSName == \"*return*\"cd"))
        #expect(q.contains("com.adobe.pdf"))
        let ranked = FinderTools.rank(
            ["/Users/me/Library/Caches/tax.pdf", "/Users/me/Documents/misc/notes.pdf", "/Users/me/Documents/tax return 2025.pdf"], query: "tax return")
        #expect(ranked.first == "/Users/me/Documents/tax return 2025.pdf")
        #expect(!ranked.contains { $0.contains("/Library/") })
    }

    @Test func stripTagsKeepsText() {
        #expect(WebTools.stripTags("<p>Hello <b>world</b></p><script>x()</script>") == "Hello world")
    }
}
