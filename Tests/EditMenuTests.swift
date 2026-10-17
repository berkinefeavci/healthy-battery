import AppKit

@main enum EditMenuTests {
    static func main() {
        var assertions = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); assertions += 1 }
        let menu = EditMenu.make()
        let items = menu.items
        check(items.count == 7, "undo, redo, separator, cut, copy, paste, select all")
        func item(_ key: String, shift: Bool = false) -> NSMenuItem? {
            items.first { $0.keyEquivalent == key && ($0.keyEquivalentModifierMask.contains(.shift) == shift) && !$0.isSeparatorItem }
        }
        check(item("z")?.action == Selector(("undo:")), "⌘Z undoes")
        check(item("z", shift: true)?.action == Selector(("redo:")), "⇧⌘Z redoes")
        check(item("x")?.action == #selector(NSText.cut(_:)), "⌘X cuts")
        check(item("c")?.action == #selector(NSText.copy(_:)), "⌘C copies")
        check(item("v")?.action == #selector(NSText.paste(_:)), "⌘V pastes")
        check(item("a")?.action == #selector(NSText.selectAll(_:)), "⌘A selects all")
        check(items.filter { !$0.isSeparatorItem }.allSatisfy { $0.target == nil },
              "no target: actions go through the responder chain to the focused text field")
        check(items.filter { !$0.isSeparatorItem }.allSatisfy { $0.keyEquivalentModifierMask.contains(.command) },
              "every shortcut uses ⌘")
        print("Edit menu: \(assertions) assertions passed; offscreen menu only.")
    }
}
