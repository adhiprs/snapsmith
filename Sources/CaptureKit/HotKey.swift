import Carbon.HIToolbox

/// System-wide hotkey via Carbon's `RegisterEventHotKey`.
/// It doesn't need Accessibility permission, unlike an NSEvent global monitor.
public final class HotKey {
    public let keyCode: UInt32
    public let modifiers: UInt32
    private let handler: () -> Void
    private var ref: EventHotKeyRef?
    private let id: UInt32

    private static var nextID: UInt32 = 1
    /// Weak, so releasing a HotKey unregisters it (a strong registry kept old shortcuts alive).
    private static var registry: [UInt32: WeakBox] = [:]
    private final class WeakBox { weak var hotKey: HotKey?; init(_ hotKey: HotKey) { self.hotKey = hotKey } }
    private static var eventHandler: EventHandlerRef?

    /// - Parameters:
    ///   - keyCode: a virtual key code such as `kVK_ANSI_4`.
    ///   - modifiers: Carbon masks such as `optionKey | shiftKey`.
    public init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.handler = handler
        self.id = HotKey.nextID
        HotKey.nextID += 1

        HotKey.installEventHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_4150) /* 'SNAP' */, id: id)
        let status = RegisterEventHotKey(self.keyCode, self.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }  // the combination is already registered in this app
        HotKey.registry[id] = WeakBox(self)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.registry[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKey.registry[hotKeyID.id]?.hotKey?.handler()
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
