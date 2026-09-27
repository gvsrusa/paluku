import AppKit
import CoreGraphics
import Foundation

public enum VoiceMode: String, Sendable { case dictation, agent }

/// Pure trigger logic, independent of CGEventTap so it can be unit-tested.
///
/// - Hold key ≥ `tapThreshold` → push-to-talk; release stops.
/// - Quick tap then second press within `doubleTapWindow` → hands-free; next press stops.
/// - Single quick tap → discarded (accidental).
/// - Escape → cancel. Another key pressed while holding → cancel (it was a shortcut chord).
public struct TriggerStateMachine: Sendable {
    public enum Event: Sendable, Equatable {
        case press(VoiceMode), release(VoiceMode), escape, otherKey, timeout
    }
    public enum Effect: Sendable, Equatable {
        case start(VoiceMode), stop(VoiceMode), cancel(VoiceMode), handsFree(VoiceMode), scheduleTimeout(Double)
    }
    enum State: Equatable {
        case idle
        case holding(VoiceMode, since: Double)
        case awaitingSecondTap(VoiceMode)
        case secondPress(VoiceMode)
        case handsFree(VoiceMode)
    }

    public var tapThreshold = 0.3
    public var doubleTapWindow = 0.35
    var state: State = .idle

    public init() {}

    public var isActive: Bool { state != .idle }

    public mutating func handle(_ event: Event, at t: Double) -> [Effect] {
        switch (state, event) {
        case (.idle, .press(let m)):
            state = .holding(m, since: t)
            return [.start(m)]

        case (.holding(let m, let since), .release(let r)) where r == m:
            if t - since >= tapThreshold {
                state = .idle
                return [.stop(m)]
            }
            state = .awaitingSecondTap(m)
            return [.scheduleTimeout(doubleTapWindow)]

        case (.awaitingSecondTap(let m), .press(let p)) where p == m:
            state = .secondPress(m)
            return [.handsFree(m)]
        case (.awaitingSecondTap(let m), .timeout):
            state = .idle
            return [.cancel(m)]

        case (.secondPress(let m), .release(let r)) where r == m:
            state = .handsFree(m)
            return []

        case (.handsFree(let m), .press(let p)) where p == m:
            state = .idle
            return [.stop(m)]

        case (.holding(let m, _), .otherKey), (.awaitingSecondTap(let m), .otherKey):
            state = .idle
            return [.cancel(m)]

        case (.holding(let m, _), .escape), (.awaitingSecondTap(let m), .escape),
            (.secondPress(let m), .escape), (.handsFree(let m), .escape):
            state = .idle
            return [.cancel(m)]

        default:
            return []
        }
    }

    /// Force back to idle (e.g. recording ended by max length).
    public mutating func reset() { state = .idle }
}

/// System-wide key listener (CGEventTap). Requires Accessibility permission.
@MainActor
public final class HotkeyMonitor {
    public var dictationKey: TriggerKey
    public var agentKey: TriggerKey
    public var onEffect: ((TriggerStateMachine.Effect) -> Void)?
    /// Called for Escape while no recording is active; return true to consume it (e.g. to close the panel).
    public var swallowEscape: (() -> Bool)?

    private var machine = TriggerStateMachine()
    private var tap: CFMachPort?
    private var pressed: Set<TriggerKey> = []
    private var timeoutWork: DispatchWorkItem?

    public init(dictationKey: TriggerKey, agentKey: TriggerKey) {
        self.dictationKey = dictationKey
        self.agentKey = agentKey
    }

    public var isRunning: Bool { tap != nil }

    /// Returns false when Accessibility permission is missing.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, refcon in
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                    return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
                }, userInfo: refcon)
        else { return false }
        tap = port
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    public func resetState() {
        machine.reset()
        timeoutWork?.cancel()
    }

    private func mode(for key: TriggerKey) -> VoiceMode? {
        if key == dictationKey { return .dictation }
        if key == agentKey { return .agent }
        return nil
    }

    static func key(forKeyCode code: Int64) -> TriggerKey? {
        switch code {
        case 63, 179: .fn  // kVK_Function; 179 = globe on some keyboards
        case 61: .rightOption
        case 54: .rightCommand
        case 62: .rightControl
        case 60: .rightShift
        default: nil
        }
    }

    static func isDown(_ key: TriggerKey, flags: CGEventFlags) -> Bool {
        // Device-dependent bits distinguish right-hand modifiers (IOLLEvent.h NX_DEVICER*KEYMASK).
        let raw = flags.rawValue
        switch key {
        case .fn: return flags.contains(.maskSecondaryFn)
        case .rightOption: return raw & 0x40 != 0
        case .rightCommand: return raw & 0x10 != 0
        case .rightControl: return raw & 0x2000 != 0
        case .rightShift: return raw & 0x04 != 0
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .flagsChanged, let key = Self.key(forKeyCode: code), let m = mode(for: key) {
            let down = Self.isDown(key, flags: event.flags)
            guard down != pressed.contains(key) else { return Unmanaged.passUnretained(event) }
            if down { pressed.insert(key) } else { pressed.remove(key) }
            // Trigger chords with other modifiers (e.g. fn+⌃) are left to the system.
            let others: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]
            let chord = down && key != .fn && !event.flags.intersection(others.subtracting(Self.flagClass(key))).isEmpty
            if chord && !machine.isActive { return Unmanaged.passUnretained(event) }
            apply(machine.handle(down ? .press(m) : .release(m), at: now))
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown, machine.isActive {
            if code == 53 {  // Escape
                apply(machine.handle(.escape, at: now))
                return nil  // swallow so the frontmost app doesn't also react
            }
            apply(machine.handle(.otherKey, at: now))
        } else if type == .keyDown, code == 53, swallowEscape?() == true {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private static func flagClass(_ key: TriggerKey) -> CGEventFlags {
        switch key {
        case .fn: .maskSecondaryFn
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .rightControl: .maskControl
        case .rightShift: .maskShift
        }
    }

    private func apply(_ effects: [TriggerStateMachine.Effect]) {
        for e in effects {
            if case .scheduleTimeout(let secs) = e {
                timeoutWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.apply(self.machine.handle(.timeout, at: ProcessInfo.processInfo.systemUptime))
                }
                timeoutWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + secs, execute: work)
            } else {
                onEffect?(e)
            }
        }
    }
}
