// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Only in Squirrel's English mode with learning explicitly enabled. Shift-Space starts a multiword draft.
struct EnglishDraft {
  private(set) var text = ""
  var beganInASCII = true
  private var offset = 0
  var caret: Int { text.prefix(offset).utf16.count }
  // A reading copy only. The editor, caret and ordinary Return always use text.
  var previewText: String { text.split(separator: " ").joined(separator: " ") }
  mutating func insert(_ value: String) {
    text.insert(contentsOf: value, at: text.index(text.startIndex, offsetBy: offset))
    offset += value.count
  }
  mutating func move(_ n: Int) { offset = max(0, min(text.count, offset + n)) }
  mutating func erase(backwards: Bool) {
    let i = backwards ? offset - 1 : offset
    guard i >= 0, i < text.count else { return }
    text.remove(at: text.index(text.startIndex, offsetBy: i))
    if backwards { offset -= 1 }
  }
}
