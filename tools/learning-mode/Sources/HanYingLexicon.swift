// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3

struct EnglishChoice: Equatable, Sendable {
  let english: String
  let hint: String
}

// Only LearningEngine's actor uses this connection. The index belongs to the
// user's .dictionary bundle; no dictionary content travels with the IME.
final class HanYingLexicon {
  static let installedURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Dictionaries/HanYing3.dictionary/Contents/Resources/LearningSenses.sqlite3")
  private var db: OpaquePointer?
  private var statement: OpaquePointer?

  init?(url: URL) {
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          sqlite3_prepare_v2(db, "SELECT choices FROM lookup WHERE word = ?", -1, &statement, nil) == SQLITE_OK
    else { return nil }
  }

  deinit { sqlite3_finalize(statement); sqlite3_close(db) }

  func choices(for text: String) -> [EnglishChoice] {
    defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
    guard sqlite3_bind_text(statement, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0),
          let rows = try? JSONDecoder().decode([[String]].self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))) else { return [] }
    return rows.prefix(3).compactMap { $0.count == 2 && !$0[0].isEmpty ? EnglishChoice(english: $0[0], hint: $0[1]) : nil }
  }
}
