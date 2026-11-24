// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3

struct LexicalChoice: Equatable, Sendable {
  let text: String
  let hint: String
}

// Each owner has its own read-only connection; dictionary contents stay local.
final class LexicalIndex {
  static let hanYingURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Dictionaries/HanYing3.dictionary/Contents/Resources/LearningSenses.sqlite3")
  static let longmanURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/RimeLearning/Lexicons/Longman.sqlite3")
  private var db: OpaquePointer?
  private var statement: OpaquePointer?

  init?(url: URL) {
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          sqlite3_prepare_v2(db, "SELECT choices FROM lookup WHERE word = ?", -1, &statement, nil) == SQLITE_OK
    else { return nil }
  }

  deinit { sqlite3_finalize(statement); sqlite3_close(db) }

  func choices(for text: String, limit: Int = 3) -> [LexicalChoice] {
    defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
    guard sqlite3_bind_text(statement, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0),
          let rows = try? JSONDecoder().decode([[String]].self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))) else { return [] }
    return rows.prefix(limit).compactMap { $0.count == 2 && !$0[0].isEmpty ? LexicalChoice(text: $0[0], hint: $0[1]) : nil }
  }
}
