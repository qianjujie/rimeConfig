import Cocoa
import InputMethodKit
import Darwin

enum LearningChecks {
  static func check(_ pass: @autoclosure () -> Bool, _ message: String) {
    if !pass() { print("FAIL: \(message)"); fflush(stdout); exit(1) }
  }
  static func wait(_ predicate: () -> Bool) {
    let end = Date(timeIntervalSinceNow: 8)
    while !predicate() && Date() < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.012)) }
    check(predicate(), "result did not arrive at rest")
  }
  /// Pixel check on the fixed light theme. Both scripts must center the visible ink,
  /// not the font's line box; the previous four-character chip missed by six points.
  static func checkCenteredSource(_ rep: NSBitmapImageRep) {
    var chip = CGRect.null, ink = CGRect.null
    for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
      guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
            c.alphaComponent > 0.96, c.greenComponent - c.redComponent > 0.025,
            c.greenComponent - c.blueComponent > 0.025 else { continue }
      let pixel = CGRect(x: x, y: y, width: 1, height: 1)
      chip = chip.union(pixel)
      if c.greenComponent < 0.57 { ink = ink.union(pixel) }
    }}
    let scale = CGFloat(rep.pixelsWide) / rep.size.width
    print("optical center:", chip, ink, "delta", ink.midX-chip.midX,ink.midY-chip.midY)
    check(!ink.isNull && !chip.isNull && abs(chip.midX - ink.midX) <= scale &&
          abs(chip.midY - ink.midY) <= scale, "source text is not centered in its highlight")
  }
  static func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.appearance = NSAppearance(named: .aqua)
    let delegate = SquirrelApplicationDelegate(); app.delegate = delegate
    let panel = delegate.panel!
    let body = panel.contentView!.subviews.compactMap { $0 as? SquirrelView }.first!
    _ = FileManager.default.changeCurrentDirectoryPath(Bundle.main.sharedSupportPath!)
    delegate.setupRime()
    let api = delegate.rimeAPI
    api.initialize(nil); delegate.loadSettings()
    let server: IMKServer? = nil // The isolated controller initializes a local test client itself.
    let field = ProbeClient()
    let c = SquirrelInputController(server: server, delegate: nil, client: field)!
    func key(_ text: String, _ code: UInt16 = 0, _ flags: NSEvent.ModifierFlags = []) -> Bool {
      let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
      return c.handle(e, client: field)
    }
    func type(_ text: String) { for ch in text { check(key(String(ch), ch == " " ? 49 : 0), "unhandled example character: \(ch)") } }
    func snapshot() -> [String] {
      var ctx = RimeContext_stdbool.rimeStructInit()
      guard api.get_context(c.testSession, &ctx) else { return [] }
      defer { _ = api.free_context(&ctx) }
      return (0..<Int(ctx.menu.num_candidates)).map { String(cString: ctx.menu.candidates[$0].text) }
    }
    func screenshot(_ name: String, window: NSWindow? = nil) {
      let window = window ?? panel
      guard let v = window.contentView else { exit(1) }
      v.layoutSubtreeIfNeeded(); window.display()
      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
      v.cacheDisplay(in: v.bounds, to: rep)
      let url = URL(filePath: CommandLine.arguments[3]).appendingPathComponent(name + ".png")
      try! rep.representation(using: .png, properties: [:])!.write(to: url)
      if ["you","font-size","en-zh"].contains(name) { checkCenteredSource(rep) }
      if ["you","fragment","en-zh"].contains(name) {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        func firstInk(from top: Int, to bottom: Int) -> Int? {
          for x in Int(2*scale)..<Int(30*scale) {
            for y in top..<bottom {
              if let c = rep.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),
                 c.alphaComponent > 0.96, max(c.redComponent,c.greenComponent,c.blueComponent) < 0.63 { return x }
            }
          }
          return nil
        }
        let upper = firstInk(from:Int(7*scale),to:Int(25*scale))
        let lower = firstInk(from:rep.pixelsHigh-Int(16*scale),to:rep.pixelsHigh-Int(3*scale))
        print("Left ink (pixels),", name, upper as Any, lower as Any)
        check(upper != nil && lower != nil && abs(upper! - lower!) <= 1, "translation and source do not share a visible left edge: " + name)
      }
    }
    if ProcessInfo.processInfo.environment["RIME_TEST_SENSES_DB"] != nil {
      c.testSetup("learning_flypy", learning:true, ascii:false)
      func compose(_ spelling: String, _ word: String) {
        type(spelling)
        if c.testQuery?.text != word, let slot = snapshot().firstIndex(of:word) {
          for _ in 0..<slot { _ = key("\u{f703}",124) }
        }
        check(c.testQuery?.text == word, "unexpected query: " + (c.testQuery?.text ?? "-") + " (" + spelling + ")")
        wait { c.testTranslation != nil }
      }
      let digitCodes: [UInt16] = [18,19,20,21,23,22]
      func jump(_ number: Int) {
        check(key(String(number),digitCodes[number-1],.control), "Control+number not handled")
      }
      type("difh")
      let firstPage = snapshot()
      let originalMarked = field.marked
      for number in [6,2,4] {
        jump(number)
        check(body.hilightedIndex == number-1 && c.testQuery?.text == firstPage[number-1] &&
              snapshot() == firstPage && field.committed == "" && field.marked == originalMarked,
              "direct preview changed composition or selected the wrong word")
      }
      wait { c.testTranslation != nil }
      print("Control+4:", firstPage[3], "→", c.testTranslation!, "(no commit)")
      screenshot("control-preview")
      _ = key(" ",49); check(field.committed == firstPage[3], "Space did not confirm the previewed word")
      field.committed = ""

      type("qkdj"); check(key("=",24), "page down before direct preview")
      let secondPage = snapshot()
      guard let shortSlot = secondPage.firstIndex(of:"清") else { fatalError("missing partial candidate") }
      jump(shortSlot+1)
      check(c.testQuery?.text == "清" && field.committed == "" && snapshot() == secondPage, "preview jumped off the current page")
      wait { c.testTranslation != nil }
      let shortResult = c.testTranslation!
      _ = key("\r",36,.option)
      check(field.committed == shortResult && field.marked == "dj", "preview lost the unconverted syllable")
      field.committed = ""; _ = key("\u{1b}",53)

      for (digit, expected) in [(0,"place"),(1,"place"),(2,"part"),(3,"locality")] {
        compose("difh","地方")
        check(c.testUsesBook && panel.learningLine?.text == "1\u{00a0}place 地点　2\u{00a0}part 部分　3\u{00a0}locality 行政区", "wrong dictionary caption")
        if digit == 0 {
          let caption = panel.contentView!.subviews.compactMap { $0 as? PreviewCaption }.first!.value
          for range in panel.learningLine!.labelRanges {
            let number = caption.attribute(.font, at:range.location, effectiveRange:nil) as? NSFont
            let word = caption.attribute(.font, at:NSMaxRange(range)+1, effectiveRange:nil) as? NSFont
            check(number?.pointSize == 11 && word?.pointSize == 14, "only the choice number should use the small label font")
          }
          check(panel.learningLine!.labelRanges.count == 3, "missing small choice labels")
          screenshot("dictionary-senses")
        }
        let unmodified = digit == 0 ? "\r" : String(digit)
        check(key(unmodified,digit == 0 ? 36 : UInt16(17+digit),.option) && field.committed == expected,
              "wrong sense committed: " + expected)
        field.committed=""
      }
      type("difh"); if let slot = snapshot().firstIndex(of:"地方") { for _ in 0..<slot { _ = key("\u{f703}",124) } }; _ = key("2",19,.option)
      check(field.committed == "", "pending dictionary shortcut leaked")
      wait { c.testUsesBook }
      let secondChinese = snapshot()[1]
      _ = key("2",19); check(field.committed == secondChinese,"ordinary digits must still select Chinese")
      field.committed=""
      compose("difh","地方"); _ = key(" ",49)
      check(field.committed == "地方","Space must still commit Chinese"); field.committed=""
      compose("uzuivozi","收拾桌子")
      check(c.testUsesBook && c.testTranslation == "clear the table","book example pair missed")
      _ = key("\r",36,.option)
      check(field.committed == "clear the table","phrase did not commit"); field.committed=""
      compose("kjkj","看看")
      check(!c.testUsesBook,"unlisted reduplication incorrectly reduced to 看")
      print("看看 (Apple):",c.testTranslation!)
      _ = key("\u{1b}",53)
      compose("woysdockerbuuu","我用docker部署")
      check(!c.testUsesBook,"translated a fragment instead of the whole mixed sentence")
      print("PASS: complete phrase routing, Apple fallback, native panel, default/numbered English and Chinese commits")
      c.testClose(); delegate.config?.close(); api.cleanup_all_sessions(); api.finalize(); fflush(stdout); exit(0)
    }
    check(c.menu().items.map(\.title) == ["翻译预览", "主题"], "native menu contains unrelated features")
    check(c.menu().items[0].state == .on, "default must be on")
    let id = "learning_flypy"
    do {
      c.testSetup(id, learning: true, ascii: false)
      c.toggleLearning(nil)
      check(c.menu().items[0].state == .off, "menu toggle off")
      type("ma"); check(panel.learningLine == nil, "preview remained when disabled"); check(snapshot().first == "吗", "familiar two-key first choice")
      _ = key(" ",49); field.committed = ""
      type("pkgo"); let baseline = snapshot()
      check(!baseline.isEmpty, "original Chinese candidates")
      check(key(" ",49), "ordinary selection"); check(field.committed == baseline[0], "baseline space")
      field.committed = ""
      c.toggleLearning(nil)
      check(c.menu().items[0].state == .on, "menu toggle on")
      type("pkgo"); check(snapshot() == baseline, "candidate order changed")
      check(panel.learningLine == .pending && !(field.marked ?? "").contains("\u{00a0}"), "pending preview leaked into input")
      check(key("\r",36,.option), "pending shortcut leaked")
      check(field.committed == "", "pending shortcut inserted something")
      wait { c.testTranslation != nil }
      let translation = c.testTranslation!
      check(panel.learningLine == LearningLine(text: translation, isTranslation: true), "no idle panel refresh")
      print(id, "zh→en:", baseline[0], "→", translation)
      check(snapshot() == baseline, "translated preview changed candidates")
      check(key("\r",36,.option), "translation shortcut"); check(field.committed == translation, "wrong translated commit")
      field.committed = ""
      type("pkgo"); _ = key(" ",49); check(field.committed == baseline[0], "space inserted a translation")
      field.committed = ""
    }
    // No commit, switch or separator between the double-pinyin and English.
    do {
      c.testSetup(id, learning:true, ascii:false)
      let mixed = "我用docker部署"
      type("woysdockerbuuu")
      check(field.committed == "" && snapshot().first == mixed, "mixed sentence split or committed early")
      wait { c.testTranslation != nil }
      check(panel.learningLine?.isTranslation == true && snapshot().first == mixed, "translation displaced mixed sentence")
      screenshot("mixed-docker")
      _ = key(" ",49)
      check(field.committed == mixed, "one Space did not commit the complete mixed sentence")
      field.committed = ""
      c.toggleLearning(nil)
      for (code, expected) in [("dockerbuuu","docker部署"), ("woysgit","我用git"),
                               ("woyspythonbuuu","我用python部署"), ("wode","我的"),
                               ("hovebulwma","或者不累吗"), ("go","过")] {
        type(code)
        check(snapshot().first == expected && field.committed == "", "wrong first choice: " + code)
        _ = key(" ",49); check(field.committed == expected, "incomplete commit: " + code); field.committed = ""
      }
      type("woysdocke"); type("r")
      check(snapshot().first == "我用docker", "could not finish English at the end")
      _ = key("\u{7f}",51); type("rbuuu")
      check(snapshot().first == mixed && field.committed == "", "could not edit a mixed sentence")
      _ = key("\u{1b}",53)
      check(field.marked == "" && field.committed == "", "mixed Escape did not cancel")
      c.toggleLearning(nil)
      print("Mixed input: woysdockerbuuu →", mixed, "(one Space); editable with preview off")
    }
    c.testSetup("learning_flypy", learning: true, ascii: false)
    do {
      func laterPage(_ term: String, scroll: Bool = false) {
        type("qkdj")
        check(scroll ? c.page(up:false) : key("=",24), "page down")
        let page = snapshot()
        guard let slot = page.firstIndex(of:term) else { fatalError("missing later-page candidate: \(page)") }
        if term == "清" {
          let query = c.testQuery
          let box = body.contentRect(range:body.convert(range:body.candidateRanges[slot])!)
          let p = body.textView.convert(NSPoint(x:box.midX+body.textView.textContainerOrigin.x,
                                               y:box.midY+body.textView.textContainerOrigin.y),to:nil)
          let hover = NSEvent.mouseEvent(with:.mouseMoved,location:p,modifierFlags:[],timestamp:0,
                                         windowNumber:panel.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0)!
          panel.sendEvent(hover)
          check(body.hilightedIndex == slot && c.testQuery == query, "page-two hover changed the keyboard selection")
        }
        for _ in 0..<slot { _ = key("\u{f703}",124) }
        check(body.hilightedIndex == slot && c.testQuery?.text == term, "wrong translation source on page two")
      }
      laterPage("清")
      check(key("\r",36,.option) && field.committed == "", "pending partial preview committed")
      wait { c.testTranslation != nil }
      let clear = c.testTranslation!
      check(panel.learningLine == LearningLine(text:clear,isTranslation:true), "missing single-character caption")
      screenshot("page-two-clear")
      _ = key("\r",36,.option)
      check(field.committed == clear && field.marked == "dj" && !snapshot().isEmpty, "shortcut lost the remaining syllable")
      let next = snapshot()[0]; _ = key(" ",49)
      check(field.committed == clear+next, "remaining syllable could not be selected")
      print("Page two: 清 →", clear, "; Option+Return kept dj →", next)
      field.committed = ""
      laterPage("请", scroll:true)
      _ = key(" ",49)
      check(field.committed == "" && (field.marked ?? "").hasPrefix("请"), "ordinary Chinese selection changed")
      let chineseTail = snapshot()[0]; _ = key(" ",49)
      check(field.committed == "请"+chineseTail, "ordinary Chinese composition did not finish")
      field.committed = ""
    }
    do {
      type("toyhheth")
      let page = snapshot()
      check(page.first == "脱氧核糖" && page.count == 6, "screenshot input did not produce the expected page")
      func boxes() -> [CGRect] {
        body.candidateRanges.map { body.contentRect(range:body.convert(range:$0)!) }
      }
      let before = boxes(), width = panel.frame.width
      let rows = Dictionary(grouping:before, by:\.minY).sorted { $0.key < $1.key }
      let used = rows.map { $0.value.map(\.maxX).max()! }
      print("脱氧核糖 — row counts:", rows.map { $0.value.count }, "widths:", used, "window:", width)
      check(before.allSatisfy { $0.height <= body.currentTheme.font.pointSize+8 }, "split a long candidate across two rows")
      if body.textContainer.size.width >= 575 {
        check(rows.count == 2 && used.min()! / used.max()! > 0.55, "long first row and orphan last row")
      }
      check(width <= 38*body.currentTheme.font.pointSize + 1, "example used the width ceiling instead of hugging its balanced rows")
      wait { c.testTranslation != nil }
      check(before == boxes() && snapshot() == page, "translation rearranged the candidate page")
      screenshot("balanced-rows")
      _ = key("\u{1b}",53)
    }
    type("toyhhethhe")
    check(snapshot().first == "脱氧核糖和", "unexpected candidate for screenshot example")
    wait { c.testTranslation != nil }
    let fragment = c.testTranslation!
    check(fragment.first?.isLowercase == true, "ordinary fragment capitalized: " + fragment)
    screenshot("fragment")
    _ = key("\r",36,.option); check(field.committed == fragment, "inserted text differs from formatted preview")
    print("Fragment: 脱氧核糖和 →", fragment)
    field.committed = ""
    type("ishvdm")
    var frostMatches = snapshot()
    for _ in 0..<6 where !frostMatches.contains("充会电") {
      _ = key("=",24); frostMatches += snapshot()
    }
    check(frostMatches.contains("充会电"), "current upstream Frost entry not available from Xiaohe")
    _ = key("\u{1b}",53)
    type("ni"); wait { c.testTranslation != nil }; screenshot("you")
    _ = key("\u{1b}",53)
    type("zitihfxn"); wait { c.testTranslation != nil }; screenshot("font-size")
    let original = snapshot(), translation = panel.learningLine
    let selectedTitle = (body.textContentStorage.attributedString!.string as NSString).range(of: "字体很小")
    check(selectedTitle.location != NSNotFound, "absent font sample")
    func assertFont(_ range: NSRange, _ size: CGFloat) {
      let font = body.textContentStorage.attributedString!.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
      check(font?.pointSize == size && font?.fontName == body.currentTheme.font.fontName, "unexpected candidate/preview font or size")
    }
    assertFont(selectedTitle, 16)
    let caption = panel.contentView!.subviews.compactMap { $0 as? PreviewCaption }.first!
    check(!caption.isHidden && (caption.value.attribute(.font, at:0,effectiveRange:nil) as? NSFont)?.pointSize == 14, "wrong preview font")
    func openPicker() -> PalettePicker {
      let item = c.menu().items[1]
      c.doCommand(by: item.action, command: [kIMKCommandMenuItemName as String: item])
      wait { delegate.palettePicker?.isVisible == true }
      guard let picker = delegate.palettePicker else { check(false, "menu did not open chooser"); exit(1) }
      check(picker.isVisible && picker.tiles.map(\.title) == ["青瓷","雾蓝","琥珀","石墨"], "theme choices not available")
      check(picker.tiles.filter { $0.state == .on }.map(\.palette) == [CandidatePalette.current], "active tile not indicated")
      return picker
    }
    for palette in CandidatePalette.allCases {
      let picker = openPicker()
      if palette == .jade {
        _ = picker.makeFirstResponder(picker.tiles[0])
        check(picker.tiles.allSatisfy { $0.focusRingType == .none }, "native focus ring covers sample translation")
        screenshot("theme-picker", window: picker)
        picker.appearance = NSAppearance(named: .darkAqua)
        screenshot("theme-picker-dark", window: picker)
        picker.appearance = nil
      }
      picker.tiles.first { $0.palette == palette }!.performClick(nil)
      check(!picker.isVisible && CandidatePalette.current == palette && CandidatePalette.defaults.string(forKey: "CandidatePalette") == palette.rawValue, "palette not saved")
      check(snapshot() == original && panel.learningLine == translation && field.committed == "", "color switch changed active input")
      let expected = SquirrelTheme()
      expected.load(config: delegate.config!, dark: false, palette: palette)
      check(body.currentTheme.highlightedBackColor != nil && body.currentTheme.highlightedBackColor == expected.highlightedBackColor, "wrong day palette")
      screenshot("palette-" + palette.rawValue)
      app.appearance = NSAppearance(named: .darkAqua); panel.appearance = app.appearance; c.testRefreshPanel()
      let night = SquirrelTheme(); night.load(config: delegate.config!, dark: true, palette: palette)
      check(body.currentTheme.highlightedBackColor == night.highlightedBackColor && night.highlightedBackColor != expected.highlightedBackColor, "wrong night palette")
      screenshot("palette-" + palette.rawValue + "-dark")
      app.appearance = NSAppearance(named: .aqua); panel.appearance = app.appearance; c.testRefreshPanel()
    }
    let picker = openPicker(); picker.tiles[0].performClick(nil)
    print("font sample:", snapshot(), panel.learningLine?.text ?? "-")
    app.appearance = NSAppearance(named: .darkAqua); panel.appearance = app.appearance
    // Refresh the current composition without selecting another candidate.
    c.testRefreshPanel()
    screenshot("font-size-dark")
    app.appearance = NSAppearance(named: .aqua); panel.appearance = app.appearance
    _ = key("\u{1b}",53)
    type("womauhjqdc"); wait { c.testTranslation != nil }
    print("sentence:", snapshot(), panel.learningLine?.text ?? "-"); screenshot("zh-en")
    _ = key("\u{1b}",53)
    c.testSetup("learning_flypy", learning: true, ascii: true)
    type("See you tomorrow."); wait { c.testTranslation != nil }
    check(field.marked == "See you tomorrow.", "English spaces or punctuation lost")
    let reverse = c.testTranslation!
    check(reverse.unicodeScalars.contains(where: { $0.properties.isIdeographic }), "English did not translate to Chinese")
    print("en→zh:", field.marked ?? "", "→", reverse); screenshot("en-zh")
    app.appearance = NSAppearance(named: .darkAqua); panel.appearance = app.appearance
    c.testRefreshPanel(); screenshot("en-zh-dark")
    app.appearance = NSAppearance(named: .aqua); panel.appearance = app.appearance
    _ = key("\r",36,.option); check(field.committed == reverse, "reverse commit failed")
    field.committed = ""; type("hello world"); _ = key("\r",36)
    check(field.committed == "hello world", "ordinary Return changed original English")
    field.committed = ""; type("cancel this"); _ = key("\u{1b}",53)
    check(field.committed == "" && field.marked == "", "Escape did not discard draft")
    c.testSetup("learning_flypy", learning: false, ascii: true)
    check(!key("a"), "normal English passthrough affected")
    let screen = NSScreen.main!.visibleFrame
    // Measure the source in screen coordinates, including its offset when the
    // preview is above the row. A window-height assertion alone misses jumps.
    func baseline() -> CGFloat {
      body.textLayoutManager.ensureLayout(for: body.textLayoutManager.documentRange)
      let frag = body.textLayoutManager.textLayoutFragment(for: body.textLayoutManager.documentRange.location)!
      let line = frag.textLineFragments[0]
      let y = body.textView.textContainerOrigin.y + frag.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
      return panel.convertPoint(toScreen:body.textView.convert(NSPoint(x:0,y:y),to:nil)).y
    }
    func primaryFrame() -> CGRect { panel.convertToScreen(body.convert(body.bounds,to:nil)) }
    c.testSetup(id,learning:true,ascii:false)
    let host = NSWindow(contentRect:CGRect(x:screen.midX-280,y:screen.midY,width:620,height:90),styleMask:.borderless,backing:.buffered,defer:false)
    let editor = NSTextView(frame:host.contentView!.bounds)
    editor.isRichText=false; editor.font = .systemFont(ofSize:17); editor.string = "我知道"
    editor.setSelectedRange(NSRange(location:3,length:0))
    host.contentView!.addSubview(editor); host.alphaValue=0; host.orderFrontRegardless()
    field.editor=editor
    var inlineTop:CGFloat?, floorY:CGFloat?
    for (index, ch) in "ufmeuihzhvdz".enumerated() {
      type(String(ch))
      check(editor.hasMarkedText() && editor.string.hasPrefix("我知道"), "native editor lost composition")
      let firstMarked = NSRange(location:editor.markedRange().location,length:1)
      func inputY() -> CGFloat { editor.firstRect(forCharacterRange:firstMarked,actualRange:nil).minY }
      if inlineTop == nil { inlineTop=inputY() }
      if floorY == nil {floorY=baseline()}
      let frame = primaryFrame()
      let end=Date(timeIntervalSinceNow: 0.087) // normal continuous typing, no gap between syllables
      while Date() < end {
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.008))
        check(caption.isHidden && panel.frame.height==31 && frame==primaryFrame() && abs(baseline()-floorY!)<0.5 && abs(inputY()-inlineTop!)<0.5,
              "lift on key \(index): row \(primaryFrame()) expected \(frame); baseline \(baseline()) expected \(floorY!); editor \(inputY()) expected \(inlineTop!); height \(panel.frame.height), caption hidden \(caption.isHidden)")
      }
    }
    print("Native marked text:",editor.string,"input row y:",inlineTop!, "candidate baseline:",floorY!)
    let beforeReply = primaryFrame(), beforeText = body.textContentStorage.attributedString!.string
    wait { c.testTranslation != nil }
    print("steady across reply", beforeReply, primaryFrame(), "source same",beforeText == body.textContentStorage.attributedString?.string,"caption hidden",caption.isHidden,"height",panel.frame.height)
    check(!caption.isHidden && beforeReply == primaryFrame() && beforeText == body.textContentStorage.attributedString?.string, "preview reflowed the source row")
    _ = key("\u{1b}",53)
    // Use the real English controller and an NSTextView. The host must retain
    // every space; identical readings must not move the panel or blink its caption.
    c.testSetup(id,learning:true,ascii:true)
    do {
      editor.string = ""; editor.setSelectedRange(NSRange(location:0,length:0))
      func firstX() -> CGFloat {
        panel.convertPoint(toScreen:body.convert(NSPoint(x:body.sourceLeadingInkX,y:0),to:nil)).x
      }
      func hostLine() -> CGRect {
        editor.firstRect(forCharacterRange:NSRange(location:editor.markedRange().location,length:1),actualRange:nil)
      }
      for word in ["qeqwe","qweqwe"] {
        type(word); wait { c.testTranslation != nil }
        let reply = c.testTranslation!, window = panel.frame, source = primaryFrame()
        let x = firstX(), y = baseline(), line = hostLine()
        for n in 1...12 {
          type(" ")
          check(field.marked == word+String(repeating:" ",count:n) && editor.hasMarkedText(), "editor lost an English space")
          let sourceText = body.textContentStorage.attributedString?.string
          check(sourceText == word && c.testQuery?.text == word &&
                c.testTranslation == reply && !caption.isHidden,
                "space \(n) in \(word): source=\(String(reflecting:sourceText)) query=\(String(reflecting:c.testQuery?.text)) reply=\(String(reflecting:c.testTranslation)) expected \(reply), hidden=\(caption.isHidden)")
          check(window == panel.frame && source == primaryFrame() && firstX() == x && baseline() == y && hostLine() == line,
                "space moved source, caption window, or editor")
        }
        if word == "qeqwe" {
          _ = key("\r",36,.option)
          check(field.committed == reply, "trailing space invalidated ready translation shortcut")
        } else {
          type("q")
          check(c.testTranslation == nil && caption.isHidden && c.testQuery?.text == "qweqwe q", "new word retained stale translation")
          _ = key("\r",36,.option); check(field.committed.isEmpty, "stale translation inserted")
          type("we"); wait { c.testTranslation != nil }
          let reading = word+" qwe", translated = c.testTranslation!
          check(body.textContentStorage.attributedString?.string == reading && c.testQuery?.text == reading, "excess spaces in preview")
          check(firstX() == x && baseline() == y && hostLine() == line, "first glyph jumped after an internal space")
          screenshot("english-spaces")
          for _ in 0..<3 { _ = key("\u{f702}",123) }
          _ = key("\u{7f}",51) // Remove one of twelve spaces inside the actual draft.
          let raw = word+String(repeating:" ",count:11)+"qwe"
          check(field.marked == raw && c.testTranslation == translated && body.textContentStorage.attributedString?.string == reading, "editing a space changed the reading")
          _ = key("\r",36); check(field.committed == raw, "Return collapsed intentional spaces")
        }
        field.committed = ""; editor.string = ""; editor.setSelectedRange(NSRange(location:0,length:0))
        print("English spacing:", word, "12 spaces: fixed window", window.size, "first glyph", x,y)
      }
    }
    field.editor=nil; host.orderOut(nil)
    for english in [true,false] {
      for (x,y) in [(screen.midX,screen.midY),(screen.midX,screen.minY+48),(screen.maxX-15,screen.midY)] {
        panel.hide()
        let words = english ? [] : ["我","往","王"]
        var compact:CGRect?, y0:CGFloat?
        for (i,text) in ["","A much longer single-line translation here.","","好","","You"].enumerated() {
          panel.position=CGRect(x:x+CGFloat(i % 2),y:y+CGFloat(i % 2)*5,width:1,height:18)
          panel.learningLine = text.isEmpty ? .pending : LearningLine(text:text,isTranslation:true)
          panel.update(preedit:english ? "www" : "",selRange:.empty,caretPos:0,candidates:words,comments:words.map{_ in ""},labels:[],highlighted:0,page:0,lastPage:true,update:true)
          if compact == nil {compact=primaryFrame();y0=baseline()}
          check(primaryFrame()==compact && abs(baseline()-y0!)<0.5 && screen.contains(panel.frame), "source moved during result at edge")
          if text.isEmpty { check(caption.isHidden && panel.frame==compact, "pending preview reserves space") }
          else { check(!caption.isHidden && panel.frame.height>compact!.height, "missing preview") }
        }
        panel.position.origin.y += 27; panel.redrawVisibleComposition()
        check(abs(baseline()-y0!)>10, "ignored actual line change")
      }
    }
    panel.hide()
    CandidatePalette.current = .mist
    delegate.loadSettings(for: id)
    panel.position = CGRect(x: screen.midX, y: screen.midY, width: 1, height: 18)
    panel.learningLine = .pending
    panel.update(preedit: "", selRange: .empty, caretPos: 0,
                 candidates: ["剧烈了","剧烈","据","句","局","剧"], comments: Array(repeating:"",count:6),
                 labels: [], highlighted: 0, page: 0, lastPage: true, update: true)
    screenshot("intense-typing")
    panel.refreshLearningLine(LearningLine(text:"It's intense", isTranslation:true))
    screenshot("intense")
    print("mist sample:", panel.frame.size, "insets:", body.currentTheme.edgeInset)
    panel.hide()
    panel.learningLine = .pending
    panel.update(preedit:"",selRange:.empty,caretPos:0,candidates:["清单","清淡","氢弹","轻淡","氢氮","清胆"],
                 comments:Array(repeating:"",count:6),labels:[],highlighted:4,page:0,lastPage:true,update:true)
    let beforeCaption = primaryFrame()
    panel.refreshLearningLine(LearningLine(text:"hydrogen nitrogen",isTranslation:true))
    check(primaryFrame() == beforeCaption && caption.frame.minY == 2, "lower caption lift moved the row or lost its bottom inset")
    screenshot("hydrogen-nitrogen")
    panel.hide()
    // Long translations may use the entire row, with no shortcut view or trailing column.
    let long = Array(repeating: "Some sentences need more than one line.", count: 6).joined(separator: " ")
    panel.learningLine = LearningLine(text: long, isTranslation: true)
    panel.update(preedit: "", selRange: .empty, caretPos: 0, candidates: ["测试"], comments: [""],
                 labels: [], highlighted: 0, page: 0, lastPage: true, update: true)
    screenshot("wrapped")
    let needed = caption.measure(maxWidth:caption.frame.width).height
    let oneLine = caption.measure(maxWidth: .greatestFiniteMagnitude).height
    check(!caption.isHidden && needed > oneLine && caption.frame.height >= needed && panel.contentView!.bounds.contains(caption.frame) &&
          caption.value.string==long, "long translation clipped")
    panel.hide()
    let oversized = String(repeating:"超长词", count:24)
    panel.update(preedit:"",selRange:.empty,caretPos:0,candidates:["前",oversized,"后"],comments:["","",""],
                 labels:[],highlighted:1,page:0,lastPage:true,update:true)
    let boxes = body.candidateRanges.map { body.contentRect(range:body.convert(range:$0)!) }
    check(boxes.count==3 && boxes[0].maxY <= boxes[1].minY && boxes[1].maxY <= boxes[2].minY &&
          boxes[1].height > 30 && panel.frame.width <= 48*body.currentTheme.font.pointSize+1,
          "a single oversized candidate did not wrap within its own row")
    panel.hide(); panel.learningLine = .pending
    panel.update(preedit:"",selRange:.empty,caretPos:0,candidates:["去","钱","前","起","期","其"],comments:Array(repeating:"",count:6),labels:[],highlighted:0,page:0,lastPage:true,update:true)
    screenshot("compact")
    panel.refreshLearningLine(LearningLine(text:"go",isTranslation:true))
    screenshot("compact-ready")
    // Drive the real panel without moving the system cursor. Keep the targets
    // in screen coordinates: recomputing them after a jump would hide the bug.
    for (x, code) in [(screen.midX,"ni"),(screen.maxX-1,"ni"),(screen.maxX-1,"toyhheth")] {
      panel.hide()
      field.caretRect = CGRect(x:x, y:screen.midY, width:1, height:18)
      c.testSetup(id, learning:true, ascii:false)
      type(code)
      let words = snapshot(), row = primaryFrame(), y = baseline()
      check(words.count == 6, "expected a full page for " + code)
      if code == "ni" { check(row.height == 31, "short page should stay on one line") }
      let points = body.candidateRanges.map { range -> NSPoint in
        let box = body.contentRect(range:body.convert(range:range)!)
        let p = NSPoint(x:box.midX + body.textView.textContainerOrigin.x,
                        y:box.midY + body.textView.textContainerOrigin.y)
        return panel.convertPoint(toScreen:body.textView.convert(p,to:nil))
      }
      func mouse(_ slot: Int, _ kind: NSEvent.EventType = .mouseMoved) {
        let event = NSEvent.mouseEvent(with:kind, location:panel.convertPoint(fromScreen:points[slot]),
                                       modifierFlags:[], timestamp:0, windowNumber:panel.windowNumber,
                                       context:nil, eventNumber:0, clickCount:kind == .mouseMoved ? 0 : 1, pressure:0)!
        panel.sendEvent(event)
      }
      func still(_ slot: Int) {
        check(body.hilightedIndex == slot && snapshot() == words, "navigation did not reach candidate \(slot+1) on the same page")
        check(primaryFrame() == row && baseline() == y, "candidate row moved at slot \(slot+1): \(row) → \(primaryFrame())")
      }
      wait { c.testTranslation != nil }
      let translatedWindow = panel.frame, reply = panel.learningLine
      for slot in [1,2,3,4,5,4,5,0] {
        mouse(slot); still(slot)
        check(panel.frame == translatedWindow && panel.learningLine == reply, "hover changed translation or window frame")
      }
      for slot in [1,2,3,4,5,4,5] {
        let forward = slot > body.hilightedIndex
        check(key(forward ? "\u{f703}" : "\u{f702}", forward ? 124 : 123), "unhandled candidate arrow")
        still(slot)
      }
      wait { c.testTranslation != nil }; still(5)
      if x == screen.maxX - 1 { screenshot(code == "ni" ? "last-candidate" : "last-candidate-wrapped") }
      print("Fifth ↔ sixth, mouse and arrow keys: fixed source frame", row)
      // The same event coordinates also select the intended word on click.
      mouse(5, .leftMouseDown); mouse(5, .leftMouseUp)
      check(field.committed == words[5], "click selected the wrong candidate")
      field.committed = ""
    }
    c.testClose()
    delegate.config?.close()
    api.cleanup_all_sessions()
    api.finalize()
    print("PASS: controller, actual Rime, bilingual model, idle redraw, selection and English editing")
    fflush(stdout); exit(0)
  }
}
