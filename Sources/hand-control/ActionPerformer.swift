import CoreGraphics
import Foundation
import HandControlCore

struct ActionPerformer {
    /// Synthetic key events need the Accessibility permission; without it they are
    /// silently dropped. The request call shows the system prompt once.
    static func ensureAccess() -> Bool {
        CGPreflightPostEventAccess() || CGRequestPostEventAccess()
    }

    private let source = CGEventSource(stateID: .hidSystemState)

    func perform(_ action: Action) throws {
        switch action {
        case .hotkey(let combo):
            try send(combo)
        case .system(let command):
            try run(command)
        }
    }

    /// Sleep has no synthesizable hotkey (the power key is not a kVK key code), so it goes
    /// through the built-in pmset, which needs no root for these two verbs.
    private func run(_ command: SystemCommand) throws {
        let verb = switch command {
        case .sleep: "sleepnow"
        case .displaySleep: "displaysleepnow"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = [verb]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError("pmset \(verb) exited with \(process.terminationStatus)")
        }
    }

    private func send(_ combo: KeyCombo) throws {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false)
        else { throw CLIError("cannot create key event for \(combo)") }
        let flags = Self.flags(for: combo)
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Mirror what a physical keyboard reports: arrows carry numericPad+fn, the F-row and
    /// navigation keys carry fn. Some consumers match shortcut flags exactly.
    static func flags(for combo: KeyCombo) -> CGEventFlags {
        var f: CGEventFlags = []
        if combo.modifiers.contains(.control) { f.insert(.maskControl) }
        if combo.modifiers.contains(.option) { f.insert(.maskAlternate) }
        if combo.modifiers.contains(.command) { f.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { f.insert(.maskShift) }
        if combo.modifiers.contains(.function) || combo.isFunctionRow { f.insert(.maskSecondaryFn) }
        if combo.isArrow { f.insert(.maskNumericPad) }
        return f
    }
}
