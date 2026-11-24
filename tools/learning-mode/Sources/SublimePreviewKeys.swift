import AppKit
import Carbon

// Sublime dispatches its focus_group bindings before InputMethodKit sees keyDown.
// Reserve only occupied top-row slots, only for the lifetime of this panel in Sublime.
final class SublimePreviewKeys {
  static let host = "com.sublimetext.4"
  private static let signature: OSType = 0x524C5056 // RLPV
  private static let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6]
  private var keys = [Int:EventHotKeyRef]()
  private var handler: EventHandlerRef?
  private var activation: NSObjectProtocol?
  private weak var owner: SquirrelInputController?

  init() {
    var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
      guard let event, let context else { return OSStatus(eventNotHandledErr) }
      var id = EventHotKeyID()
      guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout.size(ofValue:id), nil, &id) == noErr,
            id.signature == SublimePreviewKeys.signature else { return OSStatus(eventNotHandledErr) }
      let bindings = Unmanaged<SublimePreviewKeys>.fromOpaque(context).takeUnretainedValue()
      guard bindings.keys[Int(id.id)] != nil, let owner = bindings.owner, owner.needsSublimePreviewKeys else {
        bindings.clear(); return OSStatus(eventNotHandledErr)
      }
      _ = owner.previewCandidate(Int(id.id))
      return noErr
    }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
        object:nil, queue:.main) { [weak self] _ in
      if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != SublimePreviewKeys.host { self?.clear() }
    }
  }

  func update(owner: SquirrelInputController, count: Int) {
    guard count > 0, handler != nil, owner.needsSublimePreviewKeys else { clear(); return }
    self.owner = owner
    let limit = min(count, Self.codes.count)
    for n in keys.keys.filter({ $0 > limit }) { UnregisterEventHotKey(keys.removeValue(forKey:n)) }
    for n in 1...limit where keys[n] == nil {
      var ref: EventHotKeyRef?
      // Do not displace an existing system or third-party hot key.
      let id = EventHotKeyID(signature:Self.signature, id:UInt32(n))
      if RegisterEventHotKey(UInt32(Self.codes[n-1]), UInt32(controlKey), id, GetEventDispatcherTarget(),
                             OptionBits(kEventHotKeyExclusive), &ref) == noErr { keys[n] = ref }
    }
  }

  func clear() {
    for ref in keys.values { UnregisterEventHotKey(ref) }
    keys.removeAll()
    owner = nil
  }

  deinit {
    clear()
    if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
    if let handler { RemoveEventHandler(handler) }
  }
}
