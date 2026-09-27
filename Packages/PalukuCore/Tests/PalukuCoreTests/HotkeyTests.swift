import Testing

@testable import PalukuCore

@Suite struct TriggerStateMachineTests {
    @Test func holdIsPushToTalk() {
        var m = TriggerStateMachine()
        #expect(m.handle(.press(.dictation), at: 0) == [.start(.dictation)])
        #expect(m.handle(.release(.dictation), at: 1.0) == [.stop(.dictation)])
        #expect(!m.isActive)
    }

    @Test func singleQuickTapIsDiscarded() {
        var m = TriggerStateMachine()
        _ = m.handle(.press(.agent), at: 0)
        #expect(m.handle(.release(.agent), at: 0.1) == [.scheduleTimeout(0.35)])
        #expect(m.handle(.timeout, at: 0.5) == [.cancel(.agent)])
    }

    @Test func doubleTapIsHandsFreeUntilNextPress() {
        var m = TriggerStateMachine()
        _ = m.handle(.press(.dictation), at: 0)
        _ = m.handle(.release(.dictation), at: 0.1)
        #expect(m.handle(.press(.dictation), at: 0.2) == [.handsFree(.dictation)])
        #expect(m.handle(.release(.dictation), at: 0.25) == [])
        #expect(m.handle(.timeout, at: 0.45) == [])  // stale timer ignored
        #expect(m.handle(.otherKey, at: 1) == [])  // typing allowed while hands-free
        #expect(m.handle(.press(.dictation), at: 5) == [.stop(.dictation)])
    }

    @Test func escapeCancelsAndChordCancelsHold() {
        var m = TriggerStateMachine()
        _ = m.handle(.press(.dictation), at: 0)
        #expect(m.handle(.escape, at: 0.5) == [.cancel(.dictation)])
        _ = m.handle(.press(.agent), at: 1)
        #expect(m.handle(.otherKey, at: 1.1) == [.cancel(.agent)])
    }

    @Test func otherModeKeyIgnoredWhileActive() {
        var m = TriggerStateMachine()
        _ = m.handle(.press(.dictation), at: 0)
        #expect(m.handle(.press(.agent), at: 0.5) == [])
        #expect(m.handle(.release(.dictation), at: 1) == [.stop(.dictation)])
    }
}
