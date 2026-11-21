// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreText

extension NSAttributedString {
  /// Offset from the insertion point to the visible left stroke of the first character.
  var leadingInkOffset: CGFloat {
    guard length > 0 else { return 0 }
    let first = (string as NSString).rangeOfComposedCharacterSequence(at: 0)
    let run = CTLineCreateWithAttributedString(attributedSubstring(from: first))
    let ink = CTLineGetBoundsWithOptions(run, .useGlyphPathBounds)
    return ink.isEmpty ? 0 : ink.minX
  }
}

/// A drawing surface inside the candidate panel, not another window or text input.
final class PreviewCaption: NSView {
  private(set) var value = NSAttributedString()
  private let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func setText(_ text: String, theme: SquirrelTheme) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    var attrs = theme.previewAttrs
    attrs[.paragraphStyle] = style
    let next = NSAttributedString(string: text, attributes: attrs)
    if !value.isEqual(to: next) {
      value = next; needsDisplay = true
      setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityValue(text)
    }
  }
  func measure(maxWidth: CGFloat) -> CGSize {
    let size = value.boundingRect(with: CGSize(width:maxWidth,height:.greatestFiniteMagnitude),options:options).size
    return CGSize(width:ceil(size.width),height:ceil(size.height))
  }
  override func draw(_ dirtyRect: NSRect) { value.draw(with:bounds,options:options) }
}
