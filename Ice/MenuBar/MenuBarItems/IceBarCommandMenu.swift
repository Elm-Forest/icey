//
//  IceBarCommandMenu.swift
//  Ice
//

import Cocoa

/// A local AppKit menu for a status item whose AppKit menu is anchored offscreen.
/// Each choice retains the corresponding remote element, including duplicate titles.
@MainActor
final class IceBarCommandMenu: NSObject {
    struct Entry {
        let title: String
        let enabled: Bool
        let marked: Bool
        let element: AXUIElement
        let submenu: [Entry]
    }

    private var selected: Entry?
    private var commands = [Entry]()

    func choose(from entries: [Entry], at point: CGPoint) -> AXUIElement? {
        makeMenu(entries).popUp(positioning: nil, at: point, in: nil)
        return selected?.element
    }

    private func makeMenu(_ entries: [Entry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            if entry.title.isEmpty {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(selectCommand), keyEquivalent: "")
            item.isEnabled = entry.enabled
            item.state = entry.marked ? .on : .off
            if entry.submenu.isEmpty {
                item.target = self
                item.tag = commands.count
                commands.append(entry)
            } else {
                item.submenu = makeMenu(entry.submenu)
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectCommand(_ sender: NSMenuItem) {
        selected = commands[sender.tag]
    }
}
