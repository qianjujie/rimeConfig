// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum CandidateRows {
  /// Keep the reading order. Use the fewest rows, then the least uneven widths.
  /// For a fixed number of rows, minimizing squared widths minimizes variance.
  static func breaks(widths: [CGFloat], gap: CGFloat, limit: CGFloat) -> IndexSet {
    let n = widths.count
    guard n > 1, widths.reduce(0,+) + CGFloat(n-1)*gap > limit else { return [] }
    var best = Array(repeating:(rows:Int.max, cost:CGFloat.infinity, start:0), count:n+1)
    best[0] = (0,0,0)
    for end in 1...n {
      var width: CGFloat = 0
      for start in (0..<end).reversed() {
        width += widths[start] + (start == end-1 ? 0 : gap)
        // A term wider than the whole window gets a row of its own;
        // TextKit can still wrap the term rather than cutting it off.
        if width > limit && start < end-1 { break }
        let rows = best[start].rows + 1, cost = best[start].cost + width*width
        if rows < best[end].rows || (rows == best[end].rows && cost < best[end].cost) {
          best[end] = (rows,cost,start)
        }
      }
    }
    var breaks = IndexSet(), i = best[n].start
    while i > 0 { breaks.insert(i); i = best[i].start }
    return breaks
  }
}
