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
    private static let logger = Logger(category: "IceBarAccessibilityClicker")

    static func click(item: MenuBarItem, mouseButton: CGMouseButton) async -> Bool {
        let pid = item.sourcePID ?? item.ownerPID
        let bounds = Bridging.getWindowBounds(for: item.windowID) ?? item.bounds
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
                    action: action
                )
                continuation.resume(returning: outcome)
            }
        }

        switch outcome {
        case .success:
            logger.debug("Activated \(item.logString, privacy: .public) using \(action, privacy: .public) without moving it")
            return true
        case .indeterminate:
            // A timed-out AX action is not proof of a successful click.
            // Callers must not silently dismiss this failure as success.
            logger.error("Accessibility activation was not confirmed for \(item.logString, privacy: .public)")
            return false
        case .unavailable(let reason):
            logger.error("Could not activate \(item.logString, privacy: .public) without moving it: \(reason, privacy: .public)")
            return false
        }
    }

    private enum Outcome {
        case success
        case indeterminate
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
        action: String
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

        // Keep a before/after snapshot: some NSStatusItem accessibility
        // actions return cannotComplete when opening a modal popup. A timeout
        // without a newly displayed interface is not success.
        let originalWindows = onScreenWindowIDs(ownerPID: pid)
        AXUIElementSetMessagingTimeout(candidate.element, 1)
        var result = AXUIElementPerformAction(candidate.element, action as CFString)
        if result == .success {
            return .success
        }
        if aNewInterfaceAppeared(ownerPID: pid, before: originalWindows) {
            return .success
        }

        // Some items expose the actionable button one level under the menu
        // bar item. Only try it if there is one unambiguous child and there
        // was no observable interface from the initial action.
        let nested = children(of: candidate.element)
        if nested.count == 1 {
            AXUIElementSetMessagingTimeout(nested[0], 1)
            result = AXUIElementPerformAction(nested[0], action as CFString)
            if result == .success || aNewInterfaceAppeared(ownerPID: pid, before: originalWindows) {
                return .success
            }
        }

        // AXPress and AXShowMenu are distinct actions. Some menu-only apps
        // implement one but not the other; try AXShowMenu only when AXPress
        // failed and no interface was observed, without rearranging icons.
        if action == kAXPressAction as String {
            AXUIElementSetMessagingTimeout(candidate.element, 1)
            result = AXUIElementPerformAction(candidate.element, kAXShowMenuAction as CFString)
            if result == .success || aNewInterfaceAppeared(ownerPID: pid, before: originalWindows) {
                return .success
            }
        }

        switch result {
        case .cannotComplete: return .indeterminate
        default: return .unavailable("AX action returned \(result.rawValue)")
        }
    }

    /// A target app can display its menu while the AX action is blocked in
    /// its run loop; look for new on-screen windows before retrying.
    private nonisolated static func onScreenWindowIDs(ownerPID: pid_t) -> Set<CGWindowID> {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return Set(windows.compactMap { info in
            guard
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                pid == ownerPID,
                let number = info[kCGWindowNumber as String] as? CGWindowID
            else {
                return nil
            }
            return number
        })
    }

    private nonisolated static func aNewInterfaceAppeared(
        ownerPID: pid_t,
        before: Set<CGWindowID>
    ) -> Bool {
        // Give the target process a short grace period to create its popup.
        Thread.sleep(forTimeInterval: 0.15)
        return !onScreenWindowIDs(ownerPID: ownerPID).subtracting(before).isEmpty
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
