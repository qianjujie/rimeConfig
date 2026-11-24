//
//  SquirrelPanel.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import AppKit
import CoreText

final class SquirrelPanel: NSPanel {
  private let view: SquirrelView
  private let back: NSVisualEffectView
  private let preview = PreviewCaption()
  weak var inputController: SquirrelInputController?
  var learningLine: LearningLine?

  // Repaint existing rows only; never ask Rime to recompute or select a candidate.
  func refreshLearningLine(_ text: LearningLine?) {
    guard learningLine != text, isVisible else { return }
    learningLine = text
    show() // The source string, glyph layout and editor are untouched.
  }

  func redrawVisibleComposition() {
    guard isVisible, !preedit.isEmpty || !candidates.isEmpty else { return }
    update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
  }


  var position: NSRect
  private var screenRect: NSRect = .zero
  private var maxHeight: CGFloat = 0
  private var previousLine: (caret: NSRect, screen: NSRect, above: Bool, left: CGFloat)?


  private var statusMessage: String = ""
  private var statusTimer: Timer?

  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var candidates: [String] = .init()
  var candidateCount: Int { candidates.count }
  private var comments: [String] = .init()
  private var labels: [String] = .init()
  private var index: Int = 0
  private var cursorIndex: Int = 0
  private var scrollDirection: CGVector = .zero
  private var scrollTime: Date = .distantPast
  private var page: Int = 0
  private var lastPage: Bool = true
  private var pagingUp: Bool?

  init(position: NSRect) {
    self.position = position
    self.view = SquirrelView(frame: position)
    self.back = NSVisualEffectView()
    super.init(contentRect: position, styleMask: .nonactivatingPanel, backing: .buffered, defer: true)
    self.level = .init(Int(CGShieldingWindowLevel()))
    self.hidesOnDeactivate = false
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    self.hasShadow = true
    self.isOpaque = false
    self.backgroundColor = .clear
    back.blendingMode = .behindWindow
    back.material = .hudWindow
    back.state = .active
    back.wantsLayer = true
    back.layer?.mask = view.shape
    let contentView = NSView()
    contentView.wantsLayer = true
    contentView.addSubview(back)
    contentView.addSubview(view)
    contentView.addSubview(view.textView)
    preview.isHidden = true
    contentView.addSubview(preview)
    self.contentView = contentView
  }

  var linear: Bool {
    view.currentTheme.linear
  }
  var vertical: Bool {
    view.currentTheme.vertical
  }
  var inlinePreedit: Bool {
    view.currentTheme.inlinePreedit
  }
  var inlineCandidate: Bool {
    view.currentTheme.inlineCandidate
  }

  // swiftlint:disable:next cyclomatic_complexity
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      let (index, _, pagingUp) = view.click(at: view.convert(event.locationInWindow, from: nil))
      if let pagingUp {
        self.pagingUp = pagingUp
      } else {
        self.pagingUp = nil
      }
      if let index, index >= 0 && index < candidates.count {
        self.index = index
      }
    case .leftMouseUp:
      let (index, preeditIndex, pagingUp) = view.click(at: view.convert(event.locationInWindow, from: nil))

      if let pagingUp, pagingUp == self.pagingUp {
        _ = inputController?.page(up: pagingUp)
      } else {
        self.pagingUp = nil
      }
      if let preeditIndex, preeditIndex >= 0 && preeditIndex < preedit.utf16.count {
        if preeditIndex < caretPos {
          _ = inputController?.moveCaret(forward: true)
        } else if preeditIndex > caretPos {
          _ = inputController?.moveCaret(forward: false)
        }
      }
      if let index, index == self.index && index >= 0 && index < candidates.count {
        _ = inputController?.selectCandidate(index)
      }
    case .mouseEntered:
      acceptsMouseMovedEvents = true
    case .mouseExited:
      acceptsMouseMovedEvents = false
      if cursorIndex != index {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
      pagingUp = nil
    case .mouseMoved:
      let (index, _, _) = view.click(at: view.convert(event.locationInWindow, from: nil))
      if let index = index, cursorIndex != index && index >= 0 && index < candidates.count {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
    case .scrollWheel:
      if event.phase == .began {
        scrollDirection = .zero
        // Scrollboard span
      } else if event.phase == .ended || (event.phase == .init(rawValue: 0) && event.momentumPhase != .init(rawValue: 0)) {
        if abs(scrollDirection.dx) > abs(scrollDirection.dy) && abs(scrollDirection.dx) > 10 {
          _ = inputController?.page(up: (scrollDirection.dx < 0) == vertical)
        } else if abs(scrollDirection.dx) < abs(scrollDirection.dy) && abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
        }
        scrollDirection = .zero
        // Mouse scroll wheel
      } else if event.phase == .init(rawValue: 0) && event.momentumPhase == .init(rawValue: 0) {
        if scrollTime.timeIntervalSinceNow < -1 {
          scrollDirection = .zero
        }
        scrollTime = .now
        if (scrollDirection.dy >= 0 && event.scrollingDeltaY > 0) || (scrollDirection.dy <= 0 && event.scrollingDeltaY < 0) {
          scrollDirection.dy += event.scrollingDeltaY
        } else {
          scrollDirection = .zero
        }
        if abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
          scrollDirection = .zero
        }
      } else {
        scrollDirection.dx += event.scrollingDeltaX
        scrollDirection.dy += event.scrollingDeltaY
      }
    default:
      break
    }
    super.sendEvent(event)
  }

  func hide() {
    learningLine = nil
    inputController = nil
    statusTimer?.invalidate()
    statusTimer = nil
    orderOut(nil)
    previousLine = nil
    maxHeight = 0
  }

  // Main function to add attributes to text output from librime
  // swiftlint:disable:next cyclomatic_complexity function_parameter_count
  func update(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted index: Int, page: Int, lastPage: Bool, update: Bool) {
    if update {
      self.preedit = preedit
      self.selRange = selRange
      self.caretPos = caretPos
      self.candidates = candidates
      self.comments = comments
      self.labels = labels
      self.index = index
      self.page = page
      self.lastPage = lastPage
    }
    cursorIndex = index

    if !candidates.isEmpty || !preedit.isEmpty {
      statusMessage = ""
      statusTimer?.invalidate()
      statusTimer = nil
    } else {
      if !statusMessage.isEmpty {
        show(status: statusMessage)
        statusMessage = ""
      } else if statusTimer == nil {
        hide()
      }
      return
    }

    let theme = view.currentTheme
    currentScreen()

    let text = NSMutableAttributedString()
    let preeditRange: NSRange
    let highlightedPreeditRange: NSRange

    // preedit
    if !preedit.isEmpty {
      preeditRange = NSRange(location: 0, length: preedit.utf16.count)
      highlightedPreeditRange = selRange

      let line = NSMutableAttributedString(string: preedit)
      let sourceOnly = candidates.isEmpty && learningLine != nil
      line.addAttributes(sourceOnly ? theme.highlightedAttrs : theme.preeditAttrs, range: preeditRange)
      line.addAttributes(theme.preeditHighlightedAttrs, range: selRange)
      text.append(line)

      let style = theme.preeditParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
      if sourceOnly {
        style.firstLineHeadIndent = 7
        style.headIndent = 7
        style.paragraphSpacing = 0
      }
      text.addAttribute(.paragraphStyle, value: style, range: preeditRange)
      if !candidates.isEmpty {
        text.append(NSAttributedString(string: "\n", attributes: theme.preeditAttrs))
      }
    } else {
      preeditRange = .empty
      highlightedPreeditRange = .empty
    }

    // candidates
    var items = [NSMutableAttributedString]()
    let horizontal = theme.linear && !theme.vertical
    let rowIndent: CGFloat = preedit.isEmpty ? 4.5 : 0
    for i in 0..<candidates.count {
      let attrs = i == index ? theme.highlightedAttrs : theme.attrs
      let labelAttrs = i == index ? theme.labelHighlightedAttrs : theme.labelAttrs
      let commentAttrs = i == index ? theme.commentHighlightedAttrs : theme.commentAttrs

      let label = if theme.candidateFormat.contains(/\[label\]/) {
        if labels.count > 1 && i < labels.count {
          labels[i]
        } else if labels.count == 1 && i < labels.first!.count {
          // custom: A. B. C...
          String(labels.first![labels.first!.index(labels.first!.startIndex, offsetBy: i)])
        } else {
          // default: 1. 2. 3...
          "\(i+1)"
        }
      } else {
        ""
      }

      let candidate = candidates[i].precomposedStringWithCanonicalMapping
      let comment = comments[i].precomposedStringWithCanonicalMapping

      let line = NSMutableAttributedString(string: theme.candidateFormat, attributes: labelAttrs)
      for range in line.string.ranges(of: /\[candidate\]/) {
        let convertedRange = convert(range: range, in: line.string)
        line.addAttributes(attrs, range: convertedRange)
        if candidate.count <= 5 {
          line.addAttribute(.noBreak, value: true, range: NSRange(location: convertedRange.location+1, length: convertedRange.length-1))
        }
      }
      for range in line.string.ranges(of: /\[comment\]/) {
        line.addAttributes(commentAttrs, range: convert(range: range, in: line.string))
      }
      line.mutableString.replaceOccurrences(of: "[label]", with: label, range: NSRange(location: 0, length: line.length))
      let labeledLine = line.copy() as! NSAttributedString
      line.mutableString.replaceOccurrences(of: "[candidate]", with: candidate, range: NSRange(location: 0, length: line.length))
      line.mutableString.replaceOccurrences(of: "[comment]", with: comment, range: NSRange(location: 0, length: line.length))

      if line.length <= 10 {
        line.addAttribute(.noBreak, value: true, range: NSRange(location: 1, length: line.length-1))
      }

      let paragraphStyleCandidate = (i == 0 ? theme.firstParagraphStyle : theme.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
      if linear {
        if i == 0 && preedit.isEmpty {
          paragraphStyleCandidate.paragraphSpacingBefore = 0
        }
        if preedit.isEmpty && (horizontal || i == 0) { paragraphStyleCandidate.firstLineHeadIndent = rowIndent }
        if horizontal { paragraphStyleCandidate.headIndent = SquirrelView.chipPadding }
        paragraphStyleCandidate.paragraphSpacingBefore -= theme.linespace
        paragraphStyleCandidate.lineSpacing = theme.linespace
      }
      if !linear, let labelEnd = labeledLine.string.firstMatch(of: /\[(candidate|comment)\]/)?.range.lowerBound {
        let labelString = labeledLine.attributedSubstring(from: NSRange(location: 0, length: labelEnd.utf16Offset(in: labeledLine.string)))
        let labelWidth = labelString.boundingRect(with: .zero, options: [.usesLineFragmentOrigin]).width
        paragraphStyleCandidate.headIndent = labelWidth
      }
      line.addAttribute(.paragraphStyle, value: paragraphStyleCandidate, range: NSRange(location: 0, length: line.length))

      // A template may end with a space for a comment which isn't present.
      if i == candidates.count - 1, comment.isEmpty {
        let last = (line.string as NSString).rangeOfCharacter(from: .whitespaces.inverted, options: .backwards)
        if last.location != NSNotFound, NSMaxRange(last) < line.length {
          line.deleteCharacters(in: NSRange(location: NSMaxRange(last), length: line.length - NSMaxRange(last)))
        }
      }
      items.append(line)
    }
    let separator = NSMutableAttributedString(string:linear ? "  " : "\n", attributes:theme.attrs)
    if vertical { separator.addAttribute(.verticalGlyphForm, value:1, range:NSRange(location:0,length:separator.length)) }
    view.separatorWidth = separator.boundingRect(with:.zero).width
    let breaks: IndexSet
    if horizontal && items.count > 1 {
      let widths = items.map { CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString($0), nil, nil, nil)) }
      breaks = CandidateRows.breaks(widths:widths, gap:view.separatorWidth,
                                    limit:candidateTextWidth()-rowIndent)
    } else { breaks = [] }
    var candidateRanges = [NSRange](), rowEnds = [NSRange]()
    for (i, line) in items.enumerated() {
      if i > 0 {
        if breaks.contains(i) {
          text.append(NSAttributedString(string:"\n", attributes:theme.attrs))
        } else { text.append(separator) }
      }
      let range = NSRange(location:text.length, length:line.length)
      candidateRanges.append(range)
      if breaks.contains(i+1) || i == items.count-1 { rowEnds.append(range) }
      text.append(line)
    }

    view.highlightsEnglishDraft = candidates.isEmpty && !preedit.isEmpty && learningLine != nil
    // text done!
    view.textView.textContentStorage?.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: candidateRanges, rowEnds: rowEnds, hilightedIndex: index, preeditRange: preeditRange, highlightedPreeditRange: highlightedPreeditRange, canPageUp: page > 0, canPageDown: !lastPage)
    show()
  }

  func updateStatus(long longMessage: String, short shortMessage: String) {
    let theme = view.currentTheme
    switch theme.statusMessageType {
    case .mix:
      statusMessage = shortMessage.isEmpty ? longMessage : shortMessage
    case .long:
      statusMessage = longMessage
    case .short:
      if !shortMessage.isEmpty {
        statusMessage = shortMessage
      } else if let initial = longMessage.first {
        statusMessage = String(initial)
      } else {
        statusMessage = ""
      }
    }
  }

  func load(config: SquirrelConfig, forDarkMode isDark: Bool) {
    if isDark {
      view.darkTheme = SquirrelTheme()
      view.darkTheme.load(config: config, dark: true)
    } else {
      view.lightTheme = SquirrelTheme()
      view.lightTheme.load(config: config, dark: isDark)
    }
  }
}

private extension SquirrelPanel {
  func currentScreen() {
    if let screen = NSScreen.main {
      screenRect = screen.visibleFrame
    }
    for screen in NSScreen.screens where screen.frame.contains(position.origin) {
      screenRect = screen.visibleFrame
      break
    }
  }

  func maxTextWidth() -> CGFloat {
    let theme = view.currentTheme
    let font: NSFont = theme.font
    let fontScale = font.pointSize / 12
    let textWidthRatio = min(1, 1 / (vertical ? 4 : 3) + fontScale / 12)
    let maxWidth = if vertical {
      screenRect.height * textWidthRatio - theme.edgeInset.height * 2
    } else {
      screenRect.width * textWidthRatio - theme.edgeInset.width * 2
    }
    return maxWidth
  }

  // Beyond 48 full-width characters a horizontal menu is hard to scan even
  // on a large monitor. Small screens keep their existing, tighter limit.
  func candidateTextWidth() -> CGFloat {
    let theme = view.currentTheme
    return min(maxTextWidth(), 48 * theme.font.pointSize - 2 * theme.edgeInset.width) - SquirrelView.chipPadding
  }

  // Get the window size, the windows will be the dirtyRect in
  // SquirrelView.drawRect
  // swiftlint:disable:next cyclomatic_complexity
  func show() {
    currentScreen()
    let theme = view.currentTheme
    if theme.native || view.darkTheme.available {
      self.appearance = NSApp.effectiveAppearance
    } else {
      // user configured only a light theme, set window appearance to light.
      self.appearance = NSAppearance(named: .aqua)
    }

    // Break line if the text is too long, based on screen size.
    let textWidth = maxTextWidth()
    let maxTextHeight = vertical ? screenRect.width - theme.edgeInset.width * 2 : screenRect.height - theme.edgeInset.height * 2
    let sourceWidth = linear && !vertical && !view.candidateRanges.isEmpty ? candidateTextWidth() : textWidth
    view.textContainer.size = NSSize(width: sourceWidth, height: maxTextHeight)

    var panelRect = NSRect.zero
    var captionOnScreen: NSRect?
    // in vertical mode, the width and height are interchanged
    var contentRect = view.contentRect
    if theme.memorizeSize && (vertical && position.midY / screenRect.height < 0.5) ||
        (vertical && position.minX + max(contentRect.width, maxHeight) + theme.edgeInset.width * 2 > screenRect.maxX) {
      if contentRect.width >= maxHeight {
        maxHeight = contentRect.width
      } else {
        contentRect.size.width = maxHeight
        view.textContainer.size = NSSize(width: maxHeight, height: maxTextHeight)
      }
    }

    if vertical {
      panelRect.size = NSSize(width: min(0.95 * screenRect.width, contentRect.height + theme.edgeInset.height * 2),
                              height: min(0.95 * screenRect.height, contentRect.width + theme.edgeInset.width * 2) + theme.pagingOffset)

      // To avoid jumping up and down while typing, use the lower screen when
      // typing on upper, and vice versa
      if position.midY / screenRect.height >= 0.5 {
        panelRect.origin.y = position.minY - SquirrelTheme.offsetHeight - panelRect.height + theme.pagingOffset
      } else {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
      // Make the first candidate fixed at the left of cursor
      panelRect.origin.x = position.minX - panelRect.width - SquirrelTheme.offsetHeight
      if view.preeditRange.length > 0, let preeditTextRange = view.convert(range: view.preeditRange) {
        let preeditRect = view.contentRect(range: preeditTextRange)
        panelRect.origin.x += preeditRect.height + theme.edgeInset.width
      }
    } else {
      let visibleHeight = max(theme.font.pointSize + 8, contentRect.maxY)
      panelRect.size = NSSize(width: min(0.95 * screenRect.width, ceil(view.visibleRightEdge(contentRect: contentRect) + theme.edgeInset.width * 2)),
                              height: min(0.95 * screenRect.height, ceil(visibleHeight + theme.edgeInset.height * 2)))
      panelRect.size.width += theme.pagingOffset
      // Editors can return a slightly different caret rect for Latin and Chinese glyphs
      // on the same line. Follow real line changes, not subpixel font differences.
      let old = previousLine
      let sample = (position.height <= 0 ? old?.caret : nil) ?? position
      let sameLine = old.map { $0.screen == screenRect &&
        abs($0.caret.midY - sample.midY) <= max(2, min($0.caret.height, sample.height) / 2) } ?? false
      let caret = sameLine ? old!.caret : sample
      let below = caret.minY - SquirrelTheme.offsetHeight
      // Pick a side from the source row, before a translation exists. A result
      // returning at the bottom of the screen must never move the source row.
      let room = panelRect.height + (learningLine == nil ? 0 : theme.previewFont.pointSize * 1.8)
      let above = sameLine ? old!.above : below - room < screenRect.minY
      // At the right edge, grow left only as far as necessary. A shorter result
      // must not pull the source line back to the right on the very next update.
      let preferredLeft = sameLine ? old!.left : caret.minX - theme.pagingOffset
      let left = max(screenRect.minX, min(preferredLeft, screenRect.maxX - panelRect.width))
      previousLine = (caret, screenRect, above, left)
      panelRect.origin = NSPoint(x: left,
                                 y: above ? caret.maxY + SquirrelTheme.offsetHeight : below - panelRect.height)
    }
    if panelRect.maxX > screenRect.maxX {
      panelRect.origin.x = screenRect.maxX - panelRect.width
    }
    if panelRect.minX < screenRect.minX {
      panelRect.origin.x = screenRect.minX
    }
    if panelRect.minY < screenRect.minY {
      if vertical {
        panelRect.origin.y = screenRect.minY
      } else {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
    }
    if panelRect.maxY > screenRect.maxY {
      panelRect.origin.y = screenRect.maxY - panelRect.height
    }
    if panelRect.minY < screenRect.minY {
      panelRect.origin.y = screenRect.minY
    }
    // Compute the candidate rectangle first. The caption may enlarge the outside
    // window, never the candidate layout, and grows away from the insertion line.
    let sourceOnScreen = panelRect
    func sizeSourceText(_ size: CGSize) {
      view.textView.setFrameSize(NSSize(width:size.width-theme.pagingOffset, height:size.height))
      var inset = theme.edgeInset
      if !vertical && !candidates.isEmpty { inset.height = ceil(inset.height) }
      view.textView.textContainerInset = inset
    }
    if !vertical, let line = learningLine, !line.text.isEmpty {
      // Resolve the actual drawing origin before aligning the caption.
      sizeSourceText(sourceOnScreen.size)
      let inset = theme.edgeInset.width
      preview.setLine(line, theme: theme)
      let leading = view.sourceLeadingInkX - preview.value.leadingInkOffset
      let left = panelRect.minX
      // Wrap within the space right of the source anchor. Sliding a long
      // caption left would break alignment near the edge of the screen.
      let available = max(1, min(textWidth, screenRect.maxX-left-leading-inset))
      let textSize = preview.measure(maxWidth:available)
      let width = min(screenRect.maxX-left, max(panelRect.width, ceil(leading+textSize.width+inset)))
      // The font already includes space above and below its ink. Share the
      // source row's bottom inset instead of stacking a second empty margin.
      let overlap = min(2, theme.edgeInset.height)
      let height = ceil(textSize.height - overlap)
      var goesUp = previousLine?.above ?? false
      let lowerRoom = panelRect.minY - screenRect.minY
      let upperRoom = screenRect.maxY - panelRect.maxY
      if goesUp && upperRoom < height && lowerRoom > upperRoom { goesUp = false }
      if !goesUp && lowerRoom < height && upperRoom > lowerRoom { goesUp = true }
      let usedHeight = min(height, max(0, goesUp ? upperRoom : lowerRoom))
      let strip = CGRect(x:left,y:goesUp ? panelRect.maxY : panelRect.minY-usedHeight,width:width,height:usedHeight)
      // Give descenders two extra points of breathing room at the bottom
      // without growing the window or moving the candidate rows.
      let captionY = goesUp ? strip.minY-overlap : strip.minY+2
      captionOnScreen = CGRect(x:left+leading,y:captionY,
                               width:width-leading-inset,height:usedHeight+overlap)
      panelRect = panelRect.union(strip)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    if frame != panelRect { setFrame(panelRect, display: false, animate: false) }

    // rotate the view, the core in vertical mode!
    if vertical {
      contentView!.boundsRotation = -90
      contentView!.setBoundsOrigin(NSPoint(x: 0, y: panelRect.width))
    } else {
      contentView!.boundsRotation = 0
      contentView!.setBoundsOrigin(.zero)
    }
    view.textView.boundsRotation = 0

    let sourceFrame = sourceOnScreen.offsetBy(dx: -panelRect.minX, dy: -panelRect.minY)
    view.frame = vertical ? contentView!.bounds : sourceFrame
    sizeSourceText(view.frame.size)
    view.textView.setFrameOrigin(NSPoint(x:view.frame.minX+theme.pagingOffset, y:view.frame.minY))
    view.textView.setBoundsOrigin(.zero)
    if let rect = captionOnScreen {
      preview.frame = rect.offsetBy(dx: -panelRect.minX, dy: -panelRect.minY)
      preview.isHidden = false
    } else { preview.isHidden = true }
    if let layer = contentView!.layer {
      layer.cornerRadius = theme.cornerRadius
      layer.masksToBounds = true
      layer.backgroundColor = captionOnScreen == nil ? nil : theme.backgroundColor.cgColor
    }

    if theme.translucency {
      back.frame = contentView!.bounds
      back.frame.size.width += theme.pagingOffset
      back.appearance = NSApp.effectiveAppearance
      back.isHidden = false
    } else {
      back.isHidden = true
    }
    alphaValue = theme.alpha
    #if LEARNING_TESTS
    alphaValue = 0  // Exercise the real NSPanel and capture its content without overlaying the desktop.
    #endif
    displayIfNeeded()
    invalidateShadow()
    if NSApp.isHidden { NSApp.unhideWithoutActivation() }
    if !isVisible { orderFrontRegardless() }
    // voila!
  }

  func show(status message: String) {
    learningLine = nil
    view.highlightsEnglishDraft = false

    let theme = view.currentTheme
    let text = NSMutableAttributedString(string: message, attributes: theme.attrs)
    text.addAttribute(.paragraphStyle, value: theme.paragraphStyle, range: NSRange(location: 0, length: text.length))
    view.textContentStorage.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: [NSRange(location: 0, length: text.length)], hilightedIndex: -1,
                  preeditRange: .empty, highlightedPreeditRange: .empty, canPageUp: false, canPageDown: false)
    show()

    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: SquirrelTheme.showStatusDuration, repeats: false) { _ in
      self.hide()
    }
  }

  func convert(range: Range<String.Index>, in string: String) -> NSRange {
    let startPos = range.lowerBound.utf16Offset(in: string)
    let endPos = range.upperBound.utf16Offset(in: string)
    return NSRange(location: startPos, length: endPos - startPos)
  }
}
