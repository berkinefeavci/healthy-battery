import AppKit

/// The standard Edit menu. Healthy Battery has no visible menu bar, but macOS only routes ⌘C/⌘V/⌘X/⌘A/⌘Z
/// to a focused text field (Schedule editor, settings) when the main menu has items for them.
/// Items have no target, so each action travels the responder chain to the focused field.
enum EditMenu {
    static func make() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Düzen"))
        menu.addItem(withTitle: String(localized: "Geri al"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: String(localized: "Yinele"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Kes"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: String(localized: "Kopyala"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: String(localized: "Yapıştır"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: String(localized: "Tümünü seç"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }
}
