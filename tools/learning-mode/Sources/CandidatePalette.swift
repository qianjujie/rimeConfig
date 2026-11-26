// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum CandidateAppearance {
  #if LEARNING_TESTS
  static let defaults = UserDefaults(suiteName: "local.rime.appearance-test." + UUID().uuidString)!
  #else
  static let defaults = UserDefaults.standard
  #endif

  static var popupAnimationEnabled: Bool {
    get { defaults.bool(forKey: "CandidatePopupAnimationEnabled") }
    set { defaults.set(newValue, forKey: "CandidatePopupAnimationEnabled") }
  }
}

enum CandidatePalette: String, CaseIterable {
  case jade, mist, amber, graphite, wechat, controlBlue = "control_blue"
  var title: String {
    switch self { case .jade: "青瓷"; case .mist: "雾蓝"; case .amber: "琥珀"; case .graphite: "石墨"; case .wechat: "翠微"; case .controlBlue: "晴空" }
  }
  func scheme(dark: Bool) -> String {
    let mode = dark ? "dark" : "light"
    return self == .jade ? mode : rawValue + "_" + mode
  }

  private static let key = "CandidatePalette"
  static var current: Self {
    get { CandidateAppearance.defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .jade }
    set { CandidateAppearance.defaults.set(newValue.rawValue, forKey: key) }
  }
}

/// A single menu command works with IMK's cross-process menu. Its choices
/// use native buttons and the same day/night palettes as the candidate panel.
final class PalettePicker: NSPanel {
  private let choose: (CandidatePalette) -> Void
  let tiles: [PaletteTile]
  init(config: SquirrelConfig, choose: @escaping (CandidatePalette) -> Void) {
    self.choose = choose
    tiles = CandidatePalette.allCases.map { PaletteTile(palette: $0, config: config) }
    let rows = (tiles.count + 1) / 2
    let tileWidth = tiles.map(\.sampleSize.width).max()! + 6
    let tileHeight = tiles.map(\.sampleSize.height).max()! + 31
    let gap: CGFloat = 14, margin: CGFloat = 16
    let width = 2 * tileWidth + 2 * margin + gap
    let height = CGFloat(rows) * tileHeight + CGFloat(rows - 1) * gap + 2 * margin
    super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
               styleMask: [.titled, .closable], backing: .buffered, defer: false)
    title = "主题"
    collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    isReleasedWhenClosed = false
    isFloatingPanel = true
    hidesOnDeactivate = false
    let content = PaletteBackdrop(frame: contentView!.bounds)
    contentView = content
    for (index, tile) in tiles.enumerated() {
      tile.frame = NSRect(x: margin + CGFloat(index % 2) * (tileWidth + gap),
                          y: margin + CGFloat(rows - 1 - index / 2) * (tileHeight + gap),
                          width: tileWidth, height: tileHeight)
      tile.target = self
      tile.action = #selector(selectTile(_:))
      content.addSubview(tile)
    }
    for (i, tile) in tiles.enumerated() { tile.nextKeyView = tiles[(i + 1) % tiles.count] }
    center()
  }
  func present() {
    for tile in tiles {
      tile.state = tile.palette == CandidatePalette.current ? .on : .off
      tile.setAccessibilityValue(tile.state == .on ? "已选" : "未选")
      tile.needsDisplay = true
    }
    #if LEARNING_TESTS
    alphaValue = 0
    #endif
    // The IME usually has no active window. Present the requested settings on the
    // display where the menu was clicked, without activating on ordinary typing.
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
      let area = screen.visibleFrame
      setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2))
    }
    #if !LEARNING_TESTS
    NSApp.activate(ignoringOtherApps: true)
    #endif
    makeKeyAndOrderFront(nil)
    orderFrontRegardless()
  }
  @objc private func selectTile(_ tile: PaletteTile) {
    choose(tile.palette)
    orderOut(nil)
  }
  override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

private final class PaletteBackdrop: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }
}

final class PaletteTile: NSButton {
  let palette: CandidatePalette
  private let day: SquirrelTheme
  private let night: SquirrelTheme
  private let daySample: NSView
  private let nightSample: NSView
  private var dark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
  var sampleSize: NSSize {
    NSSize(width: max(daySample.frame.width, nightSample.frame.width),
           height: max(daySample.frame.height, nightSample.frame.height))
  }
  init(palette: CandidatePalette, config: SquirrelConfig) {
    self.palette = palette
    let day = SquirrelTheme(), night = SquirrelTheme()
    day.load(config: config, dark: false, palette: palette)
    night.load(config: config, dark: true, palette: palette)
    self.day = day; self.night = night
    daySample = SquirrelPanel.paletteSample(theme: day)
    nightSample = SquirrelPanel.paletteSample(theme: night)
    super.init(frame: .zero)
    title = palette.title
    setButtonType(.momentaryPushIn)
    isBordered = false
    focusRingType = .none
    for sample in [daySample, nightSample] {
      addSubview(sample)
      sample.setFrameOrigin(NSPoint(x: 3, y: 3))
    }
    updateAppearance()
    setAccessibilityLabel(palette.title)
    setAccessibilityChildren([])
  }
  required init?(coder: NSCoder) { fatalError("Not created from a nib") }
  override var isFlipped: Bool { true }
  // The sample contains a real text view; clicks anywhere still select the theme.
  override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }
  private func updateAppearance() {
    daySample.isHidden = dark
    nightSample.isHidden = !dark
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    let theme = dark ? night : day
    let sample = dark ? nightSample : daySample
    let active = state == .on
    let accent: NSColor = switch palette {
    case .graphite: .labelColor
    case .wechat, .controlBlue: theme.highlightedBackColor ?? .labelColor
    default: theme.highlightedAttrs[.foregroundColor] as? NSColor ?? .labelColor
    }
    let ring = NSBezierPath(roundedRect: sample.frame.insetBy(dx: -1, dy: -1),
                            xRadius: theme.cornerRadius + 1, yRadius: theme.cornerRadius + 1)
    (active || isHighlighted ? accent : NSColor.separatorColor).setStroke()
    ring.lineWidth = active ? 1.5 : 0.75
    ring.stroke()
    let labelY = sampleSize.height + 9
    (palette.title as NSString).draw(at: NSPoint(x: 3, y: labelY), withAttributes:
      [.font: NSFont.systemFont(ofSize: 14, weight: active ? .semibold : .regular), .foregroundColor: NSColor.labelColor])
    if active {
      ("✓" as NSString).draw(at: NSPoint(x: sample.frame.maxX - 13, y: labelY - 1), withAttributes:
        [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor])
    }
  }
}
