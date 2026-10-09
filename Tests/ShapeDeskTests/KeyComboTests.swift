import XCTest
import AppKit
import Carbon.HIToolbox
@testable import ShapeDesk

final class KeyComboTests: XCTestCase {
    private func press(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                       isARepeat: false, keyCode: UInt16(keyCode)))
    }

    func testDefaultShortcutLabelUsesMacOrder() {
        XCTAssertEqual(KeyCombo.standard.label, "⌃⌥⌘D")
        let all = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey),
                           key: "Space")
        XCTAssertEqual(all.label, "⌃⌥⇧⌘Space")
    }

    func testGlobalShortcutsNeedCommandControlOrOptionExceptFunctionKeys() throws {
        XCTAssertNil(KeyCombo(event: try press(kVK_ANSI_D, [])))
        XCTAssertNil(KeyCombo(event: try press(kVK_ANSI_D, [.shift])))
        let combo = try XCTUnwrap(KeyCombo(event: try press(kVK_ANSI_D, [.control, .option, .command])))
        XCTAssertEqual(combo.keyCode, UInt32(kVK_ANSI_D))
        XCTAssertEqual(combo.modifiers, UInt32(controlKey | optionKey | cmdKey))
        let function = try XCTUnwrap(KeyCombo(event: try press(kVK_F5, [])))
        XCTAssertEqual(function.label, "F5")
        XCTAssertEqual(KeyCombo(event: try press(kVK_Space, [.option]))?.label, "⌥Space")
    }

    func testShortcutSurvivesSaving() throws {
        let data = try JSONEncoder().encode(KeyCombo.standard)
        XCTAssertEqual(try JSONDecoder().decode(KeyCombo.self, from: data), .standard)
    }
}
