import AppKit
import Carbon.HIToolbox

/// The system-wide ⌥Space shortcut, registered with Carbon's hot key API
/// (which needs no accessibility permission).
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register() {
        guard hotKey == nil else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { GlobalHotKey.shared.onPress?() }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4148_4B59), id: 1) // "AHKY"
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { hotKey = nil }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}
