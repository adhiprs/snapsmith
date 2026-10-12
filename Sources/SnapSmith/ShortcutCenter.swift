import AppKit
import CaptureKit

/// Owns the global hotkeys: registers each action's shortcut from Preferences, re-registers
/// when they change, and pauses while a shortcut is being recorded (otherwise pressing the
/// current combination to re-record it would trigger a capture instead of reaching the recorder).
final class ShortcutCenter {
    static let pauseRequested = Notification.Name("ShortcutCenter.pauseRequested")
    static let resumeRequested = Notification.Name("ShortcutCenter.resumeRequested")

    private let handlers: [ShortcutAction: () -> Void]
    private var hotKeys: [ShortcutAction: HotKey] = [:]
    /// Actions whose shortcut couldn't be registered.
    private(set) var unavailable: Set<ShortcutAction> = []
    private var pauseCount = 0
    private var observers: [NSObjectProtocol] = []

    init(handlers: [ShortcutAction: () -> Void]) {
        self.handlers = handlers
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in self?.reload() },
            center.addObserver(forName: Self.pauseRequested, object: nil, queue: .main) { [weak self] _ in self?.pause() },
            center.addObserver(forName: Self.resumeRequested, object: nil, queue: .main) { [weak self] _ in self?.resume() },
        ]
        reload()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Registers every action's current shortcut (skipped while paused).
    func reload() {
        guard pauseCount == 0 else { return }
        hotKeys = [:]  // HotKey unregisters in deinit
        unavailable = []
        for action in ShortcutAction.allCases {
            guard let shortcut = Preferences.shortcut(for: action), let handler = handlers[action] else { continue }
            if let hotKey = HotKey(keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers), handler: handler) {
                hotKeys[action] = hotKey
            } else {
                unavailable.insert(action)
                NSLog("SnapSmith: couldn't register \(shortcut.displayString) for \(action.title)")
            }
        }
    }

    private func pause() {
        pauseCount += 1
        hotKeys = [:]
    }

    private func resume() {
        pauseCount = max(0, pauseCount - 1)
        reload()
    }
}
