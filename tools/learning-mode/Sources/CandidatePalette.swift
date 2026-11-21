// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum CandidatePalette: String, CaseIterable {
  case jade, mist, amber, graphite
  var title: String {
    switch self { case .jade: "青瓷"; case .mist: "雾蓝"; case .amber: "琥珀"; case .graphite: "石墨" }
  }
  func scheme(dark: Bool) -> String {
    let mode = dark ? "dark" : "light"
    return self == .jade ? mode : rawValue + "_" + mode
  }

  private static let key = "CandidatePalette"
  #if LEARNING_TESTS
  static let defaults = UserDefaults(suiteName: "local.rime.palette-test." + UUID().uuidString)!
  #else
  static let defaults = UserDefaults.standard
  #endif
  static var current: Self {
    get { defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .jade }
    set { defaults.set(newValue.rawValue, forKey: key) }
  }
}

/// A single menu command works with IMK's cross-process menu. Its four choices
/// use native buttons and the same day/night palettes as the candidate panel.
final class PalettePicker: NSPanel {
  private let choose: (CandidatePalette) -> Void
  let tiles: [PaletteTile]
  init(config: SquirrelConfig, choose: @escaping (CandidatePalette) -> Void) {
    self.choose = choose
    tiles = CandidatePalette.allCases.map { PaletteTile(palette: $0, config: config) }
    super.init(contentRect: NSRect(x: 0, y: 0, width: 394, height: 212),
               styleMask: [.titled, .closable], backing: .buffered, defer: false)
    title = "主题"
    collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    isReleasedWhenClosed = false
    isFloatingPanel = true
    hidesOnDeactivate = false
    let content = PaletteBackdrop(frame: contentView!.bounds)
    contentView = content
    for (index, tile) in tiles.enumerated() {
      tile.frame = NSRect(x: 16 + (index % 2) * 187, y: 110 - (index / 2) * 96, width: 175, height: 88)
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
  private let day = SquirrelTheme()
  private let night = SquirrelTheme()
  init(palette: CandidatePalette, config: SquirrelConfig) {
    self.palette = palette
    super.init(frame: .zero)
    day.load(config: config, dark: false, palette: palette)
    night.load(config: config, dark: true, palette: palette)
    title = palette.title
    setButtonType(.momentaryPushIn)
    isBordered = false
    focusRingType = .none
    setAccessibilityLabel(palette.title)
  }
  required init?(coder: NSCoder) { fatalError("Not created from a nib") }
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    let theme = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? night : day
    let sample = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: bounds.width - 2, height: 61), xRadius: 9, yRadius: 9)
    let active = state == .on
    let accent = palette == .graphite ? NSColor.labelColor : (theme.highlightedAttrs[.foregroundColor] as? NSColor ?? .labelColor)
    theme.backgroundColor.setFill(); sample.fill()
    (active || isHighlighted ? accent : NSColor.separatorColor).setStroke()
    sample.lineWidth = active ? 1.5 : 0.75; sample.stroke()
    let chip = NSBezierPath(roundedRect: NSRect(x: 9, y: 8, width: 62, height: 23), xRadius: 7, yRadius: 7)
    theme.highlightedBackColor?.setFill(); chip.fill()
    ("1  春天" as NSString).draw(at: NSPoint(x: 16, y: 9), withAttributes: theme.highlightedAttrs)
    ("2  春田" as NSString).draw(at: NSPoint(x: 81, y: 9), withAttributes: theme.attrs)
    ("spring" as NSString).draw(at: NSPoint(x: 16, y: 34), withAttributes: theme.previewAttrs)
    (palette.title as NSString).draw(at: NSPoint(x: 3, y: 67), withAttributes:
      [.font: NSFont.systemFont(ofSize: 14, weight: active ? .semibold : .regular), .foregroundColor: NSColor.labelColor])
    if active {
      ("✓" as NSString).draw(at: NSPoint(x: bounds.width - 18, y: 66), withAttributes:
        [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor])
    }
  }
}
