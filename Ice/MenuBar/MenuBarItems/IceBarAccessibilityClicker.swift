//
//  IceBarAccessibilityClicker.swift
//  Ice
//

import ApplicationServices
import Cocoa
import OSLog

/// Activates an Ice Bar item through Accessibility without moving its status
/// item into the visible menu bar. Unlike temporarilyShow, this does not
/// rearrange the user's other status items when the menu bar is full.
@MainActor
enum IceBarAccessibilityClicker {
    private nonisolated static let logger = Logger(category: "IceBarAccessibilityClicker")
    private static var activationInProgress = false

    static func click(item: MenuBarItem, mouseButton: CGMouseButton, at point: CGPoint) async {
        // Do not interleave operations on two status items while the target
        // process is handling a potentially modal Accessibility action.
        guard !activationInProgress else {
            logger.notice("An Ice Bar item activation is already in progress")
            return
        }
        activationInProgress = true
        defer { activationInProgress = false }
        let pid = item.sourcePID ?? item.ownerPID
        guard let window = WindowInfo(windowID: item.windowID), window.ownerPID == item.ownerPID else {
            showUnavailable(for: item, at: point)
            return
        }
        let bounds = window.bounds
        let displays = NSScreen.screens.map { CGDisplayBounds($0.displayID) }
        let bundle = item.sourceApplication?.bundleURL
        let isICopy = item.tag.namespace == .string("cn.better365.iCopy")
        let isWiFi = item.tag.namespace == .controlCenter && item.tag.title == "WiFi"
        let title = item.title
        let tagTitle = item.tag.title
        let action = mouseButton == .right ? kAXShowMenuAction as String : kAXPressAction as String

        // AX actions can block while another process displays a menu. Never
        // perform these cross-process calls on Icey's main actor.
        let outcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = activate(
                    pid: pid,
                    bounds: bounds,
                    title: title,
                    tagTitle: tagTitle,
                    action: action,
                    displays: displays,
                    isICopy: isICopy,
                    wifiBundle: isWiFi ? bundle : nil
                )
                continuation.resume(returning: outcome)
            }
        }

        switch outcome {
        case .visible:
            logger.debug("Observed a visible interface for \(item.logString, privacy: .public)")
        case .commands(let entries):
            let menu = IceBarCommandMenu()
            guard let command = menu.choose(from: entries, at: point) else { return }
            let result = await Task.detached {
                AXUIElementPerformAction(command, kAXPressAction as CFString)
            }.value
            if result != .success {
                logger.error("Menu command for \(item.logString, privacy: .public) returned \(result.rawValue)")
                showUnavailable(for: item, at: point)
            }
        case .unavailable(let reason):
            logger.notice("No visible interface for \(item.logString, privacy: .public): \(reason, privacy: .public)")
            showUnavailable(for: item, at: point)
        }
    }

    private static func showUnavailable(for item: MenuBarItem, at point: CGPoint) {
        let menu = NSMenu(title: item.displayName)
        menu.addItem(withTitle: String(localized: "Couldn’t open \(item.displayName) here"), action: nil, keyEquivalent: "")
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    private enum Outcome {
        case visible
        case commands([IceBarCommandMenu.Entry])
        case unavailable(String)
    }

    private struct Candidate {
        let element: AXUIElement
        let frame: CGRect?
        let names: [String]
    }

    private nonisolated static func activate(
        pid: pid_t,
        bounds: CGRect,
        title: String?,
        tagTitle: String,
        action: String,
        displays: [CGRect],
        isICopy: Bool,
        wifiBundle: URL?
    ) -> Outcome {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)

        var barValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &barValue) == .success,
            let barValue,
            CFGetTypeID(barValue) == AXUIElementGetTypeID()
        else {
            return .unavailable("No accessible extras menu bar")
        }

        // Validated against the CoreFoundation runtime type before conversion.
        // swiftlint:disable:next force_cast
        let bar = barValue as! AXUIElement
        let candidates = children(of: bar).map { element in
            Candidate(
                element: element,
                frame: frame(of: element),
                names: [
                    string(of: element, attribute: kAXIdentifierAttribute),
                    string(of: element, attribute: kAXTitleAttribute),
                    string(of: element, attribute: kAXDescriptionAttribute),
                ].compactMap { $0 }
            )
        }

        guard let candidate = matching(candidates, bounds: bounds, title: title, tagTitle: tagTitle) else {
            return .unavailable("No unique accessibility item matched the status window")
        }

        // iCopy exposes its menu even while closed. On Sequoia both mouse
        // buttons open this same menu thousands of points off the display.
        if isICopy, let menu = children(of: candidate.element).first(where: { role($0) == kAXMenuRole }) {
            var budget = 128
            if let entries = entries(in: menu, budget: &budget), !entries.isEmpty {
                return .commands(entries)
            }
        }
        if let wifiBundle, candidate.names.contains("com.apple.menuextra.wifi") {
            return openWiFi(app: app, candidates: candidates, bundleURL: wifiBundle, displays: displays)
        }

        // A successful AX call can open an invisible menu. Conversely, a
        // modal menu can time out the call that opened it. Record both facts.
        let before = Set(interfaceWindows(pid: pid).map(\.windowID))
        let nested = children(of: candidate.element)
        let targets = [candidate.element] + (nested.count == 1 && role(nested[0]) != kAXMenuRole ? nested : [])
        let actions = action == kAXPressAction ? [action, kAXShowMenuAction as String] : [action]
        let supported = targets.map { ($0, actionNames(of: $0)) }
        guard let (target, requested) = actions.compactMap({ name in
            supported.first { $0.1.contains(name) }.map { ($0.0, name) }
        }).first else { return .unavailable("Requested action is not supported") }
        AXUIElementSetMessagingTimeout(target, 1)
        let result = AXUIElementPerformAction(target, requested as CFString)
        Thread.sleep(forTimeInterval: 0.15)
        let appeared = interfaceWindows(pid: pid).filter { !before.contains($0.windowID) }
        let visible = appeared.filter { window in
            displays.contains { $0.contains(CGPoint(x: window.bounds.midX, y: window.bounds.midY)) }
        }
        logger.info("Status item pid=\(pid) action=\(requested, privacy: .public) AX=\(result.rawValue) newVisibleWindows=\(visible.count)")
        if result == .success, !visible.isEmpty {
            return .visible
        }
        // Do not send a second click: the first can already be tracking an offscreen menu.
        if result == .success || result == .cannotComplete,
           let menu = children(of: candidate.element).first(where: { role($0) == kAXMenuRole }),
           let rect = frame(of: menu),
           let popup = appeared.first(where: { $0.layer > Int(CGWindowLevelForKey(.statusWindow)) && $0.bounds.intersects(rect) }) {
            // A visible window corresponding to this very AXMenu is independent
            // evidence that the app opened it, even when AXPress timed out.
            if visible.contains(where: { $0.windowID == popup.windowID }) { return .visible }
            guard AXUIElementPerformAction(menu, kAXCancelAction as CFString) == .success else {
                return .unavailable("Could not dismiss the offscreen menu")
            }
            var budget = 128
            if let entries = entries(in: menu, budget: &budget), !entries.isEmpty {
                return .commands(entries)
            }
        }
        return .unavailable("AX action returned \(result.rawValue), no visible response confirmed")
    }

    private nonisolated static func interfaceWindows(pid: pid_t) -> [WindowInfo] {
        WindowInfo.createWindows(option: .onScreen).filter {
            $0.ownerPID == pid && $0.layer != Int(CGWindowLevelForKey(.statusWindow))
        }
    }

    private nonisolated static func actionNames(of element: AXUIElement) -> [String] {
        var actions: CFArray?
        AXUIElementCopyActionNames(element, &actions)
        return actions as? [String] ?? []
    }

    private nonisolated static func role(_ element: AXUIElement) -> String? {
        string(of: element, attribute: kAXRoleAttribute)
    }

    private nonisolated static func entries(in menu: AXUIElement, budget: inout Int) -> [IceBarCommandMenu.Entry]? {
        var entries = [IceBarCommandMenu.Entry]()
        for child in children(of: menu) {
            guard budget > 0, role(child) == kAXMenuItemRole else { return nil }
            budget -= 1
            let nested = children(of: child)
            var submenu = [IceBarCommandMenu.Entry]()
            if !nested.isEmpty {
                guard
                    nested.count == 1, role(nested[0]) == kAXMenuRole,
                    let rows = self.entries(in: nested[0], budget: &budget), !rows.isEmpty
                else { return nil }
                submenu = rows
            }
            var enabled: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXEnabledAttribute as CFString, &enabled)
            let title = string(of: child, attribute: kAXTitleAttribute) ?? ""
            let isEnabled = enabled as? Bool == true
            guard !title.isEmpty || !isEnabled else { return nil }
            entries.append(.init(
                title: title,
                enabled: isEnabled,
                marked: !(string(of: child, attribute: kAXMenuItemMarkCharAttribute) ?? "").isEmpty,
                element: child,
                submenu: submenu
            ))
        }
        return entries
    }

    /// Open Control Center's visible Wi-Fi detail view. The tile's ordinary
    /// press toggles the radio, so only invoke its advertised details action.
    private nonisolated static func openWiFi(
        app: AXUIElement,
        candidates: [Candidate],
        bundleURL: URL,
        displays: [CGRect]
    ) -> Outcome {
        func controls() -> [AXUIElement] {
            var windows: CFTypeRef?
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
            return (windows as? [AXUIElement] ?? []).filter { window in
                guard let rect = frame(of: window) else { return false }
                return displays.contains { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }
            }.flatMap { children(of: $0) }.flatMap { children(of: $0) }
        }
        func control(_ identifier: String) -> AXUIElement? {
            controls().first { string(of: $0, attribute: kAXIdentifierAttribute) == identifier }
        }

        if control("wifi-header") != nil { return .visible }
        if control("controlcenter-wifi") == nil {
            guard let entry = candidates.first(where: { candidate in
                guard let frame = candidate.frame else { return false }
                return candidate.names.contains("com.apple.menuextra.controlcenter") &&
                    displays.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
            }), AXUIElementPerformAction(entry.element, kAXPressAction as CFString) == .success else {
                return .unavailable("No visible Control Center entry")
            }
        }
        guard let bundle = Bundle(url: bundleURL) else { return .unavailable("Missing Control Center resources") }
        var names = [bundle.localizedString(forKey: "show details", value: nil, table: nil)]
        if #available(macOS 15.4, *) {
            names.append(bundle.localizedString(
                forKey: "show details",
                value: nil,
                table: nil,
                localizations: Locale.preferredLanguages.map { Locale.Language(identifier: $0) }
            ))
        }
        let detailActions = Set(names.map { "Name:\($0)" })
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.08)
            guard let tile = control("controlcenter-wifi") else { continue }
            guard let action = actionNames(of: tile).first(where: {
                guard let name = $0.components(separatedBy: "\n").first else { return false }
                return detailActions.contains(name)
            }), AXUIElementPerformAction(tile, action as CFString) == .success else {
                return .unavailable("Wi-Fi detail action unavailable")
            }
            for _ in 0..<5 {
                Thread.sleep(forTimeInterval: 0.08)
                if control("wifi-header") != nil { return .visible }
            }
            break
        }
        return .unavailable("Wi-Fi detail view did not appear on a display")
    }

    private nonisolated static func matching(
        _ candidates: [Candidate],
        bounds: CGRect,
        title: String?,
        tagTitle: String
    ) -> Candidate? {
        guard !candidates.isEmpty else { return nil }

        // Identify the correct status item by its WindowServer coordinates.
        // This still works when the item's x coordinate is outside the screen.
        let positioned = candidates.compactMap { candidate -> (Candidate, CGFloat)? in
            guard let frame = candidate.frame, frame.width > 0, frame.height > 0 else { return nil }
            let dx = abs(frame.midX - bounds.midX)
            let dy = abs(frame.midY - bounds.midY)
            guard
                dx <= max(12, min(frame.width, bounds.width) / 2),
                dy <= max(12, min(frame.height, bounds.height) / 2)
            else {
                return nil
            }
            return (candidate, dx + dy)
        }.sorted { $0.1 < $1.1 }

        if let best = positioned.first,
           positioned.count == 1 || positioned[1].1 - best.1 > 4 {
            return best.0
        }

        let wanted = [title, tagTitle].compactMap { $0 }.map(normalize).filter { !$0.isEmpty }
        let named = candidates.filter { candidate in
            candidate.names.map(normalize).contains { wanted.contains($0) }
        }
        if named.count == 1 {
            return named[0]
        }

        // A large fraction of menu bar apps publish one status item. Use it
        // only when there is no ambiguity about which item we would press.
        return candidates.count == 1 ? candidates[0] : nil
    }

    private nonisolated static func normalize(_ string: String) -> String {
        string.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private nonisolated static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
            let children = value as? [AXUIElement]
        else {
            return []
        }
        return children
    }

    private nonisolated static func string(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            let positionValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let sizeValue,
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin), // swiftlint:disable:this force_cast
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &dimensions) // swiftlint:disable:this force_cast
        else {
            return nil
        }
        return CGRect(origin: origin, size: dimensions)
    }
}
