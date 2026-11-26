//
//  SquirrelInputController.swift
//  Squirrel
//
//  Created by Leo Liu on 5/7/24.
//

import InputMethodKit

final class SquirrelInputController: IMKInputController {
  private static let keyRollOver = 50
  private static var unknownAppCnt: UInt = 0

  private weak var client: IMKTextInput?
  private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var lastModifiers: NSEvent.ModifierFlags = .init()
  // In English preview mode letter keys go to the draft, not to Rime. Defer
  // Shift until release so Rime sees only a real tap, never Shift used to type.
  private var deferredEnglishShiftTap: Bool?
  private var session: RimeSessionId = 0
  private var schemaId: String = ""
  private var inlinePreedit = false
  private var inlineCandidate = false
  // for chord-typing
  private var chordKeyCodes: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordModifiers: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordKeyCount: Int = 0
  private var chordTimer: Timer?
  private var chordDuration: TimeInterval = 0
  private var currentApp: String = ""
  private var english = EnglishDraft()
  private static let completions = Bundle.main.sharedSupportURL.flatMap { LexicalIndex(url: $0.appendingPathComponent("EnglishCompletions.sqlite3")) }
  private var englishWords = [String]()
  private var englishIndex = 0
  private var englishWordSeed = ""
  private let learning = LearningPreview()
  private var candidateReading: CandidateReading?
  // A complete English candidate, not a Chinese syllable or a partial conversion.
  private var literalCandidate: String?
  // One preference shared by all input sessions. A fresh installation starts enabled.
  private static let preferenceKey = "LearningPreviewEnabled"
  #if LEARNING_TESTS
  private static var wantsPreview = true
  #else
  private static var wantsPreview: Bool {
    get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
  }
  #endif
  private var learningEnabled: Bool {
    schemaId == "learning_flypy" && Self.wantsPreview && !IsSecureEventInputEnabled()
  }

  #if LEARNING_TESTS
  func testSetup(_ id: String, learning enabled: Bool, ascii: Bool) {
    _ = rimeAPI.select_schema(session, id)
    rimeAPI.set_option(session, "ascii_mode", ascii)
    Self.wantsPreview = enabled
    rimeUpdate()
  }
  var testSession: RimeSessionId { session }
  func testRefreshPanel() { rimeUpdate() }
  func testClose() { destroySession() }
  var testTranslation: String? { learning.translation }
  var testQuery: LearningQuery? { learning.query }
  var testUsesBook: Bool { if case .dictionary = learning.reply { return true }; return false }
  #endif

  // swiftlint:disable:next cyclomatic_complexity
  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event = event else { return false }
    let modifiers = event.modifierFlags
    let changes = lastModifiers.symmetricDifference(modifiers)

    // Return true to indicate the the key input was received and dealt with.
    // Key processing will not continue in that case.  In other words the
    // system will not deliver a key down event to the application.
    // Returning false means the original key down will be passed on to the client.
    var handled = false

    if session == 0 || !rimeAPI.find_session(session) {
      createSession()
      if session == 0 {
        return false
      }
    }

    if let old = client, let new = sender as? IMKTextInput, old !== new {
      if !english.text.isEmpty { finishEnglish() }
      learning.reset()
    }
    self.client ?= sender as? IMKTextInput
    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()
    }

    switch event.type {
    case .flagsChanged:
      if lastModifiers == modifiers {
        handled = true
        break
      }
      // print("[DEBUG] FLAGSCHANGED client: \(sender ?? "nil"), modifiers: \(modifiers)")
      var rimeModifiers: UInt32 = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
      // For flags-changed event, keyCode is available since macOS 10.15
      // (#715)
      let rimeKeycode: UInt32 = SquirrelKeycode.osxKeycodeToRime(keycode: event.keyCode, keychar: nil, shift: false, caps: false)

      if changes.contains(.capsLock) {
        // NOTE: rime assumes XK_Caps_Lock to be sent before modifier changes,
        // while NSFlagsChanged event has the flag changed already.
        // so it is necessary to revert kLockMask.
        rimeModifiers ^= kLockMask.rawValue
        _ = processKey(rimeKeycode, modifiers: rimeModifiers)
      }

      if deferredEnglishShiftTap != nil && !changes.intersection([.option,.command,.control,.capsLock]).isEmpty {
        deferredEnglishShiftTap = false
      }
      // Need to process release before modifier down. Because
      // sometimes release event is delayed to next modifier keydown.
      var buffer = [(keycode: UInt32, modifier: UInt32)]()
      for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] where changes.contains(flag) {
        if flag == .shift {
          if modifiers.contains(.shift), learningEnabled, rimeAPI.get_option(session, "ascii_mode") {
            deferredEnglishShiftTap = modifiers.intersection([.control,.command,.option]).isEmpty
            continue
          }
          if !modifiers.contains(.shift), let tap = deferredEnglishShiftTap {
            deferredEnglishShiftTap = nil
            if tap {
              buffer.append((rimeKeycode, rimeModifiers | kShiftMask.rawValue))
              buffer.append((rimeKeycode, rimeModifiers | kReleaseMask.rawValue))
            }
            continue
          }
        }
        if modifiers.contains(flag) { // New modifier
          buffer.append((keycode: rimeKeycode, modifier: rimeModifiers))
        } else { // Release
          buffer.insert((keycode: rimeKeycode, modifier: rimeModifiers | kReleaseMask.rawValue), at: 0)
        }
      }
      for (keycode, modifier) in buffer {
        _ = processKey(keycode, modifiers: modifier)
      }

      lastModifiers = modifiers
      rimeUpdate()

    case .keyDown:
      if deferredEnglishShiftTap != nil { deferredEnglishShiftTap = false }
      // Caps Lock changes letter case, not Backspace. Passing LockMask to
      // Rime here can return false: the host then deletes the entire marked
      // range while Rime still owns the old spelling. Use the hardware key
      // even for clients that send no characters for Delete.
      if [51,117].contains(event.keyCode), modifiers.intersection([.shift,.control,.option,.command]).isEmpty,
         rimeAPI.get_input(session).map({ $0.pointee != 0 }) == true {
        _ = processKey(UInt32(event.keyCode == 51 ? XK_BackSpace : XK_Delete), modifiers:0)
        rimeUpdate()
        return true
      }
      if let result = handleLearningKey(event) { return result }
      // ignore Command+X hotkeys.
      if modifiers.contains(.command) {
        break
      }

      let keyCode = event.keyCode
      var keyChars = event.charactersIgnoringModifiers
      let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
      if let code = keyChars?.first,
         (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
        keyChars = event.characters
      }
      // print("[DEBUG] KEYDOWN client: \(sender ?? "nil"), modifiers: \(modifiers), keyCode: \(keyCode), keyChars: [\(keyChars ?? "empty")]")

      // translate osx keyevents to rime keyevents
      if let char = keyChars?.first {
        let rimeKeycode = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: char,
                                                           shift: modifiers.contains(.shift),
                                                           caps: modifiers.contains(.capsLock))
        if rimeKeycode != 0 {
          let rimeModifiers = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
          handled = processKey(rimeKeycode, modifiers: rimeModifiers)
          rimeUpdate()
        }
      }

    default:
      break
    }

    return handled
  }

  var needsSublimePreviewKeys: Bool {
    currentApp == SublimePreviewKeys.host && learningEnabled &&
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == currentApp &&
      NSApp.squirrelAppDelegate.panel?.inputController === self && NSApp.squirrelAppDelegate.panel?.isVisible == true
  }

  // Both the ordinary IMK event and the Sublime shortcut only move the highlight.
  func previewCandidate(_ number: Int, repeatKey: Bool = false) -> Bool {
    guard learningEnabled, let panel = NSApp.squirrelAppDelegate.panel, panel.inputController === self,
          panel.isVisible, panel.candidateCount > 0 else { return false }
    guard !repeatKey, number > 0, number <= panel.candidateCount else { return true }
    let index = number - 1
    if !englishWords.isEmpty {
      if englishWords.indices.contains(index), englishIndex != index { englishIndex = index; showEnglish() }
    } else if rimeAPI.highlight_candidate_on_current_page(session, index) {
      rimeUpdate()
    }
    return true
  }

  func selectCandidate(_ index: Int) -> Bool {
    if !english.text.isEmpty {
      guard englishWords.indices.contains(index) else { return false }
      finishEnglish(as:englishWords[index]); return true
    }
    let success = rimeAPI.select_candidate_on_current_page(session, index)
    if success {
      rimeUpdate()
    }
    return success
  }

  // swiftlint:disable:next identifier_name
  func page(up: Bool) -> Bool {
    var handled = false
    handled = rimeAPI.change_page(session, up)
    if handled {
      rimeUpdate()
    }
    return handled
  }

  func moveCaret(forward: Bool) -> Bool {
    let currentCaretPos = rimeAPI.get_caret_pos(session)
    guard let input = rimeAPI.get_input(session) else { return false }
    if forward {
      if currentCaretPos <= 0 {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos - 1)
    } else {
      let inputStr = String(cString: input)
      if currentCaretPos >= inputStr.utf8.count {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos + 1)
    }
    rimeUpdate()
    return true
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    // print("[DEBUG] recognizedEvents:")
    return Int(NSEvent.EventTypeMask.Element(arrayLiteral: .keyDown, .flagsChanged).rawValue)
  }

  override func activateServer(_ sender: Any!) {
    StateDiagnostics.shared.sample(.active)
    self.client ?= sender as? IMKTextInput
    // print("[DEBUG] activateServer:")
    var keyboardLayout = NSApp.squirrelAppDelegate.config?.getString("keyboard_layout") ?? ""
    if keyboardLayout == "last" || keyboardLayout == "" {
      keyboardLayout = ""
    } else if keyboardLayout == "default" {
      keyboardLayout = "com.apple.keylayout.ABC"
    } else if !keyboardLayout.hasPrefix("com.apple.keylayout.") {
      keyboardLayout = "com.apple.keylayout.\(keyboardLayout)"
    }
    if keyboardLayout != "" {
      client?.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    preedit = ""
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    // print("[DEBUG] initWithServer: \(server ?? .init()) delegate: \(delegate ?? "nil") client:\(client ?? "nil")")
    #if LEARNING_TESTS
    // IMK only accepts its own remote client proxy in this initializer. The isolated
    // controller test uses a local text-field double; real installations use IMK below.
    super.init()
    #else
    super.init(server: server, delegate: delegate, client: client)
    #endif
    learning.changed = { [weak self] in
      guard let self, self.client != nil, let panel = NSApp.squirrelAppDelegate.panel,
            panel.inputController === self, self.learningEnabled else { return }
      panel.refreshLearningLine(self.learning.line)
    }
    createSession()
  }

  override func deactivateServer(_ sender: Any!) {
    StateDiagnostics.shared.sample(.inactive)
    deferredEnglishShiftTap = nil
    // print("[DEBUG] deactivateServer: \(sender ?? "nil")")
    hidePalettes()
    commitComposition(sender)
    client = nil
  }

  override func hidePalettes() {
    literalCandidate = nil
    candidateReading = nil
    englishWords = []; englishWordSeed = ""; englishIndex = 0
    learning.reset()
    if let panel = NSApp.squirrelAppDelegate.panel, panel.inputController === self || panel.inputController == nil {
      panel.hide()
    }
    super.hidePalettes()
  }

  /*!
   @method
   @abstract   Called when a user action was taken that ends an input session.
   Typically triggered by the user selecting a new input method
   or keyboard layout.
   @discussion When this method is called your controller should send the
   current input buffer to the client via a call to
   insertText:replacementRange:.  Additionally, this is the time
   to clean up if that is necessary.
   */
  override func commitComposition(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    // print("[DEBUG] commitComposition: \(sender ?? "nil")")
    if !english.text.isEmpty { finishEnglish(); return }
    //  commit raw input
    if session != 0 {
      if let input = rimeAPI.get_input(session), input.pointee != 0 {
        let raw = String(cString: input)
        rimeAPI.clear_composition(session)
        commit(string: raw)
      }
    }
  }

  override func menu() -> NSMenu! {
    let menu = NSMenu()
    let toggle = NSMenuItem(title: "翻译预览", action: #selector(toggleLearning(_:)), keyEquivalent: "")
    toggle.state = Self.wantsPreview ? .on : .off
    toggle.target = self
    menu.addItem(toggle)
    let themes = menu.addItem(withTitle: "主题", action: #selector(showPreferences(_:)), keyEquivalent: "")
    themes.target = self
    let animation = menu.addItem(withTitle: "候选窗弹出动画", action: #selector(togglePopupAnimation(_:)), keyEquivalent: "")
    animation.target = self
    animation.state = CandidateAppearance.popupAnimationEnabled ? .on : .off
    menu.addItem(.separator())
    let diagnostics = menu.addItem(withTitle:"状态诊断日志", action:#selector(toggleDiagnostics(_:)), keyEquivalent:"")
    diagnostics.target = self
    diagnostics.state = StateDiagnostics.shared.enabled ? .on : .off
    if FileManager.default.fileExists(atPath:StateDiagnostics.file.path) {
      let reveal = menu.addItem(withTitle:"显示诊断日志文件", action:#selector(revealDiagnostics(_:)), keyEquivalent:"")
      reveal.target = self
    }
    return menu
  }

  @objc func togglePopupAnimation(_ sender: Any?) {
    CandidateAppearance.popupAnimationEnabled.toggle()
    NSApp.squirrelAppDelegate.panel?.applyPopupAnimationPreference()
    (sender as? NSMenuItem)?.state = CandidateAppearance.popupAnimationEnabled ? .on : .off
  }

  @objc func toggleDiagnostics(_ sender: Any?) {
    StateDiagnostics.defaults.set(!StateDiagnostics.shared.enabled, forKey:StateDiagnostics.preference)
    StateDiagnostics.shared.applyPreference()
    (sender as? NSMenuItem)?.state = StateDiagnostics.shared.enabled ? .on : .off
  }

  @objc func revealDiagnostics(_ sender: Any?) {
    let file = StateDiagnostics.file
    if FileManager.default.fileExists(atPath:file.path) {
      NSWorkspace.shared.activateFileViewerSelecting([file])
    } else { NSSound.beep() }
  }

  override func showPreferences(_ sender: Any!) {
    // Let the system input menu close before ordering the settings window.
    DispatchQueue.main.async { NSApp.squirrelAppDelegate.showPalettes() }
  }

  @objc func toggleLearning(_ sender: Any?) {
    Self.wantsPreview.toggle()
    if let item = sender as? NSMenuItem { item.state = Self.wantsPreview ? .on : .off }
    if !Self.wantsPreview { learning.reset() }
    // InputMethodKit can invoke a menu action through a different controller.
    let owner = NSApp.squirrelAppDelegate.panel?.inputController ?? self
    if owner.session != 0 && owner.rimeAPI.find_session(owner.session) { owner.rimeUpdate() }
  }

  deinit {
    destroySession()
  }
}

private extension SquirrelInputController {

  func onChordTimer(_: Timer) {
    // chord release triggered by timer
    var processedKeys = false
    if chordKeyCount > 0 && session != 0 {
      // simulate key-ups
      for i in 0..<chordKeyCount {
        let handled = rimeAPI.process_key(session, Int32(chordKeyCodes[i]), Int32(chordModifiers[i] | kReleaseMask.rawValue))
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      rimeUpdate()
    }
  }

  func updateChord(keycode: UInt32, modifiers: UInt32) {
    // print("[DEBUG] update chord: {\(chordKeyCodes)} << \(keycode)")
    for i in 0..<chordKeyCount where chordKeyCodes[i] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      // you are cheating. only one human typist (fingers <= 10) is supported.
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    // reset timer
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = NSApp.squirrelAppDelegate.config?.getDouble("chord_duration"), duration > 0 {
      chordDuration = duration
    }
    chordTimer = Timer.scheduledTimer(withTimeInterval: chordDuration, repeats: false, block: onChordTimer)
  }

  func clearChord() {
    chordKeyCount = 0
    if let timer = chordTimer {
      if timer.isValid {
        timer.invalidate()
      }
      chordTimer = nil
    }
  }

  func createSession() {
    learning.reset()

    let app = client?.bundleIdentifier() ?? {
      SquirrelInputController.unknownAppCnt &+= 1
      return "UnknownApp\(SquirrelInputController.unknownAppCnt)"
    }()
    print("createSession: \(app)")
    currentApp = app
    session = rimeAPI.create_session()
    schemaId = ""

    if session != 0 {
      updateAppOptions()
    }
  }

  func updateAppOptions() {
    if currentApp == "" {
      return
    }
    if let appOptions = NSApp.squirrelAppDelegate.config?.getAppOptions(currentApp) {
      for (key, value) in appOptions {
        print("set app option: \(key) = \(value)")
        rimeAPI.set_option(session, key, value)
      }
    }
  }

  func destroySession() {
    // print("[DEBUG] destroySession:")
    if session != 0 {
      _ = rimeAPI.destroy_session(session)
      session = 0
    }
    clearChord()
  }

  func processKey(_ rimeKeycode: UInt32, modifiers rimeModifiers: UInt32) -> Bool {
    // TODO add special key event preprocessing here

    // with linear candidate list, arrow keys may behave differently.
    if let panel = NSApp.squirrelAppDelegate.panel {
      if panel.linear != rimeAPI.get_option(session, "_linear") {
        rimeAPI.set_option(session, "_linear", panel.linear)
      }
      // with vertical text, arrow keys may behave differently.
      if panel.vertical != rimeAPI.get_option(session, "_vertical") {
        rimeAPI.set_option(session, "_vertical", panel.vertical)
      }
    }

    let handled = rimeAPI.process_key(session, Int32(rimeKeycode), Int32(rimeModifiers))
    // print("[DEBUG] rime_keycode: \(rimeKeycode), rime_modifiers: \(rimeModifiers), handled = \(handled)")

    // TODO add special key event postprocessing here

    if !handled {
      let isVimBackInCommandMode = rimeKeycode == XK_Escape || ((rimeModifiers & kControlMask.rawValue != 0) && (rimeKeycode == XK_c || rimeKeycode == XK_C || rimeKeycode == XK_bracketleft))
      if isVimBackInCommandMode && rimeAPI.get_option(session, "vim_mode") &&
          !rimeAPI.get_option(session, "ascii_mode") {
        rimeAPI.set_option(session, "ascii_mode", true)
        // print("[DEBUG] turned Chinese mode off in vim-like editor's command mode")
      }
    } else {
      let isChordingKey = switch Int32(rimeKeycode) {
      case XK_space...XK_asciitilde, XK_Control_L, XK_Control_R, XK_Alt_L, XK_Alt_R, XK_Shift_L, XK_Shift_R:
        true
      default:
        false
      }
      if isChordingKey && rimeAPI.get_option(session, "_chord_typing") {
        updateChord(keycode: rimeKeycode, modifiers: rimeModifiers)
      } else if (rimeModifiers & kReleaseMask.rawValue) == 0 {
        // non-chording key pressed
        clearChord()
      }
    }

    return handled
  }

  func rimeConsumeCommittedText() {
    var commitText = RimeCommit.rimeStructInit()
    if rimeAPI.get_commit(session, &commitText) {
      if let text = commitText.text {
        commit(string: String(cString: text))
      }
      _ = rimeAPI.free_commit(&commitText)
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  func rimeUpdate() {
    // print("[DEBUG] rimeUpdate")
    rimeConsumeCommittedText()

    var status = RimeStatus_stdbool.rimeStructInit()
    if rimeAPI.get_status(session, &status) {
      StateDiagnostics.shared.mode(ascii:status.is_ascii_mode)
      // enable schema specific ui style
      // swiftlint:disable:next identifier_name
      if let schema_id = status.schema_id, schemaId == "" || schemaId != String(cString: schema_id) {
        schemaId = String(cString: schema_id)
        NSApp.squirrelAppDelegate.loadSettings(for: schemaId)
        // inline preedit
        if let panel = NSApp.squirrelAppDelegate.panel {
          inlinePreedit = (panel.inlinePreedit && !rimeAPI.get_option(session, "no_inline")) || rimeAPI.get_option(session, "inline")
          inlineCandidate = panel.inlineCandidate && !rimeAPI.get_option(session, "no_inline")
          // if not inline, embed soft cursor in preedit string
          rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
        }
      }
      _ = rimeAPI.free_status(&status)
    }

    if !english.text.isEmpty {
      if learningEnabled && rimeAPI.get_option(session, "ascii_mode") == english.beganInASCII { showEnglish(); return }
      finishEnglish()
    }

    var ctx = RimeContext_stdbool.rimeStructInit()
    if rimeAPI.get_context(session, &ctx) {
      // update preedit text
      let preedit = ctx.composition.preedit.map({ String(cString: $0) }) ?? ""

      let start = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_start)), within: preedit) ?? preedit.startIndex
      let end = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_end)), within: preedit) ?? preedit.startIndex
      let caretPos = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.cursor_pos)), within: preedit) ?? preedit.startIndex

      let raw = rimeAPI.get_input(session).map { String(cString: $0) } ?? ""
      let hi = Int(ctx.menu.highlighted_candidate_index)
      let selected = hi >= 0 && hi < Int(ctx.menu.num_candidates) ? String(cString: ctx.menu.candidates[hi].text) : ""
      literalCandidate = !raw.isEmpty && raw.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) } &&
        selected.caseInsensitiveCompare(raw) == .orderedSame && ctx.commit_text_preview.map { String(cString: $0) } == selected ? raw : nil
      if inlinePreedit, let word = literalCandidate {
        // Chinese syllable separators are not part of an English spelling ("L L M").
        show(preedit: word, selRange: NSRange(location: 0, length: word.utf16.count),
             caretPos: min(Int(rimeAPI.get_caret_pos(session)), word.utf16.count))
      } else if inlineCandidate {
        var candidatePreview = ctx.commit_text_preview.map { String(cString: $0) } ?? ""
        let endOfCandidatePreview = candidatePreview.endIndex
        if inlinePreedit {
          // 左移光標後的情形：
          // preedit:             ^已選某些字[xiang zuo yi dong]|guangbiao$
          // commit_text_preview: ^已選某些字向左移動$
          // candidate_preview:   ^已選某些字[向左移動]|guangbiao$
          // 繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidong$
          // candidate_preview:   ^已選某些字[向左]yidong|guangbiao$
          // 光標移至當前段落最左端的情形：
          // preedit:             ^已選某些字|[xiang zuo yi dong guang biao]$
          // commit_text_preview: ^已選某些字向左移動光標$
          // candidate_preview:   ^已選某些字|[向左移動光標]$
          // 討論：
          // preedit 與 commit_text_preview 中“已選某些字”部分一致
          // 因此，選中範圍即正在翻譯的碼段“向左移動”中，兩者的 start 值一致
          // 光標位置的範圍是 start ..= endOfCandidatePreview
          if caretPos >= end && caretPos < preedit.endIndex {
            // 從 preedit 截取光標後未翻譯的編碼“guangbiao”
            candidatePreview += preedit[caretPos...]
          }
        } else {
          // 翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字[向左???]|$
          // 光標移至當前段落最左端，繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字|[xiang zuo]yidongguangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字|[向左]???$
          // FIXME: add librime APIs to support preview candidate without remaining code.
        }
        // preedit can contain additional prompt text before start:
        // ^(prompt)[selection]$
        let start = min(start, candidatePreview.endIndex)
        // caret can be either before or after the selected range.
        let caretPos = caretPos <= start ? caretPos : endOfCandidatePreview
        show(preedit: candidatePreview,
             selRange: NSRange(location: start.utf16Offset(in: candidatePreview),
                               length: candidatePreview.utf16.distance(from: start, to: candidatePreview.endIndex)),
             caretPos: caretPos.utf16Offset(in: candidatePreview))
      } else {
        if inlinePreedit {
          show(preedit: preedit, selRange: NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end)), caretPos: caretPos.utf16Offset(in: preedit))
        } else {
          // TRICKY: display a non-empty string to prevent iTerm2 from echoing
          // each character in preedit. note this is a full-shape space U+3000;
          // using half shape characters like "..." will result in an unstable
          // baseline when composing Chinese characters.
          show(preedit: preedit.isEmpty ? "" : "　", selRange: NSRange(location: 0, length: 0), caretPos: 0)
        }
      }

      // update candidates
      let numCandidates = Int(ctx.menu.num_candidates)
      var candidates = [String]()
      var comments = [String]()
      for i in 0..<numCandidates {
        let candidate = ctx.menu.candidates[i]
        candidates.append(candidate.text.map { String(cString: $0) } ?? "")
        comments.append(candidate.comment.map { String(cString: $0) } ?? "")
      }
      // Some editors deliver uppercase letters without a Caps Lock flag. Once
      // Rime identifies a complete standalone acronym, use the same English
      // menu as ASCII mode, regardless of how the uppercase keys arrived.
      if learningEnabled, raw.count >= 2, literalCandidate == raw,
         raw.utf8.allSatisfy({ (65...90).contains($0) }),
         candidates.allSatisfy({ $0.utf8.allSatisfy { $0 < 128 } }),
         Int(rimeAPI.get_caret_pos(session)) == raw.utf8.count {
        _ = rimeAPI.free_context(&ctx)
        rimeAPI.clear_composition(session)
        english = EnglishDraft(); english.beganInASCII = rimeAPI.get_option(session,"ascii_mode")
        english.insert(raw); showEnglish()
        return
      }
      var labels = [String]()
      // swiftlint:disable identifier_name
      if let select_keys = ctx.menu.select_keys {
        labels = String(cString: select_keys).map { String($0) }
      } else if let select_labels = ctx.select_labels {
        let pageSize = Int(ctx.menu.page_size)
        for i in 0..<pageSize {
          labels.append(select_labels[i].map { String(cString: $0) } ?? "")
        }
      }
      // swiftlint:enable identifier_name
      candidateReading = nil
      var spelling: String?
      if learningEnabled, candidates.indices.contains(hi), ctx.composition.length > 0,
         let raw = rimeAPI.get_input(session), let preview = ctx.commit_text_preview {
        let input = String(cString: raw)
        spelling = input
        candidateReading = CandidateReading(preview:String(cString:preview), highlighted:candidates[hi],
                                            raw:input, prefix:preedit[..<start], tail:preedit[end...])
      }
      if learningEnabled { learning.update(candidateReading?.query, spelling: spelling) } else { learning.reset() }
      let page = Int(ctx.menu.page_no)
      let lastPage = ctx.menu.is_last_page

      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      showPanel(preedit: inlinePreedit ? "" : preedit, selRange: selRange, caretPos: caretPos.utf16Offset(in: preedit),
                candidates: candidates, comments: comments, labels: labels, highlighted: Int(ctx.menu.highlighted_candidate_index),
                page: page, lastPage: lastPage)
      _ = rimeAPI.free_context(&ctx)
    } else {
      hidePalettes()
    }
  }

  func commit(string: String) {
    guard let client = client else { return }
    // print("[DEBUG] commitString: \(string)")
    client.insertText(string, replacementRange: .empty)
    preedit = ""
    hidePalettes()
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int) {
    guard let client = client else { return }
    // print("[DEBUG] showPreeditString: '\(preedit)'")
    if self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    // print("[DEBUG] selRange.location = \(selRange.location), selRange.length = \(selRange.length); caretPos = \(caretPos)")
    let start = selRange.location
    let attrString = NSMutableAttributedString(string: preedit)
    if start > 0 {
      let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: start))! as! [NSAttributedString.Key: Any]
      attrString.setAttributes(attrs, range: NSRange(location: 0, length: start))
    }
    let remainingRange = NSRange(location: start, length: preedit.utf16.count - start)
    let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: remainingRange)! as! [NSAttributedString.Key: Any]
    attrString.setAttributes(attrs, range: remainingRange)
    client.setMarkedText(attrString, selectionRange: NSRange(location: caretPos, length: 0), replacementRange: .empty)
  }

  // swiftlint:disable:next function_parameter_count
  func showPanel(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted: Int, page: Int, lastPage: Bool) {
    // print("[DEBUG] showPanelWithPreedit:...:")
    guard let client = client else { return }
    var inputPos = NSRect()
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.position = inputPos
      panel.inputController = self
      let composing = !candidates.isEmpty || !preedit.isEmpty
      panel.learningLine = learning.line ?? (learningEnabled && composing ? .pending : nil)
      panel.update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels,
                   highlighted: highlighted, page: page, lastPage: lastPage, update: true)
      panel.sublimeKeys.update(owner:self, count:panel.candidateCount)
    }
  }
}

// The IME owns only its own marked (not yet committed) English text.
// No global key monitor, clipboard, accessibility permission or surrounding-text reads.
private extension SquirrelInputController {
  func finishEnglish(as chosen: String? = nil) {
    let original = chosen ?? english.text
    english = EnglishDraft()
    if !original.isEmpty { commit(string: original) }
    learning.reset()
  }

  func showEnglish() {
    literalCandidate = nil
    candidateReading = nil
    let text = english.text
    let end = english.caret
    let preview = english.previewText
    if englishWordSeed != text {
      englishWordSeed = text; englishIndex = 0; englishWords = []
      if text.count >= 2 && text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) {
        let matches = Self.completions?.choices(for:text.lowercased(),limit:5).map(\.text) ?? []
        if !matches.isEmpty { englishWords = [text] + matches }
      }
    }
    let reading = englishWords.indices.contains(englishIndex) ? englishWords[englishIndex] : preview
    // Unlike a pinyin spelling, trailing spaces can't change this reading.
    // Keep both an in-flight request and a ready caption for equivalent drafts.
    learning.update(preview.isEmpty ? nil : LearningQuery(text:reading, direction:.chinese))
    show(preedit: text, selRange: NSRange(location: 0, length: text.utf16.count), caretPos: end)
    if preview.isEmpty { hidePalettes(); return }
    showPanel(preedit: englishWords.isEmpty ? preview : "", selRange: NSRange(location:0,length:0), caretPos:0,
              candidates:englishWords, comments:Array(repeating:"",count:englishWords.count), labels:[], highlighted:englishIndex, page:0, lastPage:true)
  }

  func handleLearningKey(_ event: NSEvent) -> Bool? {
    guard learningEnabled else {
      if !english.text.isEmpty { finishEnglish() }
      return nil
    }
    let flags = event.modifierFlags.intersection([.option, .command, .control, .shift])
    let code = event.keyCode
    if flags == .control, let key = event.charactersIgnoringModifiers, key.count == 1,
       let number = Int(key), (1...6).contains(number), previewCandidate(number, repeatKey:event.isARepeat) {
      return true
    }
    let optionReturn = code == 36 || code == 76
    if flags.isEmpty, (code == 49 || optionReturn), let word = literalCandidate,
       let panel = NSApp.squirrelAppDelegate.panel, panel.isVisible, panel.inputController === self {
      // End Rime's composition before notifying the editor; it may call us back synchronously.
      rimeAPI.clear_composition(session)
      commit(string: word)
      return true
    }
    // Use the unmodified key to distinguish the physical shortcut from its Option symbol.
    let digit = event.charactersIgnoringModifiers.flatMap { ["1","2","3"].firstIndex(of: $0) }
    let selectedSense = digit.flatMap(learning.numbered)
    let choosingSense = selectedSense != nil || (digit != nil && learning.query != nil &&
      (learning.reply == nil || !english.text.isEmpty))
    if flags == .option, optionReturn || choosingSense,
       learning.query != nil || (!preedit.isEmpty && NSApp.squirrelAppDelegate.panel?.inputController === self) {
      guard let panel = NSApp.squirrelAppDelegate.panel, panel.isVisible,
            panel.inputController === self, panel.learningLine == learning.line,
            let text = optionReturn ? learning.translation : selectedSense, !event.isARepeat else { return true }
      let remainder = candidateReading?.remainder ?? ""
      if remainder.isEmpty {
        rimeAPI.clear_composition(session)
      } else {
        guard rimeAPI.set_input(session, remainder) else { return true }
      }
      english = EnglishDraft()
      commit(string: text)
      if !remainder.isEmpty { rimeUpdate() }
      return true
    }
    let ascii = rimeAPI.get_option(session, "ascii_mode")
    // A lowercase continuation in Chinese mode can be the next Xiaohe syllable.
    // Give Rime the original prefix back; a highlighted suggestion is not typed text.
    if !ascii, !english.beganInASCII, !english.text.isEmpty, english.caret == english.text.utf16.count,
       english.text.utf8.allSatisfy({ (65...90).contains($0) }), flags.isEmpty,
       !event.modifierFlags.contains(.capsLock), event.characters?.first.map({ $0.isASCII && $0.isLowercase }) == true,
       rimeAPI.set_input(session,english.text) {
      english = EnglishDraft(); englishWordSeed = ""; englishWords = []; englishIndex = 0
      return nil
    }
    let capsWord = event.modifierFlags.contains(.capsLock) && flags.isEmpty &&
      event.characters?.first.map { $0.isASCII && $0.isUppercase } == true
    guard ascii || !english.text.isEmpty || capsWord,
          rimeAPI.get_input(session).map({ $0.pointee == 0 }) ?? true else { return nil }
    // Pass shortcuts and navigation through after committing only original English.
    if !flags.subtracting(.shift).isEmpty {
      if !english.text.isEmpty { finishEnglish() }
      return nil
    }
    let editing = !english.text.isEmpty
    if !editing { english.beganInASCII = ascii }
    let chosen = englishWords.indices.contains(englishIndex) ? englishWords[englishIndex] : nil
    switch code {
    case 125,126:
      guard !englishWords.isEmpty && flags.isEmpty else { if editing { finishEnglish() }; return nil }
      englishIndex = max(0,min(englishWords.count-1,englishIndex+(code == 125 ? 1 : -1)))
    case 36, 76:
      guard editing else { return nil }; finishEnglish(as:chosen); return true
    case 49 where editing && flags.isEmpty && !english.text.contains(" "):
      finishEnglish(as:chosen); return true
    case 53 where editing:
      english = EnglishDraft(); showEnglish(); return true
    case 51 where editing: english.erase(backwards: true)
    case 117 where editing: english.erase(backwards: false)
    case 123 where editing: english.move(-1)
    case 124 where editing: english.move(1)
    default:
      if let value = event.characters, !value.isEmpty,
         value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 || "’‘“”".unicodeScalars.contains($0) }),
         editing || value.first?.isLetter == true {
        english.insert(value)
      } else {
        if editing { finishEnglish() }
        return nil
      }
    }
    showEnglish()
    return true
  }
}
