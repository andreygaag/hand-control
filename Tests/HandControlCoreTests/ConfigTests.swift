import Carbon.HIToolbox
import Foundation
import Testing
@testable import HandControlCore

@Suite struct KeyComboTests {
    @Test func parsesModifiersAndKey() throws {
        let k = try KeyCombo("Ctrl + Alt+Right")
        #expect(k.keyCode == UInt16(kVK_RightArrow))
        #expect(k.modifiers == [.control, .option])
        #expect(k.isArrow)
    }

    @Test(arguments: ["", "ctrl+", "ctrl+ctrl+a", "hyper+a", "ctrl+nosuchkey"])
    func rejectsInvalid(_ text: String) {
        #expect(throws: KeyComboError.self) { try KeyCombo(text) }
    }

    @Test func digitsAndFunctionRow() throws {
        #expect(try KeyCombo("ctrl+1").keyCode == UInt16(kVK_ANSI_1))
        #expect(try KeyCombo("f5").isFunctionRow)
        #expect(!(try KeyCombo("a").isFunctionRow))
    }
}

@Suite struct ConfigTests {
    @Test func decodesWithDefaults() throws {
        let json = #"{"bindings": {"fist": {"hotkey": "ctrl+right"}}}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.holdMs == 300)
        #expect(c.bindings["fist"] == .hotkey(try KeyCombo("ctrl+right")))
    }

    @Test func decodesSystemCommands() throws {
        let json = #"{"bindings": {"a": {"system": "sleep"}, "b": {"system": "displaySleep"}}}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.bindings["a"] == .system(.sleep))
        #expect(c.bindings["b"] == .system(.displaySleep))
        #expect(c.bindings["a"]?.description == "system sleep")
    }

    @Test(arguments: [
        #"{"bindings": {"x": {"system": "reboot"}}}"#,
        #"{"bindings": {"x": {"shell": "ls"}}}"#,
        #"{"bindings": {"x": {"hotkey": "ctrl+a", "extra": 1}}}"#,
        #"{"bindings": {"x": {}}}"#,
        #"{"bindings": {"x": {"hotkey": "ctrl+bogus"}}}"#,
    ])
    func rejectsInvalidActions(_ json: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Config.self, from: Data(json.utf8)) }
    }

    @Test func roundTripsThroughFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = Config()
        config.bindings = ["fist": .hotkey(try KeyCombo("cmd+shift+4")), "sleep": .system(.sleep)]
        try config.save(to: dir.appendingPathComponent("config.json"))
        #expect(try Config.load(from: dir.appendingPathComponent("config.json")) == config)

        var store = GestureStore()
        store.samples = ["fist": [hand()]]
        try store.save(to: dir.appendingPathComponent("g.json"))
        #expect(try GestureStore.load(from: dir.appendingPathComponent("g.json")) == store)
        #expect(try GestureStore.load(from: dir.appendingPathComponent("missing.json")) == GestureStore())
    }

    @Test func rejectsUnknownStoreVersion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version": 99, "samples": {}}"#.utf8).write(to: url)
        #expect(throws: StorageError.self) { try GestureStore.load(from: url) }
    }
}
